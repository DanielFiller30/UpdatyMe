import Foundation
import Testing
@testable import UpdatyMeCore
import UpdatyMeCoreTestSupport

@Suite("BrewEcosystem")
struct BrewEcosystemTests {
    static let infoArguments = ["info", "--json=v2", "--installed"]

    static func items(_ fixture: String = "Brew/info-installed.json") throws -> [String: InstalledItem] {
        let data = Data(try Fixture.string(fixture).utf8)
        let items = try BrewEcosystem.parseInstalled(data, prefix: "/opt/homebrew")
        return Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
    }

    // MARK: - Formulae (aufgezeichnet)

    @Test func parsesAllRecordedEntries() throws {
        let items = try Self.items()
        #expect(items.count == 13)
        #expect(items.values.filter { $0.source == .brew }.count == 7)
        #expect(items.values.filter { $0.source == .cask }.count == 6)
        #expect(items.values.allSatisfy { $0.ecosystem == .brew && $0.status == .unknown && $0.updateCapability == .auto })
    }

    @Test func formulaRequestedOnRequestIsCLI() throws {
        let docker = try #require(try Self.items()["brew:formula/docker"])
        #expect(docker.name == "docker")
        #expect(docker.kind == .cli)
        #expect(docker.installedVersion == "29.9.2")
        #expect(docker.installPath == "/opt/homebrew/Cellar/docker/29.9.2")
        #expect(docker.metadata["tap"] == "homebrew/core")
        #expect(docker.metadata["installedOnRequest"] == "true")
    }

    @Test func dependencyIsPackageAndKeepsRevision() throws {
        let cffi = try #require(try Self.items()["brew:formula/cffi"])
        #expect(cffi.kind == .package)
        #expect(cffi.installedVersion == "2.1.1_1")
    }

    @Test func kegOnlyWithoutLinkedKegUsesInstalledVersion() throws {
        let icu = try #require(try Self.items()["brew:formula/icu4c@78"])
        #expect(icu.installedVersion == "78.3")
        #expect(icu.metadata["kegOnly"] == "true")
    }

    @Test func tapFormulaUsesFullNameInIDAndShortNameInPath() throws {
        let maestro = try #require(try Self.items()["brew:formula/mobile-dev-inc/tap/maestro"])
        #expect(maestro.name == "maestro")
        #expect(maestro.installPath == "/opt/homebrew/Cellar/maestro/2.11.0")
        #expect(maestro.metadata["fullName"] == "mobile-dev-inc/tap/maestro")
    }

    @Test func dateVersionIsKeptVerbatim() throws {
        #expect(try Self.items()["brew:formula/ca-certificates"]?.installedVersion == "2026-10-20")
    }

    // MARK: - Casks (aufgezeichnet)

    @Test func caskWithApp() throws {
        let studio = try #require(try Self.items()["brew:cask/android-studio"])
        #expect(studio.name == "Android Studio")
        #expect(studio.kind == .app)
        #expect(studio.source == .cask)
        #expect(studio.installedVersion == "2026.1.3.8,quail3-patch1,AI-261.26222.65.2613.16025427")
        #expect(studio.installPath == "/Applications/Android Studio.app")
        #expect(studio.metadata["appPaths"] == "/Applications/Android Studio.app")
        #expect(studio.metadata["autoUpdates"] == "true")
    }

    @Test func caskWithoutAppIsCLI() throws {
        let fusion = try #require(try Self.items()["brew:cask/autodesk-fusion"])
        #expect(fusion.kind == .cli)
        #expect(fusion.installedVersion == "latest")
        #expect(fusion.installPath == nil)
        #expect(fusion.metadata["appPaths"] == nil)
    }

    // MARK: - Nachgebildete Sonderfälle

    @Test func pinnedFormulaUsesLinkedKegAmongSeveralVersions() throws {
        let docker = try #require(try Self.items("Brew/info-installed-synthetic.json")["brew:formula/docker"])
        #expect(docker.installedVersion == "29.8.0")
        #expect(docker.status == .pinned)
        #expect(docker.metadata["installedVersions"] == "29.8.0,29.9.2")
    }

    @Test func unlinkedFormulaUsesHighestInstalledVersion() throws {
        let item = try #require(try Self.items("Brew/info-installed-synthetic.json")["brew:formula/unlinked-multi"])
        #expect(item.installedVersion == "29.9.2")
        #expect(item.status == .unknown)
    }

    @Test func legacyArtifactFormatWithRenamedTarget() throws {
        let cask = try #require(try Self.items("Brew/info-installed-synthetic.json")["brew:cask/legacy-renamed"])
        #expect(cask.metadata["appPaths"] == "/Applications/Fork Renamed.app\n/Applications/Helper.app")
        #expect(cask.status == .pinned)
    }

