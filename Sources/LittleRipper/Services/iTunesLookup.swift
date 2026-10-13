import Foundation

/// Keyless Apple iTunes Search lookup for *music* albums. Unlike its movie search
/// (which is unreliable), the music catalog is solid — used to fill in the artist and
/// cover art when we already have an album + track titles from the mounted CD.
enum iTunesLookup {
    struct AlbumHit: Sendable {
        let artist: String
        let album: String
        let year: String
        let artworkURL: String
    }

    /// Finds the best album match for a title, optionally biased by a known track name.
    static func album(_ albumTitle: String, hintTrack: String? = nil) async -> AlbumHit? {
        let term = [albumTitle, hintTrack].compactMap { $0 }.joined(separator: " ")
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            .init(name: "term", value: term),
            .init(name: "entity", value: "album"),
            .init(name: "media", value: "music"),
            .init(name: "limit", value: "10"),
        ]
        guard let url = components.url,
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]]
        else { return nil }

        // Prefer a result whose album name matches what macOS gave us.
        let wanted = normalize(albumTitle)
        let best = results.first { normalize($0["collectionName"] as? String ?? "") == wanted }
            ?? results.first { normalize($0["collectionName"] as? String ?? "").contains(wanted) && !wanted.isEmpty }
            ?? results.first
        guard let hit = best,
              let artist = hit["artistName"] as? String,
              let album = hit["collectionName"] as? String else { return nil }

        let year = (hit["releaseDate"] as? String).map { String($0.prefix(4)) } ?? ""
        // Upsize the 100px thumbnail to a decent cover.
        let art = (hit["artworkUrl100"] as? String)?
            .replacingOccurrences(of: "100x100bb", with: "600x600bb") ?? ""
        return AlbumHit(artist: artist, album: album, year: year, artworkURL: art)
    }

    private static func normalize(_ s: String) -> String {
        s.lowercased().trimmingCharacters(in: .whitespaces)
    }
}
