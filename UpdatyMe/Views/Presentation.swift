import SwiftUI
import UpdatyMeCore

// Anzeigetexte und Symbole. Bewusst in der App, nicht im Kern: Der Kern liefert strukturierte
// Werte, übersetzt wird hier (Basis Englisch, Deutsch im String Catalog).

extension InventoryCategory {
    var title: LocalizedStringKey {
        switch self {
        case .favorites: "Favorites"
        case .overview: "Overview"
        case .system: "System"
        case .apps: "Apps"
        case .homebrew: "Homebrew"
        case .runtimes: "Runtimes"
        case .packages: "Packages"
        case .history: "History"
        }
    }

    var systemImage: String {
        switch self {
        case .favorites: "star"
        case .overview: "square.grid.2x2"
        case .system: "desktopcomputer"
        case .apps: "app.badge"
        case .homebrew: "mug"
        case .runtimes: "cube"
        case .packages: "shippingbox"
        case .history: "clock.arrow.circlepath"
        }
    }
}

extension InventoryFilter.StatusFilter {
    var title: LocalizedStringKey {
        switch self {
        case .all: "All"
        case .updates: "Updates Available"
        case .unknown: "Unknown"
        case .upToDate: "Up to Date"
        }
    }
}

extension InstalledItem.Kind {
    var title: LocalizedStringKey {
        switch self {
        case .os: "Operating system"
        case .app: "App"
        case .cli: "Command-line tool"
        case .runtime: "Runtime"
        case .package: "Package"
        }
    }

    var systemImage: String {
        switch self {
        case .os: "apple.logo"
        case .app: "app.dashed"
        case .cli: "terminal"
        case .runtime: "cube"
        case .package: "shippingbox"
        }
    }
}

extension InstalledItem.UpdateCapability {
    var title: LocalizedStringKey {
        switch self {
        case .auto: "One click"
        case .manual: "Manual"
        case .openSettings: "Via System Settings"
        case .none: "Not possible"
        }
    }
}

extension ItemSource {
    var title: String {
        switch self {
        case .system: String(localized: "System")
        case .brew: String(localized: "Homebrew")
        case .cask: String(localized: "Homebrew Cask")
        case .mas: String(localized: "App Store")
        case .sparkle: String(localized: "Sparkle")
        case .manual: String(localized: "Installed manually")
        case .conda: String(localized: "conda")
        case .config: String(localized: "Configuration file")
        case .nvm, .fnm, .volta, .asdf, .pyenv, .rbenv, .sdkman, .rustup, .cargo, .pipx, .uv, .npm, .pnpm: rawValue
        default: rawValue
        }
    }
}

extension EcosystemID {
    var title: String {
        switch self {
        case .macOS: String(localized: "macOS")
        case .brew: String(localized: "Homebrew")
        case .appBundle: String(localized: "Applications")
        case .softwareUpdate: String(localized: "Software Update")
        case .brewOutdated: String(localized: "Homebrew versions")
        case .appStore: String(localized: "App Store")
        case .sparkle: String(localized: "Sparkle")
        case .caskMatch: String(localized: "Homebrew Cask matching")
        case .node: String(localized: "Node.js")
        case .npm: String(localized: "npm (global)")
        case .pnpm: String(localized: "pnpm (global)")
        case .python: String(localized: "Python")
        case .rust: String(localized: "Rust")
        case .java: String(localized: "Java")
        case .gcloud: String(localized: "Google Cloud CLI")
        case .configuredTools: String(localized: "Configuration file")
        case .nodeReleases: String(localized: "Node.js versions")
        case .npmRegistry: String(localized: "npm registry")
        case .pythonReleases: String(localized: "Python versions")
        case .pypi: String(localized: "PyPI")
        case .rustReleases: String(localized: "Rust versions")
        case .crates: String(localized: "crates.io")
        case .javaReleases: String(localized: "Java versions")
        case .gcloudReleases: String(localized: "Google Cloud CLI versions")
        case .configuredToolReleases: String(localized: "Configured tool versions")
        default: rawValue
        }
    }
}

extension EcosystemID {
    /// Quelle für neueste Versionen (statt Inventar).
    var isLatestSource: Bool { rawValue.hasPrefix("latest.") }
}

/// Übersetzte Fehlermeldungen für strukturierte Fehler aus dem Kern.
enum ErrorText {
    /// Netz nicht erreichbar (offline, DNS, Verbindung, Zeitüberschreitung).
    static func isNetworkError(_ error: any Error) -> Bool {
        guard let error = error as? URLError else { return false }
        return [.notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
                .dnsLookupFailed, .timedOut, .internationalRoamingOff, .dataNotAllowed].contains(error.code)
    }

    static func message(for error: any Error) -> String {
        switch error {
        case let error as InventoryError:
            switch error {
            case .toolNotFound(let tool):
                return String(localized: "\(tool) is not installed")
            case .commandFailed(let command, let exitCode, let stderr):
                let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                let code = Int(exitCode)
                return detail.isEmpty
                    ? String(localized: "\(command) exited with code \(code)")
                    : String(localized: "\(command) exited with code \(code): \(detail)")
            case .unexpectedOutput(let source, let detail):
                return String(localized: "Unexpected output from \(source): \(detail)")
            }
        case let error as CommandError:
            switch error {
            case .invalidExecutable(let path):
                return String(localized: "Invalid executable: \(path)")
            case .launchFailed(let command, let reason):
                return String(localized: "Could not launch \(command): \(reason)")
            case .timedOut(let command, _, _, _):
                return String(localized: "\(command) timed out")
            case .noResult(let command):
                return String(localized: "\(command) returned no result")
            }
        case let error as UpdateError:
            switch error {
            case .requiresAdministrator(let detail):
                return detail.isEmpty
                    ? String(localized: "Requires administrator privileges. Please update manually in Terminal.")
                    : String(localized: "Requires administrator privileges. Please update manually in Terminal. (\(detail))")
            case .failed(let exitCode, let reason):
                let code = Int(exitCode)
                return reason.isEmpty
                    ? String(localized: "Exited with code \(code)")
                    : String(localized: "\(reason) (exit code \(code))")
            case .unsupported(let name):
                return String(localized: "\(name) cannot be updated automatically.")
            case .incomplete:
                return String(localized: "The update did not complete.")
            }
        default:
            return error.localizedDescription
        }
    }
}

extension ResolvedEnvironment.FallbackReason {
    var text: String {
        switch self {
        case .exitCode(let code): String(localized: "exit code \(Int(code))")
        case .missingMarkers: String(localized: "output without environment markers")
        case .missingPath: String(localized: "no PATH in output")
        case .error(let message): message
        }
    }
}

extension ResolvedEnvironment.Note {
    var text: String {
        switch self {
        case .loginShellRead(let shell, let count):
            String(localized: "Read environment from login shell \(shell) (\(count) PATH entries).")
        case .loginShellUnavailable(let reason):
            String(localized: "Login shell unavailable: \(reason.text). Using the app’s own environment.")
        case .managerDetected(let kind, let root):
            String(localized: "\(kind.rawValue) detected: \(root)")
        case .nvmDefaultNode(let path):
            String(localized: "nvm default Node: \(path)")
        case .nvmDefaultUnresolved:
            String(localized: "nvm found, but no default alias could be resolved.")
        case .pathAdded(let directory):
            String(localized: "Added to PATH: \(directory)")
        }
    }
}
