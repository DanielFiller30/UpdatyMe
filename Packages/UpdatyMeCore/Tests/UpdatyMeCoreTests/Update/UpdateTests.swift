import Foundation
import Synchronization
import Testing
@testable import UpdatyMeCore
import UpdatyMeCoreTestSupport

@Suite("BrewUpdateExecutor")
struct BrewUpdateExecutorTests {
    static func item(_ name: String, cask: Bool = false, autoUpdates: Bool = false) -> InstalledItem {
        var metadata = ["fullName": name]
        if autoUpdates { metadata["autoUpdates"] = "true" }
        return InstalledItem(id: "brew:\(cask ? "cask" : "formula")/\(name)", name: name, kind: cask ? .app : .cli,
                             ecosystem: .brew, installedVersion: "1.0", source: cask ? .cask : .brew,
                             status: .outdated, updateCapability: .auto, metadata: metadata)
    }

    @Test func argumentsForFormulaCaskAndAutoUpdatingCask() {
        #expect(BrewUpdateExecutor.arguments(for: Self.item("mobile-dev-inc/tap/maestro")) == ["upgrade", "mobile-dev-inc/tap/maestro"])
        #expect(BrewUpdateExecutor.arguments(for: Self.item("rive", cask: true)) == ["upgrade", "--cask", "rive"])
        #expect(BrewUpdateExecutor.arguments(for: Self.item("rive", cask: true, autoUpdates: true))
                == ["upgrade", "--cask", "--greedy-auto-updates", "rive"])
        var app = Self.item("x")
        app.ecosystem = .appBundle
        #expect(BrewUpdateExecutor.arguments(for: app) == nil)
    }

    @Test func streamsOutputAndCompletes() async throws {
        let home = try TemporaryDirectory()
        let brew = try home.makeExecutable("bin/brew")
        let environment = ResolvedEnvironment(source: .loginShell, variables: [:], searchPath: [brew.deletingLastPathComponent().path])
        let mock = MockCommandRunner()
        await mock.stub(brew.path, arguments: ["upgrade", "pnpm"], stdout: "==> Upgrading pnpm\n12.14.0 -> 12.15.0\n", stderr: "Warning: x\n")

        var events: [UpdateEvent] = []
        for try await event in BrewUpdateExecutor(runner: mock, environment: environment, knownPrefixes: []).update(Self.item("pnpm")) {
            events.append(event)
        }
        #expect(events == [
            .progress(nil),
            .output(line: "==> Upgrading pnpm", isError: false),
            .output(line: "12.14.0 -> 12.15.0", isError: false),
            .output(line: "Warning: x", isError: true),
            .completed(newVersion: nil, restartRequired: false),
        ])
        let invocation = try #require(await mock.invocations.first)
        #expect(invocation.environment?["HOMEBREW_NO_AUTO_UPDATE"] == "1")
        #expect(invocation.timeout == .seconds(1800))
    }

    @Test func failureCarriesBrewErrorLine() async throws {
        let home = try TemporaryDirectory()
        let brew = try home.makeExecutable("bin/brew")
        let environment = ResolvedEnvironment(source: .loginShell, variables: [:], searchPath: [brew.deletingLastPathComponent().path])
        let mock = MockCommandRunner()
        await mock.stub(brew.path, exitCode: 1, stdout: "==> Downloading\n",
                        stderr: "Error: Download failed: https://example.org/x.tar.gz\nSome trailing note\n")

        await #expect(throws: UpdateError.failed(exitCode: 1, reason: "Download failed: https://example.org/x.tar.gz")) {
            for try await _ in BrewUpdateExecutor(runner: mock, environment: environment, knownPrefixes: []).update(Self.item("x")) {}
        }
    }

    @Test(arguments: [
        "sudo: a terminal is required to read the password; either use the -S option to read from standard input or configure an askpass helper",
        "sudo: a password is required",
    ])
    func sudoPromptIsRequiresAdministrator(stderr: String) {
        let error = BrewUpdateExecutor.classifyFailure(CommandResult(exitCode: 1, stderr: "==> Running installer\n\(stderr)\n"))
        guard case .requiresAdministrator = error else {
            Issue.record("Erwartet requiresAdministrator, erhalten \(error)")
            return
        }
    }

    @Test func missingBrewFails() async {
        let environment = ResolvedEnvironment(source: .loginShell, variables: [:], searchPath: [])
        await #expect(throws: InventoryError.toolNotFound("Homebrew")) {
            for try await _ in BrewUpdateExecutor(runner: MockCommandRunner(), environment: environment, knownPrefixes: []).update(Self.item("x")) {}
        }
    }

    @Test func updatableAndRunningCheckHelpers() {
        var item = Self.item("fork", cask: true)
        item.metadata["appPaths"] = "/Applications/Fork.app\n/Applications/Helper.app"
        #expect(item.canUpdateAutomatically)
        #expect(item.appPathsToCheckBeforeUpdate == ["/Applications/Fork.app", "/Applications/Helper.app"])
        item.status = .pinned
        #expect(!item.canUpdateAutomatically)
        #expect(Self.item("pnpm").appPathsToCheckBeforeUpdate.isEmpty)
    }
}

