import Foundation
import Testing
@testable import UpdatyMeCore
import UpdatyMeCoreTestSupport

@Suite("InventoryScanner")
struct InventoryScannerTests {
    struct StaticProvider: InventoryProvider {
        var items: [InstalledItem] = []
        var error: (any Error & Sendable)?
        var delay: Duration = .zero

        func scan() async throws -> [InstalledItem] {
            try await Task.sleep(for: delay)
            if let error { throw error }
            return items
        }
    }

    static func app(_ path: String) -> InstalledItem {
        InstalledItem(
            id: InstalledItem.makeID(ecosystem: .appBundle, identifier: path),
            name: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent,
            kind: .app, ecosystem: .appBundle, installedVersion: "1.0", installPath: path, source: .manual
        )
    }

    static func cask(_ token: String, appPaths: [String]) -> InstalledItem {
        InstalledItem(
            id: InstalledItem.makeID(ecosystem: .brew, identifier: "cask/\(token)"),
            name: token, kind: .app, ecosystem: .brew, installedVersion: "1.0", installPath: appPaths.first,
            source: .cask, metadata: ["appPaths": appPaths.joined(separator: "\n")]
        )
    }

    @Test func failingProviderDoesNotAbortOthers() async throws {
        let broken = InventoryError.commandFailed(command: "brew info", exitCode: 1, stderr: "Error: lock")
        let scanner = InventoryScanner(providers: [
            .init(.macOS, StaticProvider(items: [Self.app("/System/macOS-placeholder")], delay: .milliseconds(50))),
            .init(.brew, StaticProvider(error: broken)),
            .init(.appBundle, StaticProvider(items: [Self.app("/Applications/Fork.app")])),
        ])

        let scan = await scanner.scan()

        #expect(scan.results.map(\.ecosystem) == [.macOS, .brew, .appBundle])
        #expect(scan.items.count == 2)
        #expect(scan.failures.count == 1)
        #expect(scan.failures.first?.ecosystem == .brew)
        #expect(scan.failures.first?.failure.error as? InventoryError == broken)
    }

    @Test func missingToolIsNotAFailure() async {
        let scan = await InventoryScanner(providers: [
            .init(.brew, StaticProvider(error: InventoryError.toolNotFound("Homebrew"))),
            .init(.appBundle, StaticProvider(items: [Self.app("/Applications/Fork.app")])),
        ]).scan()
        #expect(scan.failures.isEmpty)
        #expect(scan.results.first?.unavailableTool == "Homebrew")
        #expect(scan.items.map(\.name) == ["Fork"])
    }

    @Test func runsProvidersInParallel() async {
        let slow = StaticProvider(delay: .milliseconds(400))
        let scanner = InventoryScanner(providers: [.init("a", slow), .init("b", slow), .init("c", slow)])
        let clock = ContinuousClock()
        let start = clock.now
        _ = await scanner.scan()
        #expect(start.duration(to: clock.now) < .milliseconds(1000))
    }

    @Test func caskAppsReplaceAppBundleDuplicates() async {
        let scanner = InventoryScanner(providers: [
            .init(.brew, StaticProvider(items: [
                Self.cask("fork", appPaths: ["/Applications/Fork.app"]),
                Self.cask("legacy", appPaths: ["/Applications/Fork Renamed.app", "/Applications/Helper.app"]),
            ])),
            .init(.appBundle, StaticProvider(items: [
                Self.app("/Applications/Fork.app"),
                Self.app("/Applications/helper.app"),
                Self.app("/Applications/Spotify.app"),
            ])),
        ])

        let names = await scanner.scan().items.map(\.name)
        #expect(names == ["fork", "legacy", "Spotify"])
    }

    @Test func keepsAppBundlesWhenBrewFails() async {
        let scanner = InventoryScanner(providers: [
            .init(.brew, StaticProvider(error: InventoryError.toolNotFound("Homebrew"))),
            .init(.appBundle, StaticProvider(items: [Self.app("/Applications/Fork.app")])),
        ])
        #expect(await scanner.scan().items.map(\.name) == ["Fork"])
    }

    @Test func endToEndWithMockedCommandsAndFileSystem() async throws {
        let home = try TemporaryDirectory()
        let brew = try home.makeExecutable("homebrew/bin/brew")
        let applications = try home.makeDirectory("Applications")
        for name in ["Android Studio", "Spotify"] {
            let contents = applications.appendingPathComponent("\(name).app/Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let plist = try PropertyListSerialization.data(
                fromPropertyList: ["CFBundleIdentifier": "x.\(name)", "CFBundleShortVersionString": "1.0"], format: .xml, options: 0)
            try plist.write(to: contents.appendingPathComponent("Info.plist"))
        }
        // Fixture-Pfade zeigen auf /Applications; hier liegt der Ordner im Temp-Verzeichnis.
        let info = try Fixture.string("Brew/info-installed.json")
            .replacingOccurrences(of: "\"/Applications/", with: "\"\(applications.path)/")

        let mock = MockCommandRunner()
        await mock.stub(MacOSEcosystem.swVers, stdout: try Fixture.string("MacOS/sw_vers.txt"))
        await mock.stub(MacOSEcosystem.sysctl, stdout: try Fixture.string("MacOS/sysctl-kern.osversion.txt"))
        await mock.stub(brew.path, stdout: info)
        let environment = ResolvedEnvironment(source: .loginShell, variables: [:], searchPath: [brew.deletingLastPathComponent().path])

        let scan = await InventoryScanner(providers: [
            .init(.macOS, MacOSEcosystem(runner: mock)),
            .init(.brew, BrewEcosystem(runner: mock, environment: environment, appVersion: { _ in nil })),
            .init(.appBundle, AppBundleEcosystem(searchDirectories: [applications])),
        ]).scan()

        #expect(scan.failures.isEmpty)
        #expect(scan.items.filter { $0.ecosystem == .macOS }.count == 1)
        #expect(scan.items.filter { $0.ecosystem == .brew }.count == 13)
        #expect(scan.items.filter { $0.ecosystem == .appBundle }.map(\.name) == ["Spotify"], "Android Studio kommt als Cask")
    }
}
