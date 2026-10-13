import Foundation

/// Rips an audio CD to tagged FLAC + cue sheet + log using cd-paranoia and flac.
/// The result is bit-accurate and burnable back to an identical disc.
struct AudioCDRipper {
    let cdParanoiaPath: String
    let flacPath: String
    let metaflacPath: String
    let lookUpMetadata: Bool
    let downloadArt: Bool
    let musicRoot: URL
    let stagingRoot: URL

    struct Callbacks {
        var onProgress: @Sendable (Double?, String) -> Void
        var onLog: @Sendable (String) -> Void
        var onProcessStart: (ProcessRunner) -> Void
        var onReadyToEject: () -> Void = {}
        /// When set (interactive mode), called if the disc can't be identified so the
        /// user can type album info. Returns the entered metadata, or nil to skip.
        var resolveMetadata: (@Sendable (_ guess: AlbumMetadata, _ reason: String) async -> AlbumMetadata?)? = nil
    }

    struct Result {
        let albumURL: URL
        let needsMetadata: Bool     // true when filed with generic names, awaiting info
    }

    enum AudioRipError: Error, LocalizedError {
        case noTOC(String)
        case trackFailed(Int, String)

        var errorDescription: String? {
            switch self {
            case .noTOC(let detail):
                if detail.localizedCaseInsensitiveContains("busy") {
                    return "The drive was busy — another app (like Music) had the disc open. Close it and try again."
                }
                return "Couldn't read the CD's table of contents (\(detail)). The disc may be dirty or badly scratched."
            case .trackFailed(let n, let detail):
                return "Track \(n) failed to rip: \(detail)"
            }
        }
    }

    func rip(disc: Disc, callbacks: Callbacks) async throws -> Result {
        let cb = callbacks

        // 0. Exclusive access (see [[littleripper-cddafs-unmount]]): unmount before any
        //    cd-paranoia call, or reads fail with "Resource busy".
        _ = try? await runCommand("/usr/sbin/diskutil", ["unmountDisk", disc.devicePath])

        // 1. TOC.
        cb.onProgress(nil, "Reading table of contents")
        let tocResult = try await runCommand(cdParanoiaPath, ["-d", disc.devicePath, "-Q"])
        guard let toc = MusicBrainz.parseTOC(fromParanoiaOutput: tocResult.output) else {
            throw AudioRipError.noTOC(lastLine(of: tocResult.output))
        }
        let discID = toc.musicBrainzDiscID
        cb.onLog("TOC: \(toc.tracks.count) tracks, MusicBrainz disc ID \(discID)")

        // 2. Identify the album.
        var lookup: MBLookupResult = .notFound
        if lookUpMetadata {
            cb.onProgress(nil, "Looking up album on MusicBrainz")
            lookup = await MusicBrainz.lookup(toc: toc)
        }

        // 3. Rip + encode every track to staging (minimal tags; named/titled later).
        let stagingDir = stagingRoot.appendingPathComponent("cd-\(disc.bsdName)-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        var keepStaging = false
        defer { if !keepStaging { try? FileManager.default.removeItem(at: stagingDir) } }

        var logLines: [String] = []
        let total = Double(toc.tracks.count)
        for (i, track) in toc.tracks.enumerated() {
            let base = Double(i) / total
            cb.onProgress(base, "Ripping track \(track.number) of \(toc.tracks.count)")
            let wav = stagingDir.appendingPathComponent(String(format: "track%02d.wav", track.number))
            let ripProc = ProcessRunner(cdParanoiaPath,
                                        ["-d", disc.devicePath, "--never-skip=40", "-q",
                                         "\(track.number)", wav.path])
            cb.onProcessStart(ripProc)
            let expectedBytes = Double(max(track.lengthSectors, 1) * 2352)
            let ripShare = 0.85 / total
            let poller = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    let attrs = try? FileManager.default.attributesOfItem(atPath: wav.path)
                    let size = (attrs?[.size] as? Int) ?? 0
                    cb.onProgress(base + min(Double(size) / expectedBytes, 1.0) * ripShare,
                                  "Ripping track \(track.number) of \(toc.tracks.count)")
                }
            }
            let ripResult = try await ripProc.run { line in cb.onLog(line) }
            poller.cancel()
            guard ripResult.exitCode == 0, FileManager.default.fileExists(atPath: wav.path) else {
                throw AudioRipError.trackFailed(track.number, lastLine(of: ripResult.output))
            }

            cb.onProgress(base + ripShare, "Encoding track \(track.number)")
            let flacOut = stagingDir.appendingPathComponent(String(format: "%02d.flac", track.number))
            let flacArgs = ["--best", "--silent", "--verify",
                            "-T", "TRACKNUMBER=\(track.number)",
                            "-T", "TRACKTOTAL=\(toc.tracks.count)",
                            "-T", "MUSICBRAINZ_DISCID=\(discID)",
                            "-o", flacOut.path, wav.path]
            let encodeResult = try await runCommand(flacPath, flacArgs)
            guard encodeResult.exitCode == 0 else {
                throw AudioRipError.trackFailed(track.number, "FLAC encoding failed: \(lastLine(of: encodeResult.output))")
            }
            try? FileManager.default.removeItem(at: wav)
            logLines.append("Track \(String(format: "%02d", track.number)): ripped securely (cd-paranoia), encoded & verified (FLAC)")
        }

