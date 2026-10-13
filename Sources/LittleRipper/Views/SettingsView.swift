import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            VideoSettings()
                .tabItem { Label("Video", systemImage: "film") }
            AudioSettings()
                .tabItem { Label("Audio", systemImage: "music.note") }
            EnginesSettings()
                .tabItem { Label("Engines", systemImage: "wrench.and.screwdriver") }
        }
        .frame(width: 520)
    }
}

struct GeneralSettings: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        Form {
            Picker("When a disc is inserted:", selection: $settings.mode) {
                ForEach(RipMode.allCases) { mode in
                    Text(mode == .automatic ? "Rip it automatically" : "Ask me what to do").tag(mode)
                }
            }
            .pickerStyle(.radioGroup)

            Section {
                LabeledContent("Library folder:") {
                    HStack {
                        Text((settings.libraryRoot as NSString).abbreviatingWithTildeInPath)
                            .truncationMode(.middle)
                            .lineLimit(1)
                        Button("Choose…") { chooseLibraryFolder() }
                    }
                }
                Text("Rips are organized inside as Movies, TV Shows, Music, and Backups.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Eject discs when finished", isOn: $settings.autoEject)
                Toggle("Notify me when a disc is done", isOn: $settings.notifyWhenDone)
                Toggle("Open Little Ripper at login", isOn: $settings.launchAtLogin)
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 4)
    }

    private func chooseLibraryFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use This Folder"
        panel.directoryURL = settings.libraryURL
        if panel.runModal() == .OK, let url = panel.url {
            settings.libraryRoot = url.path
        }
    }
}

struct VideoSettings: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        Form {
            Section("Automatic mode rips") {
                Toggle("MKV copy for Plex & Jellyfin", isOn: $settings.autoStreamingCopy)
                Toggle("Exact decrypted backup", isOn: $settings.autoArchivalCopy)
            }
            Section {
                Toggle("Rip the main feature only", isOn: $settings.autoMainFeatureOnly)
                Stepper(value: $settings.minTitleMinutes, in: 1...120) {
                    LabeledContent("Ignore titles shorter than:", value: "\(settings.minTitleMinutes) min")
                }
                Text("Filters out menus, logos, and warning clips. Keep this low (≈5 min) for TV — short cartoon or sitcom episodes can run under 20 minutes. Doesn't affect movies when \u{201C}main feature only\u{201D} is on.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Also build a burnable ISO from DVD backups", isOn: $settings.makeDVDISO)
                Text("Blu-ray backups stay as decrypted folders (BDMV) — ideal for re-burning with disc-authoring tools or re-ripping later.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Online lookup (TMDB)") {
                SecureField("TMDB API key", text: $settings.tmdbAPIKey)
                Toggle("Download posters", isOn: $settings.downloadPoster)
                    .disabled(!settings.videoLookupEnabled)
                HStack(spacing: 4) {
                    Text("Names discs from The Movie Database and saves poster.jpg for Plex & Jellyfin. Get a free key at")
                    Link("themoviedb.org", destination: URL(string: "https://www.themoviedb.org/settings/api")!)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 4)
    }
}

struct AudioSettings: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        Form {
            Toggle("Look up album details on MusicBrainz", isOn: $settings.lookUpMetadata)
            Toggle("Download album art", isOn: $settings.downloadAlbumArt)
                .disabled(!settings.lookUpMetadata)
            Text("Album art is saved as cover.jpg (for Plex & Jellyfin) and embedded in each FLAC (for portable players). In \u{201C}Ask Each Time\u{201D} mode, if a CD can't be identified, Little Ripper asks you to type the album info. In Automatic mode it files the CD right away and flags it \u{201C}Needs album info\u{201D} so you can fill it in later.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("CDs are ripped securely with cd-paranoia, encoded to FLAC with verification, and saved with a cue sheet and rip log — a bit-accurate copy you can burn back to disc.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .padding(.vertical, 4)
    }
}

struct EnginesSettings: View {
    @EnvironmentObject private var tools: ToolLocator

    var body: some View {
        Form {
            Section {
                ForEach(tools.allTools) { tool in
                    HStack {
                        Image(systemName: tool.isInstalled ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(tool.isInstalled ? .green : .red)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(tool.displayName).font(.body.weight(.medium))
                            Text(tool.isInstalled ? tool.path ?? "" : tool.purpose)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if !tool.isInstalled {
                            Text(tool.installHint)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                    .padding(.vertical, 2)
                }
            } footer: {
                HStack {
                    Text("Install missing engines with Homebrew, then check again.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Check Again") { tools.refresh() }
                }
            }

            if tools.xldAppPresent {
                Section {
                    Label("XLD is installed — available as a hand-off for audio CDs in interactive mode.",
                          systemImage: "checkmark.seal")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Text("MakeMKV is free while in beta but needs its key entered once — open the MakeMKV app if a video rip complains about registration.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 4)
    }
}
