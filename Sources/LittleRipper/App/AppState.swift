import Foundation
import AppKit

@MainActor
final class AppState: ObservableObject {
    @Published var discs: [Disc] = []                 // discs currently in drives
    @Published var ejecting: Set<String> = []
    @Published var activeBurn: BurnController?         // non-nil while a burn sheet is up

    let settings = SettingsStore.shared
    let tools = ToolLocator()
    let history = HistoryStore()
    let notifier = Notifier()
    lazy var engine = RipEngine(settings: settings, tools: tools, history: history, notifier: notifier)

    private let monitor = DiscMonitor()

    func start() {
        notifier.requestPermission()
        tools.refresh()

        engine.onDiscComplete = { [weak self] bsdName, allSucceeded, plan in
            guard let self else { return }
            // Skip if the disc was already ejected early (e.g. backup+stream single-read).
            let stillPresent = self.discs.contains { $0.bsdName == bsdName }
            if plan.ejectWhenDone && allSucceeded && stillPresent {
                self.eject(bsdName: bsdName)
            }
        }

        engine.onEjectRequested = { [weak self] bsdName in
            self?.eject(bsdName: bsdName)
        }

        monitor.onMediaAppeared = { [weak self] bsdName, mediaKind in
            guard let self else { return }
            Task { await self.handleMediaAppeared(bsdName: bsdName, mediaKind: mediaKind) }
        }
        monitor.onMediaDisappeared = { [weak self] bsdName in
            guard let self else { return }
            self.discs.removeAll { $0.bsdName == bsdName }
            self.ejecting.remove(bsdName)
            // Disc pulled while jobs were waiting — drop them.
            self.engine.cancelJobs(forDisc: bsdName, onlyQueued: true)
        }
        monitor.start()
    }

    private func handleMediaAppeared(bsdName: String, mediaKind: String) async {
        guard !discs.contains(where: { $0.bsdName == bsdName }) else { return }

        // Placeholder while we classify (mounting can take a few seconds).
        var placeholder = Disc(bsdName: bsdName, type: .unknown, volumeName: nil,
                               mediaKind: mediaKind, trackCount: nil, insertedAt: Date())
        placeholder.volumeName = nil
        discs.append(placeholder)

        let disc = await DiscInspector.inspect(bsdName: bsdName, mediaKind: mediaKind)
        guard let idx = discs.firstIndex(where: { $0.bsdName == bsdName }) else { return }  // ejected meanwhile
        discs[idx] = disc

        switch disc.type {
        case .audioCD, .dvdVideo, .blurayVideo:
            if settings.mode == .automatic {
                var plan = defaultPlan(for: disc)
                // Automatic video: name it from TMDB's best match when a key is set.
                if disc.type.isVideo, settings.videoLookupEnabled,
                   let match = await MovieLookup.bestMatch(disc.guessedTitle, apiKey: settings.tmdbAPIKey) {
                    plan.title = match.title
                    plan.year = match.year
                    plan.videoKind = match.kind
                    plan.posterURL = settings.downloadPoster ? match.posterURL : ""
                }
                guard discs.contains(where: { $0.bsdName == bsdName }) else { return }  // ejected during lookup
                engine.enqueue(plan: plan)
            } else {
                notifier.discDetected(title: disc.guessedTitle, type: disc.type, interactive: true)
                NSApp.activate(ignoringOtherApps: false)
            }
        case .dataDisc, .unknown:
            break   // shown in the UI; nothing to rip
        }
    }

    func defaultPlan(for disc: Disc) -> RipPlan {
        var plan = RipPlan(disc: disc, title: disc.guessedTitle, year: "")
        plan.makeStreamingCopy = settings.autoStreamingCopy
        plan.makeArchivalCopy = settings.autoArchivalCopy
        plan.mainFeatureOnly = settings.autoMainFeatureOnly
        plan.ejectWhenDone = settings.autoEject
        return plan
    }

    func eject(bsdName: String) {
        ejecting.insert(bsdName)
        Task {
            _ = try? await runCommand("/usr/sbin/diskutil", ["eject", "/dev/\(bsdName)"])
            ejecting.remove(bsdName)
        }
    }

    func openInXLD(disc: Disc) {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/XLD.app"))
    }

    func revealInFinder(path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// Burns an audio CD copy from a ripped album's folder of FLACs.
    func burnAudioCD(albumPath: String) {
        let folder = URL(fileURLWithPath: albumPath)
        startBurn(files: CDBurner.audioFiles(inFolder: folder), name: folder.lastPathComponent)
    }

    /// Lets the user pick any album folder or .cue on disk and burn it — so you can
    /// burn albums ripped on another machine, not just ones in this machine's History.
    func burnFromPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Burn"
        panel.message = "Choose an album folder or a .cue file to burn to an audio CD"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if url.pathExtension.lowercased() == "cue" {
            startBurn(files: CDBurner.audioFiles(inCue: url), name: url.deletingPathExtension().lastPathComponent)
        } else {
            startBurn(files: CDBurner.audioFiles(inFolder: url), name: url.lastPathComponent)
        }
    }

    private func startBurn(files: [URL], name: String) {
        guard let flac = tools.flac.path else {
            presentAlert("Can't burn", "The FLAC decoder isn't available."); return
        }
        guard !files.isEmpty else {
            presentAlert("Nothing to burn", "No audio files were found there."); return
        }
        let controller = BurnController(albumName: name)
        activeBurn = controller
        controller.start(audioFiles: files, flacPath: flac)
    }

    private func presentAlert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}
