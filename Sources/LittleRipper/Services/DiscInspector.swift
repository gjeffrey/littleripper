import Foundation

/// Figures out what kind of disc just showed up (audio CD, DVD video, Blu-ray, data).
enum DiscInspector {

    /// Waits for the disc to mount (if it's going to) and classifies it.
    static func inspect(bsdName: String, mediaKind: String) async -> Disc {
        var disc = Disc(bsdName: bsdName,
                        type: .unknown,
                        volumeName: nil,
                        mediaKind: mediaKind,
                        trackCount: nil,
                        insertedAt: Date())

        // Give macOS up to ~20s to mount the volume. Audio CDs and encrypted
        // video discs all normally mount (cddafs / UDF / ISO9660).
        for _ in 0..<40 {
            if let mounted = mountedVolume(forWholeDisk: bsdName) {
                disc.volumeName = mounted.name
                switch true {
                case mounted.fsType == "cddafs":
                    disc.type = .audioCD
                    // macOS fetches Gracenote metadata a moment after mount, then renames
                    // the volume/tracks. Wait briefly for the real names to appear.
                    var name = mounted.name
                    var titles = readCDTrackTitles(at: mounted.url)
                    var waited = 0
                    while titles.isEmpty && waited < 16 {   // up to ~8s
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        if let refreshed = mountedVolume(forWholeDisk: bsdName) {
                            name = refreshed.name
                            titles = readCDTrackTitles(at: refreshed.url)
                        }
                        waited += 1
                    }
                    disc.volumeName = name
                    disc.cdTrackTitles = titles
                    disc.trackCount = titles.isEmpty
                        ? countAudioTracks(at: mounted.url) : titles.count
                case FileManager.default.fileExists(atPath: mounted.url.appendingPathComponent("BDMV").path):
                    disc.type = .blurayVideo
                case FileManager.default.fileExists(atPath: mounted.url.appendingPathComponent("VIDEO_TS").path):
                    disc.type = .dvdVideo
                default:
                    disc.type = fallbackType(for: mediaKind, defaultType: .dataDisc)
                }
                return disc
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        // Never mounted — classify from the physical media class.
        disc.type = fallbackType(for: mediaKind, defaultType: .unknown)
        return disc
    }

    private static func fallbackType(for mediaKind: String, defaultType: DiscType) -> DiscType {
        if mediaKind.contains("BDMedia") { return .blurayVideo }
        if mediaKind.contains("DVDMedia") { return .dvdVideo }
        return defaultType
    }

    private struct MountedVolume {
        let url: URL
        let name: String
        let fsType: String
    }

    /// Finds a mounted volume whose backing device is the given whole disk or one of its slices.
    private static func mountedVolume(forWholeDisk bsdName: String) -> MountedVolume? {
        let keys: [URLResourceKey] = [.volumeNameKey]
        guard let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                               options: [.skipHiddenVolumes]) else { return nil }
        for url in urls {
            var st = statfs()
            guard statfs(url.path, &st) == 0 else { continue }
            let device = withUnsafeBytes(of: &st.f_mntfromname) { raw in
                String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
            }
            let fsType = withUnsafeBytes(of: &st.f_fstypename) { raw in
                String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
            }
            // Match /dev/disk4 exactly or its slices (/dev/disk4s0), not /dev/disk40.
            let prefix = "/dev/\(bsdName)"
            guard device == prefix || device.hasPrefix(prefix + "s") else { continue }
            let name = (try? url.resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? url.lastPathComponent
            return MountedVolume(url: url, name: name, fsType: fsType)
        }
        return nil
    }

    private static func countAudioTracks(at volumeURL: URL) -> Int? {
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: volumeURL.path) else { return nil }
        let count = items.filter { $0.lowercased().hasSuffix(".aiff") }.count
        return count > 0 ? count : nil
    }

    /// Reads the track titles macOS fetched from Gracenote, exposed as the mounted
    /// audio-CD volume's .aiff filenames (e.g. "01 So What.aiff" → 1: "So What").
    /// Returns empty when the disc is unrecognized (files named "1 Audio Track.aiff").
    private static func readCDTrackTitles(at volumeURL: URL) -> [Int: String] {
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: volumeURL.path) else { return [:] }
        var titles: [Int: String] = [:]
        let pattern = #/^\s*(\d+)[\s._\-]+(.+?)\s*$/#
        for name in items where name.lowercased().hasSuffix(".aiff") {
            let base = (name as NSString).deletingPathExtension
            guard let m = try? pattern.firstMatch(in: base) else { continue }
            let number = Int(m.1) ?? 0
            let title = String(m.2).trimmingCharacters(in: .whitespaces)
            // Skip macOS's placeholder names for unrecognized discs.
            if title.caseInsensitiveCompare("Audio Track") == .orderedSame { continue }
            if number > 0, !title.isEmpty { titles[number] = title }
        }
        return titles
    }
}
