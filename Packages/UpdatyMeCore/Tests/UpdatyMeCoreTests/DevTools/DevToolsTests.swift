import Foundation
import Testing
@testable import UpdatyMeCore
import UpdatyMeCoreTestSupport

private func data(_ fixture: String) throws -> Data {
    Data(try Fixture.string("DevTools/\(fixture)").utf8)
}

private func environment(path: [String] = [], managers: [VersionManager] = [], variables: [String: String] = [:]) -> ResolvedEnvironment {
    ResolvedEnvironment(source: .loginShell, variables: variables, searchPath: path, versionManagers: managers)
}

private func runtime(_ ecosystem: EcosystemID, _ version: String, metadata: [String: String] = [:], kind: InstalledItem.Kind = .runtime) -> InstalledItem {
    InstalledItem(id: "\(ecosystem.rawValue):x", name: "x", kind: kind, ecosystem: ecosystem, installedVersion: version,
                  source: .manual, updateCapability: .manual, metadata: metadata)
}

// MARK: - Node

@Suite("Node")
struct NodeTests {
    @Test func nvmInstallationsWithDefaultAndForeignNode() async throws {
        let home = try TemporaryDirectory()
        try home.makeExecutable(".nvm/versions/node/v24.22.1/bin/node")
        try home.makeExecutable(".nvm/versions/node/v26.12.1/bin/node")
        try home.makeExecutable("homebrew/Cellar/node/26.0.0/bin/node")
        let other = try home.makeExecutable("usr-local/bin/node")
        let nvm = VersionManager(kind: .nvm, root: home.url.appendingPathComponent(".nvm"),
                                 binDirectories: [home.url.appendingPathComponent(".nvm/versions/node/v24.22.1/bin")])
        let mock = MockCommandRunner()
        await mock.stub(other.path, arguments: ["--version"], stdout: "v20.11.0\n")

        let items = try await NodeEcosystem(environment: environment(path: [other.deletingLastPathComponent().path], managers: [nvm]),
                                            runner: mock).scan()
        #expect(items.map(\.installedVersion) == ["24.22.1", "26.12.1", "20.11.0"])
        #expect(items.map(\.source) == [.nvm, .nvm, .manual])
        #expect(items.map { $0.metadata["isDefault"] } == ["true", "false", nil])
        #expect(items.allSatisfy { $0.kind == .runtime && $0.updateCapability == .manual })

        let brewOnly = try await NodeEcosystem(environment: environment(path: [home.url.path + "/homebrew/Cellar/node/26.0.0/bin"]),
                                               runner: mock).scan()
        #expect(brewOnly.isEmpty, "Brew-Node ist schon ein Brew-Eintrag")
    }

    @Test func npmAndPnpmGlobalPackages() throws {
        let recorded = try NodePackagesEcosystem.parseNpm(data("npm-ls-global.json"))
        #expect(recorded.map(\.name) == ["corepack", "npm"])
        #expect(recorded.map(\.version) == ["0.36.0", "11.19.1"])
        let synthetic = try NodePackagesEcosystem.parseNpm(data("npm-ls-global-synthetic.json"))
        #expect(synthetic.map(\.name) == ["@vue/cli", "corepack", "npm"], "Verlinkte (file:) Pakete werden übersprungen")
        #expect(try NodePackagesEcosystem.parsePnpm(data("pnpm-ls-global-empty.json")).isEmpty)
        #expect(try NodePackagesEcosystem.parsePnpm(data("pnpm-ls-global-synthetic.json")).map(\.name) == ["@angular/cli", "typescript"])
    }

    @Test func missingNpmYieldsNoItems() async throws {
        #expect(try await NodePackagesEcosystem(.npm, environment: environment(), runner: MockCommandRunner()).scan().isEmpty)
    }

    static func latest(_ version: String, channel: NodeLatestProvider.Channel) throws -> (RemoteVersion?, InstalledItem) {
        let releases = try JSONDecoder().decode([NodeLatestProvider.Release].self, from: data("nodejs-index.json"))
        let cycles = try JSONDecoder().decode([EndOfLifeCycle].self, from: data("endoflife-nodejs.json"))
        let item = runtime(.node, version)
        let today = try Date("2026-10-27T00:00:00Z", strategy: .iso8601)
        return (NodeLatestProvider.remoteVersion(for: item, releases: releases, cycles: cycles, channel: channel, today: today, fetchedAt: today), item)
    }

