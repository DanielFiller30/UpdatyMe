import Foundation

/// Orchestriert Scan → neueste Versionen → Zusammenführen.
///
/// Jeder Eintrag wird genau einer Quelle zugeordnet (erste passende Route). Quellen laufen parallel;
/// innerhalb einer Quelle begrenzt `LatestVersionProvider.latest(for:)` die Parallelität. Fehler betreffen
/// nur den Eintrag (`itemErrors`) bzw. – wenn alle Einträge einer Quelle scheitern – die Quelle (`failures`).
/// Die TTL-Caches (`CachingHTTPClient`, `CachingCommandRunner`) liegen in den Quellen.
public struct RefreshCoordinator: Sendable {
    public struct Route: Sendable {
        public var source: EcosystemID
        public var provider: any LatestVersionProvider
        public var handles: @Sendable (InstalledItem) -> Bool

        public init(_ source: EcosystemID, _ provider: any LatestVersionProvider, handles: @escaping @Sendable (InstalledItem) -> Bool) {
            self.source = source
            self.provider = provider
            self.handles = handles
        }
    }

    public struct LatestResult: Sendable {
        public var remotes: [InstalledItem.ID: RemoteVersion] = [:]
        /// Quellen, bei denen jede Abfrage scheiterte (z. B. kein Netz, Brew fehlt).
        public var failures: [EcosystemID: InventoryScanner.ScanFailure] = [:]
        /// Einzelne gescheiterte Abfragen (z. B. ein nicht erreichbarer Appcast).
        public var itemErrors: [InstalledItem.ID: InventoryScanner.ScanFailure] = [:]
        /// Dauer je Quelle (für Diagnose und Zeitbudget).
        public var durations: [EcosystemID: Duration] = [:]
    }

    private let routes: [Route]

    public init(routes: [Route]) {
        self.routes = routes
    }

    /// Alle Quellen dieses Koordinators.
    public var sources: Set<EcosystemID> { Set(routes.map(\.source)) }

    /// Einträge, die von einer der Quellen bearbeitet werden.
    public func items(_ items: [InstalledItem], handledBy sources: Set<EcosystemID>) -> [InstalledItem] {
        items.filter { item in routes.first { $0.handles(item) }.map { sources.contains($0.source) } ?? false }
    }

    /// Standard-Zuordnung (Plan Abschnitt 5): macOS → softwareupdate, Brew → brew outdated,
    /// App Store → iTunes Lookup, Sparkle → Appcast, manuell installierte Apps → Cask-Abgleich.
    /// System-Apps haben keine Quelle (Update mit macOS) und bleiben `unknown`.
    /// Entwickler-Tools: Node → nodejs.org, npm/pnpm → npm, Python → endoflife.date (uv: `uv python list`), pipx/uv → PyPI,
    /// Rust → static.rust-lang.org, cargo → crates.io, Java → foojay, gcloud → dl.google.com, Config → `tools.json`.
    public static func standard(
        http: CachingHTTPClient,
        commands: CachingCommandRunner,
        environment: ResolvedEnvironment,
        country: String,
        systemVersion: String,
        nodeChannel: NodeLatestProvider.Channel = .lts
    ) -> RefreshCoordinator {
        RefreshCoordinator(routes: [
            .init(.softwareUpdate, SoftwareUpdateLatestProvider(runner: commands)) { $0.ecosystem == .macOS && $0.kind == .os },
            .init(.brewOutdated, BrewLatestProvider(runner: commands, environment: environment)) { $0.ecosystem == .brew },
            .init(.appStore, AppStoreLatestProvider(http: http, country: country)) { $0.ecosystem == .appBundle && $0.source == .mas },
            .init(.sparkle, SparkleLatestProvider(http: http, systemVersion: systemVersion)) { $0.ecosystem == .appBundle && $0.source == .sparkle },
            .init(.caskMatch, CaskMatchLatestProvider(http: http)) { $0.ecosystem == .appBundle && $0.source == .manual },
            // Entwickler-Tools (Phase 6)
            .init(.nodeReleases, NodeLatestProvider(http: http, channel: nodeChannel)) { $0.ecosystem == .node },
            .init(.npmRegistry, RegistryLatestProvider(http: http, registry: .npm)) { $0.ecosystem == .npm || $0.ecosystem == .pnpm },
            .init(.pythonReleases, PythonLatestProvider(http: http, runner: commands, environment: environment)) { $0.ecosystem == .python && $0.kind == .runtime },
            .init(.pypi, RegistryLatestProvider(http: http, registry: .pypi)) { $0.ecosystem == .python && $0.kind == .package },
            .init(.rustReleases, RustLatestProvider(http: http)) { $0.ecosystem == .rust && $0.kind == .runtime },
            .init(.crates, RegistryLatestProvider(http: http, registry: .crates)) { $0.ecosystem == .rust && $0.kind == .package },
            .init(.javaReleases, JavaLatestProvider(http: http)) { $0.ecosystem == .java },
            .init(.gcloudReleases, GcloudLatestProvider(http: http)) { $0.ecosystem == .gcloud },
            .init(.configuredToolReleases, ConfiguredToolLatestProvider(http: http)) { $0.ecosystem == .configuredTools },
        ])
    }

