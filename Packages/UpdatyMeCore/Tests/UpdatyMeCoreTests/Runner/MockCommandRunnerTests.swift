import Testing
import UpdatyMeCore
import UpdatyMeCoreTestSupport

@Suite("MockCommandRunner")
struct MockCommandRunnerTests {
    @Test func returnsStubbedResultAndStreamsLines() async throws {
        let mock = MockCommandRunner()
        await mock.stub("/opt/homebrew/bin/brew", arguments: ["--version"], stdout: "Homebrew 4.6.0\nmore\n")

        var events: [CommandEvent] = []
        for try await event in await mock.stream(Command("/opt/homebrew/bin/brew", ["--version"])) {
            events.append(event)
        }
        #expect(events == [
            .stdoutLine("Homebrew 4.6.0"),
            .stdoutLine("more"),
            .completed(CommandResult(exitCode: 0, stdout: "Homebrew 4.6.0\nmore\n")),
        ])
    }

    @Test func exactStubWinsOverWildcard() async throws {
        let mock = MockCommandRunner()
        await mock.stub("/bin/tool", stdout: "wildcard")
        await mock.stub("/bin/tool", arguments: ["a"], stdout: "exact")

        #expect(try await mock.run(Command("/bin/tool", ["a"])).stdout == "exact")
        #expect(try await mock.run(Command("/bin/tool", ["b"])).stdout == "wildcard")
    }

    @Test func throwsStubbedErrorAndUnstubbedCommands() async {
        let mock = MockCommandRunner()
        let timeout = CommandError.timedOut(command: "/bin/slow", timeout: .seconds(1), partialStdout: "", partialStderr: "")
        await mock.stub("/bin/slow", with: .error(timeout))

        await #expect(throws: timeout) { _ = try await mock.run(Command("/bin/slow")) }
        await #expect(throws: MockCommandRunner.MockError.unstubbedCommand("/bin/other x")) {
            _ = try await mock.run(Command("/bin/other", ["x"]))
        }
    }

    @Test func recordsInvocations() async throws {
        let mock = MockCommandRunner()
        await mock.stub("/bin/tool")
        _ = try await mock.run(Command("/bin/tool", ["1"], environment: ["A": "B"]))
        _ = try await mock.run(Command("/bin/tool", ["2"]))

        let invocations = await mock.invocations
        #expect(invocations.map(\.arguments) == [["1"], ["2"]])
        #expect(invocations.first?.environment == ["A": "B"])
    }
}
