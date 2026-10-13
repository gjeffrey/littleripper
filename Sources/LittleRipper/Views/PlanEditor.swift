import SwiftUI

/// Interactive mode: choose what happens to this disc.
struct PlanEditor: View {
    let disc: Disc

    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var engine: RipEngine
    @EnvironmentObject private var tools: ToolLocator

    @State private var title: String = ""
    @State private var year: String = ""
    @State private var videoKind: VideoContentKind = .movie
    @State private var season: Int = 1
    @State private var firstEpisode: Int = 1
    @State private var makeStreamingCopy = true
    @State private var makeArchivalCopy = true
    @State private var mainFeatureOnly = true
    @State private var ejectWhenDone = true

    // TMDB lookup (video)
    @State private var matches: [VideoMatch] = []
    @State private var searching = false
    @State private var posterURL = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if disc.type.isVideo {
                videoOptions
            } else {
                audioOptions
            }

            Toggle("Eject when finished", isOn: $ejectWhenDone)

            HStack {
                if disc.type == .audioCD && tools.xldAppPresent {
                    Button("Open in XLD Instead") { app.openInXLD(disc: disc) }
                        .help("Hand this CD to XLD for a manual, fully-configurable rip")
                }
                Spacer()
                Button {
                    startRip()
                } label: {
                    Label("Rip", systemImage: "arrow.down.circle.fill")
                        .frame(minWidth: 90)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!canRip)
            }
        }
        .onAppear {
            title = disc.guessedTitle
            mainFeatureOnly = settings.autoMainFeatureOnly
            ejectWhenDone = settings.autoEject
            if disc.type.isVideo && settings.videoLookupEnabled && matches.isEmpty {
                runSearch(query: disc.guessedTitle)
            }
        }
    }

    private var canRip: Bool {
        if disc.type.isVideo {
            return (makeStreamingCopy || makeArchivalCopy) && tools.videoReady && !title.isEmpty
        }
        return tools.audioReady
    }

    @ViewBuilder
    private var matchPicker: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkle.magnifyingglass").foregroundStyle(.secondary)
            if searching {
                ProgressView().controlSize(.small)
                Text("Looking up on TMDB…").font(.callout).foregroundStyle(.secondary)
            } else if matches.isEmpty {
                Text("No online match — type the title below.").font(.callout).foregroundStyle(.secondary)
                Button("Search again") { runSearch(query: title) }
            } else {
                Picker("Match", selection: Binding(
                    get: { matches.first { $0.title == title && $0.year == year } ?? matches[0] },
                    set: { apply($0) })) {
                    ForEach(matches) { m in
                        Text("\(m.kind == .movie ? "🎬" : "📺")  \(m.displayTitle)").tag(m)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 340)
                Button("Search again") { runSearch(query: title) }
            }
            Spacer()
        }
        .padding(.bottom, 2)
    }

    private func apply(_ match: VideoMatch) {
        title = match.title
        year = match.year
        videoKind = match.kind
        posterURL = match.posterURL
    }

    private func runSearch(query: String) {
        guard settings.videoLookupEnabled else { return }
        searching = true
        matches = []
        Task {
            let found = await MovieLookup.search(query, apiKey: settings.tmdbAPIKey)
            await MainActor.run {
                matches = found
                searching = false
                if let best = found.first { apply(best) }
            }
        }
    }

    @ViewBuilder
    private var videoOptions: some View {
        if settings.videoLookupEnabled {
            matchPicker
        }
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                Text("Title").gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    TextField("Movie or show name", text: $title)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 320)
                        .onSubmit { if settings.videoLookupEnabled { runSearch(query: title) } }
                    if settings.videoLookupEnabled {
                        Text("Disc labels are often truncated (e.g. “SEXY_SE”). Fix the title and press Return to search.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            GridRow {
                Text("Year").foregroundStyle(.secondary)
                TextField("Optional — helps Plex & Jellyfin match it", text: $year)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 150)
            }
            GridRow {
                Text("Content").foregroundStyle(.secondary)
                Picker("", selection: $videoKind) {
                    ForEach(VideoContentKind.allCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 220)
            }
            if videoKind == .tvShow {
                GridRow {
                    Text("Season").foregroundStyle(.secondary)
                    HStack {
                        Stepper(value: $season, in: 1...99) { Text("\(season)") }
                        Text("First episode on disc").foregroundStyle(.secondary)
                        Stepper(value: $firstEpisode, in: 1...199) { Text("\(firstEpisode)") }
                    }
                }
            }
        }

        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $makeStreamingCopy) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Rip for Plex & Jellyfin")
                    Text("MKV files, named and filed so your servers recognize them")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if makeStreamingCopy && videoKind == .movie {
                Toggle("Main feature only (skip trailers and extras)", isOn: $mainFeatureOnly)
                    .padding(.leading, 20)
            }
            Toggle(isOn: $makeArchivalCopy) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Exact backup")
                    Text(disc.type == .dvdVideo
                         ? "Decrypted disc copy plus a burnable ISO"
                         : "Decrypted disc copy you can re-burn or re-rip later")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var audioOptions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text("Secure rip to FLAC with cue sheet and log — tagged and filed automatically\(settings.lookUpMetadata ? " using MusicBrainz" : "")")
                    .font(.callout)
            } icon: {
                Image(systemName: "waveform.badge.magnifyingglass")
                    .foregroundStyle(.pink)
            }
            Text("The FLAC + cue pair is bit-accurate: burn it back and you get an identical CD.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func startRip() {
        var plan = RipPlan(disc: disc, title: title.trimmingCharacters(in: .whitespaces), year: year.trimmingCharacters(in: .whitespaces))
        plan.videoKind = videoKind
        plan.season = season
        plan.firstEpisode = firstEpisode
        plan.makeStreamingCopy = makeStreamingCopy
        plan.makeArchivalCopy = makeArchivalCopy
        plan.mainFeatureOnly = videoKind == .movie ? mainFeatureOnly : false
        plan.ejectWhenDone = ejectWhenDone
        plan.posterURL = settings.downloadPoster ? posterURL : ""
        engine.enqueue(plan: plan)
    }
}
