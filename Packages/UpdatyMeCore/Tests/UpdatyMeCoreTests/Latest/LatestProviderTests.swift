import Foundation
import Testing
@testable import UpdatyMeCore
import UpdatyMeCoreTestSupport

// MARK: - softwareupdate

@Suite("SoftwareUpdateLatestProvider")
struct SoftwareUpdateLatestProviderTests {
    static let macOS = InstalledItem(id: "macos:macos", name: "macOS", kind: .os, ecosystem: .macOS,
                                     installedVersion: "26.7.1", source: .system, updateCapability: .openSettings)

    @Test func parsesEntries() throws {
        let entries = SoftwareUpdateLatestProvider.parse(try Fixture.string("Latest/softwareupdate-available.stdout.txt"))
        #expect(entries.map(\.title) == ["Command Line Tools for Xcode 26.7", "macOS Tahoe 26.8", "macOS 27 Beta"])
        #expect(entries.map(\.version) == ["26.7", "26.8", "27.0"])
        #expect(entries.map(\.recommended) == [true, true, false])
    }

    @Test func picksMacOSUpdateAndIgnoresBetas() async throws {
        let mock = MockCommandRunner()
        await mock.stub(SoftwareUpdateLatestProvider.path, arguments: ["--list"],
                        stdout: try Fixture.string("Latest/softwareupdate-available.stdout.txt"))
        let remote = try #require(try await SoftwareUpdateLatestProvider(runner: mock).latest(for: Self.macOS))
        #expect(remote.version == "26.8")
        #expect(remote.assessment == .compareVersions)
        #expect(Self.macOS.applying(latest: remote).status == .outdated)
    }

    @Test func noUpdatesMeansUpToDate() async throws {
        // Aufgezeichnet: „No new software available.“ steht auf stderr, Exit-Code 0.
        let mock = MockCommandRunner()
        await mock.stub(SoftwareUpdateLatestProvider.path,
                        stdout: try Fixture.string("Latest/softwareupdate-none.stdout.txt"),
                        stderr: try Fixture.string("Latest/softwareupdate-none.stderr.txt"))
        let remote = try #require(try await SoftwareUpdateLatestProvider(runner: mock).latest(for: Self.macOS))
        #expect(remote.version == "26.7.1")
        #expect(Self.macOS.applying(latest: remote).status == .upToDate)
    }

    @Test func failureThrows() async {
        let mock = MockCommandRunner()
        await mock.stub(SoftwareUpdateLatestProvider.path, exitCode: 1, stderr: "Can't connect")
        await #expect(throws: InventoryError.self) {
            _ = try await SoftwareUpdateLatestProvider(runner: mock).latest(for: Self.macOS)
        }
    }

    @Test func ignoresNonOSItems() async throws {
        var app = Self.macOS
        app.kind = .app
        #expect(try await SoftwareUpdateLatestProvider(runner: MockCommandRunner()).latest(for: app) == nil)
    }
}

// MARK: - Brew

@Suite("BrewLatestProvider")
struct BrewLatestProviderTests {
    /// Inventar (aufgezeichnet) + `brew outdated` (aufgezeichnet), echte App-Versionen per Stub.
    static func merged(appVersions: [String: String] = [:]) async throws -> (items: [String: InstalledItem], invocations: [Command]) {
        let home = try TemporaryDirectory()
        let brew = try home.makeExecutable("bin/brew")
        let environment = ResolvedEnvironment(source: .loginShell, variables: ["A": "B"], searchPath: [brew.deletingLastPathComponent().path])
        let mock = MockCommandRunner()
        await mock.stub(brew.path, arguments: ["info", "--json=v2", "--installed"], stdout: try Fixture.string("Brew/info-installed.json"))
        await mock.stub(brew.path, arguments: ["outdated", "--json=v2", "--greedy"], stdout: try Fixture.string("Brew/outdated-greedy.json"))

        let items = try await BrewEcosystem(runner: mock, environment: environment, knownPrefixes: [],
                                            appVersion: { appVersions[$0] }).scan()
        let result = await RefreshCoordinator(routes: [
            .init(.brew, BrewLatestProvider(runner: mock, environment: environment, knownPrefixes: [])) { $0.ecosystem == .brew },
        ]).latest(for: items)
        let merged = RefreshCoordinator.merge(items, remotes: result.remotes)
        return (Dictionary(uniqueKeysWithValues: merged.map { ($0.id, $0) }), await mock.invocations)
    }

