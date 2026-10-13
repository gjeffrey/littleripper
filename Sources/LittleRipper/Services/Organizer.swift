import Foundation

/// Places ripped MKVs into Plex/Jellyfin-friendly folder structures:
///   Movies/Title (Year)/Title (Year).mkv               (+ extras/)
///   TV Shows/Show (Year)/Season 01/Show - S01E01.mkv
enum Organizer {

    static func placeVideoFiles(_ files: [URL], plan: RipPlan,
                                moviesRoot: URL, tvRoot: URL) throws -> [URL] {
        switch plan.videoKind {
        case .movie: return try placeMovie(files, plan: plan, moviesRoot: moviesRoot)
        case .tvShow: return try placeTVShow(files, plan: plan, tvRoot: tvRoot)
        }
    }

    private static func placeMovie(_ files: [URL], plan: RipPlan, moviesRoot: URL) throws -> [URL] {
        let name = AudioCDRipper.sanitize(plan.displayTitle)
        let movieDir = moviesRoot.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: movieDir, withIntermediateDirectories: true)

        // Largest file is the main feature; anything else goes in extras/.
        let sorted = files.sorted { fileSize($0) > fileSize($1) }
        var outputs: [URL] = []

        for (i, file) in sorted.enumerated() {
            if i == 0 {
                let dest = AudioCDRipper.uniqueURL(movieDir.appendingPathComponent(name + ".mkv"))
                try FileManager.default.moveItem(at: file, to: dest)
                outputs.append(dest)
            } else {
                let extras = movieDir.appendingPathComponent("extras")
                try FileManager.default.createDirectory(at: extras, withIntermediateDirectories: true)
                let dest = AudioCDRipper.uniqueURL(extras.appendingPathComponent(file.lastPathComponent))
                try FileManager.default.moveItem(at: file, to: dest)
                outputs.append(dest)
            }
        }
        return outputs
    }

    private static func placeTVShow(_ files: [URL], plan: RipPlan, tvRoot: URL) throws -> [URL] {
        let showName = AudioCDRipper.sanitize(plan.displayTitle)
        let seasonDir = tvRoot
            .appendingPathComponent(showName)
            .appendingPathComponent(String(format: "Season %02d", plan.season))
        try FileManager.default.createDirectory(at: seasonDir, withIntermediateDirectories: true)

        // Disc order (title_t00, title_t01, ...) usually matches episode order.
        let sorted = files.sorted { $0.lastPathComponent < $1.lastPathComponent }
        var episode = plan.firstEpisode
        var outputs: [URL] = []
        for file in sorted {
            let epName = String(format: "%@ - S%02dE%02d.mkv",
                                AudioCDRipper.sanitize(plan.title), plan.season, episode)
            let dest = AudioCDRipper.uniqueURL(seasonDir.appendingPathComponent(epName))
            try FileManager.default.moveItem(at: file, to: dest)
            outputs.append(dest)
            episode += 1
        }
        return outputs
    }

    private static func fileSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }
}
