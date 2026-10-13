import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var history: HistoryStore
    @EnvironmentObject private var app: AppState

    var body: some View {
        Group {
            if history.entries.isEmpty {
                ContentUnavailableView("Nothing Ripped Yet",
                                       systemImage: "clock",
                                       description: Text("Every finished rip is remembered here."))
            } else {
                List {
                    ForEach(groupedByDay, id: \.0) { day, entries in
                        Section(day) {
                            ForEach(entries) { entry in
                                HistoryRow(entry: entry)
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .toolbar {
                    ToolbarItem(placement: .secondaryAction) {
                        Button("Clear History", role: .destructive) { history.clear() }
                    }
                }
            }
        }
    }

    private var groupedByDay: [(String, [HistoryEntry])] {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.doesRelativeDateFormatting = true
        var seen: [String] = []
        var groups: [String: [HistoryEntry]] = [:]
        for entry in history.entries {
            let key = formatter.string(from: entry.finishedAt)
            if groups[key] == nil { seen.append(key) }
            groups[key, default: []].append(entry)
        }
        return seen.map { ($0, groups[$0] ?? []) }
    }
}

struct HistoryRow: View {
    let entry: HistoryEntry
    @EnvironmentObject private var app: AppState

    private var albumPath: String? {
        guard entry.kind == .audioRip, entry.succeeded, let first = entry.outputPaths.first,
              FileManager.default.fileExists(atPath: first) else { return nil }
        return first
    }

    private var isVideo: Bool {
        entry.kind != .audioRip && entry.succeeded && !entry.outputPaths.isEmpty
    }

    private var videoKind: VideoContentKind {
        entry.outputPaths.contains { $0.contains("/TV Shows/") } ? .tvShow : .movie
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: entry.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(entry.succeeded ? .green : .orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title)
                        .font(.body.weight(.medium))
                    HStack(spacing: 6) {
                        Text(entry.discType.displayName)
                        Text("·")
                        Text(entry.kind.displayName)
                        if !entry.detail.isEmpty {
                            Text("·")
                            Text(entry.detail).lineLimit(1)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                if entry.needsMetadata { NeedsInfoBadge() }
                Text(duration)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                if entry.succeeded, let first = entry.outputPaths.first,
                   FileManager.default.fileExists(atPath: first) {
                    Button {
                        app.revealInFinder(path: first)
                    } label: {
                        Image(systemName: "magnifyingglass.circle")
                    }
                    .buttonStyle(.plain)
                    .help("Show in Finder")
                }
            }
            if let albumPath {
                HStack(spacing: 14) {
                    Spacer()
                    BurnButton(albumPath: albumPath)
                    AlbumInfoButton(albumPath: albumPath, flagged: entry.needsMetadata)
                }
            } else if isVideo {
                HStack {
                    Spacer()
                    VideoInfoButton(paths: entry.outputPaths, kind: videoKind)
                }
            }
        }
        .padding(.vertical, 3)
    }

    private var duration: String {
        let seconds = Int(entry.finishedAt.timeIntervalSince(entry.startedAt))
        if seconds < 60 { return "\(seconds)s" }
        return "\(seconds / 60)m \(seconds % 60)s"
    }
}
