import Foundation

/// DVD / Blu-ray ripping via makemkvcon: Plex/Jellyfin MKVs and exact decrypted backups.
struct VideoDiscRipper {
    let makemkv: MakeMKV
    let settings: VideoSettings

    struct VideoSettings {
        let moviesRoot: URL
        let tvRoot: URL
        let backupsRoot: URL
        let stagingRoot: URL
        let minTitleMinutes: Int
        let makeDVDISO: Bool
    }

    struct Callbacks {
        var onProgress: @Sendable (Double?, String) -> Void
        var onLog: @Sendable (String) -> Void
        var onProcessStart: (ProcessRunner) -> Void
        /// Called once the disc is no longer needed (backup done & verified), so the
        /// engine can eject it early while the MKV is made from the local copy.
        var onReadyToEject: () -> Void = {}
    }

    enum VideoRipError: Error, LocalizedError {
        case noTitles
        case nothingProduced

        var errorDescription: String? {
            switch self {
            case .noTitles:
                return "MakeMKV couldn't find any video titles long enough to rip on this disc."
            case .nothingProduced:
                return "The rip finished but produced no files."
            }
        }
    }

    // MARK: - Streaming copy only (MKV for Plex & Jellyfin)

    func ripForStreaming(disc: Disc, plan: RipPlan, callbacks cb: Callbacks) async throws -> [URL] {
        cb.onProgress(nil, "Finding the disc in MakeMKV")
        let (source, titles) = try await resolveSource(for: disc, cb: cb)

        let mkvStaging = makeStagingDir("mkv", disc: disc)
        defer { try? FileManager.default.removeItem(at: mkvStaging) }
        let mkvs = try await makeMKV(from: source, disc: disc, plan: plan, outputDir: mkvStaging,
                                     progressStart: 0, progressEnd: 0.98, stagePrefix: "",
                                     knownTitles: titles, cb: cb)
        cb.onProgress(0.99, "Organizing for Plex & Jellyfin")
        let outputs = try Organizer.placeVideoFiles(mkvs, plan: plan,
                                                    moviesRoot: settings.moviesRoot, tvRoot: settings.tvRoot)
        await savePoster(plan: plan, mediaFiles: outputs, cb: cb)
        return outputs
    }

    /// Saves the TMDB poster as poster.jpg in the movie/show folder (Plex & Jellyfin read it).
    private func savePoster(plan: RipPlan, mediaFiles: [URL], cb: Callbacks) async {
        guard !plan.posterURL.isEmpty, let primary = mediaFiles.first else { return }
        // Movie: file sits in the movie folder. TV: episode sits in Season NN/ — go up
        // to the show folder so the poster covers the whole series.
        let folder = plan.videoKind == .tvShow
            ? primary.deletingLastPathComponent().deletingLastPathComponent()
            : primary.deletingLastPathComponent()
        guard let data = await MovieLookup.downloadPoster(plan.posterURL) else { return }
        try? data.write(to: folder.appendingPathComponent("poster.jpg"))
        cb.onLog("Saved poster.jpg")
    }

    // MARK: - Exact backup only

    func ripBackup(disc: Disc, plan: RipPlan, callbacks cb: Callbacks) async throws -> [URL] {
        cb.onProgress(nil, "Finding the disc in MakeMKV")
        let (source, _) = try await resolveSource(for: disc, cb: cb)

        let staging = makeStagingDir("backup", disc: disc)
        defer { try? FileManager.default.removeItem(at: staging) }

        let isoShare = disc.type == .dvdVideo && settings.makeDVDISO
        try await makemkv.backup(source: source, outputDir: staging,
                                 onStart: cb.onProcessStart) { progress, stage in
            if progress >= 0 { cb.onProgress(progress * (isoShare ? 0.85 : 0.95), stage) }
            else { cb.onProgress(nil, stage) }
        }
        try requireNonEmpty(staging)
        return try await finalizeBackup(staging: staging, disc: disc, plan: plan,
                                        progressStart: isoShare ? 0.85 : 0.95, cb: cb)
    }