    @Test func ltsChannel() throws {
        let (lts24, item24) = try Self.latest("24.22.1", channel: .lts)
        #expect(lts24?.version == "24.22.1")
        #expect(item24.applying(latest: lts24).status == .upToDate)
        #expect(lts24?.endOfLife != nil)

        let (lts22, item22) = try Self.latest("22.23.2", channel: .lts)
        #expect(lts22?.version == "22.23.4", "Eigene LTS-Linie, solange sie gepflegt ist")
        #expect(lts22?.newerReleaseLine == "24")
        #expect(item22.applying(latest: lts22).status == .outdated)
        #expect(item22.applying(latest: lts22).isMajorUpdate == false)

        // 26 ist (noch) keine LTS-Linie, liegt aber über der neuesten LTS und wird unterstützt → eigene Linie.
        let (lts26, item26) = try Self.latest("26.12.0", channel: .lts)
        #expect(lts26?.version == "26.12.1")
        #expect(item26.applying(latest: lts26).status == .outdated)

        // 25 ist keine LTS-Linie und am Ende → neueste LTS (installiert ist neuer → aktuell, EOL im Inspector).
        let (lts25, item25) = try Self.latest("25.8.1", channel: .lts)
        #expect(lts25?.version == "24.22.1")
        #expect(item25.applying(latest: lts25).status == .upToDate)
        #expect(try #require(lts25?.endOfLife) < Date())
    }

    @Test func currentChannel() throws {
        let (current, item) = try Self.latest("24.22.1", channel: .current)
        #expect(current?.version == "26.12.1")
        #expect(item.applying(latest: current).status == .outdated)
        #expect(item.applying(latest: current).isMajorUpdate)
        #expect(current?.newerReleaseLine == nil)
    }
}

// MARK: - Python

@Suite("Python")
struct PythonTests {
    static func latest(_ version: String) throws -> RemoteVersion? {
        let cycles = try JSONDecoder().decode([EndOfLifeCycle].self, from: data("endoflife-python.json"))
        return PythonLatestProvider.remoteVersion(for: runtime(.python, version), cycles: cycles, fetchedAt: Date())
    }

    @Test func sameLineLatestWithNewerLineAndEOL() throws {
        let remote = try #require(try Self.latest("3.13.14"))
        #expect(remote.version == "3.13.18")
        #expect(remote.newerReleaseLine == "3.15")
        #expect(remote.endOfLife != nil)
        #expect(runtime(.python, "3.13.14").applying(latest: remote).status == .outdated)

        let system = try #require(try Self.latest("3.9.6"))
        #expect(system.version == "3.9.25")
        #expect(system.assessment == .compareVersions)
        var apple = runtime(.python, "3.9.6")
        apple.source = .system
        let cycles = try JSONDecoder().decode([EndOfLifeCycle].self, from: data("endoflife-python.json"))
        let appleRemote = try #require(PythonLatestProvider.remoteVersion(for: apple, cycles: cycles, fetchedAt: Date()))
        #expect(apple.applying(latest: appleRemote).status == .unknown, "Apple-Python lässt sich nicht selbst aktualisieren")
        #expect(try #require(system.endOfLife) < Date(), "3.9 ist am Ende")
        #expect(try Self.latest("3.15.2")?.newerReleaseLine == nil)
        #expect(try Self.latest("1.6.1") == nil, "Linie unbekannt")
    }

    @Test func uvOffersOnlyWhatItCanDownload() throws {
        // Aufgezeichnet mit uv 0.13.5: python.org hatte schon 3.14.10, uv bot nur 3.14.9 an.
        let downloads = try data("uv-python-list-downloads.json")
        #expect(try PythonLatestProvider.newestUvDownload(for: "3.14.7", in: downloads) == "3.14.9")
        #expect(try PythonLatestProvider.newestUvDownload(for: "3.12.15", in: downloads) == "3.12.15", "PyPy/GraalPy zählen nicht")
        #expect(try PythonLatestProvider.newestUvDownload(for: "3.16.0", in: downloads) == nil, "Keine Vorabversion für finale Linie")
        #expect(try PythonLatestProvider.newestUvDownload(for: "3.16.0a0", in: downloads) == "3.16.0a1")
        #expect(try PythonLatestProvider.newestUvDownload(for: "3.11.4", in: downloads) == nil)
        #expect(throws: InventoryError.self) { try PythonLatestProvider.newestUvDownload(for: "3.14.7", in: Data("nope".utf8)) }
    }

