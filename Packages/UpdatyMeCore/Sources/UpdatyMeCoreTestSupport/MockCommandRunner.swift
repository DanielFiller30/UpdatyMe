import Foundation
import UpdatyMeCore

/// Ersetzt `CommandRunner` in Tests: liefert hinterlegte Ausgaben (z. B. aus Fixtures) und
/// protokolliert alle Aufrufe.
public actor MockCommandRunner: CommandRunning {
    public enum Response: Sendable {
        case result(CommandResult)
        case error(CommandError)
    }

    public enum MockError: Error, Sendable, Equatable {
        case unstubbedCommand(String)
    }

    private struct Key: Hashable {
        var executable: String
        var arguments: [String]?
    }

    private var responses: [Key: Response] = [:]
    public private(set) var invocations: [Command] = []

    public init() {}

    /// Hinterlegt eine Antwort für genau diesen Aufruf. Mit `arguments: nil` gilt sie für alle
    /// Argumente dieses Programms (eine exakte Hinterlegung hat Vorrang).
    public func stub(_ executable: String, arguments: [String]? = nil, with response: Response) {
        responses[Key(executable: executable, arguments: arguments)] = response
    }

    public func stub(
        _ executable: String,
        arguments: [String]? = nil,
        exitCode: Int32 = 0,
        stdout: String = "",
        stderr: String = ""
    ) {
        stub(executable, arguments: arguments, with: .result(
            CommandResult(exitCode: exitCode, stdout: stdout, stderr: stderr)
        ))
    }

    public func stream(_ command: Command) -> AsyncThrowingStream<CommandEvent, any Error> {
        invocations.append(command)
        let path = command.executable.path
        let response = responses[Key(executable: path, arguments: command.arguments)]
            ?? responses[Key(executable: path, arguments: nil)]

        return AsyncThrowingStream { continuation in
            switch response {
            case .result(let result):
                for line in Self.lines(result.stdout) {
                    continuation.yield(.stdoutLine(line))
                }
                for line in Self.lines(result.stderr) {
                    continuation.yield(.stderrLine(line))
                }
                continuation.yield(.completed(result))
                continuation.finish()
            case .error(let error):
                continuation.finish(throwing: error)
            case nil:
                continuation.finish(throwing: MockError.unstubbedCommand(command.description))
            }
        }
    }

    private static func lines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if text.hasSuffix("\n") {
            lines.removeLast()
        }
        return lines
    }
}