    @Test func formulaeFromRecordedOutput() async throws {
        let items = try await Self.merged().items
        #expect(items["brew:formula/python@3.12"]?.status == .outdated)
        #expect(items["brew:formula/python@3.12"]?.latestVersion == "3.12.16")
        #expect(items["brew:formula/python@3.12"]?.isMajorUpdate == false)
        #expect(items["brew:formula/icu4c@78"]?.status == .outdated, "Revision 78.3 → 78.3_1")
        #expect(items["brew:formula/mobile-dev-inc/tap/maestro"]?.latestVersion == "2.12.0")
        #expect(items["brew:formula/autoconf"]?.status == .upToDate)
        #expect(items["brew:formula/autoconf"]?.latestVersion == "2.73")
    }

    @Test func latestVersionsAreUndeterminable() async throws {
        let fusion = try #require(try await Self.merged().items["brew:cask/autodesk-fusion"])
        #expect(fusion.status == .unknown)
    }

    @Test func autoUpdatingCasksUseRealAppVersion() async throws {
        let items = try await Self.merged(appVersions: [
            "/Applications/JetBrains Toolbox.app": "3.9.0.88839",
            "/Applications/Fork.app": "2.70.2",
        ]).items
        // Brew meldet 2.8.1 → 3.9 als veraltet; die App hat sich längst selbst aktualisiert.
        #expect(items["brew:cask/jetbrains-toolbox"]?.status == .upToDate)
        #expect(items["brew:cask/jetbrains-toolbox"]?.latestVersion == "3.9")
        #expect(items["brew:cask/fork"]?.status == .upToDate)
        // App nicht lesbar → Brews Stand ist unzuverlässig → unbekannt statt falsch „Update“.
        #expect(items["brew:cask/android-studio"]?.status == .unknown)
    }

    @Test func outdatedWithoutRealVersionForNormalCaskUsesBrew() {
        let item = InstalledItem(id: "brew:cask/x", name: "x", kind: .app, ecosystem: .brew,
                                 installedVersion: "py313_25.7.0-2", source: .cask, metadata: ["fullName": "x"])
        let entry = BrewLatestProvider.Outdated.Entry(name: "x", installedVersions: ["py313_25.7.0-2"], currentVersion: "py314_26.9.4-0")
        let remote = BrewLatestProvider.remoteVersion(for: item, outdated: entry)
        #expect(remote.assessment == .outdated, "Nicht vergleichbar → Brews Urteil")
        #expect(item.applying(latest: remote).status == .outdated)

        var upgraded = item
        upgraded.installedVersion = "py314_26.9.4-0"
        #expect(BrewLatestProvider.remoteVersion(for: upgraded, outdated: entry).assessment == .undeterminable,
                "Installierte Version passt nicht mehr zum (evtl. alten) Brew-Ergebnis")
    }

    @Test func runsWithoutAutoUpdateAndOnlyOnce() async throws {
        let invocations = try await Self.merged().invocations
        let outdatedCalls = invocations.filter { $0.arguments.first == "outdated" }
        #expect(outdatedCalls.count == 1)
        #expect(outdatedCalls.first?.environment?["HOMEBREW_NO_AUTO_UPDATE"] == "1")
    }

    @Test func missingBrewFailsAllItems() async {
        let environment = ResolvedEnvironment(source: .loginShell, variables: [:], searchPath: [])
        let item = InstalledItem(id: "brew:formula/x", name: "x", kind: .cli, ecosystem: .brew, installedVersion: "1", source: .brew)
        let result = await RefreshCoordinator(routes: [
            .init(.brew, BrewLatestProvider(runner: MockCommandRunner(), environment: environment, knownPrefixes: [])) { _ in true },
        ]).latest(for: [item])
        #expect(result.failures[.brew]?.error as? InventoryError == .toolNotFound("Homebrew"))
        #expect(result.remotes.isEmpty)
    }
}

// MARK: - App Store

@Suite("AppStoreLatestProvider")
struct AppStoreLatestProviderTests {
    static let demoApp = InstalledItem(id: "app-bundle:/Applications/DemoApp.app", name: "DemoApp", kind: .app, ecosystem: .appBundle,
                                     installedVersion: "2.0.2", source: .mas, metadata: ["bundleIdentifier": "com.example.DemoApp"])

    static func client(_ transport: MockHTTPTransport, in directory: borrowing TemporaryDirectory) -> CachingHTTPClient {
        CachingHTTPClient(transport: transport, cache: HTTPDiskCache(directory: directory.url))
    }