    @Test func parsesPipxAndUvTools() throws {
        #expect(PythonEcosystem.parsePipx(try data("pipx-list-synthetic.json")).map(\.name) == ["black", "poetry"])
        let uv = PythonEcosystem.parseUvToolList(try Fixture.string("DevTools/uv-tool-list-synthetic.txt"))
        #expect(uv.map(\.name) == ["ruff", "httpie"])
        #expect(uv.map(\.version) == ["0.6.9", "3.2.4"])
        #expect(PythonEcosystem.parseUvToolList("No tools installed\n").isEmpty, "Aufgezeichnet auf diesem Mac")
    }

    @Test func interpretersFromPathPyenvCondaAndDeveloperDirectory() async throws {
        let home = try TemporaryDirectory()
        let pyenv = try home.makeExecutable(".pyenv/versions/3.12.1/bin/python3")
        let manual = try home.makeExecutable("opt/python/bin/python3")
        let conda = try home.makeExecutable("miniconda/base/bin/python3")
        try home.makeDirectory("miniconda/base/conda-meta")
        try home.makeExecutable("homebrew/Cellar/python@3.15/3.15.2/bin/python3")
        let developer = try home.makeExecutable("Xcode.app/Contents/Developer/usr/bin/python3")

        let mock = MockCommandRunner()
        await mock.stub(pyenv.path, stdout: "Python 3.12.1\n")
        await mock.stub(manual.path, stdout: "Python 3.11.9\n")
        await mock.stub(conda.path, stdout: "Python 3.13.14\n")
        await mock.stub(developer.path, stdout: "Python 3.9.6\n")
        await mock.stub(PythonEcosystem.xcodeSelect, arguments: ["-p"], stdout: home.url.path + "/Xcode.app/Contents/Developer\n")

        let env = environment(
            path: [manual.deletingLastPathComponent().path, conda.deletingLastPathComponent().path,
                   home.url.path + "/homebrew/Cellar/python@3.15/3.15.2/bin", "/usr/bin"],
            managers: [VersionManager(kind: .pyenv, root: home.url.appendingPathComponent(".pyenv"))]
        )
        let items = try await PythonEcosystem(environment: env, runner: mock, homeDirectory: home.url).scan()
        #expect(items.map(\.installedVersion) == ["3.12.1", "3.11.9", "3.13.14", "3.9.6"])
        #expect(items.map(\.source) == [.pyenv, .manual, .conda, .system])
        #expect(!(await mock.invocations).contains { $0.executable.path == "/usr/bin/python3" }, "Shim nie starten")
    }
}

// MARK: - Rust

@Suite("Rust")
struct RustTests {
    @Test func toolchainsAndCargoCrates() async throws {
        let home = try TemporaryDirectory()
        let stable = try home.makeExecutable(".rustup/toolchains/stable-aarch64-apple-darwin/bin/rustc")
        let nightly = try home.makeExecutable(".rustup/toolchains/nightly-aarch64-apple-darwin/bin/rustc")
        let cargo = try home.makeExecutable(".cargo/bin/cargo")
        try Data(#"default_toolchain = "stable-aarch64-apple-darwin""#.utf8).write(to: home.url.appendingPathComponent(".rustup/settings.toml"))

        let mock = MockCommandRunner()
        await mock.stub(stable.path, stdout: try Fixture.string("DevTools/rustc-version-stable-synthetic.txt"))
        await mock.stub(nightly.path, stdout: try Fixture.string("DevTools/rustc-version-nightly-synthetic.txt"))
        await mock.stub(cargo.path, arguments: ["install", "--list"], stdout: try Fixture.string("DevTools/cargo-install-list-synthetic.txt"))

        let items = try await RustEcosystem(environment: environment(), runner: mock, homeDirectory: home.url).scan()
        #expect(items.map(\.name) == ["Rust (nightly)", "Rust (stable)", "ripgrep", "cargo-edit"])
        #expect(items.map(\.installedVersion) == ["1.101.0-nightly", "1.98.0", "14.1.1", "0.13.0"])
        #expect(items[1].metadata["isDefault"] == "true")
        #expect(items[2].kind == .package)
    }

    @Test func stableVersionFromRecordedManifest() async throws {
        let manifest = try Fixture.string("DevTools/rust-channel-stable.toml")
        #expect(RustLatestProvider.stableVersion(in: manifest) == "1.99.1")

        let transport = MockHTTPTransport()
        await transport.stub(RustLatestProvider.channelURL, HTTPResponse(statusCode: 200, body: Data(manifest.utf8)))
        let directory = try TemporaryDirectory()
        let provider = RustLatestProvider(http: CachingHTTPClient(transport: transport, cache: HTTPDiskCache(directory: directory.url)))
        let stable = runtime(.rust, "1.98.0", metadata: ["toolchain": "stable-aarch64-apple-darwin"])
        #expect(try await provider.latest(for: stable)?.version == "1.99.1")
        #expect(try await provider.latest(for: runtime(.rust, "1.101.0-nightly", metadata: ["toolchain": "nightly-aarch64-apple-darwin"])) == nil)
        #expect(try await provider.latest(for: runtime(.rust, "1.80.0", metadata: ["toolchain": "1.80.0-aarch64-apple-darwin"])) == nil)
    }
}

// MARK: - Java

@Suite("Java")
struct JavaTests {
    @Test func parsesRecordedJavaHomeAndRelease() throws {
        #expect(JavaEcosystem.parseJavaHomeList(try Fixture.string("DevTools/java_home-V.stderr.txt"))
                == ["/Library/Java/JavaVirtualMachines/zulu-25.jdk/Contents/Home"])
        let item = try #require(JavaEcosystem.item(home: "/jdk", release: try Fixture.string("DevTools/jdk-release-zulu-25.txt"), source: .manual))
        #expect(item.name == "Java (Azul Zulu)")
        #expect(item.installedVersion == "25.0.5")
        #expect(item.metadata["distribution"] == "zulu")
        #expect(item.metadata["brewCaskCandidates"] == "zulu")
    }

