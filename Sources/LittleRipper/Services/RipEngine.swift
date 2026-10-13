import Foundation

/// Runs rip jobs serially *within* a drive, but drives run in parallel — so several
/// optical drives can rip at the same time while no single drive is asked to do two
/// things at once.
@MainActor
final class RipEngine: ObservableObject {
    @Published private(set) var jobs: [RipJob] = []

    private let settings: SettingsStore
    private let tools: ToolLocator
    private let history: HistoryStore
    private let notifier: Notifier
    private var busyDrives: Set<String> = []

    /// Called when every job for a disc has finished (for auto-eject).
    var onDiscComplete: ((_ bsdName: String, _ allSucceeded: Bool, _ plan: RipPlan) -> Void)?

    /// Called mid-job when the disc is no longer needed (early eject).
    var onEjectRequested: ((_ bsdName: String) -> Void)?

    init(settings: SettingsStore, tools: ToolLocator, history: HistoryStore, notifier: Notifier) {
        self.settings = settings
        self.tools = tools
        self.history = history
        self.notifier = notifier
    }

    var activeJobs: [RipJob] { jobs.filter { !$0.state.isTerminal } }

    func hasJobs(forDisc bsdName: String) -> Bool {
        jobs.contains { $0.plan.disc.bsdName == bsdName && !$0.state.isTerminal }
    }

    func enqueue(plan: RipPlan) {
        var newJobs: [RipJob] = []
        switch plan.disc.type {
        case .audioCD:
            newJobs.append(RipJob(kind: .audioRip, plan: plan))
        case .dvdVideo, .blurayVideo:
            if plan.makeStreamingCopy && plan.makeArchivalCopy {
                // Both: read the disc once, then make the MKV from the local backup.
                newJobs.append(RipJob(kind: .videoArchiveAndStream, plan: plan))
            } else if plan.makeStreamingCopy {
                newJobs.append(RipJob(kind: .videoStream, plan: plan))
            } else if plan.makeArchivalCopy {
                newJobs.append(RipJob(kind: .videoBackup, plan: plan))
            }
        case .dataDisc, .unknown:
            break
        }
        jobs.append(contentsOf: newJobs)
        processQueue()
    }

    func cancelJobs(forDisc bsdName: String, onlyQueued: Bool = false) {
        for job in jobs where job.plan.disc.bsdName == bsdName && !job.state.isTerminal {
            if onlyQueued && job.state != .queued { continue }
            job.cancel()
        }
    }

    func clearFinished() {
        jobs.removeAll { $0.state.isTerminal }
    }

    /// Corrects an already-filed movie/show: renames files + folder (+ backup/ISO),
    /// re-fetches the poster, and updates history. Returns the new media paths.
    @discardableResult
    func editVideoInfo(paths: [String], kind: VideoContentKind, title: String, year: String,
                       posterURL: String) async -> [String]? {
        let t = title.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        let urls = paths.map { URL(fileURLWithPath: $0) }
        do {
            let newURLs = try VideoLibraryEditor.apply(paths: urls, kind: kind, title: t,
                                                       year: year.trimmingCharacters(in: .whitespaces),
                                                       moviesRoot: settings.moviesURL, tvRoot: settings.tvURL)
            if settings.downloadPoster, !posterURL.isEmpty,
               let mkv = newURLs.first(where: { $0.pathExtension.lowercased() == "mkv" }),
               let data = await MovieLookup.downloadPoster(posterURL) {
                let folder = kind == .tvShow
                    ? mkv.deletingLastPathComponent().deletingLastPathComponent()
                    : mkv.deletingLastPathComponent()
                try? data.write(to: folder.appendingPathComponent("poster.jpg"))
            }
            let display = year.isEmpty ? t : "\(t) (\(year))"
            let newPaths = newURLs.map(\.path)
            for job in jobs where job.outputPaths.first == paths.first { job.outputPaths = newPaths }
            history.updateVideo(oldFirst: paths.first, newPaths: newPaths, title: display)
            return newPaths
        } catch {
            return nil
        }
    }

