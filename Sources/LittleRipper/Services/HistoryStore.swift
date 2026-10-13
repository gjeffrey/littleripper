import Foundation

@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var entries: [HistoryEntry] = []

    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Little Ripper")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }()

    init() { load() }

    func record(_ job: RipJob) {
        let succeeded = job.state == .done
        var detail = ""
        if case .failed(let message) = job.state { detail = message }
        if case .canceled = job.state { detail = "Canceled" }
        if succeeded { detail = job.outputPaths.first.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "" }

        entries.insert(HistoryEntry(id: job.id,
                                    title: job.discTitle,
                                    discType: job.plan.disc.type,
                                    kind: job.kind,
                                    succeeded: succeeded,
                                    detail: detail,
                                    outputPaths: job.outputPaths,
                                    startedAt: job.startedAt ?? job.createdAt,
                                    finishedAt: job.finishedAt ?? Date(),
                                    needsMetadata: job.needsMetadata),
                       at: 0)
        if entries.count > 500 { entries.removeLast(entries.count - 500) }
        save()
    }

    /// Updates a video entry after its title was corrected and files/folders renamed.
    func updateVideo(oldFirst: String?, newPaths: [String], title: String) {
        guard let oldFirst else { return }
        for i in entries.indices where entries[i].outputPaths.first == oldFirst {
            entries[i].outputPaths = newPaths
            entries[i].title = title
            if let first = newPaths.first {
                entries[i].detail = (first as NSString).abbreviatingWithTildeInPath
            }
        }
        save()
    }

    /// Updates an entry after its album info was filled in and the folder moved.
    func updateAlbum(oldPath: String, newPath: String, title: String) {
        for i in entries.indices where entries[i].outputPaths.first == oldPath {
            entries[i].outputPaths = [newPath]
            entries[i].title = title
            entries[i].needsMetadata = false
            entries[i].detail = (newPath as NSString).abbreviatingWithTildeInPath
        }
        save()
    }

    func clear() {
        entries.removeAll()
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: data) else { return }
        entries = decoded
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(entries) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