    @Test func caskInstalledJDKAppearsOnlyAsCask() throws {
        let java = try #require(JavaEcosystem.item(home: "/jdk", release: try Fixture.string("DevTools/jdk-release-zulu-25.txt"), source: .manual))
        let cask = InstalledItem(id: "brew:cask/zulu@25", name: "Zulu", kind: .cli, ecosystem: .brew, installedVersion: "25.0.5,25.38.107",
                                 source: .cask, metadata: ["fullName": "zulu@25"])
        #expect(InventoryScanner.removingBrewManagedDuplicates([cask, java]).map(\.id) == [cask.id])
        var older = cask
        older.installedVersion = "25.0.4,25.36.205"
        #expect(InventoryScanner.removingBrewManagedDuplicates([older, java]).count == 2, "Andere Version = andere Installation")
    }

    @Test func latestFromFoojay() async throws {
        let transport = MockHTTPTransport()
        let url = try #require(JavaLatestProvider.packagesURL(major: "25", distribution: "zulu", architecture: "aarch64"))
        await transport.stub(url, HTTPResponse(statusCode: 200, body: try data("foojay-zulu-25.json")))
        await transport.stub(JavaLatestProvider.majorVersionsURL, HTTPResponse(statusCode: 200, body: try data("foojay-major-versions.json")))
        let directory = try TemporaryDirectory()
        let provider = JavaLatestProvider(http: CachingHTTPClient(transport: transport, cache: HTTPDiskCache(directory: directory.url)),
                                          architecture: "aarch64")

        let zulu25 = runtime(.java, "25.0.5", metadata: ["distribution": "zulu"])
        let remote = try #require(try await provider.latest(for: zulu25))
        // Aufgezeichnet: foojay kannte erst 25.0.4.1, installiert ist bereits 25.0.5.
        #expect(remote.version == "25.0.4.1")
        #expect(zulu25.applying(latest: remote).status == .upToDate)
        #expect(remote.newerReleaseLine == nil, "27 ist STS, keine neuere LTS")
        #expect(try await provider.latest(for: runtime(.java, "25.0.5")) == nil, "Unbekannter Hersteller")
    }
}

// MARK: - Registries, gcloud

