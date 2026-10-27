import Foundation
import UpdatyMeCore

/// Beispieldaten für Previews und Snapshot-Tests. Enthält bewusst alle Status.
enum SampleInventory {
    static let favorites: Set<InstalledItem.ID> = ["brew:Fork", "brew:python@3.12"]

    static let items: [InstalledItem] = [
        item("macOS", kind: .os, ecosystem: .macOS, version: "26.7.1", latest: "26.8", source: .system,
             status: .outdated, capability: .openSettings),
        item("Safari", kind: .app, ecosystem: .appBundle, version: "27.0", source: .system,
             status: .upToDate, capability: .openSettings, path: "/Applications/Safari.app"),
        item("Fork", kind: .app, ecosystem: .brew, version: "2.70.2", latest: "2.71.0", source: .cask,
             status: .outdated, path: "/Applications/Fork.app"),
        item("Spotify", kind: .app, ecosystem: .appBundle, version: "1.3.6.1921", source: .manual,
             status: .unknown, capability: .manual, path: "/Applications/Spotify.app"),
        item("Xcode", kind: .app, ecosystem: .appBundle, version: "26.6", source: .manual,
             status: .unknown, capability: .manual, path: "/Applications/Xcode.app"),
        item("ripgrep", kind: .cli, ecosystem: .brew, version: "15.2.0", latest: "15.2.0", source: .brew,
             status: .upToDate, path: "/opt/homebrew/Cellar/ripgrep/15.2.0"),
        item("python@3.12", kind: .cli, ecosystem: .brew, version: "3.12.15_1", latest: "4.0.0", source: .brew,
             status: .outdated, major: true, path: "/opt/homebrew/Cellar/python@3.12/3.12.15_1"),
        item("docker", kind: .cli, ecosystem: .brew, version: "29.8.0", latest: "29.9.2", source: .brew,
             status: .pinned, path: "/opt/homebrew/Cellar/docker/29.8.0"),
        item("libpng", kind: .package, ecosystem: .brew, version: "1.6.59", source: .brew,
             status: .unknown, path: "/opt/homebrew/Cellar/libpng/1.6.59"),
    ]

    private static func item(
        _ name: String,
        kind: InstalledItem.Kind,
        ecosystem: EcosystemID,
        version: String,
        latest: String? = nil,
        source: ItemSource,
        status: InstalledItem.Status,
        major: Bool = false,
        capability: InstalledItem.UpdateCapability = .auto,
        path: String? = nil
    ) -> InstalledItem {
        InstalledItem(
            id: InstalledItem.makeID(ecosystem: ecosystem, identifier: name),
            name: name,
            kind: kind,
            ecosystem: ecosystem,
            installedVersion: version,
            installPath: path,
            source: source,
            latestVersion: latest,
            status: status,
            updateCapability: capability,
            isMajorUpdate: major
        )
    }
}
