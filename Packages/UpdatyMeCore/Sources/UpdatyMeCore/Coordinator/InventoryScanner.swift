import Foundation

/// Führt alle Inventory-Provider parallel aus. Der Fehler eines Providers bricht die anderen
/// nicht ab; er wird pro Ökosystem im Ergebnis gemeldet. Ein nicht installiertes Werkzeug
/// (`InventoryError.toolNotFound`, z. B. kein Homebrew) ist kein Fehler, sondern ein leeres Ergebnis
/// mit Hinweis in `unavailableTool` – auf einem frischen Mac ist das normal.
///
/// Doppelungen: Per Cask installierte Apps erscheinen nur einmal – als Cask. App-Bundles, deren
/// Pfad in den App-Pfaden eines Casks steht, werden entfernt (nur wenn der Brew-Scan gelungen ist).
public struct InventoryScanner: Sendable {
    public struct Provider: Sendable {
        public var ecosystem: EcosystemID
        public var provider: any InventoryProvider

        public init(_ ecosystem: EcosystemID, _ provider: any InventoryProvider) {
            self.ecosystem = ecosystem
            self.provider = provider
        }
    }

    public struct EcosystemResult: Sendable {
        public var ecosystem: EcosystemID
        /// Erfolgreich: alle Einträge des Providers (vor der Deduplizierung).
        public var outcome: Result<[InstalledItem], ScanFailure>
        public var duration: Duration
        /// Name des fehlenden Werkzeugs, falls der Provider deshalb nichts liefern konnte.
        public var unavailableTool: String?
    }

    /// Fehler eines Providers. `error` bleibt strukturiert erhalten (z. B. `InventoryError`),
    /// damit die App ihn übersetzen kann; `message` ist die technische englische Beschreibung.
    public struct ScanFailure: Error, Sendable, CustomStringConvertible {
        public var error: any Error & Sendable
        public var message: String { String(describing: error) }

        public init(error: any Error & Sendable) {
            self.error = error
        }
        public var description: String { message }
    }

    public struct Scan: Sendable {
        /// In der Reihenfolge der registrierten Provider.
        public var results: [EcosystemResult]
        /// Zusammengeführte, deduplizierte Einträge aller erfolgreichen Provider.
        public var items: [InstalledItem]

        public var failures: [(ecosystem: EcosystemID, failure: ScanFailure)] {
            results.compactMap { result in
                if case .failure(let failure) = result.outcome { return (result.ecosystem, failure) }
                return nil
            }
        }
    }

    private let providers: [Provider]

    public init(providers: [Provider]) {
        self.providers = providers
    }

    public func scan() async -> Scan {
        let results = await withTaskGroup(of: (Int, EcosystemResult).self) { group in
            for (index, entry) in providers.enumerated() {
                group.addTask {
                    let clock = ContinuousClock()
                    let start = clock.now
                    let outcome: Result<[InstalledItem], ScanFailure>
                    var unavailable: String?
                    do {
                        outcome = .success(try await entry.provider.scan())
                    } catch InventoryError.toolNotFound(let tool) {
                        unavailable = tool
                        outcome = .success([])
                    } catch {
                        outcome = .failure(ScanFailure(error: error))
                    }
                    return (index, EcosystemResult(ecosystem: entry.ecosystem, outcome: outcome,
                                                   duration: start.duration(to: clock.now), unavailableTool: unavailable))
                }
            }
            var collected: [(Int, EcosystemResult)] = []
            for await result in group {
                collected.append(result)
            }
            return collected.sorted { $0.0 < $1.0 }.map(\.1)
        }

        let all = results.flatMap { (try? $0.outcome.get()) ?? [] }
        return Scan(results: results, items: Self.removingBrewManagedDuplicates(Self.removingCaskDuplicates(all)))
    }

    static func removingCaskDuplicates(_ items: [InstalledItem]) -> [InstalledItem] {
        let caskAppPaths = Set(
            items.filter { $0.source == .cask }
                .compactMap { $0.metadata[InstalledItem.MetadataKey.caskAppPaths] }
                .flatMap { $0.split(separator: "\n").map { standardized(String($0)) } }
        )
        guard !caskAppPaths.isEmpty else { return items }
        return items.filter { item in
            guard item.ecosystem == .appBundle, let path = item.installPath else { return true }
            return !caskAppPaths.contains(standardized(path))
        }
    }

    /// Einträge mit `brewCaskCandidates` (z. B. JDKs) entfallen, wenn ein passender Cask dieselbe Version hat
    /// (`zulu@25` mit `25.0.5,25.38.107` ↔ Java `25.0.5`).
    static func removingBrewManagedDuplicates(_ items: [InstalledItem]) -> [InstalledItem] {
        let casks = items.filter { $0.source == .cask }
        guard !casks.isEmpty else { return items }
        return items.filter { item in
            guard let candidates = item.metadata[InstalledItem.MetadataKey.brewCaskCandidates]?.split(separator: ","),
                  !candidates.isEmpty else { return true }
            return !casks.contains { cask in
                let token = cask.metadata[InstalledItem.MetadataKey.brewFullName] ?? ""
                let version = cask.metadata[BrewEcosystem.brewRecordedVersionKey] ?? cask.installedVersion
                let main = version.split(separator: ",", maxSplits: 1).first.map(String.init) ?? version
                return candidates.contains { token.hasPrefix($0) } && main == item.installedVersion
            }
        }
    }

    /// Kleinschreibung, weil APFS standardmäßig Groß-/Kleinschreibung ignoriert.
    private static func standardized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path.lowercased()
    }
}
