import SwiftUI

/// Album artist / title / year entry, used both for the mid-rip prompt and for
/// editing an already-filed album.
struct MetadataForm: View {
    let reason: String?
    @State private var artist: String
    @State private var album: String
    @State private var year: String
    let saveTitle: String
    let showSkip: Bool
    let onSave: (_ artist: String, _ album: String, _ year: String) -> Void
    let onSkip: (() -> Void)?

    init(reason: String? = nil, artist: String = "", album: String = "", year: String = "",
         saveTitle: String = "Save", showSkip: Bool = false,
         onSave: @escaping (String, String, String) -> Void, onSkip: (() -> Void)? = nil) {
        self.reason = reason
        _artist = State(initialValue: artist)
        _album = State(initialValue: album)
        _year = State(initialValue: year)
        self.saveTitle = saveTitle
        self.showSkip = showSkip
        self.onSave = onSave
        self.onSkip = onSkip
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let reason {
                Label(reason, systemImage: "questionmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            TextField("Album artist", text: $artist).textFieldStyle(.roundedBorder)
            TextField("Album title", text: $album).textFieldStyle(.roundedBorder)
            TextField("Year (optional)", text: $year).textFieldStyle(.roundedBorder).frame(maxWidth: 130)
            HStack {
                if showSkip, let onSkip {
                    Button("Skip for now") { onSkip() }
                }
                Spacer()
                Button(saveTitle) { onSave(artist, album, year) }
                    .buttonStyle(.borderedProminent)
                    .disabled(album.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// The mid-rip prompt shown on a job that's paused waiting for album info.
struct MetadataPromptView: View {
    @ObservedObject var job: RipJob

    var body: some View {
        if let prompt = job.metadataPrompt {
            MetadataForm(reason: prompt.reason,
                         artist: prompt.artist, album: prompt.album, year: prompt.year,
                         saveTitle: "Save & Continue", showSkip: true,
                         onSave: { artist, album, year in
                             job.metadataResolver?(AlbumMetadata(
                                artist: artist.isEmpty ? "Unknown Artist" : artist,
                                album: album, year: year,
                                trackTitles: [:], trackArtists: [:]))
                         },
                         onSkip: { job.metadataResolver?(nil) })
        }
    }
}

/// A reveal-button + form for adding/fixing album info on an already-filed album.
struct AlbumInfoButton: View {
    let albumPath: String
    let flagged: Bool
    @EnvironmentObject private var engine: RipEngine
    @State private var editing = false
    @State private var working = false

    var body: some View {
        if editing {
            MetadataForm(reason: "Little Ripper will re-tag, rename, fetch art, and re-file this album.",
                         saveTitle: working ? "Saving…" : "Save") { artist, album, year in
                working = true
                Task {
                    _ = await engine.editAlbumInfo(albumFolder: URL(fileURLWithPath: albumPath),
                                                   artist: artist, album: album, year: year)
                    working = false
                    editing = false
                }
            }
        } else {
            Button(flagged ? "Add album info" : "Edit info") { editing = true }
                .buttonStyle(.link)
                .font(.callout)
        }
    }
}

/// Corrects a filed movie/show's title (TMDB picker) and re-files it. Mirrors AlbumInfoButton.
struct VideoInfoButton: View {
    let paths: [String]
    let kind: VideoContentKind
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var engine: RipEngine

    @State private var editing = false
    @State private var title = ""
    @State private var year = ""
    @State private var matches: [VideoMatch] = []
    @State private var searching = false
    @State private var posterURL = ""
    @State private var working = false

    var body: some View {
        if editing {
            VStack(alignment: .leading, spacing: 8) {
                if settings.videoLookupEnabled {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkle.magnifyingglass").foregroundStyle(.secondary)
                        if searching {
                            ProgressView().controlSize(.small)
                            Text("Searching TMDB…").font(.caption).foregroundStyle(.secondary)
                        } else if !matches.isEmpty {
                            Picker("Match", selection: Binding(
                                get: { matches.first { $0.title == title && $0.year == year } ?? matches[0] },
                                set: { apply($0) })) {
                                ForEach(matches) { m in
                                    Text("\(m.kind == .movie ? "🎬" : "📺")  \(m.displayTitle)").tag(m)
                                }
                            }.labelsHidden().frame(maxWidth: 300)
                        } else {
                            Text("No match — type the title and press Return.").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
                TextField("Title", text: $title)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 300)
                    .onSubmit { runSearch() }
                TextField("Year (optional)", text: $year)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 120)
                HStack {
                    Button("Cancel") { editing = false }
                    Spacer()
                    Button(working ? "Saving…" : "Save") {
                        working = true
                        Task {
                            _ = await engine.editVideoInfo(paths: paths, kind: kind,
                                                           title: title, year: year, posterURL: posterURL)
                            working = false
                            editing = false
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || working)
                }
            }
            .padding(10)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        } else {
            Button("Edit info") { begin() } .buttonStyle(.link).font(.callout)
        }
    }

    private func begin() {
        let (t, y) = Self.guessTitle(from: paths)
        title = t; year = y
        editing = true
        if settings.videoLookupEnabled { runSearch() }
    }

    private func apply(_ m: VideoMatch) { title = m.title; year = m.year; posterURL = m.posterURL }

    private func runSearch() {
        guard settings.videoLookupEnabled else { return }
        searching = true; matches = []
        Task {
            let found = await MovieLookup.search(title, apiKey: settings.tmdbAPIKey)
            await MainActor.run {
                matches = found
                searching = false
                if let best = found.first(where: { $0.kind == kind }) ?? found.first { apply(best) }
            }
        }
    }

    /// Parses "Title (Year)" from the media folder name.
    static func guessTitle(from paths: [String]) -> (String, String) {
        guard let mkv = paths.first(where: { $0.lowercased().hasSuffix(".mkv") }) ?? paths.first else { return ("", "") }
        let folder = (mkv as NSString).deletingLastPathComponent
        let name = (folder as NSString).lastPathComponent
        if let m = try? #/^(.*) \((\d{4})\)$/#.firstMatch(in: name) {
            return (String(m.1), String(m.2))
        }
        return (name, "")
    }
}

/// Burns an audio-CD copy from a ripped album.
struct BurnButton: View {
    let albumPath: String
    @EnvironmentObject private var app: AppState

    var body: some View {
        Button { app.burnAudioCD(albumPath: albumPath) } label: {
            Label("Burn to CD", systemImage: "opticaldisc")
        }
        .buttonStyle(.link)
        .font(.callout)
        .help("Burn an exact audio-CD copy from this album's FLAC files")
    }
}

/// Small orange "Needs album info" pill.
struct NeedsInfoBadge: View {
    var body: some View {
        Label("Needs album info", systemImage: "exclamationmark.circle")
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(.orange.opacity(0.18), in: Capsule())
            .foregroundStyle(.orange)
    }
}
