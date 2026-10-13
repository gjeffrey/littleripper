import Foundation

enum DiscType: String, Codable, CaseIterable {
    case audioCD
    case dvdVideo
    case blurayVideo
    case dataDisc
    case unknown

    var displayName: String {
        switch self {
        case .audioCD: return "Audio CD"
        case .dvdVideo: return "DVD"
        case .blurayVideo: return "Blu-ray"
        case .dataDisc: return "Data Disc"
        case .unknown: return "Disc"
        }
    }

    var symbolName: String {
        switch self {
        case .audioCD: return "music.note"
        case .dvdVideo: return "film"
        case .blurayVideo: return "film.stack"
        case .dataDisc: return "externaldrive"
        case .unknown: return "opticaldisc"
        }
    }

    var isVideo: Bool { self == .dvdVideo || self == .blurayVideo }
}

enum VideoContentKind: String, Codable, CaseIterable, Identifiable {
    case movie
    case tvShow

    var id: String { rawValue }
    var displayName: String { self == .movie ? "Movie" : "TV Show" }
}

/// A disc currently present in a drive.
struct Disc: Identifiable, Equatable {
    let bsdName: String           // e.g. "disk4"
    var type: DiscType
    var volumeName: String?       // raw volume label, e.g. "THE_MATRIX"
    var mediaKind: String         // IOKit media class, e.g. "IODVDMedia"
    var trackCount: Int?          // audio CDs, when known
    var insertedAt: Date
    /// Track titles macOS/Gracenote already fetched, read from the mounted audio-CD
    /// volume's .aiff filenames (what Apple Music shows). Empty when unrecognized.
    var cdTrackTitles: [Int: String] = [:]

    var id: String { bsdName }
    var devicePath: String { "/dev/\(bsdName)" }
    var rawDevicePath: String { "/dev/r\(bsdName)" }

    /// A human-friendly guess at the title, derived from the volume label.
    var guessedTitle: String {
        guard var name = volumeName, !name.isEmpty else { return type.displayName }
        name = name.replacingOccurrences(of: "_", with: " ")
        // Strip common disc-label noise.
        for suffix in ["DISC 1", "DISC 2", "DISC1", "DISC2", "D1", "D2", "BD", "DVD"] {
            if name.uppercased().hasSuffix(" " + suffix) {
                name = String(name.dropLast(suffix.count + 1))
            }
        }
        name = name.trimmingCharacters(in: .whitespaces)
        if name == name.uppercased() {
            name = name.capitalized
        }
        return name.isEmpty ? type.displayName : name
    }

    static func == (lhs: Disc, rhs: Disc) -> Bool { lhs.bsdName == rhs.bsdName && lhs.type == rhs.type }
}

/// What the user (or automatic mode) decided to do with a disc.
struct RipPlan {
    var disc: Disc
    var title: String
    var year: String                       // empty when unknown
    var videoKind: VideoContentKind = .movie
    var season: Int = 1
    var firstEpisode: Int = 1
    var makeStreamingCopy: Bool = true     // MKV for Plex/Jellyfin (video) — always true for audio
    var makeArchivalCopy: Bool = true      // decrypted full backup / ISO
    var mainFeatureOnly: Bool = true       // video: only rip the longest title
    var ejectWhenDone: Bool = true
    var posterURL: String = ""             // TMDB poster to save as poster.jpg

    var displayTitle: String {
        year.isEmpty ? title : "\(title) (\(year))"
    }
}