    /// Applies user-entered album info to an already-filed album: re-tags, renames,
    /// fetches art, and moves it to Music/Artist/Album (Year). Returns the new folder.
    @discardableResult
    func editAlbumInfo(albumFolder: URL, artist: String, album: String, year: String) async -> URL? {
        guard let metaflac = tools.metaflac.path else { return nil }
        let meta = AlbumMetadata(
            artist: artist.trimmingCharacters(in: .whitespaces).isEmpty ? "Unknown Artist" : artist.trimmingCharacters(in: .whitespaces),
            album: album.trimmingCharacters(in: .whitespaces).isEmpty ? "Unknown Album" : album.trimmingCharacters(in: .whitespaces),
            year: year.trimmingCharacters(in: .whitespaces),
            trackTitles: [:], trackArtists: [:])
        let art = settings.downloadAlbumArt ? await AudioCDRipper.fetchArt(for: meta) : nil
        do {
            try AudioCDRipper.applyMetadata(inAlbumDir: albumFolder, meta: meta, discID: "",
                                            artData: art, metaflacPath: metaflac)
            let newURL = try AudioCDRipper.placeAlbum(albumFolder, meta: meta, musicRoot: settings.musicURL)
            // Reflect the change in any live job and in history.
            for job in jobs where job.outputPaths.first == albumFolder.path {
                job.outputPaths = [newURL.path]
                job.needsMetadata = false
            }
            history.updateAlbum(oldPath: albumFolder.path, newPath: newURL.path,
                                title: meta.year.isEmpty ? meta.album : "\(meta.album) (\(meta.year))")
            return newURL
        } catch {
            return nil
        }
    }

    /// Starts the next queued job on every drive that isn't already busy.
    /// Jobs on the same drive stay serialized; different drives run concurrently.
    private func processQueue() {
        let queued = jobs.filter { $0.state == .queued }
        var started = busyDrives
        for job in queued {
            let drive = job.plan.disc.bsdName
            guard !started.contains(drive) else { continue }  // one in-flight job per drive
            started.insert(drive)
            busyDrives.insert(drive)
            Task {
                await run(job)
                busyDrives.remove(drive)
                checkDiscCompletion(for: job)
                processQueue()   // pull this drive's next job (or newly-idle drives)
            }
        }
    }

    private func run(_ job: RipJob) async {
        guard job.state == .queued else { return }
        job.state = .running
        job.startedAt = Date()
        job.stage = "Starting"

        do {
            try ensureLibraryFolders()
            let outputs: [URL]
            switch job.kind {
            case .audioRip:
                outputs = try await runAudio(job)
            case .videoStream:
                let ripper = try videoRipper()
                outputs = try await ripper.ripForStreaming(disc: job.plan.disc, plan: job.plan,
                                                           callbacks: callbacks(for: job))
            case .videoBackup:
                let ripper = try videoRipper()
                outputs = try await ripper.ripBackup(disc: job.plan.disc, plan: job.plan,
                                                     callbacks: callbacks(for: job))
            case .videoArchiveAndStream:
                let ripper = try videoRipper()
                outputs = try await ripper.ripArchiveAndStream(disc: job.plan.disc, plan: job.plan,
                                                               callbacks: callbacks(for: job))
            }
            guard job.state == .running else { return }   // canceled mid-flight
            job.outputPaths = outputs.map(\.path)
            job.state = .done
            job.progress = 1.0
            job.stage = "Done"
        } catch {
            guard job.state == .running else { return }
            job.state = .failed(error.localizedDescription)
            job.stage = "Failed"
            job.appendLog("ERROR: \(error.localizedDescription)")
        }
        job.finishedAt = Date()
        job.cancelHandler = nil
        history.record(job)
    }

    private func runAudio(_ job: RipJob) async throws -> [URL] {
        guard let paranoia = tools.cdParanoia.path, let flac = tools.flac.path,
              let metaflac = tools.metaflac.path else {
            throw ToolMissingError(tools: ["cd-paranoia", "flac"], hint: "brew install libcdio-paranoia flac")
        }
        let ripper = AudioCDRipper(cdParanoiaPath: paranoia,
                                   flacPath: flac,
                                   metaflacPath: metaflac,
                                   lookUpMetadata: settings.lookUpMetadata,
                                   downloadArt: settings.downloadAlbumArt,
                                   musicRoot: settings.musicURL,
                                   stagingRoot: settings.stagingURL)
        var audioCallbacks = AudioCDRipper.Callbacks(
            onProgress: progressHandler(for: job),
            onLog: logHandler(for: job),
            onProcessStart: processStartHandler(for: job))
        let shouldEject = job.plan.ejectWhenDone
        let bsdName = job.plan.disc.bsdName
        audioCallbacks.onReadyToEject = { [weak self] in
            guard shouldEject else { return }
            Task { @MainActor in self?.onEjectRequested?(bsdName) }
        }
        // Only ask interactively; automatic mode flags the album to fix later.
        if settings.mode == .interactive {
            audioCallbacks.resolveMetadata = { [weak self] guess, reason in
                await self?.promptForMetadata(job: job, guess: guess, reason: reason) ?? nil
            }
        }
        let result = try await ripper.rip(disc: job.plan.disc, callbacks: audioCallbacks)
        job.needsMetadata = result.needsMetadata
        return [result.albumURL]
    }

