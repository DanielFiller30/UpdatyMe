import Foundation

/// Neueste Versionen für Brew-Formulae und -Casks über `brew outdated --json=v2 --greedy`.
///
/// - Nicht gelistete Einträge sind laut Brew aktuell.
/// - Vergleichbare Versionen werden selbst verglichen (robust, falls der Cache älter ist als ein
///   zwischenzeitliches Upgrade); sonst gilt Brews Urteil.
/// - `latest`-Versionen sind nicht bewertbar.
/// - Selbst-aktualisierende Casks: Verglichen wird die echte App-Version (siehe `BrewEcosystem`);
///   ist sie unbekannt, ist der Status nicht bewertbar, weil Brews eigener Stand veraltet sein kann.
/// - `brew update` wird nie ausgelöst (`HOMEBREW_NO_AUTO_UPDATE=1`).
public struct BrewLatestProvider: LatestVersionProvider {
    public static let source = "brew outdated"

    struct Outdated: Decodable {
        struct Entry: Decodable {
            var name: String
            var installedVersions: [String]
            var currentVersion: String

            enum CodingKeys: String, CodingKey {
                case name
                case installedVersions = "installed_versions"
                case currentVersion = "current_version"
            }
        }

        var formulae: [Entry]
        var casks: [Entry]
    }

    private let runner: any CommandRunning
    private let brew: BrewEcosystem
    private let environment: ResolvedEnvironment

    /// - Parameter runner: Sollte ein `CachingCommandRunner` sein.
    public init(runner: any CommandRunning, environment: ResolvedEnvironment, knownPrefixes: [String] = BrewEcosystem.knownPrefixes) {
        self.runner = runner
        self.environment = environment
        brew = BrewEcosystem(runner: runner, environment: environment, knownPrefixes: knownPrefixes)
    }

    public func latest(for item: InstalledItem) async throws -> RemoteVersion? {
        try await latest(for: [item])[item.id]?.get() ?? nil
    }

    public func latest(for items: [InstalledItem]) async -> [InstalledItem.ID: Result<RemoteVersion?, any Error>] {
        let outdated: Outdated
        do {
            outdated = try await fetchOutdated()
        } catch {
            return Dictionary(uniqueKeysWithValues: items.map { ($0.id, .failure(error)) })
        }
        let formulae = Dictionary(outdated.formulae.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let casks = Dictionary(outdated.casks.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })

        var results: [InstalledItem.ID: Result<RemoteVersion?, any Error>] = [:]
        for item in items where item.ecosystem == .brew {
            let fullName = item.metadata[InstalledItem.MetadataKey.brewFullName] ?? item.name
            let entry = item.source == .cask ? casks[fullName] : formulae[fullName]
            results[item.id] = .success(Self.remoteVersion(for: item, outdated: entry))
        }
        return results
    }

    static func remoteVersion(for item: InstalledItem, outdated entry: Outdated.Entry?) -> RemoteVersion {
        let isAutoUpdatingCask = item.source == .cask && item.metadata["autoUpdates"] == "true"
        let usesRealAppVersion = item.metadata[BrewEcosystem.brewRecordedVersionKey] != nil

        guard let entry else {
            // Laut Brew aktuell.
            let undeterminable = item.installedVersion == "latest" || item.installedVersion.isEmpty
            return RemoteVersion(itemID: item.id, version: item.installedVersion, source: source,
                                 assessment: undeterminable ? .undeterminable : .upToDate)
        }

        if entry.currentVersion == "latest" {
            return RemoteVersion(itemID: item.id, version: entry.currentVersion, source: source, assessment: .undeterminable)
        }
        if isAutoUpdatingCask {
            guard usesRealAppVersion else {
                return RemoteVersion(itemID: item.id, version: entry.currentVersion, source: source, assessment: .undeterminable)
            }
            // App-Versionen tragen keinen Cask-Build-Zusatz („3.9,3.9.0.88839“ → „3.9“); bei Tools ggf.
            // ein eigenes Muster („py314_26.9.4-0“ → „26.9.4“).
            var main = String(entry.currentVersion.split(separator: ",", maxSplits: 1).first ?? "")
            if let pattern = item.metadata[BrewEcosystem.latestVersionPatternKey] {
                guard let extracted = DevTools.firstMatch(pattern, in: entry.currentVersion) else {
                    return RemoteVersion(itemID: item.id, version: entry.currentVersion, source: source, assessment: .undeterminable)
                }
                main = extracted
            }
            return RemoteVersion(itemID: item.id, version: main, source: source, assessment: .compareVersions)
        }
        if VersionComparator.compare(item.installedVersion, entry.currentVersion) != nil {
            return RemoteVersion(itemID: item.id, version: entry.currentVersion, source: source, assessment: .compareVersions)
        }
        let assessment: RemoteVersion.Assessment = entry.installedVersions.contains(item.installedVersion)
            ? .outdated : .undeterminable
        return RemoteVersion(itemID: item.id, version: entry.currentVersion, source: source, assessment: assessment)
    }

    private func fetchOutdated() async throws -> Outdated {
        guard let executable = brew.locateBrew() else {
            throw InventoryError.toolNotFound("Homebrew")
        }
        var processEnvironment = environment.processEnvironment
        processEnvironment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        let command = Command(
            executable: executable,
            arguments: ["outdated", "--json=v2", "--greedy"],
            environment: processEnvironment,
            timeout: .seconds(180)
        )
        let output = try await runner.runChecked(command).stdout
        do {
            return try JSONDecoder().decode(Outdated.self, from: Data(output.utf8))
        } catch {
            throw InventoryError.unexpectedOutput(source: "brew outdated", detail: String(describing: error))
        }
    }
}