    @Test func installedVersionSelection() {
        #expect(BrewEcosystem.installedVersion(linkedKeg: "1.0", installed: ["1.0", "2.0"]) == "1.0")
        #expect(BrewEcosystem.installedVersion(linkedKeg: "3.0", installed: ["1.10", "1.9"]) == "1.10")
        #expect(BrewEcosystem.installedVersion(linkedKeg: nil, installed: []) == nil)
    }

    @Test func rejectsInvalidJSON() {
        #expect(throws: InventoryError.self) {
            _ = try BrewEcosystem.parseInstalled(Data("Error: no JSON".utf8), prefix: "/opt/homebrew")
        }
    }

    // MARK: - Aufruf

    @Test func scanRunsBrewFromResolvedPathWithEnvironment() async throws {
        let home = try TemporaryDirectory()
        let brew = try home.makeExecutable("homebrew/bin/brew")
        let environment = ResolvedEnvironment(
            source: .loginShell,
            variables: ["HOMEBREW_PREFIX": home.url.appendingPathComponent("homebrew").path],
            searchPath: [brew.deletingLastPathComponent().path]
        )
        let mock = MockCommandRunner()
        await mock.stub(brew.path, arguments: Self.infoArguments, stdout: try Fixture.string("Brew/info-installed.json"))

        let items = try await BrewEcosystem(runner: mock, environment: environment, knownPrefixes: [], appVersion: { _ in nil }).scan()

        #expect(items.count == 13)
        let invocation = try #require(await mock.invocations.first)
        #expect(invocation.executable == brew)
        #expect(invocation.environment?["PATH"] == brew.deletingLastPathComponent().path)
        let docker = try #require(items.first { $0.id == "brew:formula/docker" })
        #expect(docker.installPath == home.url.path + "/homebrew/Cellar/docker/29.9.2")
    }

    @Test func autoUpdatingCaskUsesRealAppVersion() async throws {
        let home = try TemporaryDirectory()
        let brew = try home.makeExecutable("bin/brew")
        let environment = ResolvedEnvironment(source: .loginShell, variables: [:], searchPath: [brew.deletingLastPathComponent().path])
        let mock = MockCommandRunner()
        await mock.stub(brew.path, stdout: try Fixture.string("Brew/info-installed.json"))
        let versions = ["/Applications/JetBrains Toolbox.app": "3.9.0.88839"]

        let items = try await BrewEcosystem(runner: mock, environment: environment, knownPrefixes: [],
                                            appVersion: { versions[$0] }).scan()

        let toolbox = try #require(items.first { $0.id == "brew:cask/jetbrains-toolbox" })
        #expect(toolbox.installedVersion == "3.9.0.88839")
        #expect(toolbox.metadata["brewRecordedVersion"] == "2.8.1,2.8.1.52155")
        let studio = try #require(items.first { $0.id == "brew:cask/android-studio" })
        #expect(studio.metadata["brewRecordedVersion"] == nil, "App nicht lesbar → Brews Version bleibt")
        let docker = try #require(items.first { $0.id == "brew:formula/docker" })
        #expect(docker.metadata["brewRecordedVersion"] == nil, "Formulae sind nicht betroffen")
    }

    @Test func fallsBackToKnownPrefix() throws {
        let home = try TemporaryDirectory()
        try home.makeExecutable("usr-local/bin/brew")
        let environment = ResolvedEnvironment(source: .loginShell, variables: [:], searchPath: [])
        let ecosystem = BrewEcosystem(
            runner: MockCommandRunner(), environment: environment,
            knownPrefixes: [home.url.appendingPathComponent("missing").path, home.url.appendingPathComponent("usr-local").path]
        )
        #expect(ecosystem.locateBrew()?.path == home.url.path + "/usr-local/bin/brew")
    }

    @Test func missingBrewThrowsToolNotFound() async {
        let environment = ResolvedEnvironment(source: .loginShell, variables: [:], searchPath: [])
        let ecosystem = BrewEcosystem(runner: MockCommandRunner(), environment: environment, knownPrefixes: [])
        await #expect(throws: InventoryError.toolNotFound("Homebrew")) { _ = try await ecosystem.scan() }
    }

    @Test func failingBrewThrowsCommandFailed() async throws {
        let home = try TemporaryDirectory()
        let brew = try home.makeExecutable("bin/brew")
        let environment = ResolvedEnvironment(source: .loginShell, variables: [:], searchPath: [brew.deletingLastPathComponent().path])
        let mock = MockCommandRunner()
        await mock.stub(brew.path, exitCode: 1, stderr: "Error: Another active Homebrew process is already in progress.")

        await #expect {
            _ = try await BrewEcosystem(runner: mock, environment: environment).scan()
        } throws: { error in
            guard case InventoryError.commandFailed(_, 1, let stderr) = error else { return false }
            return stderr.contains("Another active Homebrew process")
        }
    }
}
