import Foundation
import CryptoKit

struct CDTableOfContents {
    struct Track {
        let number: Int
        let startSector: Int   // absolute LBA, not including the 150-sector lead-in
        let lengthSectors: Int
    }
    let tracks: [Track]
    let leadOutSector: Int     // LBA of lead-out

    /// MusicBrainz Disc ID: SHA-1 over first/last track numbers and 99 frame offsets.
    var musicBrainzDiscID: String {
        guard let first = tracks.first, let last = tracks.last else { return "" }
        var input = String(format: "%02X%02X", first.number, last.number)
        var offsets = [Int](repeating: 0, count: 100)
        offsets[0] = leadOutSector + 150
        for track in tracks where track.number <= 99 {
            offsets[track.number] = track.startSector + 150
        }
        for i in 0..<100 {
            input += String(format: "%08X", offsets[i])
        }
        let digest = Insecure.SHA1.hash(data: Data(input.utf8))
        let base64 = Data(digest).base64EncodedString()
        return base64
            .replacingOccurrences(of: "+", with: ".")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "-")
    }
}

struct AlbumMetadata: Sendable {
    var artist: String
    var album: String
    var year: String            // "" when unknown
    var trackTitles: [Int: String]  // track number -> title
    var trackArtists: [Int: String]
    var releaseMBID: String = ""    // MusicBrainz release ID, for cover art

    static func generic(trackCount: Int) -> AlbumMetadata {
        AlbumMetadata(artist: "Unknown Artist", album: "Unknown Album",
                      year: "", trackTitles: [:], trackArtists: [:])
    }
}

/// Outcome of a MusicBrainz lookup — distinguishes "no match" from a network error
/// so the UI can say which happened.
enum MBLookupResult: Sendable {
    case found(AlbumMetadata)
    case notFound
    case failed(String)
}

enum MusicBrainz {

    /// Parses `cd-paranoia -Q` output into a TOC.
    ///
    /// Expected shape:
    /// ```
    /// track        length               begin        copy pre ch
    /// ===========================================================
    ///   1.    16448 [03:39.23]        0 [00:00.00]    no   no  2
    /// ...
    /// TOTAL  226372 [50:18.22]    (audio only)
    /// ```
    static func parseTOC(fromParanoiaOutput output: String) -> CDTableOfContents? {
        var tracks: [CDTableOfContents.Track] = []
        var total: Int?
        let trackRegex = #/^\s*(\d+)\.\s+(\d+)\s+\[[0-9:.]+\]\s+(\d+)\s+\[/#
        let totalRegex = #/^TOTAL\s+(\d+)\s+/#
        for line in output.split(separator: "\n") {
            if let m = try? trackRegex.firstMatch(in: String(line)) {
                tracks.append(.init(number: Int(m.1) ?? 0,
                                    startSector: Int(m.3) ?? 0,
                                    lengthSectors: Int(m.2) ?? 0))
            } else if let m = try? totalRegex.firstMatch(in: String(line)) {
                total = Int(m.1)
            }
        }
        guard !tracks.isEmpty else { return nil }
        let leadOut = total.map { $0 + (tracks.first?.startSector ?? 0) }
            ?? (tracks.last!.startSector + tracks.last!.lengthSectors)
        return CDTableOfContents(tracks: tracks, leadOutSector: leadOut)
    }

    /// Looks the disc up on MusicBrainz, distinguishing no-match from network failure.
    static func lookup(toc: CDTableOfContents) async -> MBLookupResult {
        let discID = toc.musicBrainzDiscID
        guard !discID.isEmpty,
              let url = URL(string: "https://musicbrainz.org/ws/2/discid/\(discID)?inc=recordings+artist-credits&fmt=json")
        else { return .notFound }

        guard let (data, status) = await throttledFetch(url) else {
            return .failed("Couldn't reach MusicBrainz.")
        }
        // 404 for a disc ID means "this exact disc isn't in the database" — a real no-match.
        if status == 404 { return .notFound }
        guard status == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failed("MusicBrainz returned status \(status).")
        }
        guard let releases = json["releases"] as? [[String: Any]], let release = releases.first else {
            return .notFound
        }

