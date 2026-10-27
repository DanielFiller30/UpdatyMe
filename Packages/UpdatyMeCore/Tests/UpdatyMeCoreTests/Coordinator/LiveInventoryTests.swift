import Foundation
import Testing
import UpdatyMeCore

/// Läuft gegen den echten Rechner und ist deshalb standardmäßig aus:
/// `UPDATYME_LIVE_TESTS=1 swift test --filter LiveInventory`
@Suite("LiveInventory", .enabled(if: ProcessInfo.processInfo.environment["UPDATYME_LIVE_TESTS"] == "1"))
struct LiveInventoryTests {
    @Test func scansThisMac() async throws {
        let runner = CommandRunner()
        let environment = await EnvironmentResolver(runner: runner).resolve()
        let scan = await InventoryScanner(providers: [
            .init(.macOS, MacOSEcosystem(runner: runner)),
            .init(.brew, BrewEcosystem(runner: runner, environment: environment)),
            .init(.appBundle, AppBundleEcosystem()),
        ]).scan()

        for result in scan.results {
            switch result.outcome {
            case .success(let items):
                print("[live] \(result.ecosystem): \(items.count) Einträge in \(result.duration)")
            case .failure(let failure):
                print("[live] \(result.ecosystem): FEHLER \(failure)")
            }
        }
        let bySource = Dictionary(grouping: scan.items, by: \.source.rawValue).mapValues(\.count)
        print("[live] nach Deduplizierung: \(scan.items.count) Einträge, Quellen: \(bySource.sorted { $0.key < $1.key })")
        for item in scan.items where item.ecosystem != .brew || item.source == .cask {
            print("[live]   \(item.ecosystem) | \(item.name) | \(item.installedVersion) | \(item.source)")
        }

        #expect(scan.failures.isEmpty)
        #expect(!scan.items.filter { $0.ecosystem == .macOS }.isEmpty)
        #expect(!scan.items.filter { $0.ecosystem == .appBundle }.isEmpty)
    }
}

/// Akzeptanzkriterium Phase 4 gegen die echten Quellen: Der zweite Refresh innerhalb der TTL
/// sendet keine HTTP-Requests und startet weder `softwareupdate` noch `brew outdated` erneut.
/// `UPDATYME_LIVE_TESTS=1 swift test --filter LiveLatest`
@Suite("LiveLatest", .enabled(if: ProcessInfo.processInfo.environment["UPDATYME_LIVE_TESTS"] == "1"))
struct LiveLatestTests {
    actor CountingTransport: HTTPTransport {
        private let base = URLSessionTransport()
        private(set) var urls: [URL] = []

        func send(_ request: URLRequest) async throws -> HTTPResponse {
            urls.append(request.url!)
            return try await base.send(request)
        }
    }

    actor CountingRunner: CommandRunning {
        private let base = CommandRunner()
        private(set) var commands: [String] = []

        func stream(_ command: Command) async -> AsyncThrowingStream<CommandEvent, any Error> {
            commands.append(command.description)
            return await base.stream(command)
        }
    }

