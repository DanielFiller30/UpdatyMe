import Foundation
import Synchronization
import Testing
@testable import UpdatyMeCore
import UpdatyMeCoreTestSupport

@Suite("CachingCommandRunner")
struct CachingCommandRunnerTests {
    final class Clock: Sendable {
        private let current = Mutex(Date(timeIntervalSince1970: 1_800_000_000))
        var now: Date { current.withLock { $0 } }
        func advance(by seconds: TimeInterval) { current.withLock { $0 += seconds } }
    }

    @Test func servesFromCacheWithinTTLAndAcrossInstances() async throws {
        let directory = try TemporaryDirectory()
        let mock = MockCommandRunner()
        await mock.stub("/usr/sbin/softwareupdate", stdout: "a\nb\n")
        let clock = Clock()
        func runner() -> CachingCommandRunner {
            CachingCommandRunner(base: mock, directory: directory.url, now: { clock.now })
        }
        let command = Command("/usr/sbin/softwareupdate", ["--list"])

        #expect(try await runner().run(command).stdout == "a\nb\n")
        clock.advance(by: 6 * 3600 - 1)
        var events: [CommandEvent] = []
        for try await event in await runner().stream(command) { events.append(event) }
        #expect(events == [.stdoutLine("a"), .stdoutLine("b"), .completed(CommandResult(exitCode: 0, stdout: "a\nb\n"))])
        #expect(await mock.invocations.count == 1)

        clock.advance(by: 1)
        _ = try await runner().run(command)
        #expect(await mock.invocations.count == 2, "Nach Ablauf der TTL wird neu abgefragt")
    }

    @Test func doesNotCacheFailuresAndRemoveAllForcesRerun() async throws {
        let directory = try TemporaryDirectory()
        let mock = MockCommandRunner()
        await mock.stub("/bin/x", exitCode: 1)
        let runner = CachingCommandRunner(base: mock, directory: directory.url)
        _ = try await runner.run(Command("/bin/x"))
        _ = try await runner.run(Command("/bin/x"))
        #expect(await mock.invocations.count == 2)

        await mock.stub("/bin/y", stdout: "ok")
        _ = try await runner.run(Command("/bin/y"))
        await runner.removeAll()
        _ = try await runner.run(Command("/bin/y"))
        #expect(await mock.invocations.count == 4)
    }

    @Test func differentArgumentsAreDifferentEntries() async throws {
        let directory = try TemporaryDirectory()
        let mock = MockCommandRunner()
        await mock.stub("/bin/x", arguments: ["1"], stdout: "one")
        await mock.stub("/bin/x", arguments: ["2"], stdout: "two")
        let runner = CachingCommandRunner(base: mock, directory: directory.url)
        #expect(try await runner.run(Command("/bin/x", ["1"])).stdout == "one")
        #expect(try await runner.run(Command("/bin/x", ["2"])).stdout == "two")
    }
}

@Suite("RefreshCoordinator")
struct RefreshCoordinatorTests {
    struct Fixed: LatestVersionProvider {
        var versions: [String: String] = [:]
        var failing: Set<String> = []

        func latest(for item: InstalledItem) async throws -> RemoteVersion? {
            if failing.contains(item.id) { throw InventoryError.unexpectedOutput(source: "test", detail: item.id) }
            return versions[item.id].map { RemoteVersion(itemID: item.id, version: $0, source: "test") }
        }
    }

    static func app(_ id: String, _ version: String, source: ItemSource = .manual, pinned: Bool = false) -> InstalledItem {
        InstalledItem(id: id, name: id, kind: .app, ecosystem: .appBundle, installedVersion: version, source: source,
                      metadata: pinned ? ["pinned": "true"] : [:])
    }

