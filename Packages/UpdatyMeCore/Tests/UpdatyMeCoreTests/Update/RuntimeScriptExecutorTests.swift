import Foundation
import Testing
import UpdatyMeCoreTestSupport
@testable import UpdatyMeCore

@Suite("RuntimeScriptExecutor")
struct RuntimeScriptExecutorTests {
    static let environment = ResolvedEnvironment(source: .loginShell, variables: [:], searchPath: ["/usr/bin"])

    static func item(_ source: ItemSource, _ installed: String, latest: String? = nil) -> InstalledItem {
        RuntimeGuideTests.runtime(.node, source, installed, latest: latest, isDefault: true)
    }

    static func events(_ executor: RuntimeScriptExecutor, _ item: InstalledItem) async throws -> [UpdateEvent] {
        var events: [UpdateEvent] = []
        for try await event in executor.update(item) { events.append(event) }
        return events
    }

    @Test func uninstallCommandsPerManager() {
        func uninstall(_ item: InstalledItem) -> String? { RuntimeGuide.guide(for: item)?.uninstall?.command }
        #expect(uninstall(Self.item(.nvm, "22.1.0")) == "nvm uninstall 22.1.0")
        #expect(uninstall(Self.item(.fnm, "22.1.0")) == "fnm uninstall 22.1.0")
        #expect(uninstall(RuntimeGuideTests.runtime(.python, .pyenv, "3.12.1")) == "pyenv uninstall -f 3.12.1")
        #expect(uninstall(RuntimeGuideTests.runtime(.rust, .rustup, "1.101.0-nightly", metadata: ["toolchain": "nightly-aarch64-apple-darwin"]))
                == "rustup toolchain uninstall nightly-aarch64-apple-darwin")
        #expect(uninstall(Self.item(.manual, "20.1.0")) == nil)
        #expect(uninstall(RuntimeGuideTests.runtime(.python, .system, "3.9.6")) == nil, "System-Python nie entfernen")
    }

    @Test func updateStepsExcludeListAndDisplayOnlyCommands() throws {
        let node = try #require(RuntimeGuide.guide(for: Self.item(.nvm, "24.21.0", latest: "24.22.1")))
        #expect(node.canRunUpdate)
        #expect(node.updateSteps.map(\.purpose) == [.installLatest, .setDefault])
        let current = try #require(RuntimeGuide.guide(for: Self.item(.nvm, "24.22.1")))
        #expect(!current.canRunUpdate, "Ohne neuere Version kein Update")
        let java = try #require(RuntimeGuide.guide(for: RuntimeGuideTests.runtime(.java, .manual, "25.0.5", latest: "25.0.6")))
        #expect(!java.canRunUpdate, "`export JAVA_HOME` wird nicht ausgeführt")
    }

    @Test func runsEachStepThroughTheConstantWrapper() async throws {
        let runner = MockCommandRunner()
        await runner.stub("/bin/zsh", stdout: "ok")
        let executor = RuntimeScriptExecutor(runner: runner, environment: Self.environment)
        let job = Self.item(.nvm, "24.21.0", latest: "24.22.1").runtimeJob(.update)
        let events = try await Self.events(executor, job)

        let invocations = await runner.invocations
        #expect(invocations.map(\.arguments) == [
            ["-f", "-c", RuntimeScriptExecutor.wrapperScript, "updatyme-runtime", "nvm", "install", "24.22.1", "--reinstall-packages-from=24.21.0"],
            ["-f", "-c", RuntimeScriptExecutor.wrapperScript, "updatyme-runtime", "nvm", "alias", "default", "24.22.1"],
        ])
        #expect(events.last == .completed(newVersion: nil, restartRequired: false))
    }

    @Test func failureStopsAndReportsLastLine() async throws {
        let runner = MockCommandRunner()
        await runner.stub("/bin/zsh", exitCode: 3, stderr: "warn\nVersion not found")
        let executor = RuntimeScriptExecutor(runner: runner, environment: Self.environment)
        let job = Self.item(.nvm, "24.21.0", latest: "24.22.1").runtimeJob(.update)
        await #expect(throws: UpdateError.failed(exitCode: 3, reason: "Version not found")) {
            _ = try await Self.events(executor, job)
        }
        #expect(await runner.invocations.count == 1)
    }

    @Test func rejectsUnsafeArgumentsAndMissingAction() async throws {
        let runner = MockCommandRunner()
        let executor = RuntimeScriptExecutor(runner: runner, environment: Self.environment)
        await #expect(throws: UpdateError.self) {
            _ = try await Self.events(executor, Self.item(.nvm, "1.0; rm -rf ~").runtimeJob(.uninstall))
        }
        await #expect(throws: UpdateError.self) {
            _ = try await Self.events(executor, Self.item(.nvm, "22.1.0"))
        }
        #expect(await runner.invocations.isEmpty)
    }
}

@Suite("RuntimeScriptExecutor custom version")
struct RuntimeCustomVersionTests {
    @Test func buildsInstallCommandsForEnteredVersion() {
        let nvm = RuntimeGuideTests.runtime(.node, .nvm, "22.1.0")
        #expect(RuntimeGuide.installSteps(for: nvm, version: "20.11.0", setDefault: true).map(\.command)
                == ["nvm install 20.11.0 --reinstall-packages-from=22.1.0", "nvm alias default 20.11.0"])
        #expect(RuntimeGuide.installSteps(for: nvm, version: "20.11.0", setDefault: false).count == 1)
        #expect(RuntimeGuide.installSteps(for: nvm, version: "--evil", setDefault: false).isEmpty)
        #expect(RuntimeGuide.installSteps(for: nvm, version: "1 2", setDefault: false).isEmpty)
        #expect(!RuntimeGuide.supportsCustomVersion(RuntimeGuideTests.runtime(.node, .manual, "20.1.0")))
        #expect(RuntimeGuide.supportsCustomVersion(RuntimeGuideTests.runtime(.python, .pyenv, "3.12.1")))
    }

    @Test func executorRunsEnteredVersion() async throws {
        let runner = MockCommandRunner()
        await runner.stub("/bin/zsh")
        let executor = RuntimeScriptExecutor(runner: runner, environment: RuntimeScriptExecutorTests.environment)
        let job = RuntimeGuideTests.runtime(.node, .fnm, "22.1.0").runtimeInstallJob(version: "18.20.4", setDefault: false)
        for try await _ in executor.update(job) {}
        #expect(await runner.invocations.map { Array($0.arguments.dropFirst(4)) } == [["fnm", "install", "18.20.4"]])
    }
}
