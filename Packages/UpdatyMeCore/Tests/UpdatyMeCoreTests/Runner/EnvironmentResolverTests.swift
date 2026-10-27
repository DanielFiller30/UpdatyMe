import Foundation
import Testing
@testable import UpdatyMeCore
import UpdatyMeCoreTestSupport

@Suite("EnvironmentResolver")
struct EnvironmentResolverTests {
    static let shell = "/bin/zsh"
    static let loginArguments = ["-l", "-i", "-c", EnvironmentResolver.loginShellScript]
    static let guiEnvironment = ["HOME": "/Users/gui", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "SECRET_TOKEN": "x"]

    func makeResolver(
        _ mock: MockCommandRunner,
        home: URL,
        wellKnown: [String] = []
    ) -> EnvironmentResolver {
        EnvironmentResolver(
            runner: mock,
            shell: Self.shell,
            homeDirectory: home,
            baseEnvironment: Self.guiEnvironment,
            wellKnownDirectories: wellKnown
        )
    }

    // MARK: - Parser

    @Test func parsesFixtureIgnoringShellNoise() throws {
        let output = try Fixture.string("EnvironmentResolver/zsh-login-env.txt")
        let variables = try #require(EnvironmentResolver.parseEnvironment(output))
        #expect(variables["HOME"] == "/Users/fixture")
        #expect(variables["LANG"] == "de_DE.UTF-8")
        #expect(variables["MULTILINE"] == "line one\nline two")
        #expect(variables["EQUALS"] == "a=b=c")
        #expect(variables["EMPTY"] == "")
        #expect(variables.count == 7)
    }

    @Test func parserRejectsOutputWithoutMarkers() throws {
        let output = try Fixture.string("EnvironmentResolver/zsh-login-no-markers.txt")
        #expect(EnvironmentResolver.parseEnvironment(output) == nil)
    }

    @Test func splitPathDropsEmptyAndDuplicateEntries() {
        #expect(EnvironmentResolver.splitPath("/a::/b:/a:/c") == ["/a", "/b", "/c"])
        #expect(EnvironmentResolver.splitPath(nil) == [])
    }

    // MARK: - Login-Shell

    @Test func usesLoginShellEnvironment() async throws {
        let home = try TemporaryDirectory()
        let mock = MockCommandRunner()
        await mock.stub(Self.shell, arguments: Self.loginArguments,
                        stdout: try Fixture.string("EnvironmentResolver/zsh-login-env.txt"))

        let environment = await makeResolver(mock, home: home.url).resolve()

        #expect(environment.source == .loginShell)
        #expect(environment.searchPath.starts(with: [
            "/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        ]))
        #expect(environment.variables["PATH"] == nil)
        #expect(environment.processEnvironment["PATH"]?.hasPrefix("/opt/homebrew/bin:") == true)
        #expect(environment.variables["SECRET_TOKEN"] == nil, "GUI-Umgebung darf die Shell-Umgebung nicht überlagern")

        let invocation = try #require(await mock.invocations.first)
        #expect(invocation.arguments == Self.loginArguments)
        #expect(invocation.workingDirectory == home.url)
    }

    @Test(arguments: [
        MockCommandRunner.Response.result(CommandResult(exitCode: 1, stderr: "zsh: error")),
        .result(CommandResult(exitCode: 0, stdout: "no markers")),
        .error(.timedOut(command: "zsh", timeout: .seconds(15), partialStdout: "", partialStderr: "")),
    ])
    func fallsBackToProcessEnvironment(response: MockCommandRunner.Response) async throws {
        let home = try TemporaryDirectory()
        let mock = MockCommandRunner()
        await mock.stub(Self.shell, arguments: Self.loginArguments, with: response)

        let environment = await makeResolver(mock, home: home.url).resolve()

        guard case .fallback = environment.source else {
            Issue.record("Erwartet Fallback, erhalten \(environment.source)")
            return
        }
        #expect(environment.searchPath == ["/usr/bin", "/bin", "/usr/sbin", "/sbin"])
        #expect(environment.variables["SECRET_TOKEN"] == "x")
        guard case .loginShellUnavailable? = environment.notes.first else {
            Issue.record("Erster Hinweis sollte die nicht nutzbare Login-Shell melden: \(environment.notes)")
            return
        }
    }

    @Test func appendsExistingWellKnownDirectoriesOnce() async throws {
        let home = try TemporaryDirectory()
        try home.makeDirectory(".cargo/bin")
        let mock = MockCommandRunner()
        await mock.stub(Self.shell, arguments: Self.loginArguments, exitCode: 1)

        let environment = await makeResolver(
            mock, home: home.url, wellKnown: ["~/.cargo/bin", "~/.missing/bin", "/usr/bin"]
        ).resolve()

        #expect(environment.searchPath == ["/usr/bin", "/bin", "/usr/sbin", "/sbin", home.url.path + "/.cargo/bin"])
    }

    @Test func resolvesOnlyOnce() async throws {
        let home = try TemporaryDirectory()
        let mock = MockCommandRunner()
        await mock.stub(Self.shell, arguments: Self.loginArguments,
                        stdout: try Fixture.string("EnvironmentResolver/zsh-login-env.txt"))
        let resolver = makeResolver(mock, home: home.url)

        async let first = resolver.resolve()
        async let second = resolver.resolve()
        _ = await (first, second)
        _ = await resolver.resolve()
        #expect(await mock.invocations.count == 1)

        _ = await resolver.refresh()
        #expect(await mock.invocations.count == 2)
    }