        var meta = AlbumMetadata.generic(trackCount: toc.tracks.count)
        meta.releaseMBID = release["id"] as? String ?? ""
        meta.album = release["title"] as? String ?? meta.album
        if let date = release["date"] as? String, date.count >= 4 {
            meta.year = String(date.prefix(4))
        }
        if let credits = release["artist-credit"] as? [[String: Any]] {
            meta.artist = joinedArtistCredit(credits) ?? meta.artist
        }

        // Find the medium matching this disc's track count (multi-disc releases).
        if let media = release["media"] as? [[String: Any]] {
            let medium = media.first { ($0["tracks"] as? [[String: Any]])?.count == toc.tracks.count }
                ?? media.first
            if let tracks = medium?["tracks"] as? [[String: Any]] {
                for track in tracks {
                    guard let position = track["position"] as? Int else { continue }
                    if let title = track["title"] as? String {
                        meta.trackTitles[position] = title
                    }
                    if let recording = track["recording"] as? [String: Any],
                       let credits = recording["artist-credit"] as? [[String: Any]],
                       let artist = joinedArtistCredit(credits) {
                        meta.trackArtists[position] = artist
                    }
                }
            }
        }
        return .found(meta)
    }

    /// Front cover art (JPEG data) from the Cover Art Archive for a release, or nil.
    static func frontCover(releaseMBID: String) async -> Data? {
        guard !releaseMBID.isEmpty,
              let url = URL(string: "https://coverartarchive.org/release/\(releaseMBID)/front-500")
        else { return nil }
        guard let (data, response) = try? await URLSession.shared.data(for: request(url)),
              (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else { return nil }
        return data
    }

    /// Best-effort release MBID from a free-text artist/album search — used to find
    /// cover art after the user types album info manually (no disc-ID match).
    static func searchRelease(artist: String, album: String) async -> String? {
        var components = URLComponents(string: "https://musicbrainz.org/ws/2/release/")!
        let query = "release:\"\(album)\" AND artist:\"\(artist)\""
        components.queryItems = [.init(name: "query", value: query),
                                 .init(name: "limit", value: "1"),
                                 .init(name: "fmt", value: "json")]
        guard let url = components.url,
              let (data, status) = await throttledFetch(url), status == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let releases = json["releases"] as? [[String: Any]],
              let mbid = releases.first?["id"] as? String
        else { return nil }
        return mbid
    }

    private static func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("LittleRipper/1.0 (https://github.com/littleripper)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        return request
    }

    /// Fetches a musicbrainz.org URL through the shared rate limiter, retrying on 503
    /// (MusicBrainz's "too many requests"). Returns (data, statusCode) or nil on a
    /// connection error. This is what makes concurrent CD rips each get their metadata.
    private static func throttledFetch(_ url: URL, retries: Int = 3) async -> (Data, Int)? {
        for attempt in 0...retries {
            await MusicBrainzThrottle.shared.reserveSlot()
            do {
                let (data, response) = try await URLSession.shared.data(for: request(url))
                guard let http = response as? HTTPURLResponse else { return nil }
                if (http.statusCode == 503 || http.statusCode == 429), attempt < retries {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)   // rate limited — back off
                    continue
                }
                return (data, http.statusCode)
            } catch {
                if attempt < retries {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)   // transient network blip
                    continue
                }
                return nil
            }
        }
        return nil
    }

    private static func joinedArtistCredit(_ credits: [[String: Any]]) -> String? {
        var result = ""
        for credit in credits {
            if let artist = credit["artist"] as? [String: Any], let name = artist["name"] as? String {
                result += name
            } else if let name = credit["name"] as? String {
                result += name
            }
            if let join = credit["joinphrase"] as? String {
                result += join
            }
        }
        return result.isEmpty ? nil : result
    }
}

/// Serializes MusicBrainz requests to honor its ~1 req/sec limit, even when several
/// discs are ripping at once. Each caller reserves the next free time slot, so two
/// concurrent lookups run ~1.1s apart instead of colliding into a 503.
actor MusicBrainzThrottle {
    static let shared = MusicBrainzThrottle()
    private var nextAllowed = Date.distantPast
    private let spacing: TimeInterval = 1.1

    func reserveSlot() async {
        let now = Date()
        let slot = max(now, nextAllowed)
        nextAllowed = slot.addingTimeInterval(spacing)
        let delay = slot.timeIntervalSince(now)
        if delay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }
}
