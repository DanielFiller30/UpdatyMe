import Foundation

/// Löst das PATH-Problem von GUI-Apps: Eine aus dem Finder gestartete App erbt nur den
/// launchd-PATH (`/usr/bin:/bin:/usr/sbin:/sbin`) und findet `brew`, `node` & Co. nicht.
///
/// Vorgehen:
/// 1. Einmalig `zsh -l -i` starten und dessen Umgebung lesen (wie ein neues Terminal-Fenster).
/// 2. Versionsmanager (nvm, fnm, volta, asdf, pyenv, rbenv, sdkman) explizit erkennen und deren
///    Verzeichnisse hinten an den PATH anhängen, falls die Shell-Konfiguration sie nicht schon setzt
///    (z. B. bei lazy geladenem nvm). nvm ist eine Shell-Funktion, daher wird `nvm.sh` gesourct.
/// 3. Schlägt die Login-Shell fehl: Umgebung des App-Prozesses plus bekannte Verzeichnisse.
///
/// Die Shell-Skripte sind Konstanten; variable Werte werden nur als Positionsparameter übergeben.
public actor EnvironmentResolver {
    static let beginMarker = "__UPDATYME_ENV_BEGIN__"
    static let endMarker = "__UPDATYME_ENV_END__"

    static let loginShellScript =
        #"printf '%s\0' \#(beginMarker); /usr/bin/env -0; printf '%s\0' \#(endMarker)"#

    /// `$1` = NVM_DIR. Gibt den Pfad zum `node`-Binary des Default-Alias aus.
    static let nvmDefaultScript =
        #"source "$1/nvm.sh" --no-use >/dev/null 2>&1 || exit 97; nvm which default"#

    public static let defaultWellKnownDirectories = [
        "/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/usr/local/sbin",
        "~/.local/bin", "~/.cargo/bin",
    ]

    static let systemPath = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]

    private let runner: any CommandRunning
    private let shell: String
    private let homeDirectory: URL
    private let baseEnvironment: [String: String]
    private let wellKnownDirectories: [String]
    private let loginShellTimeout: Duration
    private var cached: Task<ResolvedEnvironment, Never>?

    public init(
        runner: any CommandRunning,
        shell: String = "/bin/zsh",
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        wellKnownDirectories: [String] = EnvironmentResolver.defaultWellKnownDirectories,
        loginShellTimeout: Duration = .seconds(15)
    ) {
        self.runner = runner
        self.shell = shell
        self.homeDirectory = homeDirectory
        self.baseEnvironment = baseEnvironment
        self.wellKnownDirectories = wellKnownDirectories
        self.loginShellTimeout = loginShellTimeout
    }

    /// Liefert die Umgebung; wird nur beim ersten Aufruf ermittelt.
    public func resolve() async -> ResolvedEnvironment {
        if let cached {
            return await cached.value
        }
        let task = Task { await self.computeEnvironment() }
        cached = task
        return await task.value
    }

    /// Verwirft den Cache und ermittelt die Umgebung neu.
    public func refresh() async -> ResolvedEnvironment {
        cached = nil
        return await resolve()
    }

    // MARK: - Ermittlung

    private func computeEnvironment() async -> ResolvedEnvironment {
        var notes: [ResolvedEnvironment.Note] = []
        var variables: [String: String]
        var searchPath: [String]
        let source: ResolvedEnvironment.Source

        switch await readLoginShellEnvironment() {
        case .success(let shellVariables):
            source = .loginShell
            variables = shellVariables
            searchPath = Self.splitPath(shellVariables["PATH"])
            notes.append(.loginShellRead(shell: shell, pathEntries: searchPath.count))
        case .failure(let reason):
            source = .fallback(reason: reason)
            variables = baseEnvironment
            searchPath = Self.splitPath(baseEnvironment["PATH"])
            notes.append(.loginShellUnavailable(reason))
        }
        variables["PATH"] = nil

        var managers: [VersionManager] = []
        for kind in VersionManager.Kind.allCases {
            if let manager = await detect(kind, variables: variables, searchPath: searchPath, notes: &notes) {
                managers.append(manager)
            }
        }

        var additions = managers.flatMap(\.binDirectories).map(\.path)
        additions += wellKnownDirectories.map(expandTilde)
        additions += Self.systemPath
        for directory in additions where !searchPath.contains(directory) && isDirectory(directory) {
            searchPath.append(directory)
            notes.append(.pathAdded(directory))
        }

        return ResolvedEnvironment(
            source: source,
            variables: variables,
            searchPath: searchPath,
            versionManagers: managers,
            notes: notes
        )
    }

    private enum ShellOutcome {
        case success([String: String])
        case failure(ResolvedEnvironment.FallbackReason)
    }

    private func readLoginShellEnvironment() async -> ShellOutcome {
        let command = Command(
            shell,
            ["-l", "-i", "-c", Self.loginShellScript],
            environment: baseEnvironment,
            workingDirectory: homeDirectory,
            timeout: loginShellTimeout
        )
        do {
            let result = try await runner.run(command)
            guard result.succeeded else {
                return .failure(.exitCode(result.exitCode))
            }
            guard let variables = Self.parseEnvironment(result.stdout) else {
                return .failure(.missingMarkers)
            }
            guard variables["PATH"] != nil else {
                return .failure(.missingPath)
            }
            return .success(variables)
        } catch {
            return .failure(.error(String(describing: error)))
        }
    }

    /// Liest `KEY=VALUE`-Einträge (NUL-getrennt) zwischen den Markern. Ausgaben von
    /// `.zshrc` & Co. davor oder danach werden ignoriert.
    static func parseEnvironment(_ output: String) -> [String: String]? {
        let fields = output.split(separator: "\0", omittingEmptySubsequences: false)
        guard let begin = fields.lastIndex(where: { $0.hasSuffix(beginMarker) }),
              let end = fields[begin...].firstIndex(where: { $0 == endMarker }) else {
            return nil
        }
        var variables: [String: String] = [:]
        for entry in fields[fields.index(after: begin)..<end] {
            guard let separator = entry.firstIndex(of: "="), separator != entry.startIndex else { continue }
            variables[String(entry[..<separator])] = String(entry[entry.index(after: separator)...])
        }
        return variables
    }

    // MARK: - Versionsmanager

    private func detect(
        _ kind: VersionManager.Kind,
        variables: [String: String],
        searchPath: [String],
        notes: inout [ResolvedEnvironment.Note]
    ) async -> VersionManager? {
        let home = homeDirectory.path
        func root(_ variable: String, _ defaults: [String]) -> URL? {
            let candidates = [variables[variable]].compactMap { $0 } + defaults.map { "\(home)/\($0)" }
            return candidates.first(where: isDirectory).map { URL(fileURLWithPath: $0) }
        }

        let manager: VersionManager?
        switch kind {
        case .nvm:
            guard let root = root("NVM_DIR", [".nvm"]),
                  FileManager.default.fileExists(atPath: root.appendingPathComponent("nvm.sh").path) else {
                return nil
            }
            var bins: [URL] = []
            if let node = await nvmDefaultNode(root: root, variables: variables) {
                bins.append(node.deletingLastPathComponent())
                notes.append(.nvmDefaultNode(path: node.path))
            } else {
                notes.append(.nvmDefaultUnresolved)
            }
            manager = VersionManager(kind: .nvm, root: root, binDirectories: bins)
        case .fnm:
            guard let root = root("FNM_DIR", [".local/share/fnm", "Library/Application Support/fnm", ".fnm"]) else {
                return nil
            }
            let bins = [root.appendingPathComponent("aliases/default/bin")].filter { isDirectory($0.path) }
            manager = VersionManager(kind: .fnm, root: root, binDirectories: bins)
        case .volta:
            guard let root = root("VOLTA_HOME", [".volta"]) else { return nil }
            let bins = [root.appendingPathComponent("bin")].filter { isDirectory($0.path) }
            manager = VersionManager(kind: .volta, root: root, binDirectories: bins)
        case .asdf:
            guard let root = root("ASDF_DATA_DIR", [".asdf"]) else { return nil }
            let bins = [root.appendingPathComponent("shims")].filter { isDirectory($0.path) }
            manager = VersionManager(kind: .asdf, root: root, binDirectories: bins)
        case .pyenv:
            guard let root = root("PYENV_ROOT", [".pyenv"]) else { return nil }
            let bins = [root.appendingPathComponent("shims"), root.appendingPathComponent("bin")]
                .filter { isDirectory($0.path) }
            manager = VersionManager(kind: .pyenv, root: root, binDirectories: bins)
        case .rbenv:
            guard let root = root("RBENV_ROOT", [".rbenv"]) else { return nil }
            let bins = [root.appendingPathComponent("shims"), root.appendingPathComponent("bin")]
                .filter { isDirectory($0.path) }
            manager = VersionManager(kind: .rbenv, root: root, binDirectories: bins)
        case .sdkman:
            guard let root = root("SDKMAN_DIR", [".sdkman"]) else { return nil }
            let candidates = root.appendingPathComponent("candidates")
            let names = (try? FileManager.default.contentsOfDirectory(atPath: candidates.path)) ?? []
            let bins = names.sorted()
                .map { candidates.appendingPathComponent($0).appendingPathComponent("current/bin") }
                .filter { isDirectory($0.path) }
            manager = VersionManager(kind: .sdkman, root: root, binDirectories: bins)
        }
        if let manager {
            notes.append(.managerDetected(manager.kind, root: manager.root.path))
        }
        return manager
    }

    private func nvmDefaultNode(root: URL, variables: [String: String]) async -> URL? {
        var environment = variables
        environment["PATH"] = Self.systemPath.joined(separator: ":")
        environment["NVM_DIR"] = root.path
        let command = Command(
            shell,
            ["-f", "-c", Self.nvmDefaultScript, "updatyme-nvm", root.path],
            environment: environment,
            workingDirectory: homeDirectory,
            timeout: .seconds(10)
        )
        guard let result = try? await runner.run(command), result.succeeded else { return nil }
        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n").last.map(String.init) ?? ""
        guard path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    // MARK: - Hilfsfunktionen

    static func splitPath(_ path: String?) -> [String] {
        var seen = Set<String>()
        return (path ?? "")
            .split(separator: ":")
            .map(String.init)
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private func expandTilde(_ path: String) -> String {
        path.hasPrefix("~/") ? homeDirectory.path + path.dropFirst() : path
    }

    private nonisolated func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
