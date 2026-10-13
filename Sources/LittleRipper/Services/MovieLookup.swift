import Foundation

/// A candidate match for a video disc from The Movie Database (TMDB).
struct VideoMatch: Identifiable, Sendable, Hashable {
    let id: Int
    let title: String
    let year: String
    let kind: VideoContentKind
    let posterURL: String
    let overview: String

    var displayTitle: String { year.isEmpty ? title : "\(title) (\(year))" }
}

/// Looks up movie & TV details on TMDB so discs get proper Plex/Jellyfin names and art.
/// Requires the user's free TMDB API key (Settings → Video).
enum MovieLookup {
    static let posterBase = "https://image.tmdb.org/t/p/w500"

    /// Searches movies and TV shows for a disc label, best matches first.
    static func search(_ query: String, apiKey: String) async -> [VideoMatch] {
        let cleaned = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, !apiKey.isEmpty else { return [] }
        async let movies = searchOne(kind: .movie, query: cleaned, apiKey: apiKey)
        async let shows = searchOne(kind: .tvShow, query: cleaned, apiKey: apiKey)
        // Interleave a little so the top TV result isn't buried under many films.
        let m = await movies, t = await shows
        var result: [VideoMatch] = []
        if let first = m.first { result.append(first) }
        if let first = t.first { result.append(first) }
        result.append(contentsOf: m.dropFirst())
        result.append(contentsOf: t.dropFirst())
        return result
    }

    private static func searchOne(kind: VideoContentKind, query: String, apiKey: String) async -> [VideoMatch] {
        let path = kind == .movie ? "movie" : "tv"
        var components = URLComponents(string: "https://api.themoviedb.org/3/search/\(path)")!
        components.queryItems = [
            .init(name: "api_key", value: apiKey),
            .init(name: "query", value: query),
            .init(name: "include_adult", value: "false"),
        ]
        guard let url = components.url,
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]]
        else { return [] }

        return results.prefix(6).compactMap { item in
            guard let id = item["id"] as? Int else { return nil }
            let title = (kind == .movie ? item["title"] : item["name"]) as? String ?? ""
            guard !title.isEmpty else { return nil }
            let dateKey = kind == .movie ? "release_date" : "first_air_date"
            let year = (item[dateKey] as? String).map { String($0.prefix(4)) } ?? ""
            let poster = (item["poster_path"] as? String).map { posterBase + $0 } ?? ""
            return VideoMatch(id: id, title: title, year: year, kind: kind,
                              posterURL: poster, overview: item["overview"] as? String ?? "")
        }
    }

    /// Best single match for automatic mode (movies favored, then TV).
    static func bestMatch(_ query: String, apiKey: String) async -> VideoMatch? {
        await search(query, apiKey: apiKey).first
    }

    static func downloadPoster(_ urlString: String) async -> Data? {
        guard !urlString.isEmpty, let url = URL(string: urlString),
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else { return nil }
        return data
    }
}