    @Test func secondRefreshWithinTTLMakesNoRequests() async throws {
        let directory = try TemporaryDirectory()
        let runner = CommandRunner()
        let environment = await EnvironmentResolver(runner: runner).resolve()
        let items = await InventoryScanner(providers: [
            .init(.macOS, MacOSEcosystem(runner: runner)),
            .init(.brew, BrewEcosystem(runner: runner, environment: environment)),
            .init(.appBundle, AppBundleEcosystem()),
        ]).scan().items

        let transport = CountingTransport()
        let counting = CountingRunner()
        func coordinator() -> RefreshCoordinator {
            .standard(
                http: CachingHTTPClient(transport: transport, cache: HTTPDiskCache(directory: directory.url.appendingPathComponent("http"))),
                commands: CachingCommandRunner(base: counting, directory: directory.url.appendingPathComponent("commands")),
                environment: environment, country: "de", systemVersion: "26.0"
            )
        }

        let first = await coordinator().latest(for: items)
        let requests = await transport.urls.count
        let commands = await counting.commands.count
        print("[live] 1. Refresh: \(first.remotes.count) Versionen, \(requests) Requests, \(commands) CLI-Aufrufe, Fehler: \(first.failures.mapValues(\.message)) \(first.itemErrors.count)")

        let second = await coordinator().latest(for: items)
        print("[live] 2. Refresh: \(second.remotes.count) Versionen, \(await transport.urls.count - requests) Requests, \(await counting.commands.count - commands) CLI-Aufrufe")

        #expect(requests > 0 && commands > 0)
        #expect(await transport.urls.count == requests)
        #expect(await counting.commands.count == commands)
        #expect(second.remotes.mapValues(\.version) == first.remotes.mapValues(\.version))
    }
}

/// Phase 6 gegen den echten Mac und echte Quellen. `UPDATYME_LIVE_TESTS=1 swift test --filter LiveDevTools`
@Suite("LiveDevTools", .enabled(if: ProcessInfo.processInfo.environment["UPDATYME_LIVE_TESTS"] == "1"))
struct LiveDevToolsTests {
    @Test func developerToolsAndConfiguredTool() async throws {
        let directory = try TemporaryDirectory()
        let runner = CommandRunner()
        let environment = await EnvironmentResolver(runner: runner).resolve()
        let scan = await InventoryScanner(providers: [
            .init(.brew, BrewEcosystem(runner: runner, environment: environment)),
            .init(.node, NodeEcosystem(environment: environment, runner: runner)),
            .init(.npm, NodePackagesEcosystem(.npm, environment: environment, runner: runner)),
            .init(.pnpm, NodePackagesEcosystem(.pnpm, environment: environment, runner: runner)),
            .init(.python, PythonEcosystem(environment: environment, runner: runner)),
            .init(.rust, RustEcosystem(environment: environment, runner: runner)),
            .init(.java, JavaEcosystem(environment: environment, runner: runner)),
            .init(.gcloud, GcloudEcosystem(environment: environment, runner: runner)),
        ]).scan()
        for result in scan.results {
            if case .failure(let failure) = result.outcome { print("[live] FEHLER \(result.ecosystem): \(failure)") }
        }
        let coordinator = RefreshCoordinator.standard(
            http: CachingHTTPClient(cache: HTTPDiskCache(directory: directory.url.appendingPathComponent("http"))),
            commands: CachingCommandRunner(base: runner, directory: directory.url.appendingPathComponent("commands")),
            environment: environment, country: "de", systemVersion: "26.0", nodeChannel: .lts
        )
        let devEcosystems: Set<EcosystemID> = [.node, .npm, .pnpm, .python, .rust, .java, .gcloud, .configuredTools]
        let items = scan.items.filter { devEcosystems.contains($0.ecosystem) || $0.metadata["brewRecordedVersion"] != nil }
        let latest = await coordinator.latest(for: items)
        let merged = RefreshCoordinator.merge(items, remotes: latest.remotes)
        for item in merged {
            let remote = latest.remotes[item.id]
            print("[live] \(item.ecosystem) | \(item.name) [\(item.source)] \(item.installedVersion) → \(item.latestVersion ?? "-") = \(item.status) via \(remote?.source ?? "-") newer=\(remote?.newerReleaseLine ?? "-") error=\(item.metadata["configError"] ?? latest.itemErrors[item.id]?.message ?? "-")")
        }
        print("[live] Quellen-Fehler: \(latest.failures.mapValues(\.message))")
        #expect(scan.failures.isEmpty)
        #expect(latest.failures.isEmpty)
        let swift = try #require(merged.first { $0.id == "config:swift" }, "Nur per Konfiguration ergänztes Tool")
        #expect(!swift.installedVersion.isEmpty)
        #expect(swift.latestVersion != nil)
    }
}

