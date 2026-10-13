import Foundation

enum RipJobKind: String, Codable {
    case audioRip              // FLAC tracks + cue + log (bit-perfect, burnable)
    case videoStream           // makemkvcon mkv: MKV files for Plex/Jellyfin
    case videoBackup           // makemkvcon backup --decrypt: exact disc structure (+ ISO for DVDs)
    case videoArchiveAndStream // both, reading the disc only once

    var displayName: String {
        switch self {
        case .audioRip: return "Rip CD"
        case .videoStream: return "Rip for Plex & Jellyfin"
        case .videoBackup: return "Exact Backup"
        case .videoArchiveAndStream: return "Exact Backup + Plex/Jellyfin"
        }
    }

    var symbolName: String {
        switch self {
        case .audioRip: return "music.note.list"
        case .videoStream: return "play.rectangle.on.rectangle"
        case .videoBackup: return "archivebox"
        case .videoArchiveAndStream: return "square.stack.3d.up"
        }
    }
}

enum RipJobState: Equatable {
    case queued
    case running
    case finishing         // moving/renaming output into the library
    case done
    case failed(String)
    case canceled

    var isTerminal: Bool {
        switch self {
        case .done, .failed, .canceled: return true
        default: return false
        }
    }

    var displayName: String {
        switch self {
        case .queued: return "Waiting"
        case .running: return "Ripping"
        case .finishing: return "Organizing"
        case .done: return "Done"
        case .failed: return "Failed"
        case .canceled: return "Canceled"
        }
    }
}

@MainActor
final class RipJob: ObservableObject, Identifiable {
    let id = UUID()
    let kind: RipJobKind
    let plan: RipPlan
    let createdAt = Date()

    @Published var state: RipJobState = .queued
    @Published var progress: Double? = nil     // 0...1, nil = indeterminate
    @Published var stage: String = "Waiting for the drive"
    @Published var logTail: [String] = []
    @Published var outputPaths: [String] = []
    @Published var startedAt: Date?
    @Published var finishedAt: Date?

    /// True when the album was filed with generic names and still needs album info.
    @Published var needsMetadata: Bool = false
    /// Non-nil while the rip is paused waiting for the user to type album info.
    @Published var metadataPrompt: MetadataPrompt?

    /// Set while the job is running so it can be canceled.
    var cancelHandler: (() -> Void)?
    /// Set while `metadataPrompt` is showing; the UI calls this to submit or skip.
    var metadataResolver: ((AlbumMetadata?) -> Void)?

    init(kind: RipJobKind, plan: RipPlan) {
        self.kind = kind
        self.plan = plan
    }

    var discTitle: String { plan.displayTitle }

    func appendLog(_ line: String) {
        logTail.append(line)
        if logTail.count > 400 { logTail.removeFirst(logTail.count - 400) }
    }

    func cancel() {
        guard !state.isTerminal else { return }
        cancelHandler?()
        state = .canceled
        finishedAt = Date()
        stage = "Canceled"
    }
}

/// A request for album info shown to the user when a CD can't be identified.
struct MetadataPrompt: Identifiable {
    let id = UUID()
    var reason: String
    var artist: String = ""
    var album: String = ""
    var year: String = ""
}

/// A completed job, persisted to disk for the History view.
struct HistoryEntry: Codable, Identifiable {
    var id: UUID
    var title: String
    var discType: DiscType
    var kind: RipJobKind
    var succeeded: Bool
    var detail: String            // error message or output summary
    var outputPaths: [String]
    var startedAt: Date
    var finishedAt: Date
    var needsMetadata: Bool = false
}
