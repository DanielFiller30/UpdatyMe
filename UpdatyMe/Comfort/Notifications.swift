import Foundation
import UserNotifications

/// Mitteilungen über neue Updates und abgeschlossene Update-Serien.
@MainActor
protocol UpdateNotifier: AnyObject {
    func notifyNewUpdates(_ names: [String])
    func notifyUpdatesFinished(succeeded: [String], failed: [String])
}

/// Ohne Wirkung (Previews, Tests).
final class SilentNotifier: UpdateNotifier {
    func notifyNewUpdates(_ names: [String]) {}
    func notifyUpdatesFinished(succeeded: [String], failed: [String]) {}
}

/// Mitteilungszentrale von macOS. Die Erlaubnis wird erst vor der ersten Mitteilung erfragt.
final class SystemNotifier: UpdateNotifier {
    private var isAuthorized: Bool?

    func notifyNewUpdates(_ names: [String]) {
        let content = UNMutableNotificationContent()
        content.title = names.count == 1
            ? String(localized: "Update available")
            : String(localized: "\(names.count) updates available")
        content.body = Self.list(names)
        post(content, id: "new-updates")
    }

    func notifyUpdatesFinished(succeeded: [String], failed: [String]) {
        let content = UNMutableNotificationContent()
        if failed.isEmpty {
            content.title = String(localized: "Updates finished")
            content.body = Self.list(succeeded)
        } else {
            content.title = String(localized: "\(failed.count) updates failed")
            content.body = Self.list(failed)
        }
        post(content, id: "updates-finished")
    }

    /// Höchstens fünf Namen, Rest als „+ n weitere“.
    static func list(_ names: [String]) -> String {
        let shown = names.prefix(5).joined(separator: ", ")
        return names.count > 5 ? String(localized: "\(shown) and \(names.count - 5) more") : shown
    }

    private func post(_ content: UNMutableNotificationContent, id: String) {
        Task {
            let center = UNUserNotificationCenter.current()
            if isAuthorized == nil {
                isAuthorized = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            }
            guard isAuthorized == true else { return }
            content.sound = .default
            try? await center.add(UNNotificationRequest(identifier: "\(id)-\(UUID().uuidString)", content: content, trigger: nil))
        }
    }
}