    @Test func routesEachItemToFirstMatchingSourceAndIsolatesErrors() async {
        let items = [Self.app("a", "1.0"), Self.app("b", "1.0", source: .sparkle), Self.app("c", "1.0", source: .sparkle), Self.app("s", "1.0", source: .system)]
        let coordinator = RefreshCoordinator(routes: [
            .init("sparkle", Fixed(versions: ["b": "2.0"], failing: ["c"])) { $0.source == .sparkle },
            .init("cask", Fixed(versions: ["a": "1.0", "b": "9.9"])) { $0.source == .manual || $0.source == .sparkle },
            .init("never", Fixed(failing: ["a", "b", "c", "s"])) { _ in true },
        ])
        let result = await coordinator.latest(for: Array(items.prefix(3)))
        #expect(result.remotes["b"]?.version == "2.0", "Erste passende Route gewinnt")
        #expect(result.remotes["a"]?.version == "1.0")
        #expect(result.itemErrors.keys.sorted() == ["c"])
        #expect(result.failures.isEmpty)

        let merged = RefreshCoordinator.merge(items, remotes: result.remotes)
        #expect(merged.map(\.status) == [.upToDate, .outdated, .unknown, .unknown])
    }

    @Test func restrictsToSourcesWithoutReroutingItems() async {
        let coordinator = RefreshCoordinator(routes: [
            .init("slow", Fixed(versions: ["m": "2.0"])) { $0.id == "m" },
            .init("fast", Fixed(versions: ["m": "9.9", "a": "2.0"])) { _ in true },
        ])
        let items = [Self.app("m", "1.0"), Self.app("a", "1.0")]
        let fast = await coordinator.latest(for: items, sources: ["fast"])
        #expect(fast.remotes.keys.sorted() == ["a"], "m gehört zu „slow“ und wird nicht „fast“ zugeschlagen")
        #expect(coordinator.items(items, handledBy: ["slow"]).map(\.id) == ["m"])
        #expect(await coordinator.latest(for: items, sources: ["slow"]).remotes["m"]?.version == "2.0")
        #expect(Set(fast.durations.keys) == ["fast"])
    }

    @Test func sourceFailsWhenAllItemsFail() async {
        let coordinator = RefreshCoordinator(routes: [
            .init("appstore", Fixed(failing: ["x", "y"])) { _ in true },
        ])
        let result = await coordinator.latest(for: [Self.app("x", "1"), Self.app("y", "1")])
        #expect(result.failures["appstore"] != nil)
        #expect(result.itemErrors.isEmpty)
    }

    @Test func pinnedItemsStayPinned() {
        let item = Self.app("p", "1.0", pinned: true)
        let merged = RefreshCoordinator.merge([item], remotes: ["p": RemoteVersion(itemID: "p", version: "2.0", source: "test")])
        #expect(merged.first?.status == .pinned)
        #expect(merged.first?.latestVersion == "2.0")
    }

