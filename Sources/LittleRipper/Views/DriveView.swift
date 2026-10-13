import SwiftUI

/// The hero view: what's in the drive right now.
struct DriveView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var tools: ToolLocator

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if !tools.everythingReady {
                    ToolBanner()
                }
                if app.discs.isEmpty {
                    EmptyDriveView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                } else {
                    ForEach(app.discs) { disc in
                        DiscCard(disc: disc)
                            .transition(.asymmetric(insertion: .scale(scale: 0.94).combined(with: .opacity),
                                                    removal: .opacity))
                    }
                }
            }
            .padding(24)
            .animation(.spring(duration: 0.4), value: app.discs)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct EmptyDriveView: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "opticaldisc")
                .font(.system(size: 96, weight: .ultraLight))
                .foregroundStyle(.tertiary)
                .symbolEffect(.pulse.byLayer, options: .repeating.speed(0.3))
            Text("Insert a Disc")
                .font(.title2.weight(.semibold))
            Text(settings.mode == .automatic
                 ? "Little Ripper will rip it, file it, and eject it — hands free."
                 : "Little Ripper will read it and ask what you'd like to do.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
    }
}

/// One inserted disc: artwork, identity, and either a plan editor or job status.
struct DiscCard: View {
    let disc: Disc
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var engine: RipEngine

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 18) {
                DiscArtwork(type: disc.type)
                VStack(alignment: .leading, spacing: 5) {
                    if disc.type == .unknown {
                        Text("Reading disc…")
                            .font(.title3.weight(.semibold))
                        ProgressView().controlSize(.small)
                    } else {
                        Text(disc.guessedTitle)
                            .font(.title3.weight(.semibold))
                            .lineLimit(2)
                        HStack(spacing: 6) {
                            TypeBadge(type: disc.type)
                            if let tracks = disc.trackCount {
                                Text("\(tracks) tracks")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Spacer()
                Button {
                    app.eject(bsdName: disc.bsdName)
                } label: {
                    if app.ejecting.contains(disc.bsdName) {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Eject", systemImage: "eject.fill")
                    }
                }
                .disabled(app.ejecting.contains(disc.bsdName))
                .help("Eject this disc")
            }
            .padding(18)

            if shouldShowPlanEditor {
                Divider()
                PlanEditor(disc: disc)
                    .padding(18)
            } else if engine.hasJobs(forDisc: disc.bsdName) {
                Divider()
                DiscJobsSummary(bsdName: disc.bsdName)
                    .padding(18)
            } else if disc.type == .dataDisc {
                Divider()
                Text("This looks like a data disc — nothing here for Little Ripper to rip.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(.separator.opacity(0.5), lineWidth: 1))
    }

    private var shouldShowPlanEditor: Bool {
        settings.mode == .interactive
            && (disc.type.isVideo || disc.type == .audioCD)
            && !engine.hasJobs(forDisc: disc.bsdName)
    }
}

/// A pretty disc render — concentric gradients, like a physical disc.
struct DiscArtwork: View {
    let type: DiscType

    private var tint: Color {
        switch type {
        case .audioCD: return .pink
        case .dvdVideo: return .orange
        case .blurayVideo: return .blue
        case .dataDisc: return .gray
        case .unknown: return .gray.opacity(0.6)
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(AngularGradient(colors: [
                    tint.opacity(0.55), .white.opacity(0.75), tint.opacity(0.35),
                    .white.opacity(0.6), tint.opacity(0.55),
                ], center: .center))
            Circle()
                .strokeBorder(.white.opacity(0.7), lineWidth: 1)
            Circle()
                .fill(Color(nsColor: .windowBackgroundColor))
                .frame(width: 22, height: 22)
            Circle()
                .strokeBorder(.separator, lineWidth: 1)
                .frame(width: 22, height: 22)
            Image(systemName: type.symbolName)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
                .offset(y: 26)
                .opacity(0)   // keep layout stable; badge carries the type
        }
        .frame(width: 72, height: 72)
        .shadow(color: .black.opacity(0.18), radius: 5, y: 2)
    }
}

struct TypeBadge: View {
    let type: DiscType

    var body: some View {
        Label(type.displayName, systemImage: type.symbolName)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.quaternary, in: Capsule())
    }
}

/// Compact status of this disc's jobs, shown right on the disc card.
struct DiscJobsSummary: View {
    let bsdName: String
    @EnvironmentObject private var engine: RipEngine

    var body: some View {
        VStack(spacing: 10) {
            ForEach(engine.jobs.filter { $0.plan.disc.bsdName == bsdName && !$0.state.isTerminal }) { job in
                JobProgressLine(job: job)
            }
            let finished = engine.jobs.filter { $0.plan.disc.bsdName == bsdName && $0.state.isTerminal }
            if !finished.isEmpty {
                ForEach(finished) { job in
                    JobFinishedLine(job: job)
                }
            }
        }
    }
}

struct JobProgressLine: View {
    @ObservedObject var job: RipJob

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(job.kind.displayName, systemImage: job.kind.symbolName)
                    .font(.callout.weight(.medium))
                Spacer()
                if job.state == .queued {
                    Text("Waiting")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let progress = job.progress {
                    Text(progress.formatted(.percent.precision(.fractionLength(0))))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Button {
                    job.cancel()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Cancel")
            }
            if job.state == .queued {
                ProgressView(value: 0).tint(.secondary)
            } else if let progress = job.progress {
                ProgressView(value: progress)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
            }
            Text(job.stage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if job.metadataPrompt != nil {
                MetadataPromptView(job: job)
            }
        }
    }
}

struct JobFinishedLine: View {
    @ObservedObject var job: RipJob
    @EnvironmentObject private var app: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
        HStack {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
            Text(job.kind.displayName)
                .font(.callout)
            if job.needsMetadata { NeedsInfoBadge() }
            Spacer()
            if job.state == .done, let first = job.outputPaths.first {
                Button("Show in Finder") { app.revealInFinder(path: first) }
                    .buttonStyle(.link)
                    .font(.callout)
            } else if case .failed(let msg) = job.state {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(msg)
            }
        }
        if job.state == .done, job.kind == .audioRip, let path = job.outputPaths.first {
            HStack(spacing: 14) {
                Spacer()
                BurnButton(albumPath: path)
                AlbumInfoButton(albumPath: path, flagged: job.needsMetadata)
            }
        }
        if job.state == .done, job.kind != .audioRip, !job.outputPaths.isEmpty {
            HStack { Spacer(); VideoInfoButton(paths: job.outputPaths, kind: job.plan.videoKind) }
        }
        }
    }

    private var iconName: String {
        switch job.state {
        case .done: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        default: return "minus.circle"
        }
    }

    private var iconColor: Color {
        switch job.state {
        case .done: return .green
        case .failed: return .orange
        default: return .secondary
        }
    }
}

/// Banner shown when backends are missing.
struct ToolBanner: View {
    @EnvironmentObject private var tools: ToolLocator

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "wrench.and.screwdriver")
                .font(.title3)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Some ripping engines are missing")
                    .font(.callout.weight(.semibold))
                Text(missingSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            SettingsLink {
                Text("Review…")
            }
            Button("Check Again") { tools.refresh() }
        }
        .padding(14)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var missingSummary: String {
        let missing = tools.allTools.filter { !$0.isInstalled }
        return missing.map { "\($0.displayName) (\($0.installHint))" }.joined(separator: " · ")
    }
}