        // 4. Resolve album metadata.
        cb.onProgress(0.9, "Preparing tags")
        var meta = AlbumMetadata.generic(trackCount: toc.tracks.count)
        var needsMetadata = false
        var directArtURL = ""
        switch lookup {
        case .found(let found):
            meta = found
            cb.onLog("MusicBrainz: \(meta.artist) — \(meta.album)\(meta.year.isEmpty ? "" : " (\(meta.year))")")
        case .notFound, .failed:
            let reason: String
            if case .failed(let msg) = lookup { reason = msg }
            else { reason = "This CD isn’t in the MusicBrainz database." }
            cb.onLog("MusicBrainz: \(reason)")

            // Fall back to what macOS/Apple Music already fetched (Gracenote), exposed
            // via the mounted CD's volume name + .aiff track filenames.
            if let apple = await buildFromAppleData(disc: disc) {
                meta = apple.meta
                directArtURL = apple.artURL
                cb.onLog("Used the album info macOS already had: \(meta.artist) — \(meta.album)")
            } else {
                // Audio is safely captured — let the disc go while we sort out naming.
                cb.onReadyToEject()
                if let resolver = cb.resolveMetadata {
                    cb.onProgress(nil, "Waiting for album info")
                    let guess = AlbumMetadata(artist: "", album: Self.cleanAlbum(disc.volumeName) ?? "",
                                              year: "", trackTitles: [:], trackArtists: [:])
                    if let entered = await resolver(guess, reason) {
                        meta = entered
                    } else {
                        meta = uniqueGenericMeta()
                        needsMetadata = true
                    }
                } else {
                    meta = uniqueGenericMeta()
                    needsMetadata = true
                }
            }
        }

        // 5. Album art (best-effort): the direct URL (iTunes) first, then MusicBrainz.
        var artData: Data?
        if downloadArt {
            cb.onProgress(0.92, "Fetching album art")
            if !directArtURL.isEmpty { artData = await MovieLookup.downloadPoster(directArtURL) }
            if artData == nil { artData = await Self.fetchArt(for: meta) }
            cb.onLog(artData == nil ? "Album art: none found" : "Album art: downloaded")
        }

        // 6. Tag, embed art, name, cue.
        cb.onProgress(0.95, "Tagging and naming")
        try Self.applyMetadata(inAlbumDir: stagingDir, meta: meta, discID: discID,
                               artData: artData, metaflacPath: metaflacPath)
        try writeLog(to: stagingDir.appendingPathComponent("Rip Log.txt"),
                     disc: disc, toc: toc, discID: discID, meta: meta, lines: logLines)

