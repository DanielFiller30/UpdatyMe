import Foundation

/// Ein externer Programmaufruf: absoluter Binary-Pfad plus Argument-Array, niemals ein Shell-String.
public struct Command: Sendable, Hashable, CustomStringConvertible {
    public var executable: URL
    public var arguments: [String]
    /// `nil` übernimmt die Umgebung des aufrufenden Prozesses.
    public var environment: [String: String]?
    public var workingDirectory: URL?
    public var timeout: Duration

    public static let defaultTimeout: Duration = .seconds(60)

    public init(
        executable: URL,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        workingDirectory: URL? = nil,
        timeout: Duration = Command.defaultTimeout
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.timeout = timeout
    }

    public init(
        _ executablePath: String,
        _ arguments: [String] = [],
        environment: [String: String]? = nil,
        workingDirectory: URL? = nil,
        timeout: Duration = Command.defaultTimeout
    ) {
        self.init(
            executable: URL(fileURLWithPath: executablePath),
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory,
            timeout: timeout
        )
    }

    public var description: String {
        ([executable.path] + arguments).joined(separator: " ")
    }
}

/// Ergebnis eines beendeten Aufrufs. Ein Exit-Code ungleich 0 ist kein Fehler des Runners;
/// der Aufrufer entscheidet, wie er ihn bewertet.
public struct CommandResult: Sendable, Hashable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String

    public init(exitCode: Int32, stdout: String = "", stderr: String = "") {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }

    public var succeeded: Bool { exitCode == 0 }
}

/// Live-Ereignisse eines laufenden Aufrufs. `completed` ist immer das letzte Ereignis eines
/// erfolgreich beendeten Streams.
public enum CommandEvent: Sendable, Hashable {
    case stdoutLine(String)
    case stderrLine(String)
    case completed(CommandResult)
}

public enum CommandError: Error, Sendable, Hashable, CustomStringConvertible {
    /// Der Pfad ist nicht absolut oder zeigt nicht auf eine ausführbare Datei.
    case invalidExecutable(String)
    case launchFailed(command: String, reason: String)
    /// Der Prozess wurde nach Ablauf des Timeouts beendet; enthält die bis dahin gelesene Ausgabe.
    case timedOut(command: String, timeout: Duration, partialStdout: String, partialStderr: String)
    /// Der Stream endete ohne `completed`-Ereignis (z. B. durch Abbruch).
    case noResult(command: String)

    public var description: String {
        switch self {
        case .invalidExecutable(let path):
            "Invalid executable: \(path)"
        case .launchFailed(let command, let reason):
            "Launch failed (\(command)): \(reason)"
        case .timedOut(let command, let timeout, _, _):
            "Timed out after \(timeout) (\(command))"
        case .noResult(let command):
            "No result (\(command))"
        }
    }
}
