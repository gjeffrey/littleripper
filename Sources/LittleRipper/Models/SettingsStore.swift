import Foundation
import Combine
import ServiceManagement

enum RipMode: String, CaseIterable, Identifiable {
    case automatic
    case interactive

    var id: String { rawValue }
    var displayName: String { self == .automatic ? "Automatic" : "Ask Each Time" }
    var symbolName: String { self == .automatic ? "bolt.fill" : "hand.raised.fill" }
}

@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    private let defaults = UserDefaults.standard

    @Published var mode: RipMode { didSet { defaults.set(mode.rawValue, forKey: "mode") } }

    // Library locations
    @Published var libraryRoot: String { didSet { defaults.set(libraryRoot, forKey: "libraryRoot") } }

    // Automatic-mode defaults
    @Published var autoStreamingCopy: Bool { didSet { defaults.set(autoStreamingCopy, forKey: "autoStreamingCopy") } }
    @Published var autoArchivalCopy: Bool { didSet { defaults.set(autoArchivalCopy, forKey: "autoArchivalCopy") } }
    @Published var autoMainFeatureOnly: Bool { didSet { defaults.set(autoMainFeatureOnly, forKey: "autoMainFeatureOnly") } }
    @Published var autoEject: Bool { didSet { defaults.set(autoEject, forKey: "autoEject") } }

    // Video
    @Published var minTitleMinutes: Int { didSet { defaults.set(minTitleMinutes, forKey: "minTitleMinutes") } }
    @Published var makeDVDISO: Bool { didSet { defaults.set(makeDVDISO, forKey: "makeDVDISO") } }
    @Published var tmdbAPIKey: String { didSet { defaults.set(tmdbAPIKey, forKey: "tmdbAPIKey") } }
    @Published var downloadPoster: Bool { didSet { defaults.set(downloadPoster, forKey: "downloadPoster") } }

    var videoLookupEnabled: Bool { !tmdbAPIKey.trimmingCharacters(in: .whitespaces).isEmpty }

    // Audio
    @Published var lookUpMetadata: Bool { didSet { defaults.set(lookUpMetadata, forKey: "lookUpMetadata") } }
    @Published var downloadAlbumArt: Bool { didSet { defaults.set(downloadAlbumArt, forKey: "downloadAlbumArt") } }

    // Notifications
    @Published var notifyWhenDone: Bool { didSet { defaults.set(notifyWhenDone, forKey: "notifyWhenDone") } }

    @Published var launchAtLogin: Bool {
        didSet {
            guard oldValue != launchAtLogin else { return }
            do {
                if launchAtLogin { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            } catch {
                // Not fatal (e.g. running unbundled during development).
                launchAtLogin = oldValue
            }
        }
    }

    var libraryURL: URL { URL(fileURLWithPath: (libraryRoot as NSString).expandingTildeInPath) }
    var moviesURL: URL { libraryURL.appendingPathComponent("Movies") }
    var tvURL: URL { libraryURL.appendingPathComponent("TV Shows") }
    var musicURL: URL { libraryURL.appendingPathComponent("Music") }
    var backupsURL: URL { libraryURL.appendingPathComponent("Backups") }
    var stagingURL: URL { libraryURL.appendingPathComponent(".ripping") }

    private init() {
        mode = RipMode(rawValue: defaults.string(forKey: "mode") ?? "") ?? .interactive
        libraryRoot = defaults.string(forKey: "libraryRoot") ?? "~/Movies/Little Ripper"
        autoStreamingCopy = defaults.object(forKey: "autoStreamingCopy") as? Bool ?? true
        autoArchivalCopy = defaults.object(forKey: "autoArchivalCopy") as? Bool ?? true
        autoMainFeatureOnly = defaults.object(forKey: "autoMainFeatureOnly") as? Bool ?? true
        autoEject = defaults.object(forKey: "autoEject") as? Bool ?? true
        minTitleMinutes = defaults.object(forKey: "minTitleMinutes") as? Int ?? 5
        makeDVDISO = defaults.object(forKey: "makeDVDISO") as? Bool ?? true
        tmdbAPIKey = defaults.string(forKey: "tmdbAPIKey") ?? ""
        downloadPoster = defaults.object(forKey: "downloadPoster") as? Bool ?? true
        lookUpMetadata = defaults.object(forKey: "lookUpMetadata") as? Bool ?? true
        downloadAlbumArt = defaults.object(forKey: "downloadAlbumArt") as? Bool ?? true
        notifyWhenDone = defaults.object(forKey: "notifyWhenDone") as? Bool ?? true
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