        // 7. File it under Music/Artist/Album (Year).
        cb.onProgress(0.98, "Filing in your library")
        let destination = try Self.placeAlbum(stagingDir, meta: meta, musicRoot: musicRoot)
        keepStaging = true   // moved, not deleted
        cb.onProgress(1.0, needsMetadata ? "Filed — needs album info" : "Done")
        return Result(albumURL: destination, needsMetadata: needsMetadata)
    }

    private func uniqueGenericMeta() -> AlbumMetadata {
        var meta = AlbumMetadata.generic(trackCount: 0)
        meta.album = "Unknown Album \(Self.dateStamp())"
        return meta
    }

    /// Builds metadata from what macOS/Gracenote already fetched (album from the CD
    /// volume name, track titles from the .aiff filenames), enriched with artist/year/
    /// art from iTunes. Returns nil when the disc was unrecognized by macOS too.
    private func buildFromAppleData(disc: Disc) async -> (meta: AlbumMetadata, artURL: String)? {
        let album = Self.cleanAlbum(disc.volumeName)
        guard album != nil || !disc.cdTrackTitles.isEmpty else { return nil }

        var meta = AlbumMetadata(artist: "Unknown Artist",
                                 album: album ?? "Unknown Album",
                                 year: "", trackTitles: disc.cdTrackTitles, trackArtists: [:])
        var artURL = ""
        if let hit = await iTunesLookup.album(meta.album, hintTrack: disc.cdTrackTitles[1]) {
            meta.artist = hit.artist
            if album == nil { meta.album = hit.album }
            meta.year = hit.year
            artURL = hit.artworkURL
        }
        // Only worthwhile if we ended up with real track names or a real album title.
        guard !meta.trackTitles.isEmpty || album != nil else { return nil }
        return (meta, artURL)
    }

    /// A real album title from the volume name, or nil for macOS's "Audio CD" placeholder.
    static func cleanAlbum(_ volumeName: String?) -> String? {
        guard let trimmed = volumeName?.trimmingCharacters(in: .whitespaces), !trimmed.isEmpty,
              trimmed.caseInsensitiveCompare("Audio CD") != .orderedSame else { return nil }
        return trimmed
    }

    // MARK: - Reusable metadata application (also used to fix albums after the fact)

    static func fetchArt(for meta: AlbumMetadata) async -> Data? {
        if !meta.releaseMBID.isEmpty {
            if let data = await MusicBrainz.frontCover(releaseMBID: meta.releaseMBID) { return data }
        }
        if !meta.artist.isEmpty && !meta.album.isEmpty && meta.artist != "Unknown Artist" {
            if let mbid = await MusicBrainz.searchRelease(artist: meta.artist, album: meta.album) {
                return await MusicBrainz.frontCover(releaseMBID: mbid)
            }
        }
        return nil
    }

    /// Tags every FLAC in `dir`, embeds art, writes cover.jpg, renames files to
    /// "NN - Title.flac", and rebuilds the cue sheet. Works on a fresh rip or an
    /// already-filed album. Returns the final FLAC URLs.
    @discardableResult
    static func applyMetadata(inAlbumDir dir: URL, meta: AlbumMetadata, discID: String,
                              artData: Data?, metaflacPath: String) throws -> [URL] {
        let fm = FileManager.default
        let flacs = (try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))
            .filter { $0.pathExtension.lowercased() == "flac" }

        // Write cover.jpg for Plex/Jellyfin.
        var artFile: URL?
        if let artData {
            let cover = dir.appendingPathComponent("cover.jpg")
            try? artData.write(to: cover)
            artFile = cover
        }

        // Order by TRACKNUMBER tag (falls back to filename).
        var numbered: [(n: Int, url: URL)] = []
        for flac in flacs {
            let n = readTrackNumber(flac, metaflacPath: metaflacPath)
                ?? Int(flac.deletingPathExtension().lastPathComponent.prefix(2)) ?? 0
            numbered.append((n, flac))
        }
        numbered.sort { $0.n < $1.n }
        let trackTotal = numbered.count

        var finalURLs: [URL] = []
        for (number, url) in numbered {
            let title = meta.trackTitles[number]
                ?? existingTag(url, "TITLE", metaflacPath: metaflacPath)
                ?? "Track \(String(format: "%02d", number))"
            let artist = meta.trackArtists[number] ?? meta.artist

            // Replace tags. (Leave MUSICBRAINZ_DISCID alone unless we have one, so a
            // later manual edit doesn't strip the disc ID captured at rip time.)
            var args = ["--remove-tag=TITLE", "--remove-tag=ARTIST", "--remove-tag=ALBUMARTIST",
                        "--remove-tag=ALBUM", "--remove-tag=DATE", "--remove-tag=TRACKNUMBER",
                        "--remove-tag=TRACKTOTAL",
                        "--set-tag=TITLE=\(title)", "--set-tag=ARTIST=\(artist)",
                        "--set-tag=ALBUMARTIST=\(meta.artist)", "--set-tag=ALBUM=\(meta.album)",
                        "--set-tag=TRACKNUMBER=\(number)", "--set-tag=TRACKTOTAL=\(trackTotal)"]
            if !meta.year.isEmpty { args.append("--set-tag=DATE=\(meta.year)") }
            if !discID.isEmpty {
                args.append("--remove-tag=MUSICBRAINZ_DISCID")
                args.append("--set-tag=MUSICBRAINZ_DISCID=\(discID)")
            }
            // Tag edits are "shorthand" ops and can't be combined with block removal.
            runSync(metaflacPath, args + [url.path])

            // Replace album art in a separate pass (block removal is a "major" op).
            if let artFile {
                runSync(metaflacPath, ["--remove", "--block-type=PICTURE", "--dont-use-padding", url.path])
                runSync(metaflacPath, ["--import-picture-from=3||||\(artFile.path)", url.path])
            }

            // Rename to "NN - Title.flac".
            let newName = sanitize(String(format: "%02d - %@.flac", number, title))
            let newURL = dir.appendingPathComponent(newName)
            if newURL != url {
                try? fm.removeItem(at: newURL)
                try? fm.moveItem(at: url, to: newURL)
                finalURLs.append(fm.fileExists(atPath: newURL.path) ? newURL : url)
            } else {
                finalURLs.append(url)
            }
        }

        try? rebuildCue(inDir: dir, meta: meta, files: finalURLs, metaflacPath: metaflacPath)
        return finalURLs
    }

    /// Moves an album folder to Music/Artist/Album (Year), returning the new location.
    static func placeAlbum(_ dir: URL, meta: AlbumMetadata, musicRoot: URL) throws -> URL {
        let fm = FileManager.default
        let artistDir = musicRoot.appendingPathComponent(sanitize(meta.artist))
        try fm.createDirectory(at: artistDir, withIntermediateDirectories: true)
        let folderName = sanitize(meta.year.isEmpty ? meta.album : "\(meta.album) (\(meta.year))")
        let target = artistDir.appendingPathComponent(folderName)
        if target.standardizedFileURL == dir.standardizedFileURL { return dir }
        let destination = uniqueURL(target)
        try fm.moveItem(at: dir, to: destination)
        return destination
    }

    // MARK: - Small helpers

    private static func readTrackNumber(_ url: URL, metaflacPath: String) -> Int? {
        existingTag(url, "TRACKNUMBER", metaflacPath: metaflacPath).flatMap { Int($0) }
    }

    private static func existingTag(_ url: URL, _ tag: String, metaflacPath: String) -> String? {
        let out = runSync(metaflacPath, ["--show-tag=\(tag)", url.path])
        // Output like "TITLE=So What"
        guard let eq = out.firstIndex(of: "=") else { return nil }
        let value = String(out[out.index(after: eq)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func totalSamples(_ url: URL, metaflacPath: String) -> Int? {
        Int(runSync(metaflacPath, ["--show-total-samples", url.path]).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Rebuilds the cue sheet from the final FLACs' sample counts (44100 Hz, 75 frames/s).
    private static func rebuildCue(inDir dir: URL, meta: AlbumMetadata, files: [URL],
                                   metaflacPath: String) throws {
        let cueName = sanitize("\(meta.artist) - \(meta.album).cue")
        // Remove any stale cue(s).
        if let existing = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for f in existing where f.pathExtension.lowercased() == "cue" {
                try? FileManager.default.removeItem(at: f)
            }
        }
        var cue = "REM COMMENT \"Ripped by Little Ripper (cd-paranoia)\"\n"
        cue += "PERFORMER \"\(meta.artist)\"\n"
        cue += "TITLE \"\(meta.album)\"\n"
        if !meta.year.isEmpty { cue += "REM DATE \(meta.year)\n" }
        var cumulativeFrames = 0
        for (index, url) in files.enumerated() {
            let number = index + 1
            let title = existingTag(url, "TITLE", metaflacPath: metaflacPath) ?? "Track \(number)"
            let artist = existingTag(url, "ARTIST", metaflacPath: metaflacPath) ?? meta.artist
            cue += "FILE \"\(url.lastPathComponent)\" WAVE\n"
            cue += String(format: "  TRACK %02d AUDIO\n", number)
            cue += "    TITLE \"\(title)\"\n"
            cue += "    PERFORMER \"\(artist)\"\n"
            cue += "    INDEX 01 \(framesToMSF(cumulativeFrames))\n"
            if let samples = totalSamples(url, metaflacPath: metaflacPath) {
                cumulativeFrames += samples / 588   // 44100 / 75
            }
        }
        try cue.write(to: dir.appendingPathComponent(cueName), atomically: true, encoding: .utf8)
    }

    private static func framesToMSF(_ frames: Int) -> String {
        let m = frames / (75 * 60)
        let s = (frames / 75) % 60
        let f = frames % 75
        return String(format: "%02d:%02d:%02d", m, s, f)
    }

    private func writeLog(to url: URL, disc: Disc, toc: CDTableOfContents,
                          discID: String, meta: AlbumMetadata, lines: [String]) throws {
        var log = "Little Ripper — audio CD rip log\n"
        log += "Date: \(ISO8601DateFormatter().string(from: Date()))\n"
        log += "Device: \(disc.devicePath)\n"
        log += "Album: \(meta.artist) — \(meta.album)\(meta.year.isEmpty ? "" : " (\(meta.year))")\n"
        log += "MusicBrainz disc ID: \(discID)\n"
        log += "Ripper: cd-paranoia (secure mode, --never-skip=40)\nEncoder: flac --best --verify\n\n"
        log += "Table of contents (sectors):\n"
        for t in toc.tracks {
            log += "  Track \(String(format: "%02d", t.number)): start \(t.startSector), length \(t.lengthSectors)\n"
        }
        log += "  Lead-out: \(toc.leadOutSector)\n\n"
        log += lines.joined(separator: "\n") + "\n"
        try log.write(to: url, atomically: true, encoding: .utf8)
    }

    private func lastLine(of output: String) -> String {
        output.split(separator: "\n").last.map(String.init) ?? "unknown error"
    }

    static func sanitize(_ name: String) -> String {
        var result = name.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: " -")
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return result.isEmpty ? "Untitled" : result
    }

    static func uniqueURL(_ url: URL) -> URL {
        var candidate = url
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = url.deletingLastPathComponent()
                .appendingPathComponent(url.lastPathComponent + " (\(n))")
            n += 1
        }
        return candidate
    }

    private static func dateStamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        return formatter.string(from: Date())
    }
}

/// Runs a short command synchronously and returns combined output. For quick metaflac
/// calls where async streaming isn't needed.
@discardableResult
private func runSync(_ executable: String, _ arguments: [String]) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do {
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    } catch {
        return ""
    }
}