@Suite("UpdateQueue")
struct UpdateQueueTests {
    /// Ausführer mit steuerbarem Ergebnis, der gleichzeitige Läufe misst.
    final class Recorder: UpdateExecutor {
        let delay: Duration
        let failing: Set<String>
        private let state = Mutex((current: 0, maximum: 0, order: [String]()))

        init(delay: Duration = .milliseconds(60), failing: Set<String> = []) {
            self.delay = delay
            self.failing = failing
        }

        var maximumConcurrency: Int { state.withLock { $0.maximum } }
        var order: [String] { state.withLock { $0.order } }

        func update(_ item: InstalledItem) -> AsyncThrowingStream<UpdateEvent, any Error> {
            AsyncThrowingStream { continuation in
                Task {
                    state.withLock { s in
                        s.current += 1
                        s.maximum = max(s.maximum, s.current)
                        s.order.append(item.id)
                    }
                    continuation.yield(.output(line: "updating \(item.id)", isError: false))
                    try? await Task.sleep(for: delay)
                    state.withLock { $0.current -= 1 }
                    if failing.contains(item.id) {
                        continuation.finish(throwing: UpdateError.failed(exitCode: 1, reason: "boom"))
                    } else {
                        continuation.yield(.completed(newVersion: "2.0", restartRequired: false))
                        continuation.finish()
                    }
                }
            }
        }
    }

    static func item(_ id: String, _ ecosystem: EcosystemID) -> InstalledItem {
        InstalledItem(id: id, name: id, kind: .cli, ecosystem: ecosystem, installedVersion: "1.0", source: .brew,
                      status: .outdated, updateCapability: .auto)
    }

    static func collect(_ queue: UpdateQueue, count: Int) async -> [UpdateQueue.Event] {
        var events: [UpdateQueue.Event] = []
        for await event in queue.events {
            events.append(event)
            if events.count == count { break }
        }
        return events
    }

    @Test func serializesPerEcosystemAndContinuesAfterFailure() async {
        let brew = Recorder(failing: ["b"])
        let queue = UpdateQueue(executors: [.brew: brew])
        await queue.enqueue([Self.item("a", .brew), Self.item("b", .brew), Self.item("c", .brew)])
        await queue.waitUntilIdle()

        #expect(brew.maximumConcurrency == 1, "Brew-Updates nie gleichzeitig")
        #expect(brew.order == ["a", "b", "c"])
        let events = await Self.collect(queue, count: 12)
        let finished = events.compactMap { event -> String? in
            switch event {
            case .succeeded(let id, let version, _): "\(id) ok \(version ?? "-")"
            case .failed(let id, let error): "\(id) failed \(error)"
            default: nil
            }
        }
        #expect(finished == ["a ok 2.0", "b failed Failed with exit code 1: boom", "c ok 2.0"])
        #expect(await queue.isIdle)
    }

    @Test func differentEcosystemsRunInParallel() async {
        let shared = Recorder(delay: .milliseconds(300))
        let queue = UpdateQueue(executors: [.brew: shared, .npm: shared])
        let clock = ContinuousClock()
        let start = clock.now
        await queue.enqueue([Self.item("a", .brew), Self.item("b", .npm)])
        await queue.waitUntilIdle()
        #expect(shared.maximumConcurrency == 2)
        #expect(start.duration(to: clock.now) < .milliseconds(550))
    }

    @Test func ignoresDuplicatesAndCancelsQueuedButNotRunning() async {
        let brew = Recorder(delay: .milliseconds(200))
        let queue = UpdateQueue(executors: [.brew: brew])
        await queue.enqueue([Self.item("a", .brew), Self.item("b", .brew)])
        await queue.enqueue([Self.item("a", .brew)])
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await queue.cancelQueued("a") == false, "Läuft bereits")
        #expect(await queue.cancelQueued("b") == true)
        await queue.waitUntilIdle()
        #expect(brew.order == ["a"])
    }

    @Test func itemsWithoutExecutorFailAsUnsupported() async {
        let queue = UpdateQueue()
        await queue.enqueue([Self.item("x", .appBundle)])
        let events = await Self.collect(queue, count: 1)
        guard case .failed("x", let error)? = events.first, case UpdateError.unsupported = error else {
            Issue.record("Erwartet unsupported, erhalten \(events)")
            return
        }
    }
}

@Suite("CachingCommandRunner.remove")
struct CachingCommandRunnerRemoveTests {
    @Test func removesOnlyMatchingEntries() async throws {
        let directory = try TemporaryDirectory()
        let mock = MockCommandRunner()
        await mock.stub("/opt/homebrew/bin/brew", stdout: "{}")
        await mock.stub("/usr/sbin/softwareupdate", stdout: "x")
        let runner = CachingCommandRunner(base: mock, directory: directory.url)
        _ = try await runner.run(Command("/opt/homebrew/bin/brew", ["outdated", "--json=v2", "--greedy"]))
        _ = try await runner.run(Command("/usr/sbin/softwareupdate", ["--list"]))

        await runner.remove { $0.contains(" outdated ") }
        _ = try await runner.run(Command("/opt/homebrew/bin/brew", ["outdated", "--json=v2", "--greedy"]))
        _ = try await runner.run(Command("/usr/sbin/softwareupdate", ["--list"]))
        #expect(await mock.invocations.map(\.executable.lastPathComponent) == ["brew", "softwareupdate", "brew"])
    }
}
