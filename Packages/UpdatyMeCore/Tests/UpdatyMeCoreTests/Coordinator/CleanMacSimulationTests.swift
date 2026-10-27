import Foundation
import Testing
@testable import UpdatyMeCore
import UpdatyMeCoreTestSupport

/// Phase 8 (Simulation statt VM, Entscheidung des Nutzers): ein frischer Mac ohne Homebrew, nvm, pnpm,
/// JDK, Developer-Tools, ohne eigene Apps und ohne Netz. Erwartet: kein Fehler, nur macOS als Eintrag.
@Suite("CleanMacSimulation")
struct CleanMacSimulationTests {
    /// Netz nicht erreichbar: jede Anfrage scheitert wie offline.
    actor OfflineTransport: HTTPTransport {
        private(set) var requests = 0
        func send(_ request: URLRequest) async throws -> HTTPResponse {
            requests += 1
            throw URLError(.notConnectedToInternet)
        }
    }

    @Test func freshMacWithoutDeveloperToolsAndOffline() async throws {
        let home = try TemporaryDirectory()
        let emptyBin = try home.makeDirectory("usr-bin")
        let applications = try home.makeDirectory("Applications")
        let environment = ResolvedEnvironment(source: .fallback(reason: .exitCode(1)), variables: ["HOME": home.url.path],
                                              searchPath: [emptyBin.path])

        let mock = MockCommandRunner()
        await mock.stub(MacOSEcosystem.swVers, stdout: try Fixture.string("MacOS/sw_vers.txt"))
        await mock.stub(MacOSEcosystem.sysctl, stdout: try Fixture.string("MacOS/sysctl-kern.osversion.txt"))
        await mock.stub(PythonEcosystem.xcodeSelect, exitCode: 2,
                        stderr: "xcode-select: error: unable to get active developer directory")
        await mock.stub(JavaEcosystem.javaHome, exitCode: 1, stderr: "Unable to find any JVMs matching version \"(null)\".")
        await mock.stub(SoftwareUpdateLatestProvider.path, stdout: try Fixture.string("Latest/softwareupdate-none.stdout.txt"),
                        stderr: try Fixture.string("Latest/softwareupdate-none.stderr.txt"))

        let scan = await InventoryScanner(providers: [
            .init(.macOS, MacOSEcosystem(runner: mock)),
            .init(.brew, BrewEcosystem(runner: mock, environment: environment, knownPrefixes: [])),
            .init(.appBundle, AppBundleEcosystem(searchDirectories: [applications])),
            .init(.node, NodeEcosystem(environment: environment, runner: mock)),
            .init(.npm, NodePackagesEcosystem(.npm, environment: environment, runner: mock)),
            .init(.pnpm, NodePackagesEcosystem(.pnpm, environment: environment, runner: mock)),
            .init(.python, PythonEcosystem(environment: environment, runner: mock, homeDirectory: home.url)),
            .init(.rust, RustEcosystem(environment: environment, runner: mock, homeDirectory: home.url)),
            .init(.java, JavaEcosystem(environment: environment, runner: mock)),
            .init(.gcloud, GcloudEcosystem(environment: environment, runner: mock, brewPrefixes: [])),
            .init(.configuredTools, ConfiguredToolsEcosystem(configuration: home.url.appendingPathComponent("tools.json"),
                                                             environment: environment, runner: mock)),
        ]).scan()

        #expect(scan.failures.isEmpty, "\(scan.failures.map { "\($0.ecosystem): \($0.failure)" })")
        #expect(scan.items.map(\.name) == ["macOS"])
        #expect(scan.results.first { $0.ecosystem == .brew }?.unavailableTool == "Homebrew")

        let transport = OfflineTransport()
        let coordinator = RefreshCoordinator.standard(
            http: CachingHTTPClient(transport: transport, cache: HTTPDiskCache(directory: home.url.appendingPathComponent("http"))),
            commands: CachingCommandRunner(base: mock, directory: home.url.appendingPathComponent("commands")),
            environment: environment, country: "de", systemVersion: "26.7.1"
        )
        let latest = await coordinator.latest(for: scan.items)
        #expect(latest.failures.isEmpty)
        #expect(latest.itemErrors.isEmpty)
        #expect(await transport.requests == 0, "Ohne Apps/Tools keine Netzabfragen")
        let merged = RefreshCoordinator.merge(scan.items, remotes: latest.remotes)
        #expect(merged.first?.status == .upToDate)
    }

    @Test func offlineWithToolsFailsPerSourceWithNetworkError() async throws {
        let home = try TemporaryDirectory()
        let transport = OfflineTransport()
        let http = CachingHTTPClient(transport: transport, cache: HTTPDiskCache(directory: home.url))
        let node = InstalledItem(id: "node:nvm/24.0.0", name: "Node.js", kind: .runtime, ecosystem: .node, installedVersion: "24.0.0",
                                 source: .nvm, updateCapability: .manual)
        let coordinator = RefreshCoordinator(routes: [.init(.nodeReleases, NodeLatestProvider(http: http, channel: .lts)) { _ in true }])
        let result = await coordinator.latest(for: [node])
        let error = try #require(result.failures[.nodeReleases]?.error as? URLError)
        #expect(error.code == .notConnectedToInternet)
        #expect(RefreshCoordinator.merge([node], remotes: result.remotes).first?.status == .unknown, "Offline nie fälschlich „aktuell“")
    }
}
