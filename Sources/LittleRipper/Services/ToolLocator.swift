import Foundation

struct Tool: Identifiable {
    let id: String
    let displayName: String
    let purpose: String
    let installHint: String        // Homebrew command
    let candidates: [String]       // absolute paths to try, in order
    var path: String?              // resolved

    var isInstalled: Bool { path != nil }
}

/// Locates the external backends Little Ripper drives.
@MainActor
final class ToolLocator: ObservableObject {
    @Published var makemkvcon = Tool(
        id: "makemkvcon",
        displayName: "MakeMKV",
        purpose: "DVD & Blu-ray ripping and exact backups",
        installHint: "brew install --cask makemkv",
        candidates: [
            "/Applications/MakeMKV.app/Contents/MacOS/makemkvcon",
            "/opt/homebrew/bin/makemkvcon",
            "/usr/local/bin/makemkvcon",
        ])

    @Published var cdParanoia = Tool(
        id: "cd-paranoia",
        displayName: "cd-paranoia",
        purpose: "Bit-accurate audio CD ripping",
        installHint: "brew install libcdio-paranoia",
        candidates: [
            "/opt/homebrew/bin/cd-paranoia",
            "/usr/local/bin/cd-paranoia",
        ])

    @Published var flac = Tool(
        id: "flac",
        displayName: "FLAC",
        purpose: "Lossless audio encoding & tagging",
        installHint: "brew install flac",
        candidates: [
            "/opt/homebrew/bin/flac",
            "/usr/local/bin/flac",
        ])

    @Published var metaflac = Tool(
        id: "metaflac",
        displayName: "metaflac",
        purpose: "Editing tags & album art on existing FLACs",
        installHint: "brew install flac",
        candidates: [
            "/opt/homebrew/bin/metaflac",
            "/usr/local/bin/metaflac",
        ])

    var allTools: [Tool] { [makemkvcon, cdParanoia, flac, metaflac] }
    var videoReady: Bool { makemkvcon.isInstalled }
    var audioReady: Bool { cdParanoia.isInstalled && flac.isInstalled && metaflac.isInstalled }
    var everythingReady: Bool { videoReady && audioReady }

    /// XLD is optional — offered as a hand-off in interactive mode when present.
    @Published var xldAppPresent = false

    init() { refresh() }

    func refresh() {
        makemkvcon.path = Self.resolve(makemkvcon)
        cdParanoia.path = Self.resolve(cdParanoia)
        flac.path = Self.resolve(flac)
        metaflac.path = Self.resolve(metaflac)
        xldAppPresent = FileManager.default.fileExists(atPath: "/Applications/XLD.app")
    }

    private static func resolve(_ tool: Tool) -> String? {
        // Prefer a copy bundled inside the app (drag-and-drop install, no Homebrew).
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/\(tool.id)").path
        if FileManager.default.isExecutableFile(atPath: bundled) { return bundled }
        return tool.candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
