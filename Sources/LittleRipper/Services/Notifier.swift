import Foundation
import UserNotifications
import AppKit

/// System notifications — quietly disabled when running unbundled (swift run).
@MainActor
final class Notifier {
    private var available: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app")
    }

    func requestPermission() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func discFinished(title: String, succeeded: Bool, enabled: Bool) {
        guard enabled else { return }
        if available {
            let content = UNMutableNotificationContent()
            content.title = succeeded ? "Disc ripped" : "Rip finished with problems"
            content.body = succeeded
                ? "“\(title)” is in your library and the disc is on its way out."
                : "“\(title)” didn’t finish cleanly. Check Little Ripper for details."
            content.sound = .default
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request)
        } else {
            NSSound(named: succeeded ? "Glass" : "Basso")?.play()
        }
    }

    func discDetected(title: String, type: DiscType, interactive: Bool) {
        guard available, interactive else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(type.displayName) inserted"
        content.body = "“\(title)” is ready. Open Little Ripper to choose what to do."
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