    @Test func readsVersionFromRecordedLookup() async throws {
        let transport = MockHTTPTransport()
        let url = try #require(AppStoreLatestProvider.lookupURL(bundleIdentifier: "com.example.DemoApp", country: "de"))
        await transport.stub(url, HTTPResponse(statusCode: 200, body: Data(try Fixture.string("Latest/itunes-lookup-demoapp.json").utf8)))
        let directory = try TemporaryDirectory()
        let http = Self.client(transport, in: directory)

        let remote = try #require(try await AppStoreLatestProvider(http: http, country: "DE").latest(for: Self.demoApp))
        let fixture = try JSONDecoder().decode(AppStoreLatestProvider.Lookup.self,
                                               from: Data(try Fixture.string("Latest/itunes-lookup-demoapp.json").utf8))
        #expect(remote.version == fixture.results.first?.version)
        #expect(remote.source == "App Store")
        #expect(remote.releaseNotesURL != nil)
        #expect(url.absoluteString == "https://itunes.apple.com/lookup?bundleId=com.example.DemoApp&country=de")
    }

    @Test func noResultIsUnknown() async throws {
        let transport = MockHTTPTransport()
        let url = try #require(AppStoreLatestProvider.lookupURL(bundleIdentifier: "com.example.DemoApp", country: "de"))
        await transport.stub(url, HTTPResponse(statusCode: 200, body: Data(#"{"resultCount":0,"results":[]}"#.utf8)))
        let directory = try TemporaryDirectory()
        let http = Self.client(transport, in: directory)
        #expect(try await AppStoreLatestProvider(http: http, country: "de").latest(for: Self.demoApp) == nil)
    }
}

// MARK: - Sparkle

@Suite("SparkleLatestProvider")
struct SparkleLatestProviderTests {
    static func app(_ name: String, short: String, build: String) -> InstalledItem {
        InstalledItem(id: "app-bundle:/Applications/\(name).app", name: name, kind: .app, ecosystem: .appBundle,
                      installedVersion: short, source: .sparkle,
                      metadata: ["bundleVersion": build, "sparkleFeedURL": "https://example.org/\(name).xml"])
    }

    @Test func parsesRecordedAppcasts() throws {
        let iterm = try AppcastParser.parse(Data(try Fixture.string("Latest/appcast-iterm.xml").utf8))
        #expect(iterm.map(\.version) == ["3.6.11", "3.7.6"])
        #expect(iterm.map(\.minimumSystemVersion) == ["12.4", "13"])
        #expect(iterm.first?.releaseNotesLink != nil)

        let fork = try AppcastParser.parse(Data(try Fixture.string("Latest/appcast-fork.xml").utf8))
        #expect(fork.first?.version == "2.71.0")
        #expect(fork.first?.shortVersionString == nil)
        #expect(fork.first?.publicationDate != nil)
    }

    @Test func picksHighestCompatibleItemNotTheFirst() throws {
        let items = try AppcastParser.parse(Data(try Fixture.string("Latest/appcast-iterm.xml").utf8))
        #expect(SparkleLatestProvider.bestItem(in: items, systemVersion: "26.7.1")?.version == "3.7.6")
        #expect(SparkleLatestProvider.bestItem(in: items, systemVersion: "12.6")?.version == "3.6.11")
        #expect(SparkleLatestProvider.bestItem(in: items, systemVersion: "12.0") == nil)
    }

    @Test func buildOnlyAppcastComparesBundleVersion() throws {
        let items = try AppcastParser.parse(Data(try Fixture.string("Latest/appcast-fork.xml").utf8))
        let best = try #require(SparkleLatestProvider.bestItem(in: items, systemVersion: "26.7.1"))
        let fork = Self.app("Fork", short: "2.70.2", build: "2.70.2")
        let remote = try #require(SparkleLatestProvider.remoteVersion(for: fork, appcastItem: best, fetchedAt: Date()))
        #expect(remote.version == "2.71.0")
        #expect(remote.assessment == .outdated)
        #expect(fork.applying(latest: remote).status == .outdated)
    }

    @Test func ignoresChannelItemsAndPrefersShortVersionElement() throws {
        let xml = """
            <?xml version="1.0"?>
            <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
              <item><title>Beta</title><sparkle:channel>beta</sparkle:channel>
                <enclosure url="https://x/b.zip" sparkle:version="300"/></item>
              <item><title>1.4</title><sparkle:version>140</sparkle:version>
                <sparkle:shortVersionString>1.4</sparkle:shortVersionString>
                <enclosure url="https://x/a.zip"/></item>
            </channel></rss>
            """
        let items = try AppcastParser.parse(Data(xml.utf8))
        let best = try #require(SparkleLatestProvider.bestItem(in: items, systemVersion: "26.0"))
        #expect(best.version == "140")
        let app = Self.app("X", short: "1.3", build: "130")
        let remote = try #require(SparkleLatestProvider.remoteVersion(for: app, appcastItem: best, fetchedAt: Date()))
        #expect(remote.version == "1.4")
        #expect(remote.assessment == .compareVersions)
        #expect(app.applying(latest: remote).status == .outdated)
    }

    @Test func invalidXMLThrows() {
        #expect(throws: InventoryError.self) { _ = try AppcastParser.parse(Data("<rss><channel>".utf8)) }
    }
}

// MARK: - Cask-Abgleich

@Suite("CaskMatchLatestProvider")
struct CaskMatchLatestProviderTests {
    static func index() throws -> [String: [CaskMatchLatestProvider.Cask]] {
        try CaskMatchLatestProvider.buildIndex(Data(try Fixture.string("Latest/cask-api-subset.json").utf8))
    }

    @Test(arguments: [
        ("1Password.app", "1password"),
        ("Claude.app", "claude"),
        ("Docker.app", "docker-desktop"),
        ("Thorium.app", "thorium"),
        ("Thorium Browser.app", "alex313031-thorium"),
        ("Android Studio.app", "android-studio"),
    ])
    func matchesUniquelyIgnoringAtVariants(appName: String, token: String) throws {
        guard case .unique(let matched, _, _) = CaskMatchLatestProvider.match(appName: appName, in: try Self.index()) else {
            Issue.record("Kein eindeutiger Treffer für \(appName)")
            return
        }
        #expect(matched == token)
    }

    @Test func realConflictsAndUnknownAppsDoNotMatch() throws {
        let json = #"[{"token":"a","version":"1","artifacts":[{"app":["Same.app"]}]},{"token":"b","version":"2","artifacts":[{"app":["Same.app"]}]}]"#
        let index = try CaskMatchLatestProvider.buildIndex(Data(json.utf8))
        #expect(CaskMatchLatestProvider.match(appName: "Same.app", in: index) == .ambiguous(["a", "b"]))
        #expect(CaskMatchLatestProvider.match(appName: "Unknown.app", in: try Self.index()) == .none)
    }

    @Test func skipsMalformedCasksInsteadOfFailing() throws {
        let json = #"[{"token":"broken"},{"token":"ok","version":"1.0","homepage":"not a url %%","artifacts":["weird",{"app":["Ok.app"]}]}]"#
        let index = try CaskMatchLatestProvider.buildIndex(Data(json.utf8))
        guard case .unique(let token, let version, _) = CaskMatchLatestProvider.match(appName: "Ok.app", in: index) else {
            Issue.record("Gültiger Cask neben fehlerhaftem sollte passen")
            return
        }
        #expect(token == "ok")
        #expect(version == "1.0")
    }

    @Test func latestStripsBuildSuffixAndUsesHTTPCache() async throws {
        let transport = MockHTTPTransport()
        await transport.stub(CaskMatchLatestProvider.apiURL,
                             HTTPResponse(statusCode: 200, body: Data(try Fixture.string("Latest/cask-api-subset.json").utf8)))
        let directory = try TemporaryDirectory()
        let provider = CaskMatchLatestProvider(http: CachingHTTPClient(transport: transport, cache: HTTPDiskCache(directory: directory.url)))
        func app(_ name: String, _ version: String) -> InstalledItem {
            InstalledItem(id: "app-bundle:/Applications/\(name).app", name: name, kind: .app, ecosystem: .appBundle,
                          installedVersion: version, installPath: "/Applications/\(name).app", source: .manual)
        }

        let docker = try #require(try await provider.latest(for: app("Docker", "4.96.3")))
        #expect(docker.version == "4.96.3")
        #expect(docker.source == "Homebrew Cask docker-desktop")
        #expect(app("Docker", "4.96.3").applying(latest: docker).status == .upToDate)
        let claude = try #require(try await provider.latest(for: app("Claude", "3.6000.0")))
        #expect(claude.version == "3.6556.2")
        #expect(app("Claude", "3.6000.0").applying(latest: claude).status == .outdated)
        #expect(try await provider.latest(for: app("Unknown", "1.0")) == nil)
        let studio = try #require(try await provider.latest(for: app("Android Studio", "2026.2")))
        #expect(studio.version == "2026.2.1.8")
        #expect(studio.assessment == .undeterminable, "Gekürzte App-Version (Präfix) ist nicht bewertbar")
        #expect(await transport.requests.count == 1, "cask.json nur einmal laden")
    }
}
