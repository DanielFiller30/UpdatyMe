import AppKit
import ServiceManagement
import UpdatyMeCore

/// Schlüssel der Einstellungen in `UserDefaults`. Fehlt ein Wert, gilt der Standard (alles an, Prüfung alle 6 h).
enum AppSettings {
    static let showMenuBarExtraKey = "showMenuBarExtra"
    static let checkIntervalKey = "automaticCheckInterval"
    static let notifyNewUpdatesKey = "notifyNewUpdates"
    static let notifyUpdatesFinishedKey = "notifyUpdatesFinished"

    static func bool(_ key: String, in defaults: UserDefaults?) -> Bool {
        defaults?.object(forKey: key) as? Bool ?? true
    }
}

/// Automatische Prüfung, solange die App läuft. Kürzer als die Cache-TTL (6 h) ist nicht wählbar:
/// die Versionsquellen kämen dann ohnehin aus dem Cache.
enum CheckInterval: String, CaseIterable, Identifiable {
    case sixHours, twelveHours, daily, weekly, never

    static let `default`: CheckInterval = .sixHours

    var id: Self { self }

    /// `nil` = keine automatische Prüfung.
    var duration: Duration? {
        switch self {
        case .sixHours: CachingHTTPClient.defaultTTL
        case .twelveHours: .seconds(12 * 3600)
        case .daily: .seconds(24 * 3600)
        case .weekly: .seconds(7 * 24 * 3600)
        case .never: nil
        }
    }
}

/// „Bei der Anmeldung öffnen“ über `SMAppService.mainApp` (Anmeldeobjekte in den Systemeinstellungen).
@MainActor
enum LaunchAtLogin {
    static var status: SMAppService.Status {
        SMAppService.mainApp.status
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// Ob dieser Start ein Anmeldeobjekt-Start ist. Nur in `applicationDidFinishLaunching` aussagekräftig.
    static func isCurrentLaunchAtLogin() -> Bool {
        #if DEBUG
        // Zum Ausprobieren ohne Ab- und Anmelden: `-UpdatyMeSimulateLoginLaunch YES`.
        if UserDefaults.standard.bool(forKey: "UpdatyMeSimulateLoginLaunch") {
            return true
        }
        #endif
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventID == AEEventID(kAEOpenApplication) else { return false }
        return event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
    }
}
