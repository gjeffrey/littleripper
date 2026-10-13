import SwiftUI
import Sparkle

@main
struct LittleRipperApp: App {
    @StateObject private var app = AppState()

    // Sparkle auto-updates. Feed URL and public key live in Info.plist
    // (SUFeedURL / SUPublicEDKey). startingUpdater:true checks on schedule.
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(app)
                .environmentObject(app.settings)
                .environmentObject(app.tools)
                .environmentObject(app.history)
                .environmentObject(app.engine)
                .frame(minWidth: 760, minHeight: 520)
                .task { app.start() }
        }
        .defaultSize(width: 900, height: 620)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
            }
            CommandGroup(after: .newItem) {
                Button("Burn Audio CD from Folder or Cue…") { app.burnFromPanel() }
                    .keyboardShortcut("b", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
                .environmentObject(app)
                .environmentObject(app.settings)
                .environmentObject(app.tools)
        }
    }
}

/// "Check for Updates…" menu item that disables itself while an update check is
/// already running (per Sparkle's recommended SwiftUI pattern).
private final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false
    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
    }
}

struct CheckForUpdatesView: View {
    @ObservedObject private var viewModel: CheckForUpdatesViewModel
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        self.viewModel = CheckForUpdatesViewModel(updater: updater)
    }

    var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!viewModel.canCheckForUpdates)
    }
}