    /// Bridges the ripper's metadata request to the UI: publishes a prompt on the job
    /// and suspends until the user submits (or skips).
    private func promptForMetadata(job: RipJob, guess: AlbumMetadata, reason: String) async -> AlbumMetadata? {
        await withCheckedContinuation { continuation in
            job.metadataPrompt = MetadataPrompt(reason: reason, artist: guess.artist,
                                                album: guess.album, year: guess.year)
            job.metadataResolver = { result in
                job.metadataPrompt = nil
                job.metadataResolver = nil
                continuation.resume(returning: result)
            }
        }
    }

    private func videoRipper() throws -> VideoDiscRipper {
        guard let makemkvPath = tools.makemkvcon.path else {
            throw ToolMissingError(tools: ["MakeMKV"], hint: "brew install --cask makemkv")
        }
        return VideoDiscRipper(
            makemkv: MakeMKV(binary: makemkvPath),
            settings: .init(moviesRoot: settings.moviesURL,
                            tvRoot: settings.tvURL,
                            backupsRoot: settings.backupsURL,
                            stagingRoot: settings.stagingURL,
                            minTitleMinutes: settings.minTitleMinutes,
                            makeDVDISO: settings.makeDVDISO))
    }

    private func callbacks(for job: RipJob) -> VideoDiscRipper.Callbacks {
        let shouldEject = job.plan.ejectWhenDone
        let bsdName = job.plan.disc.bsdName
        return VideoDiscRipper.Callbacks(
            onProgress: progressHandler(for: job),
            onLog: logHandler(for: job),
            onProcessStart: processStartHandler(for: job),
            onReadyToEject: { [weak self] in
                guard shouldEject else { return }
                Task { @MainActor in self?.onEjectRequested?(bsdName) }
            })
    }

    private func progressHandler(for job: RipJob) -> @Sendable (Double?, String) -> Void {
        { progress, stage in
            Task { @MainActor in
                guard !job.state.isTerminal else { return }
                if let progress { job.progress = min(max(progress, 0), 1) }
                if !stage.isEmpty { job.stage = stage }
            }
        }
    }

    private func logHandler(for job: RipJob) -> @Sendable (String) -> Void {
        { line in
            Task { @MainActor in job.appendLog(line) }
        }
    }

    private func processStartHandler(for job: RipJob) -> (ProcessRunner) -> Void {
        { runner in
            Task { @MainActor in
                job.cancelHandler = { runner.terminate() }
            }
        }
    }

    private func checkDiscCompletion(for job: RipJob) {
        let bsdName = job.plan.disc.bsdName
        guard !hasJobs(forDisc: bsdName) else { return }
        let discJobs = jobs.filter { $0.plan.disc.bsdName == bsdName }
        let allSucceeded = discJobs.allSatisfy { $0.state == .done }
        notifier.discFinished(title: job.plan.displayTitle, succeeded: allSucceeded,
                              enabled: settings.notifyWhenDone)
        onDiscComplete?(bsdName, allSucceeded, job.plan)
    }

    private func ensureLibraryFolders() throws {
        let fm = FileManager.default
        for url in [settings.libraryURL, settings.moviesURL, settings.tvURL,
                    settings.musicURL, settings.backupsURL, settings.stagingURL] {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
}

struct ToolMissingError: Error, LocalizedError {
    let tools: [String]
    let hint: String

    var errorDescription: String? {
        "\(tools.joined(separator: " and ")) not installed. Install with: \(hint)"
    }
}
