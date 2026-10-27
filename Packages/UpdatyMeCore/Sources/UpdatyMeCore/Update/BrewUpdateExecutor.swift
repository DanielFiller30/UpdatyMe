import Foundation

/// Aktualisiert Brew-Formulae (`brew upgrade <name>`) und -Casks (`brew upgrade --cask <name>`) und
/// übernimmt manuell installierte Apps in Homebrew (`brew install --cask --adopt <token>`).
///
/// - `HOMEBREW_NO_AUTO_UPDATE=1`: kein `brew update` vorab; installiert wird die angezeigte Version.
/// - Selbst-aktualisierende Casks brauchen `--greedy-auto-updates`, sonst überspringt Brew sie.
/// - Brew aktualisiert ggf. abhängige Pakete mit (Brew-Standardverhalten, nicht unterdrückt).
/// - Kein sudo: Fordert Brew ein Passwort an, schlägt der Aufruf fehl (stdin ist leer) und wird als
///   `UpdateError.requiresAdministrator` gemeldet.
public struct BrewUpdateExecutor: UpdateExecutor {
    private let runner: any CommandRunning
    private let brew: BrewEcosystem
    private let environment: ResolvedEnvironment
    private let timeout: Duration

    /// - Parameter runner: Ohne Cache (`CommandRunner`), sonst würde ein Update „aus dem Cache“ kommen.
    public init(
        runner: any CommandRunning,
        environment: ResolvedEnvironment,
        knownPrefixes: [String] = BrewEcosystem.knownPrefixes,
        timeout: Duration = .seconds(30 * 60)
    ) {
        self.runner = runner
        self.environment = environment
        self.timeout = timeout
        brew = BrewEcosystem(runner: runner, environment: environment, knownPrefixes: knownPrefixes)
    }

    public static func arguments(for item: InstalledItem) -> [String]? {
        if let token = item.metadata[InstalledItem.MetadataKey.adoptCask] {
            return ["install", "--cask", "--adopt", token]
        }
        guard item.ecosystem == .brew else { return nil }
        let name = item.metadata[InstalledItem.MetadataKey.brewFullName] ?? item.name
        guard item.source == .cask else {
            return ["upgrade", name]
        }
        var arguments = ["upgrade", "--cask"]
        if item.metadata["autoUpdates"] == "true" {
            arguments.append("--greedy-auto-updates")
        }
        return arguments + [name]
    }

    public func update(_ item: InstalledItem) -> AsyncThrowingStream<UpdateEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let arguments = Self.arguments(for: item) else {
                        throw UpdateError.unsupported(item.name)
                    }
                    guard let executable = brew.locateBrew() else {
                        throw InventoryError.toolNotFound("Homebrew")
                    }
                    var processEnvironment = environment.processEnvironment
                    processEnvironment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
                    processEnvironment["HOMEBREW_NO_ENV_HINTS"] = "1"
                    let command = Command(executable: executable, arguments: arguments,
                                          environment: processEnvironment, timeout: timeout)

                    continuation.yield(.progress(nil))
                    var finished = false
                    for try await event in await runner.stream(command) {
                        switch event {
                        case .stdoutLine(let line):
                            continuation.yield(.output(line: line, isError: false))
                        case .stderrLine(let line):
                            continuation.yield(.output(line: line, isError: true))
                        case .completed(let result):
                            guard result.succeeded else {
                                throw Self.classifyFailure(result)
                            }
                            finished = true
                            continuation.yield(.completed(newVersion: nil, restartRequired: false))
                        }
                    }
                    guard finished else { throw UpdateError.incomplete }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Wählt die aussagekräftigste Zeile: Brews `Error:`-Zeile, sonst die letzte nicht leere Ausgabe.
    static func classifyFailure(_ result: CommandResult) -> UpdateError {
        let combined = result.stderr + "\n" + result.stdout
        let lines = combined.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let needsAdmin = lines.contains { line in
            line.contains("sudo:") || line.localizedCaseInsensitiveContains("a terminal is required")
                || line.localizedCaseInsensitiveContains("a password is required")
                || line.localizedCaseInsensitiveContains("askpass")
        }
        let reason = lines.first { $0.hasPrefix("Error:") }.map { String($0.dropFirst("Error:".count)).trimmingCharacters(in: .whitespaces) }
            ?? lines.last ?? ""
        if needsAdmin {
            return .requiresAdministrator(detail: reason)
        }
        return .failed(exitCode: result.exitCode, reason: reason)
    }
}
