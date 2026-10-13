import SwiftUI

struct QueueView: View {
    @EnvironmentObject private var engine: RipEngine

    var body: some View {
        Group {
            if engine.jobs.isEmpty {
                ContentUnavailableView("No Activity",
                                       systemImage: "square.stack.3d.up.slash",
                                       description: Text("Rips in progress and recently finished jobs show up here."))
            } else {
                List {
                    let active = engine.jobs.filter { !$0.state.isTerminal }
                    let finished = engine.jobs.filter { $0.state.isTerminal }
                    if !active.isEmpty {
                        Section("In Progress") {
                            ForEach(active) { job in JobRow(job: job) }
                        }
                    }
                    if !finished.isEmpty {
                        Section {
                            ForEach(finished.reversed()) { job in JobRow(job: job) }
                        } header: {
                            HStack {
                                Text("Finished")
                                Spacer()
                                Button("Clear") { engine.clearFinished() }
                                    .buttonStyle(.plain)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
    }
}

struct JobRow: View {
    @ObservedObject var job: RipJob
    @EnvironmentObject private var app: AppState
    @State private var showLog = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: job.kind.symbolName)
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.discTitle)
                        .font(.body.weight(.medium))
                    Text(job.kind.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                statusView
            }

            if job.state == .running || job.state == .finishing {
                if let progress = job.progress {
                    ProgressView(value: progress)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
                Text(job.stage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if case .failed(let message) = job.state {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            // Paused waiting for album info (interactive, unidentified CD).
            if job.metadataPrompt != nil {
                MetadataPromptView(job: job)
            }

            // Finished audio album that can have its info added or edited.
            if job.state == .done, job.kind == .audioRip, let path = job.outputPaths.first {
                HStack(spacing: 14) {
                    if job.needsMetadata { NeedsInfoBadge() }
                    Spacer()
                    BurnButton(albumPath: path)
                    AlbumInfoButton(albumPath: path, flagged: job.needsMetadata)
                }
            }
            if job.state == .done, job.kind != .audioRip, !job.outputPaths.isEmpty {
                HStack { Spacer(); VideoInfoButton(paths: job.outputPaths, kind: job.plan.videoKind) }
            }

            DisclosureGroup("Log", isExpanded: $showLog) {
                ScrollView {
                    Text(job.logTail.suffix(200).joined(separator: "\n"))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 180)
            }
            .font(.caption)
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var statusView: some View {
        switch job.state {
        case .queued:
            Text("Waiting")
                .font(.caption)
                .foregroundStyle(.secondary)
            cancelButton
        case .running, .finishing:
            if let progress = job.progress {
                Text(progress.formatted(.percent.precision(.fractionLength(0))))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            cancelButton
        case .done:
            if let first = job.outputPaths.first {
                Button("Show in Finder") { app.revealInFinder(path: first) }
                    .buttonStyle(.link)
                    .font(.callout)
            }
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .canceled:
            Text("Canceled").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var cancelButton: some View {
        Button {
            job.cancel()
        } label: {
            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Cancel this job")
    }
}