/// Phase 8: Zeitbudget eines vollständigen Refreshs (Scan + neueste Versionen) mit allen Quellen.
/// Kalt = leere Caches, warm = zweiter Lauf innerhalb der TTL. `UPDATYME_LIVE_TESTS=1 swift test --filter LivePerformance`
@Suite("LivePerformance", .enabled(if: ProcessInfo.processInfo.environment["UPDATYME_LIVE_TESTS"] == "1"))
struct LivePerformanceTests {
    /// Wie die App: Umgebung einmal aufgelöst (gecacht), softwareupdate im Hintergrund (nicht im Budget).
    static func fullRefresh(http: CachingHTTPClient, commands: CachingCommandRunner, runner: CommandRunner,
                            resolver: EnvironmentResolver) async -> (Duration, [EcosystemID: Duration], Int) {
        let clock = ContinuousClock()
        let start = clock.now
        let environment = await resolver.resolve()
        print("[perf]   Umgebung: \(start.duration(to: clock.now))")
        let scanStart = clock.now
        let scan = await InventoryScanner(providers: [
            .init(.macOS, MacOSEcosystem(runner: runner)),
            .init(.brew, BrewEcosystem(runner: runner, environment: environment)),
            .init(.appBundle, AppBundleEcosystem()),
            .init(.node, NodeEcosystem(environment: environment, runner: runner)),
            .init(.npm, NodePackagesEcosystem(.npm, environment: environment, runner: runner)),
            .init(.pnpm, NodePackagesEcosystem(.pnpm, environment: environment, runner: runner)),
            .init(.python, PythonEcosystem(environment: environment, runner: runner)),
            .init(.rust, RustEcosystem(environment: environment, runner: runner)),
            .init(.java, JavaEcosystem(environment: environment, runner: runner)),
            .init(.gcloud, GcloudEcosystem(environment: environment, runner: runner)),
        ]).scan()
        let scanDurations = Dictionary(uniqueKeysWithValues: scan.results.map { ($0.ecosystem, $0.duration) })
        print("[perf]   Scan gesamt: \(scanStart.duration(to: clock.now))")
        let coordinator = RefreshCoordinator.standard(http: http, commands: commands, environment: environment,
                                                      country: "de", systemVersion: "26.0")
        let latest = await coordinator.latest(for: scan.items, sources: coordinator.sources.subtracting(RefreshCoordinator.slowSources))
        let latestStart = clock.now
        _ = latestStart
        print("[perf]   Quellen: \(latest.durations.sorted { $0.value > $1.value }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))")
        return (start.duration(to: clock.now), scanDurations, latest.remotes.count)
    }

    @Test func coldAndWarmRefresh() async throws {
        let directory = try TemporaryDirectory()
        let runner = CommandRunner()
        let http = CachingHTTPClient(cache: HTTPDiskCache(directory: directory.url.appendingPathComponent("http")))
        let commands = CachingCommandRunner(base: runner, directory: directory.url.appendingPathComponent("commands"))

        let resolver = EnvironmentResolver(runner: runner)
        let (cold, coldScan, coldCount) = await Self.fullRefresh(http: http, commands: commands, runner: runner, resolver: resolver)
        let (warm, warmScan, warmCount) = await Self.fullRefresh(http: http, commands: commands, runner: runner, resolver: resolver)
        func format(_ d: [EcosystemID: Duration]) -> String {
            d.sorted { $0.value > $1.value }.map { "\($0.key)=\(String(format: "%.2f", Double($0.value.components.seconds) + Double($0.value.components.attoseconds) / 1e18))s" }.joined(separator: " ")
        }
        print("[perf] kalt: \(cold), \(coldCount) Versionen; Scan: \(format(coldScan))")
        print("[perf] warm: \(warm), \(warmCount) Versionen; Scan: \(format(warmScan))")
        #expect(cold < .seconds(30))
        #expect(warm < .seconds(3))
    }
}