    // MARK: - Versionsmanager

    @Test func detectsNvmViaSourcedScriptAndFindsNode() async throws {
        let home = try TemporaryDirectory()
        try home.makeFile(".nvm/nvm.sh")
        let node = try home.makeExecutable(".nvm/versions/node/v24.11.0/bin/node")
        try home.makeExecutable(".nvm/versions/node/v24.11.0/bin/npm")
        let nvmRoot = home.url.appendingPathComponent(".nvm").path

        let mock = MockCommandRunner()
        await mock.stub(Self.shell, arguments: Self.loginArguments,
                        stdout: try Fixture.string("EnvironmentResolver/zsh-login-env.txt"))
        await mock.stub(Self.shell,
                        arguments: ["-f", "-c", EnvironmentResolver.nvmDefaultScript, "updatyme-nvm", nvmRoot],
                        stdout: node.path + "\n")

        let environment = await makeResolver(mock, home: home.url).resolve()

        let nvm = try #require(environment.versionManagers.first { $0.kind == .nvm })
        #expect(nvm.root.path == nvmRoot)
        #expect(nvm.binDirectories == [node.deletingLastPathComponent()])
        #expect(environment.executable(named: "node") == node)
        #expect(environment.executable(named: "npm")?.lastPathComponent == "npm")
        #expect(environment.notes.contains(.nvmDefaultNode(path: node.path)))

        let nvmCall = try #require(await mock.invocations.last)
        #expect(nvmCall.environment?["NVM_DIR"] == nvmRoot)
    }

    @Test func nvmWithoutDefaultAliasIsStillDetected() async throws {
        let home = try TemporaryDirectory()
        try home.makeFile(".nvm/nvm.sh")
        let mock = MockCommandRunner()
        await mock.stub(Self.shell, arguments: Self.loginArguments,
                        stdout: try Fixture.string("EnvironmentResolver/zsh-login-env.txt"))
        await mock.stub(Self.shell, exitCode: 3, stderr: "N/A: version \"default\" is not yet installed.")

        let environment = await makeResolver(mock, home: home.url).resolve()

        let nvm = try #require(environment.versionManagers.first { $0.kind == .nvm })
        #expect(nvm.binDirectories.isEmpty)
        #expect(environment.notes.contains(.nvmDefaultUnresolved))
    }

    @Test func detectsDirectoryBasedManagers() async throws {
        let home = try TemporaryDirectory()
        try home.makeDirectory(".volta/bin")
        try home.makeDirectory(".asdf/shims")
        try home.makeDirectory(".pyenv/shims")
        try home.makeDirectory(".rbenv/shims")
        try home.makeDirectory(".sdkman/candidates/java/current/bin")
        try home.makeDirectory(".sdkman/candidates/gradle/current/bin")
        try home.makeDirectory(".local/share/fnm/aliases/default/bin")

        let mock = MockCommandRunner()
        await mock.stub(Self.shell, arguments: Self.loginArguments, exitCode: 1)
        let environment = await makeResolver(mock, home: home.url).resolve()

        #expect(Set(environment.versionManagers.map(\.kind)) == [.fnm, .volta, .asdf, .pyenv, .rbenv, .sdkman])
        let path = home.url.path
        for directory in [
            "/.volta/bin", "/.asdf/shims", "/.pyenv/shims", "/.rbenv/shims",
            "/.sdkman/candidates/gradle/current/bin", "/.sdkman/candidates/java/current/bin",
            "/.local/share/fnm/aliases/default/bin",
        ] {
            #expect(environment.searchPath.contains(path + directory), "\(directory) fehlt im PATH")
        }
        #expect(await mock.invocations.count == 1, "Ohne nvm darf kein nvm-Aufruf erfolgen")
    }

    @Test func managerRootFromEnvironmentVariableWins() async throws {
        let home = try TemporaryDirectory()
        let custom = try home.makeDirectory("custom-volta")
        try home.makeDirectory("custom-volta/bin")
        try home.makeDirectory(".volta/bin")

        let mock = MockCommandRunner()
        var guiEnvironment = Self.guiEnvironment
        guiEnvironment["VOLTA_HOME"] = custom.path
        await mock.stub(Self.shell, arguments: Self.loginArguments, exitCode: 1)
        let resolver = EnvironmentResolver(
            runner: mock, shell: Self.shell, homeDirectory: home.url,
            baseEnvironment: guiEnvironment, wellKnownDirectories: []
        )

        let volta = try #require(await resolver.resolve().versionManagers.first { $0.kind == .volta })
        #expect(volta.root.path == custom.path)
    }

    @Test func executableLookupRejectsPaths() {
        let environment = ResolvedEnvironment(source: .loginShell, variables: [:], searchPath: ["/bin"])
        #expect(environment.executable(named: "sh")?.path == "/bin/sh")
        #expect(environment.executable(named: "../bin/sh") == nil)
        #expect(environment.executable(named: "") == nil)
        #expect(environment.command("does-not-exist-updatyme") == nil)
    }
}
