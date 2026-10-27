import Foundation

/// Ein erkannter Versionsmanager für Runtimes (Node, Python, Ruby, Java, …).
public struct VersionManager: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        case nvm, fnm, volta, asdf, pyenv, rbenv, sdkman
    }

    public var kind: Kind
    /// Installationsverzeichnis des Managers (z. B. `~/.nvm`).
    public var root: URL
    /// Verzeichnisse, die der Manager zum PATH beiträgt (Shims, aktive Version).
    public var binDirectories: [URL]

    public var id: Kind { kind }

    public init(kind: Kind, root: URL, binDirectories: [URL] = []) {
        self.kind = kind
        self.root = root
        self.binDirectories = binDirectories
    }
}

/// Die Umgebung, mit der CLI-Tools aufgerufen werden – so, wie sie ein Terminal sähe.
public struct ResolvedEnvironment: Sendable, Hashable {
    public enum Source: Sendable, Hashable {
        /// Aus `zsh -l -i` gelesen.
        case loginShell
        /// Login-Shell nicht nutzbar; Umgebung des App-Prozesses plus bekannte Verzeichnisse.
        case fallback(reason: FallbackReason)
    }

    /// Warum die Login-Shell nicht genutzt werden konnte. Strukturiert, damit die App übersetzen kann.
    public enum FallbackReason: Sendable, Hashable, CustomStringConvertible {
        case exitCode(Int32)
        case missingMarkers
        case missingPath
        case error(String)

        public var description: String {
            switch self {
            case .exitCode(let code): "exit code \(code)"
            case .missingMarkers: "output without environment markers"
            case .missingPath: "no PATH in output"
            case .error(let message): message
            }
        }
    }

    /// Nachvollziehbare Hinweise für die Diagnoseansicht („Wo wurde was gefunden?“).
    public enum Note: Sendable, Hashable, CustomStringConvertible {
        case loginShellRead(shell: String, pathEntries: Int)
        case loginShellUnavailable(FallbackReason)
        case managerDetected(VersionManager.Kind, root: String)
        case nvmDefaultNode(path: String)
        case nvmDefaultUnresolved
        case pathAdded(String)

        public var description: String {
            switch self {
            case .loginShellRead(let shell, let count): "Read environment from login shell \(shell) (\(count) PATH entries)"
            case .loginShellUnavailable(let reason): "Login shell unavailable: \(reason); using app process environment"
            case .managerDetected(let kind, let root): "\(kind.rawValue) detected: \(root)"
            case .nvmDefaultNode(let path): "nvm default node: \(path)"
            case .nvmDefaultUnresolved: "nvm found, but no default alias could be resolved"
            case .pathAdded(let directory): "Added to PATH: \(directory)"
            }
        }
    }

    public var source: Source
    /// Umgebungsvariablen ohne `PATH`. Können Secrets enthalten – nie vollständig loggen oder anzeigen.
    public var variables: [String: String]
    /// PATH-Einträge in Suchreihenfolge, ohne Duplikate.
    public var searchPath: [String]
    public var versionManagers: [VersionManager]
    public var notes: [Note]

    public init(
        source: Source,
        variables: [String: String],
        searchPath: [String],
        versionManagers: [VersionManager] = [],
        notes: [Note] = []
    ) {
        self.source = source
        self.variables = variables
        self.searchPath = searchPath
        self.versionManagers = versionManagers
        self.notes = notes
    }

    /// Umgebung für `Command.environment`.
    public var processEnvironment: [String: String] {
        var environment = variables
        environment["PATH"] = searchPath.joined(separator: ":")
        return environment
    }

    /// Sucht ein Programm wie `which` im aufgelösten PATH.
    public func executable(named name: String) -> URL? {
        guard !name.isEmpty, !name.contains("/") else { return nil }
        for directory in searchPath {
            let path = URL(fileURLWithPath: directory).appendingPathComponent(name).path
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    /// Ein Aufruf eines Programms aus dem PATH mit der aufgelösten Umgebung.
    public func command(
        _ name: String,
        _ arguments: [String] = [],
        timeout: Duration = Command.defaultTimeout
    ) -> Command? {
        guard let executable = executable(named: name) else { return nil }
        return Command(executable: executable, arguments: arguments, environment: processEnvironment, timeout: timeout)
    }
}
