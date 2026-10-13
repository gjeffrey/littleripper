import Foundation
import AppKit
import DiscRecording

/// Prepares an audio-CD burn from an album's files using Apple's native DiscRecording
/// engine. The burn itself is driven by `BurnController` with our own SwiftUI progress
/// UI — the legacy DiscRecordingUI progress panel doesn't render on modern macOS.
enum CDBurner {
    enum BurnError: LocalizedError {
        case noTracks
        case noBurner
        case decodeFailed(String)

        var errorDescription: String? {
            switch self {
            case .noTracks: return "No audio tracks were found to burn."
            case .noBurner: return "No CD/DVD burner is connected."
            case .decodeFailed(let f): return "Couldn't decode \(f) for burning."
            }
        }
    }

    struct Prepared {
        let burn: DRBurn
        let tracks: [AnyObject]
        let tempDir: URL
    }

    // MARK: - Resolving the file list

    static func audioFiles(inFolder folder: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "flac" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Files listed in a .cue (in order), falling back to the audio next to the cue.
    static func audioFiles(inCue cueURL: URL) -> [URL] {
        let fromCue = cueAudioFiles(cueURL)
        if !fromCue.isEmpty { return fromCue }
        let folder = cueURL.deletingLastPathComponent()
        return ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { ["flac", "wav", "aiff", "aif"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func cueAudioFiles(_ cueURL: URL) -> [URL] {
        let text = (try? String(contentsOf: cueURL, encoding: .utf8))
            ?? (try? String(contentsOf: cueURL, encoding: .isoLatin1)) ?? ""
        let folder = cueURL.deletingLastPathComponent()
        var files: [URL] = []
        for line in text.split(whereSeparator: \.isNewline) {
            guard let m = try? #/^\s*FILE\s+"([^"]+)"/#.firstMatch(in: String(line)) else { continue }
            let url = folder.appendingPathComponent(String(m.1))
            if FileManager.default.fileExists(atPath: url.path) { files.append(url) }
        }
        return files
    }

    // MARK: - Preparing the burn

    /// Decodes FLACs to temp AIFF (WAV/AIFF used as-is), builds Red Book tracks, and
    /// returns a configured (but not-yet-started) DRBurn. Caller starts it and cleans
    /// up `tempDir` when finished.
    static func prepare(audioFiles: [URL], flacPath: String) throws -> Prepared {
        let fm = FileManager.default
        guard !audioFiles.isEmpty else { throw BurnError.noTracks }
        guard let device = (DRDevice.devices() as? [DRDevice])?.first else { throw BurnError.noBurner }

        let temp = fm.temporaryDirectory.appendingPathComponent("lr-burn-\(UUID().uuidString.prefix(8))")
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)

        var tracks: [AnyObject] = []
        for file in audioFiles {
            let source: URL
            if file.pathExtension.lowercased() == "flac" {
                let aiff = temp.appendingPathComponent(file.deletingPathExtension().lastPathComponent + ".aiff")
                let p = Process()
                p.executableURL = URL(fileURLWithPath: flacPath)
                p.arguments = ["-d", "--force-aiff-format", "-s", "-o", aiff.path, file.path]
                try p.run()
                p.waitUntilExit()
                guard p.terminationStatus == 0, fm.fileExists(atPath: aiff.path) else {
                    try? fm.removeItem(at: temp)
                    throw BurnError.decodeFailed(file.lastPathComponent)
                }
                source = aiff
            } else {
                source = file
            }
            if let track = DRAudioTrackCreateWithURL(source as CFURL)?.takeRetainedValue() {
                tracks.append(track)
            }
        }
        guard !tracks.isEmpty else {
            try? fm.removeItem(at: temp)
            throw BurnError.noTracks
        }

        guard let burn = DRBurn(device: device) else {
            try? fm.removeItem(at: temp)
            throw BurnError.noBurner
        }
        var props = (burn.properties() as? [AnyHashable: Any]) ?? [:]
        props[DRBurnVerifyDiscKey] = true
        props[DRBurnCompletionActionKey] = DRBurnCompletionActionEject
        props[DRBurnAppendableKey] = false
        burn.setProperties(props)

        return Prepared(burn: burn, tracks: tracks, tempDir: temp)
    }
}