@Suite("Registries")
struct RegistryTests {
    @Test func npmPyPICratesAndGcloud() async throws {
        let transport = MockHTTPTransport()
        let npm = try #require(RegistryLatestProvider.url(for: "npm", in: .npm))
        let ruff = try #require(RegistryLatestProvider.url(for: "ruff", in: .pypi))
        let ripgrep = try #require(RegistryLatestProvider.url(for: "ripgrep", in: .crates))
        await transport.stub(npm, HTTPResponse(statusCode: 200, body: try data("npm-registry-npm-latest.json")))
        await transport.stub(ruff, HTTPResponse(statusCode: 200, body: try data("pypi-ruff.json")))
        await transport.stub(ripgrep, HTTPResponse(statusCode: 200, body: try data("crates-ripgrep.json")))
        await transport.stub(GcloudLatestProvider.componentsURL, HTTPResponse(statusCode: 200, body: try data("gcloud-components.json")))
        let directory = try TemporaryDirectory()
        let http = CachingHTTPClient(transport: transport, cache: HTTPDiskCache(directory: directory.url))

        #expect(try await RegistryLatestProvider(http: http, registry: .npm).latest(for: runtime(.npm, "11.19.1", metadata: ["packageName": "npm"], kind: .package))?.version == "12.2.1")
        #expect(try await RegistryLatestProvider(http: http, registry: .pypi).latest(for: runtime(.python, "0.6.9", metadata: ["packageName": "ruff"], kind: .package))?.version == "0.17.3")
        #expect(try await RegistryLatestProvider(http: http, registry: .crates).latest(for: runtime(.rust, "14.1.1", metadata: ["packageName": "ripgrep"], kind: .package))?.version == "15.2.0")
        #expect(try await GcloudLatestProvider(http: http).latest(for: runtime(.gcloud, "579.0.0"))?.version == "590.0.1")
        #expect(RegistryLatestProvider.url(for: "@vue/cli", in: .npm)?.absoluteString == "https://registry.npmjs.org/@vue%2Fcli/latest")
    }

    @Test func brewGcloudUsesRealVersionAndMinicondaPattern() async throws {
        let home = try TemporaryDirectory()
        let gcloud = try home.makeExecutable("share/google-cloud-sdk/bin/gcloud")
        let mock = MockCommandRunner()
        await mock.stub(gcloud.path, arguments: ["version"], stdout: try Fixture.string("DevTools/gcloud-version.txt"))
        let brew = BrewEcosystem(runner: mock, environment: environment(), knownPrefixes: [])
        let cask = InstalledItem(id: "brew:cask/gcloud-cli", name: "Google Cloud CLI", kind: .cli, ecosystem: .brew,
                                 installedVersion: "537.0.0", source: .cask, metadata: ["fullName": "gcloud-cli", "autoUpdates": "true"])
        let real = await brew.usingToolVersion(cask, prefix: home.url.path)
        #expect(real.installedVersion == "579.0.0")
        #expect(real.metadata["brewRecordedVersion"] == "537.0.0")
        let remote = BrewLatestProvider.remoteVersion(
            for: real, outdated: .init(name: "gcloud-cli", installedVersions: ["537.0.0"], currentVersion: "590.0.1"))
        #expect(real.applying(latest: remote).status == .outdated)

        var conda = cask
        conda.id = "brew:cask/miniconda"
        conda.installedVersion = "26.7.0"
        conda.metadata = ["fullName": "miniconda", "autoUpdates": "true", "brewRecordedVersion": "py313_25.7.0-2",
                          "brewLatestVersionPattern": #"_(\d+(?:\.\d+)+)"#]
        let condaRemote = BrewLatestProvider.remoteVersion(
            for: conda, outdated: .init(name: "miniconda", installedVersions: ["py313_25.7.0-2"], currentVersion: "py314_26.9.4-0"))
        #expect(condaRemote.version == "26.9.4")
        #expect(conda.applying(latest: condaRemote).status == .outdated)
    }

    @Test func standaloneGcloudOnlyOutsideBrew() async throws {
        let home = try TemporaryDirectory()
        let standalone = try home.makeExecutable("google-cloud-sdk/bin/gcloud")
        let mock = MockCommandRunner()
        await mock.stub(standalone.path, stdout: try Fixture.string("DevTools/gcloud-version.txt"))
        let items = try await GcloudEcosystem(environment: environment(path: [standalone.deletingLastPathComponent().path]), runner: mock,
                                              brewPrefixes: [home.url.path + "/homebrew"]).scan()
        #expect(items.map(\.installedVersion) == ["579.0.0"])
        let underBrew = try await GcloudEcosystem(environment: environment(path: [standalone.deletingLastPathComponent().path]), runner: mock,
                                                  brewPrefixes: [home.url.path]).scan()
        #expect(underBrew.isEmpty)
    }
}

// MARK: - Konfiguration

@Suite("ConfiguredTools")
struct ConfiguredToolsTests {
    @Test func toolsFromConfigWithErrorsVisibleAndBrewSkipped() async throws {
        let home = try TemporaryDirectory()
        let mytool = try home.makeExecutable("bin/mytool")
        let brewTool = try home.makeExecutable("homebrew/Cellar/gh/2.0/bin/gh")
        let config = home.url.appendingPathComponent("tools.json")
        try Data("""
            { "tools": [
              { "id": "mytool", "name": "My Tool", "command": "mytool", "versionPattern": "mytool (\\\\S+)",
                "latest": { "type": "github", "repository": "me/mytool" } },
              { "id": "missing", "command": "does-not-exist", "versionPattern": "(\\\\S+)" },
              { "id": "badpattern", "command": "mytool", "versionPattern": "([" },
              { "id": "nomatch", "command": "mytool", "arguments": ["--help"], "versionPattern": "Version (\\\\S+)" },
              { "id": "gh", "command": "\(brewTool.path)", "versionPattern": "gh version (\\\\S+)" }
            ] }
            """.utf8).write(to: config)
        let mock = MockCommandRunner()
        await mock.stub(mytool.path, arguments: ["--version"], stdout: "mytool 1.2.3\n")
        await mock.stub(mytool.path, arguments: ["--help"], stdout: "usage: mytool\n")

        let items = try await ConfiguredToolsEcosystem(configuration: config, environment: environment(path: [mytool.deletingLastPathComponent().path]),
                                                       runner: mock).scan()
        #expect(items.map(\.id) == ["config:mytool", "config:missing", "config:badpattern", "config:nomatch"])
        #expect(items[0].installedVersion == "1.2.3")
        #expect(items[0].name == "My Tool")
        #expect(items[1].name == "missing", "Name fällt auf id zurück")
        #expect(items.dropFirst().map { $0.metadata["configError"] } == ["commandNotFound", "invalidPattern", "versionNotFound"])
        #expect(items[1].applying(latest: nil).status == .unknown)
    }

