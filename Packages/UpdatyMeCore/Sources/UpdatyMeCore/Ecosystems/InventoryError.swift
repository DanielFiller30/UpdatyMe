import Foundation

public enum InventoryError: Error, Sendable, Hashable, CustomStringConvertible {
    /// Das benötigte Programm ist nicht installiert (z. B. kein Homebrew).
    case toolNotFound(String)
    case commandFailed(command: String, exitCode: Int32, stderr: String)
    case unexpectedOutput(source: String, detail: String)

    public var description: String {
        switch self {
        case .toolNotFound(let tool):
            "\(tool) is not installed"
        case .commandFailed(let command, let exitCode, let stderr):
            "\(command) exited with code \(exitCode)"
                + (stderr.isEmpty ? "" : ": \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        case .unexpectedOutput(let source, let detail):
            "Unexpected output from \(source): \(detail)"
        }
    }
}

extension CommandRunning {
    /// Führt den Aufruf aus und wirft `InventoryError.commandFailed` bei Exit-Code ≠ 0.
    func runChecked(_ command: Command) async throws -> CommandResult {
        let result = try await run(command)
        guard result.succeeded else {
            throw InventoryError.commandFailed(command: command.description, exitCode: result.exitCode, stderr: result.stderr)
        }
        return result
    }
}

extension InstalledItem {
    /// Schlüssel für `metadata`, die mehrere Komponenten gemeinsam nutzen.
    public enum MetadataKey {
        public static let bundleIdentifier = "bundleIdentifier"
        public static let bundleVersion = "bundleVersion"
        public static let sparkleFeedURL = "sparkleFeedURL"
        public static let osBuild = "build"
        public static let brewFullName = "fullName"
        public static let brewTap = "tap"
        public static let brewPinned = "pinned"
        /// Zeilengetrennte absolute Pfade der Apps eines Casks.
        public static let caskAppPaths = "appPaths"
    }
}
