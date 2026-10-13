import Foundation
import AppKit
import DiscRecording

/// Drives a DRBurn and publishes progress for our own SwiftUI sheet (the legacy
/// DiscRecordingUI progress panel renders blank on modern macOS, so we don't use it).
@MainActor
final class BurnController: NSObject, ObservableObject, Identifiable {
    let id = UUID()
    let albumName: String

    @Published var progress: Double = 0        // 0…1, -1 = indeterminate
    @Published var stage: String = "Preparing…"
    @Published var finished = false
    @Published var failed: String?

    private var burn: DRBurn?
    private var tempDir: URL?

    init(albumName: String) {
        self.albumName = albumName
        super.init()
    }

    func start(audioFiles: [URL], flacPath: String) {
        stage = "Preparing tracks…"
        progress = -1
        do {
            let prepared = try CDBurner.prepare(audioFiles: audioFiles, flacPath: flacPath)
            burn = prepared.burn
            tempDir = prepared.tempDir
            DRNotificationCenter.currentRunLoop().addObserver(
                self, selector: #selector(statusChanged(_:)),
                name: NSNotification.Name.DRBurnStatusChanged.rawValue,
                object: prepared.burn)
            stage = "Insert a blank CD-R…"
            prepared.burn.writeLayout(prepared.tracks as NSArray)
        } catch {
            failed = error.localizedDescription
            stage = "Failed"
        }
    }

    func cancel() {
        burn?.abort()
        cleanup()
        stage = "Canceled"
        finished = true
    }

    @objc private func statusChanged(_ note: Notification) {
        guard let burn, let status = burn.status() else { return }
        if let pct = (status[DRStatusPercentCompleteKey] as? NSNumber)?.doubleValue {
            progress = pct
        }
        let state = (status[DRStatusStateKey] as? String) ?? ""
        stage = Self.label(for: state, percent: progress)

        if state == DRStatusStateFailed {
            let info = status[DRErrorStatusKey] as? [AnyHashable: Any]
            failed = (info?[DRErrorStatusErrorStringKey] as? String) ?? "The burn failed."
            finished = true
            cleanup()
        } else if state == DRStatusStateDone {
            progress = 1
            stage = "Done — disc verified and ejected"
            finished = true
            cleanup()
        }
    }

    private func cleanup() {
        if let burn {
            DRNotificationCenter.currentRunLoop().removeObserver(
                self, name: NSNotification.Name.DRBurnStatusChanged.rawValue, object: burn)
        }
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
    }

    private static func label(for state: String, percent: Double) -> String {
        let pct = percent >= 0 ? " \(Int(percent * 100))%" : ""
        switch state {
        case DRStatusStatePreparing: return "Preparing…"
        case DRStatusStateSessionOpen, DRStatusStateTrackOpen: return "Starting…"
        case DRStatusStateTrackWrite: return "Burning…\(pct)"
        case DRStatusStateTrackClose, DRStatusStateSessionClose, DRStatusStateFinishing:
            return "Finishing…\(pct)"
        case DRStatusStateVerifying: return "Verifying…\(pct)"
        case DRStatusStateDone: return "Done"
        case DRStatusStateFailed: return "Failed"
        default: return percent > 0 ? "Burning…\(pct)" : "Waiting for a blank disc…"
        }
    }
}
