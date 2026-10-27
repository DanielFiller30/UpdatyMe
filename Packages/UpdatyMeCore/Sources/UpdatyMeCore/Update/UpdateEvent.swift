import Foundation

/// Live-Ereignisse eines Updates. Fehler werden über den Stream geworfen (`UpdateError`).
public enum UpdateEvent: Sendable, Hashable {
    case output(line: String, isError: Bool)
    /// Fortschritt 0…1, `nil` = unbestimmt.
    case progress(Double?)
    /// `newVersion` ist `nil`, wenn erst ein erneuter Scan die neue Version ermittelt.
    case completed(newVersion: String?, restartRequired: Bool)
}

public enum UpdateError: Error, Sendable, Hashable, CustomStringConvertible {
    /// Das Update braucht Administratorrechte (sudo). In v1 bewusst nicht unterstützt.
    case requiresAdministrator(detail: String)
    /// Der Befehl schlug fehl; `reason` ist die aussagekräftigste Fehlerzeile.
    case failed(exitCode: Int32, reason: String)
    /// Für diesen Eintrag gibt es keinen automatischen Update-Weg.
    case unsupported(String)
    /// Kein `completed`-Ereignis (z. B. abgebrochen).
    case incomplete

    public var description: String {
        switch self {
        case .requiresAdministrator(let detail): "Requires administrator privileges: \(detail)"
        case .failed(let exitCode, let reason): "Failed with exit code \(exitCode): \(reason)"
        case .unsupported(let item): "No automatic update for \(item)"
        case .incomplete: "Update did not complete"
        }
    }
}

extension InstalledItem.MetadataKey {
    /// Cask-Token für „In Homebrew übernehmen“ (`brew install --cask --adopt`), gesetzt nur für diesen Auftrag.
    public static let adoptCask = "adoptCask"
}

extension InstalledItem {
    /// Mit `brew pin` fixiert (wird angezeigt, aber nur in Brew lösbar).
    public var isPinnedInBrew: Bool {
        metadata[MetadataKey.brewPinned] == "true"
    }

    /// Cask, in den diese manuell installierte App übernommen werden kann: eindeutiger Cask-Treffer und
    /// **gleiche** Version (Brew übernimmt nur identische Apps). Sonst `nil`.
    public func adoptableCaskToken(remote: RemoteVersion?) -> String? {
        guard ecosystem == .appBundle, source == .manual, installPath != nil,
              let remote, let token = CaskMatchLatestProvider.token(fromSource: remote.source),
              VersionComparator.compare(installedVersion, remote.version) == .orderedSame else {
            return nil
        }
        return token
    }

    /// Auftrag „In Homebrew übernehmen“ für die Warteschlange.
    public func adoptionJob(token: String) -> InstalledItem {
        var job = self
        job.metadata[MetadataKey.adoptCask] = token
        return job
    }

    /// Per Knopfdruck aktualisierbar: Update verfügbar, automatischer Weg, nicht fixiert.
    public var canUpdateAutomatically: Bool {
        status == .outdated && updateCapability == .auto
    }

    /// App-Bundles, die vor dem Update nicht laufen sollten (Casks mit App).
    public var appPathsToCheckBeforeUpdate: [String] {
        guard source == .cask, let paths = metadata[MetadataKey.caskAppPaths] else { return [] }
        return paths.split(separator: "\n").map(String.init)
    }
}