    // MARK: - Both, with a single disc read

    /// Reads the disc exactly once (the backup), then makes the Plex/Jellyfin MKV from
    /// that local copy — ejecting the disc as soon as the backup is verified.
    func ripArchiveAndStream(disc: Disc, plan: RipPlan, callbacks cb: Callbacks) async throws -> [URL] {
        cb.onProgress(nil, "Finding the disc in MakeMKV")
        let (driveSource, _) = try await resolveSource(for: disc, cb: cb)

        // 1. The only pass that touches the disc. (0 → 0.5)
        let backupStaging = makeStagingDir("backup", disc: disc)
        defer { try? FileManager.default.removeItem(at: backupStaging) }
        try await makemkv.backup(source: driveSource, outputDir: backupStaging,
                                 onStart: cb.onProcessStart) { progress, stage in
            if progress >= 0 { cb.onProgress(progress * 0.5, "Backing up disc — \(stage)") }
            else { cb.onProgress(nil, "Backing up disc") }
        }
        try requireNonEmpty(backupStaging)

        // 2. Confirm the backup works as an MKV source, then release the disc.
        cb.onProgress(nil, "Verifying backup")
        let backupSource = "file:\(backupStaging.path)"
        let backupTitles = (try? await makemkv.titles(source: backupSource)) ?? []
        let source: String
        if !backupTitles.isEmpty {
            source = backupSource
            cb.onLog("Backup verified — the disc can eject now; the Plex/Jellyfin copy is made from the local backup.")
            cb.onReadyToEject()
        } else {
            // Backup isn't usable as a source — fall back to a second disc read.
            source = driveSource
            cb.onLog("Couldn't read the backup as a source; falling back to a second disc read for the MKV.")
        }

        // 3. MKV from the local backup. (0.5 → 0.9)
        let mkvStaging = makeStagingDir("mkv", disc: disc)
        defer { try? FileManager.default.removeItem(at: mkvStaging) }
        let mkvs = try await makeMKV(from: source, disc: disc, plan: plan, outputDir: mkvStaging,
                                     progressStart: 0.5, progressEnd: 0.9,
                                     stagePrefix: "Plex/Jellyfin copy — ",
                                     knownTitles: source == backupSource ? backupTitles : nil, cb: cb)

        // 4. Finalize both deliverables. (0.9 → 1.0)
        cb.onProgress(0.9, "Organizing for Plex & Jellyfin")
        var outputs = try Organizer.placeVideoFiles(mkvs, plan: plan,
                                                    moviesRoot: settings.moviesRoot, tvRoot: settings.tvRoot)
        await savePoster(plan: plan, mediaFiles: outputs, cb: cb)
        outputs += try await finalizeBackup(staging: backupStaging, disc: disc, plan: plan,
                                            progressStart: 0.94, cb: cb)
        cb.onProgress(1.0, "Done")
        return outputs
    }

    // MARK: - Shared steps

    /// Resolves the MakeMKV source (the standard `disc:index`) and the disc's titles in
    /// one place, so the rip reuses them instead of re-scanning. Note: MakeMKV opens and
    /// briefly reads every connected drive on any operation — that enumeration is
    /// unavoidable via makemkvcon, so a rip may momentarily touch another busy drive.
    /// It does not deep-scan the other disc, and both rips complete correctly.
    private func resolveSource(for disc: Disc, cb: Callbacks) async throws -> (String, [MakeMKV.TitleInfo]) {
        let index = try await makemkv.discIndex(forBSDName: disc.bsdName)
        let titles = try await makemkv.titles(source: "disc:\(index)")
        return ("disc:\(index)", titles)
    }