    @Test func missingFileYieldsNothingAndInvalidJSONFails() async throws {
        let home = try TemporaryDirectory()
        let config = home.url.appendingPathComponent("tools.json")
        let ecosystem = ConfiguredToolsEcosystem(configuration: config, environment: environment(), runner: MockCommandRunner())
        #expect(try await ecosystem.scan().isEmpty)
        try Data("{ not json".utf8).write(to: config)
        await #expect(throws: InventoryError.self) { _ = try await ecosystem.scan() }
    }

    @Test func latestFromGitHubURLAndNpm() async throws {
        let transport = MockHTTPTransport()
        await transport.stub(URL(string: "https://api.github.com/repos/cli/cli/releases/latest")!,
                             HTTPResponse(statusCode: 200, body: try data("github-cli-latest.json")))
        await transport.stub(URL(string: "https://dl.k8s.io/release/stable.txt")!, HTTPResponse(statusCode: 200, body: Data("v1.37.1".utf8)))
        await transport.stub(try #require(RegistryLatestProvider.url(for: "npm", in: .npm)),
                             HTTPResponse(statusCode: 200, body: try data("npm-registry-npm-latest.json")))
        let directory = try TemporaryDirectory()
        let provider = ConfiguredToolLatestProvider(http: CachingHTTPClient(transport: transport, cache: HTTPDiskCache(directory: directory.url)))
        func tool(_ source: ToolConfiguration.LatestSource) throws -> InstalledItem {
            runtime(.configuredTools, "1.0", metadata: ["configLatest": String(decoding: try JSONEncoder().encode(source), as: UTF8.self)], kind: .cli)
        }

        let gh = try #require(try await provider.latest(for: tool(.github(repository: "cli/cli", tagPattern: nil))))
        #expect(gh.version == "2.103.3")
        #expect(gh.releaseNotesURL?.absoluteString == "https://github.com/cli/cli/releases/tag/v2.103.3")
        #expect(try await provider.latest(for: tool(.url(URL(string: "https://dl.k8s.io/release/stable.txt")!, pattern: "v(\\S+)")))?.version == "1.37.1")
        #expect(try await provider.latest(for: tool(.npm(package: "npm")))?.version == "12.2.1")

        var broken = try tool(.npm(package: "npm"))
        broken.metadata["configError"] = "commandNotFound"
        #expect(try await provider.latest(for: broken) == nil, "Fehlerhafte Tools nicht abfragen")
    }
}
