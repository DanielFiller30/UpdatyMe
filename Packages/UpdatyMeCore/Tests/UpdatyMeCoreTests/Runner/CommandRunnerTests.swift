import Foundation
import Testing
@testable import UpdatyMeCore

/// Integrationstests gegen echte System-Binaries (`/bin/sh` nur hier im Test).
@Suite("CommandRunner")
struct CommandRunnerTests {
    let runner = CommandRunner()

    @Test func collectsStdoutAndExitCode() async throws {
        let result = try await runner.run(Command("/bin/echo", ["hallo", "welt"]))
        #expect(result.exitCode == 0)
        #expect(result.succeeded)
        #expect(result.stdout == "hallo welt\n")
        #expect(result.stderr.isEmpty)
    }

    @Test func passesArgumentsWithoutShellInterpretation() async throws {
        let argument = "$HOME; rm -rf / `whoami` | cat"
        let result = try await runner.run(Command("/bin/echo", [argument]))
        #expect(result.stdout == argument + "\n")
    }

    @Test func separatesStderrAndReportsNonZeroExit() async throws {
        let result = try await runner.run(Command("/bin/sh", ["-c", "echo out; echo err >&2; exit 3"]))
        #expect(result.exitCode == 3)
        #expect(!result.succeeded)
        #expect(result.stdout == "out\n")
        #expect(result.stderr == "err\n")
    }

    @Test func streamsLinesInOrderAndEndsWithCompleted() async throws {
        var events: [CommandEvent] = []
        for try await event in await runner.stream(Command("/bin/sh", ["-c", "printf 'a\\nb\\nc'"])) {
            events.append(event)
        }
        #expect(events == [
            .stdoutLine("a"),
            .stdoutLine("b"),
            .stdoutLine("c"),
            .completed(CommandResult(exitCode: 0, stdout: "a\nb\nc")),
        ])
    }

    @Test func streamsBeforeProcessExits() async throws {
        let command = Command("/bin/sh", ["-c", "echo first; sleep 1; echo second"])
        let clock = ContinuousClock()
        let start = clock.now
        var firstLineAfter: Duration?
        for try await event in await runner.stream(command) {
            if event == .stdoutLine("first") {
                firstLineAfter = start.duration(to: clock.now)
            }
        }
        let elapsed = try #require(firstLineAfter)
        #expect(elapsed < .milliseconds(800))
    }

    @Test func handlesOutputLargerThanPipeBuffer() async throws {
        let result = try await runner.run(Command("/usr/bin/seq", ["1", "50000"]))
        let lines = result.stdout.split(separator: "\n")
        #expect(lines.count == 50000)
        #expect(lines.last == "50000")
    }

    @Test func timesOutAndKillsProcess() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        await #expect {
            _ = try await runner.run(Command("/bin/sh", ["-c", "echo partial; sleep 30"], timeout: .milliseconds(500)))
        } throws: { error in
            guard case CommandError.timedOut(_, let timeout, let stdout, _) = error else { return false }
            return timeout == .milliseconds(500) && stdout == "partial\n"
        }
        #expect(start.duration(to: clock.now) < .seconds(5))
        try await waitUntilIdle()
    }

    @Test func rejectsRelativeOrMissingExecutable() async {
        await #expect(throws: CommandError.invalidExecutable("/does/not/exist")) {
            _ = try await runner.run(Command("/does/not/exist"))
        }
        await #expect(throws: CommandError.self) {
            _ = try await runner.run(Command(executable: URL(string: "echo")!))
        }
    }

    @Test func usesGivenEnvironmentAndWorkingDirectory() async throws {
        let directory = try TemporaryDirectory()
        let env = try await runner.run(Command("/usr/bin/env", environment: ["UPDATYME_TEST": "42"]))
        #expect(env.stdout == "UPDATYME_TEST=42\n")

        let pwd = try await runner.run(Command("/bin/pwd", workingDirectory: directory.url))
        #expect(pwd.stdout == directory.url.path + "\n")
    }

    @Test func cancellingConsumerTerminatesProcess() async throws {
        let stream = await runner.stream(Command("/bin/sleep", ["30"]))
        #expect(await runner.runningCount == 1)
        let consumer = Task {
            for try await _ in stream {}
        }
        try await Task.sleep(for: .milliseconds(200))
        consumer.cancel()
        _ = await consumer.result
        try await waitUntilIdle()
    }

    @Test func cancelAllTerminatesRunningProcesses() async throws {
        let stream = await runner.stream(Command("/bin/sleep", ["30"]))
        await runner.cancelAll()
        var exitCode: Int32?
        for try await event in stream {
            if case .completed(let result) = event { exitCode = result.exitCode }
        }
        #expect(exitCode == SIGTERM)
        try await waitUntilIdle()
    }

    private func waitUntilIdle(timeout: Duration = .seconds(5)) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while await runner.runningCount > 0 {
            guard clock.now < deadline else {
                Issue.record("Prozess läuft nach \(timeout) noch")
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}