    /// Quellen, die deutlich länger brauchen (softwareupdate: live ~70 s) und deshalb im Hintergrund laufen.
    public static let slowSources: Set<EcosystemID> = [.softwareUpdate]

    /// Ermittelt die neuesten Versionen für alle zuordenbaren Einträge.
    /// - Parameter sources: Nur diese Quellen abfragen (`nil` = alle). Die Zuordnung Eintrag → Quelle bleibt
    ///   global; Einträge anderer Quellen werden übersprungen, nie einer anderen Quelle zugeschlagen.
    public func latest(for items: [InstalledItem], sources: Set<EcosystemID>? = nil) async -> LatestResult {
        var assigned: [Int: [InstalledItem]] = [:]
        for item in items {
            if let index = routes.firstIndex(where: { $0.handles(item) }),
               sources?.contains(routes[index].source) ?? true {
                assigned[index, default: []].append(item)
            }
        }

        let perRoute = await withTaskGroup(of: (EcosystemID, Int, [InstalledItem.ID: Result<RemoteVersion?, any Error>], Duration).self) { group in
            for (index, routeItems) in assigned {
                let route = routes[index]
                group.addTask {
                    let clock = ContinuousClock()
                    let start = clock.now
                    let outcomes = await route.provider.latest(for: routeItems)
                    return (route.source, routeItems.count, outcomes, start.duration(to: clock.now))
                }
            }
            var collected: [(EcosystemID, Int, [InstalledItem.ID: Result<RemoteVersion?, any Error>], Duration)] = []
            for await entry in group {
                collected.append(entry)
            }
            return collected
        }

        var result = LatestResult()
        for (source, count, outcomes, duration) in perRoute {
            result.durations[source] = duration
            var errors: [InstalledItem.ID: InventoryScanner.ScanFailure] = [:]
            for (id, outcome) in outcomes {
                switch outcome {
                case .success(let remote?):
                    result.remotes[id] = remote
                case .success(nil):
                    break
                case .failure(let error):
                    errors[id] = InventoryScanner.ScanFailure(error: error)
                }
            }
            if count > 0, errors.count == count, let first = errors.values.first {
                result.failures[source] = first
            } else {
                result.itemErrors.merge(errors) { first, _ in first }
            }
        }
        return result
    }

    /// Wendet neueste Versionen auf die Einträge an. In Brew (`brew pin`) oder in der App fixierte
    /// Einträge bleiben `pinned`.
    public static func merge(
        _ items: [InstalledItem],
        remotes: [InstalledItem.ID: RemoteVersion],
        pinned: Set<InstalledItem.ID> = []
    ) -> [InstalledItem] {
        items.map { item in
            item.applying(latest: remotes[item.id], isPinned: item.isPinnedInBrew || pinned.contains(item.id))
        }
    }
}

