import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable {
    case drive
    case queue
    case history

    var id: String { rawValue }
    var title: String {
        switch self {
        case .drive: return "Drive"
        case .queue: return "Activity"
        case .history: return "History"
        }
    }
    var symbol: String {
        switch self {
        case .drive: return "opticaldiscdrive"
        case .queue: return "square.stack.3d.up"
        case .history: return "clock"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var engine: RipEngine
    @EnvironmentObject private var tools: ToolLocator
    @State private var selection: SidebarItem = .drive

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(SidebarItem.allCases) { item in
                    Label {
                        Text(item.title)
                    } icon: {
                        Image(systemName: item.symbol)
                    }
                    .badge(badge(for: item))
                    .tag(item)
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
            .safeAreaInset(edge: .bottom) {
                modeFooter
            }
        } detail: {
            Group {
                switch selection {
                case .drive: DriveView()
                case .queue: QueueView()
                case .history: HistoryView()
                }
            }
            .navigationTitle("Little Ripper")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Picker("Mode", selection: $settings.mode) {
                        ForEach(RipMode.allCases) { mode in
                            Label(mode.displayName, systemImage: mode.symbolName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .help("Automatic rips every disc as soon as it's inserted. Ask Each Time lets you choose per disc.")
                }
            }
        }
        .onChange(of: engine.activeJobs.isEmpty) { _, isEmpty in
            if !isEmpty { selection = .queue }
        }
        .sheet(item: $app.activeBurn) { controller in
            BurnSheet(controller: controller) { app.activeBurn = nil }
        }
    }

    private func badge(for item: SidebarItem) -> Int {
        switch item {
        case .drive: return 0
        case .queue: return engine.activeJobs.count
        case .history: return 0
        }
    }

    private var modeFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            HStack(spacing: 8) {
                Image(systemName: settings.mode.symbolName)
                    .foregroundStyle(settings.mode == .automatic ? .yellow : .blue)
                VStack(alignment: .leading, spacing: 1) {
                    Text(settings.mode.displayName)
                        .font(.callout.weight(.medium))
                    Text(settings.mode == .automatic
                         ? "Discs rip & eject on their own"
                         : "You choose per disc")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
        }
        .background(.bar)
    }
}
