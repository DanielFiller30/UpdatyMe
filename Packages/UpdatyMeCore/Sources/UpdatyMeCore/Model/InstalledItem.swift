import Foundation

/// Ein lokal installierter Eintrag (macOS, App, CLI-Tool, Runtime, Paket).
/// Werttyp für Provider und UI; persistiert wird er über `InventoryStore`.
public struct InstalledItem: Sendable, Hashable, Codable, Identifiable {
    public enum Kind: String, Sendable, Hashable, Codable, CaseIterable {
        case os, app, cli, runtime, package
    }

    public enum Status: String, Sendable, Hashable, Codable, CaseIterable {
        case upToDate, outdated, unknown, pinned
    }

    public enum UpdateCapability: String, Sendable, Hashable, Codable, CaseIterable {
        /// Per Knopfdruck aktualisierbar.
        case auto
        /// Nur manuell (z. B. erfordert sudo oder Download-Seite).
        case manual
        /// Öffnet die Systemeinstellungen (macOS).
        case openSettings
        case none
    }

    /// Stabile Kennung, z. B. `brew:formula/node`. Siehe `makeID(ecosystem:identifier:)`.
    public var id: String
    public var name: String
    public var kind: Kind
    public var ecosystem: EcosystemID
    public var installedVersion: String
    public var installPath: String?
    public var source: ItemSource
    public var latestVersion: String?
    public var status: Status
    public var updateCapability: UpdateCapability
    public var isMajorUpdate: Bool
    /// Provider-spezifische Zusatzinfos (z. B. Bundle-ID, Cask-Token, SUFeedURL).
    public var metadata: [String: String]

    public init(
        id: String,
        name: String,
        kind: Kind,
        ecosystem: EcosystemID,
        installedVersion: String,
        installPath: String? = nil,
        source: ItemSource,
        latestVersion: String? = nil,
        status: Status = .unknown,
        updateCapability: UpdateCapability = .none,
        isMajorUpdate: Bool = false,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.ecosystem = ecosystem
        self.installedVersion = installedVersion
        self.installPath = installPath
        self.source = source
        self.latestVersion = latestVersion
        self.status = status
        self.updateCapability = updateCapability
        self.isMajorUpdate = isMajorUpdate
        self.metadata = metadata
    }

    public static func makeID(ecosystem: EcosystemID, identifier: String) -> String {
        "\(ecosystem.rawValue):\(identifier)"
    }

    /// Übernimmt die neueste Version und leitet `status` und `isMajorUpdate` ab.
    /// Ohne neueste Version, ohne vergleichbare Versionen oder bei `undeterminable` bleibt der Status
    /// `unknown` – nie fälschlich „aktuell“. Entscheidet die Quelle selbst (`outdated`/`upToDate`),
    /// gilt ihr Urteil; „Major“ wird dann nur gesetzt, wenn beide Versionen vergleichbar sind.
    public func applying(
        latest remote: RemoteVersion?,
        isPinned: Bool = false,
        scheme: Version.Scheme = .automatic
    ) -> InstalledItem {
        var item = self
        item.latestVersion = remote?.version
        item.isMajorUpdate = false

        if isPinned {
            item.status = .pinned
            return item
        }
        guard let remote else {
            item.status = .unknown
            return item
        }
        let installed = Version(installedVersion, scheme: scheme)
        let latest = Version(remote.version, scheme: scheme)
        let isMajor = { () -> Bool in
            guard let installed, let latest else { return false }
            return VersionComparator.isMajorUpdate(from: installed, to: latest)
        }

        switch remote.assessment {
        case .undeterminable:
            item.status = .unknown
        case .outdated:
            item.status = .outdated
            item.isMajorUpdate = isMajor()
        case .upToDate:
            item.status = .upToDate
        case .compareVersions:
            guard let installed, let latest else {
                item.status = .unknown
                return item
            }
            if installed < latest {
                item.status = .outdated
                item.isMajorUpdate = isMajor()
            } else {
                item.status = .upToDate
            }
        }
        return item
    }
}