    /// Rips the main feature (or all titles) from a source into `outputDir` and returns
    /// the produced MKV URLs. Progress is mapped into [progressStart, progressEnd].
    /// The caller owns `outputDir`'s lifecycle.
    private func makeMKV(from source: String, disc: Disc, plan: RipPlan, outputDir: URL,
                         progressStart: Double, progressEnd: Double, stagePrefix: String,
                         knownTitles: [MakeMKV.TitleInfo]? = nil,
                         cb: Callbacks) async throws -> [URL] {
        var titleSelector = "all"
        if plan.mainFeatureOnly {
            let titles: [MakeMKV.TitleInfo]
            if let knownTitles { titles = knownTitles }
            else {
                cb.onProgress(nil, "\(stagePrefix)Scanning titles")
                titles = try await makemkv.titles(source: source) { line in
                    if line.hasPrefix("MSG:") { cb.onLog(line) }
                }
            }
            guard let main = titles.max(by: { $0.durationSeconds < $1.durationSeconds }),
                  main.durationSeconds > 0 else {
                throw VideoRipError.noTitles
            }
            titleSelector = String(main.id)
            cb.onLog("Main feature: title \(main.id), \(main.durationSeconds / 60) min, \(main.chapters) chapters")
        }

        let span = progressEnd - progressStart
        try await makemkv.ripToMKV(source: source, title: titleSelector,
                                   minLengthSeconds: settings.minTitleMinutes * 60,
                                   outputDir: outputDir, onStart: cb.onProcessStart) { progress, stage in
            if progress >= 0 { cb.onProgress(progressStart + progress * span, "\(stagePrefix)\(stage)") }
            else { cb.onProgress(nil, "\(stagePrefix)\(stage)") }
        }

        let produced = (try? FileManager.default.contentsOfDirectory(at: outputDir, includingPropertiesForKeys: [.fileSizeKey]))?
            .filter { $0.pathExtension.lowercased() == "mkv" } ?? []
        guard !produced.isEmpty else { throw VideoRipError.nothingProduced }
        return produced
    }

    /// Builds the DVD ISO (when applicable) and moves the decrypted backup into the
    /// library. `staging` is consumed (moved). Progress is mapped into [progressStart, 1].
    private func finalizeBackup(staging: URL, disc: Disc, plan: RipPlan,
                                progressStart: Double, cb: Callbacks) async throws -> [URL] {
        let backupName = AudioCDRipper.sanitize(plan.displayTitle)
        let kindFolder = disc.type == .blurayVideo ? "Blu-ray" : "DVD"
        let destRoot = settings.backupsRoot.appendingPathComponent(kindFolder)
        try FileManager.default.createDirectory(at: destRoot, withIntermediateDirectories: true)
        let destination = AudioCDRipper.uniqueURL(destRoot.appendingPathComponent(backupName))

        var outputs: [URL] = []

        // DVDs: also produce a burnable ISO from the decrypted VIDEO_TS.
        if disc.type == .dvdVideo && settings.makeDVDISO {
            cb.onProgress(progressStart, "Building ISO image")
            let iso = AudioCDRipper.uniqueURL(destRoot.appendingPathComponent(backupName + ".iso"))
            let volumeName = (disc.volumeName ?? backupName)
                .uppercased()
                .replacingOccurrences(of: " ", with: "_")
                .prefix(30)
            let result = try await runCommand("/usr/bin/hdiutil",
                ["makehybrid", "-udf", "-udf-volume-name", String(volumeName),
                 "-o", iso.path, staging.path])
            if result.exitCode == 0 {
                outputs.append(iso)
                cb.onLog("ISO written: \(iso.lastPathComponent)")
            } else {
                cb.onLog("ISO creation failed (keeping folder backup): \(result.output.suffix(200))")
            }
        }

        cb.onProgress(nil, "Moving backup into the library")
        try FileManager.default.moveItem(at: staging, to: destination)
        outputs.insert(destination, at: 0)
        return outputs
    }

    private func makeStagingDir(_ prefix: String, disc: Disc) -> URL {
        let dir = settings.stagingRoot
            .appendingPathComponent("\(prefix)-\(disc.bsdName)-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func requireNonEmpty(_ dir: URL) throws {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        if contents.isEmpty { throw VideoRipError.nothingProduced }
    }
}
