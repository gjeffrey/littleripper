import Foundation

/// Renames an already-filed movie or TV show after the fact (e.g. when a truncated
/// disc label like "SEXY_SE" produced a wrong name). Renames the media files, their
/// folder, and any backup/ISO to the corrected "Title (Year)" — mirroring the audio
/// "Edit album info" flow. Poster re-fetch is handled by the caller (it's async).
enum VideoLibraryEditor {

    /// Returns the new paths (media + backup) after renaming.
    static func apply(paths: [URL], kind: VideoContentKind, title: String, year: String,
                      moviesRoot: URL, tvRoot: URL) throws -> [URL] {
        let fm = FileManager.default
        let display = year.isEmpty ? title : "\(title) (\(year))"
        let newName = AudioCDRipper.sanitize(display)
        let episodeBase = AudioCDRipper.sanitize(title)

        let existing = paths.filter { fm.fileExists(atPath: $0.path) }
        let media = existing.filter { $0.pathExtension.lowercased() == "mkv" }
        let backups = existing.filter { $0.path.contains("/Backups/") }

        var newPaths: [URL] = []

        if kind == .movie, let folder = topFolder(for: media, under: moviesRoot) {
            // Rename the main feature (the .mkv sitting directly in the movie folder).
            if let main = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey]))?
                .filter({ $0.pathExtension.lowercased() == "mkv" })
                .max(by: { fileSize($0) < fileSize($1) }) {
                let target = folder.appendingPathComponent(newName + ".mkv")
                if main.standardizedFileURL.path != target.standardizedFileURL.path {
                    try? fm.moveItem(at: main, to: AudioCDRipper.uniqueURL(target))
                }
            }
            let newFolder = AudioCDRipper.uniqueURL(moviesRoot.appendingPathComponent(newName))
            if folder.standardizedFileURL.path != newFolder.standardizedFileURL.path {
                try fm.moveItem(at: folder, to: newFolder)
            }
            newPaths += mkvs(in: newFolder)
        } else if kind == .tvShow, let showFolder = topFolder(for: media, under: tvRoot) {
            // Re-prefix each episode file, keeping its SNNENN tag, then rename the show folder.
            let seasonTag = #/S\d{2}E\d{2}/#
            for season in subdirectories(of: showFolder) {
                for ep in mkvs(in: season) {
                    guard let m = try? seasonTag.firstMatch(in: ep.lastPathComponent) else { continue }
                    let target = season.appendingPathComponent("\(episodeBase) - \(String(m.0)).mkv")
                    if ep.standardizedFileURL.path != target.standardizedFileURL.path {
                        try? fm.moveItem(at: ep, to: AudioCDRipper.uniqueURL(target))
                    }
                }
            }
            let newFolder = AudioCDRipper.uniqueURL(tvRoot.appendingPathComponent(newName))
            if showFolder.standardizedFileURL.path != newFolder.standardizedFileURL.path {
                try fm.moveItem(at: showFolder, to: newFolder)
            }
            newPaths += subdirectories(of: newFolder).flatMap { mkvs(in: $0) }
        }

        // Rename the exact-backup folder and/or ISO alongside (Backups/DVD|Blu-ray/…).
        for item in backups {
            let parent = item.deletingLastPathComponent()
            if item.pathExtension.lowercased() == "iso" {
                let dest = AudioCDRipper.uniqueURL(parent.appendingPathComponent(newName + ".iso"))
                try? fm.moveItem(at: item, to: dest)
                newPaths.append(dest)
            } else {
                let dest = AudioCDRipper.uniqueURL(parent.appendingPathComponent(newName))
                if item.standardizedFileURL.path != dest.standardizedFileURL.path {
                    try? fm.moveItem(at: item, to: dest)
                }
                newPaths.append(dest)
            }
        }

        return newPaths.isEmpty ? existing : newPaths
    }

    /// The top-level item folder (directly under `root`) that contains the given files.
    private static func topFolder(for files: [URL], under root: URL) -> URL? {
        for file in files {
            var folder = file.deletingLastPathComponent()
            let rootStd = root.standardizedFileURL.path
            while folder.deletingLastPathComponent().standardizedFileURL.path != rootStd {
                let up = folder.deletingLastPathComponent()
                if up.standardizedFileURL.path == folder.standardizedFileURL.path { break } // reached filesystem root
                if folder.pathComponents.count <= root.pathComponents.count { break }
                folder = up
            }
            if folder.deletingLastPathComponent().standardizedFileURL.path == rootStd { return folder }
        }
        return nil
    }

    private static func mkvs(in folder: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "mkv" }
    }

    private static func subdirectories(of folder: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }

    private static func fileSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }
}
