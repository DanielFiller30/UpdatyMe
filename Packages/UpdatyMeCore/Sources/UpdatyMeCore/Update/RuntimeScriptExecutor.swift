import Foundation

extension InstalledItem.MetadataKey {
    /// `RuntimeGuide.Action` eines Auftrags für den `RuntimeScriptExecutor`, gesetzt nur für diesen Auftrag.
    public static let runtimeAction = "runtimeAction"
    /// Gewünschte Version und „als Standard setzen“ für `RuntimeGuide.Action.install`.
    public static let runtimeVersion = "runtimeVersion"
    public static let runtimeSetDefault = "runtimeSetDefault"
}

extension InstalledItem {
    /// Auftrag „Update ausführen“ bzw. „Deinstallieren“ für eine Runtime in der Warteschlange.
    public func runtimeJob(_ action: RuntimeGuide.Action) -> InstalledItem {
        var job = self
        job.metadata[MetadataKey.runtimeAction] = action.rawValue
        return job
    }

    /// Auftrag „Version installieren“ mit frei eingegebener Version.
    public func runtimeInstallJob(version: String, setDefault: Bool) -> InstalledItem {
        var job = runtimeJob(.install)
        job.metadata[MetadataKey.runtimeVersion] = version
        job.metadata[MetadataKey.runtimeSetDefault] = String(setDefault)
        return job
    }
}

/// Führt die Befehle des `RuntimeGuide` einer Runtime aus (Update, Standard setzen, Deinstallation).
/// Die Bestätigung durch den Nutzer erfolgt vorher in der UI.
///
/// Programm und Argumente werden einzeln übergeben. Die `zsh`-Hülle ist ein konstantes Skript
/// (Werte nur als Positionsparameter), damit auch Shell-Funktionen wie `nvm` und `sdk` erreichbar sind.
/// Argumente mit ungewöhnlichen Zeichen werden abgelehnt.
public struct RuntimeScriptExecutor: UpdateExecutor {
    static let shell = "/bin/zsh"
    /// `$1` ist der Name des Managers; nvm und sdkman sind Funktionen und werden vorher geladen.
    static let wrapperScript = """
    case "$1" in
      nvm) . "${NVM_DIR:-$HOME/.nvm}/nvm.sh" --no-use || exit 97 ;;
      sdk) . "${SDKMAN_DIR:-$HOME/.sdkman}/bin/sdkman-init.sh" || exit 97 ;;
    esac
    "$@"
    """

    private let runner: any CommandRunning
    private let environment: ResolvedEnvironment
    private let timeout: Duration

    public init(runner: any CommandRunning, environment: ResolvedEnvironment, timeout: Duration = .seconds(30 * 60)) {
        self.runner = runner
        self.environment = environment
        self.timeout = timeout
    }

    public static func steps(for item: InstalledItem) -> [RuntimeGuide.Step] {
        guard let action = item.metadata[InstalledItem.MetadataKey.runtimeAction].flatMap(RuntimeGuide.Action.init(rawValue:)) else { return [] }
        if action == .install {
            guard let version = item.metadata[InstalledItem.MetadataKey.runtimeVersion] else { return [] }
            return RuntimeGuide.installSteps(for: item, version: version,
                                             setDefault: item.metadata[InstalledItem.MetadataKey.runtimeSetDefault] == "true")
        }
        return RuntimeGuide.guide(for: item)?.steps(for: action) ?? []
    }

    static func isSafe(_ argument: String) -> Bool {
        !argument.isEmpty && argument.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar) || "._+-=:@/".unicodeScalars.contains(scalar)
        }
    }

    public func update(_ item: InstalledItem) -> AsyncThrowingStream<UpdateEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let steps = Self.steps(for: item)
                    guard !steps.isEmpty else { throw UpdateError.unsupported(item.name) }
                    var processEnvironment = environment.processEnvironment
                    processEnvironment["sdkman_auto_answer"] = "true"
                    processEnvironment["NONINTERACTIVE"] = "1"

                    continuation.yield(.progress(nil))
                    for step in steps {
                        guard let arguments = step.arguments, arguments.allSatisfy(Self.isSafe) else {
                            throw UpdateError.unsupported(item.name)
                        }
                        continuation.yield(.output(line: "$ \(step.command)", isError: false))
                        let command = Command(Self.shell, ["-f", "-c", Self.wrapperScript, "updatyme-runtime"] + arguments,
                                              environment: processEnvironment, timeout: timeout)
                        var finished = false
                        for try await event in await runner.stream(command) {
                            switch event {
                            case .stdoutLine(let line): continuation.yield(.output(line: line, isError: false))
                            case .stderrLine(let line): continuation.yield(.output(line: line, isError: true))
                            case .completed(let result):
                                guard result.succeeded else { throw Self.classifyFailure(result, step: step) }
                                finished = true
                            }
                        }
                        guard finished else { throw UpdateError.incomplete }
                    }
                    continuation.yield(.completed(newVersion: nil, restartRequired: false))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func classifyFailure(_ result: CommandResult, step: RuntimeGuide.Step) -> UpdateError {
        let lines = (result.stderr + "\n" + result.stdout).split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let needsAdmin = lines.contains { $0.contains("sudo:") || $0.localizedCaseInsensitiveContains("a password is required") }
        let reason = lines.last ?? step.command
        return needsAdmin ? .requiresAdministrator(detail: reason) : .failed(exitCode: result.exitCode, reason: reason)
    }
}