    /// Akzeptanzkriterium Phase 4: Ein zweiter Refresh innerhalb der TTL erzeugt keine Netzwerk-Requests
    /// (und startet weder `softwareupdate` noch `brew outdated` erneut).
    @Test func secondRefreshWithinTTLMakesNoRequests() async throws {
        let directory = try TemporaryDirectory()
        let home = try TemporaryDirectory()
        let brew = try home.makeExecutable("bin/brew")
        let environment = ResolvedEnvironment(source: .loginShell, variables: [:], searchPath: [brew.deletingLastPathComponent().path])

        let mock = MockCommandRunner()
        await mock.stub(brew.path, arguments: ["outdated", "--json=v2", "--greedy"], stdout: try Fixture.string("Brew/outdated-greedy.json"))
        await mock.stub(SoftwareUpdateLatestProvider.path, stdout: try Fixture.string("Latest/softwareupdate-available.stdout.txt"))

        let transport = MockHTTPTransport()
        let demoAppURL = try #require(AppStoreLatestProvider.lookupURL(bundleIdentifier: "com.example.DemoApp", country: "de"))
        let feedURL = URL(string: "https://iterm2.com/appcasts/final_modern.xml")!
        await transport.stub(demoAppURL, HTTPResponse(statusCode: 200, body: Data(try Fixture.string("Latest/itunes-lookup-demoapp.json").utf8)))
        await transport.stub(feedURL, HTTPResponse(statusCode: 200, body: Data(try Fixture.string("Latest/appcast-iterm.xml").utf8)))
        await transport.stub(CaskMatchLatestProvider.apiURL, HTTPResponse(statusCode: 200, body: Data(try Fixture.string("Latest/cask-api-subset.json").utf8)))

        let items: [InstalledItem] = [
            InstalledItem(id: "macos:macos", name: "macOS", kind: .os, ecosystem: .macOS, installedVersion: "26.7.1", source: .system),
            InstalledItem(id: "brew:formula/pnpm", name: "pnpm", kind: .cli, ecosystem: .brew, installedVersion: "12.14.0", source: .brew, metadata: ["fullName": "pnpm"]),
            InstalledItem(id: "app-bundle:/Applications/DemoApp.app", name: "DemoApp", kind: .app, ecosystem: .appBundle, installedVersion: "2.0.2", source: .mas, metadata: ["bundleIdentifier": "com.example.DemoApp"]),
            InstalledItem(id: "app-bundle:/Applications/iTerm.app", name: "iTerm", kind: .app, ecosystem: .appBundle, installedVersion: "3.7.6", source: .sparkle, metadata: ["bundleVersion": "3.7.6", "sparkleFeedURL": feedURL.absoluteString]),
            InstalledItem(id: "app-bundle:/Applications/Claude.app", name: "Claude", kind: .app, ecosystem: .appBundle, installedVersion: "3.6556.2", installPath: "/Applications/Claude.app", source: .manual),
        ]

        // Wie in der App: pro Refresh neue Quellen, aber dieselben Platten-Caches.
        func coordinator() -> RefreshCoordinator {
            let http = CachingHTTPClient(transport: transport, cache: HTTPDiskCache(directory: directory.url.appendingPathComponent("http")))
            let commands = CachingCommandRunner(base: mock, directory: directory.url.appendingPathComponent("commands"))
            return RefreshCoordinator(routes: [
                .init(.macOS, SoftwareUpdateLatestProvider(runner: commands)) { $0.ecosystem == .macOS },
                .init(.brew, BrewLatestProvider(runner: commands, environment: environment, knownPrefixes: [])) { $0.ecosystem == .brew },
                .init("appstore", AppStoreLatestProvider(http: http, country: "de")) { $0.source == .mas },
                .init("sparkle", SparkleLatestProvider(http: http, systemVersion: "26.7.1")) { $0.source == .sparkle },
                .init("cask", CaskMatchLatestProvider(http: http)) { $0.source == .manual },
            ])
        }

        let first = await coordinator().latest(for: items)
        #expect(first.failures.isEmpty && first.itemErrors.isEmpty, "\(first.failures) \(first.itemErrors)")
        #expect(first.remotes.count == 5)
        let requestsAfterFirst = await transport.requests.count
        let invocationsAfterFirst = await mock.invocations.count
        #expect(requestsAfterFirst == 3)
        #expect(invocationsAfterFirst == 2)

        let second = await coordinator().latest(for: items)
        #expect(await transport.requests.count == requestsAfterFirst, "Keine Netzwerk-Requests innerhalb der TTL")
        #expect(await mock.invocations.count == invocationsAfterFirst, "Keine erneuten CLI-Abfragen innerhalb der TTL")
        #expect(second.remotes.mapValues(\.version) == first.remotes.mapValues(\.version))

        let merged = Dictionary(uniqueKeysWithValues: RefreshCoordinator.merge(items, remotes: second.remotes).map { ($0.id, $0.status) })
        #expect(merged["macos:macos"] == .outdated)
        #expect(merged["brew:formula/pnpm"] == .outdated)
        #expect(merged["app-bundle:/Applications/iTerm.app"] == .upToDate)
        #expect(merged["app-bundle:/Applications/Claude.app"] == .upToDate)
    }
}

@Suite("Assessment")
struct AssessmentTests {
    static let item = InstalledItem(id: "x", name: "x", kind: .app, ecosystem: .appBundle, installedVersion: "1.9", source: .manual)

    @Test(arguments: [
        (RemoteVersion.Assessment.compareVersions, "2.0", InstalledItem.Status.outdated, true),
        (.compareVersions, "1.9", .upToDate, false),
        (.compareVersions, "latest", .unknown, false),
        (.outdated, "build-77", .outdated, false),
        (.outdated, "2.0", .outdated, true),
        (.upToDate, "2.0", .upToDate, false),
        (.undeterminable, "2.0", .unknown, false),
    ])
    func appliesAssessment(assessment: RemoteVersion.Assessment, version: String, status: InstalledItem.Status, major: Bool) {
        let result = Self.item.applying(latest: RemoteVersion(itemID: "x", version: version, source: "t", assessment: assessment))
        #expect(result.status == status)
        #expect(result.isMajorUpdate == major)
        #expect(result.latestVersion == version)
    }
}
