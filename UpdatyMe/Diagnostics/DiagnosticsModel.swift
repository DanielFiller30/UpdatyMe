import Foundation
import Observation
import OSLog
import UpdatyMeCore

/// Diagnose: zeigt, welche Umgebung die GUI-App auflöst und wo sie welche Tools findet.
@Observable
final class DiagnosticsModel {
    struct Tool: Identifiable {
        let name: String
        let path: URL?
        let version: String?

        var id: String { name }
    }

    static let toolNames = ["brew", "node", "npm", "pnpm", "yarn", "git", "python3"]

    /// Ein Speicherort mit Größe (für Caches) und ob er existiert.
    struct Location: Identifiable {
        enum Kind { case store, httpCache, commandCache, toolsConfiguration, homebrew }
        let kind: Kind
        let url: URL?
        let size: Int64?
        var id: Kind { kind }
        var exists: Bool { url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false }
    }

    private(set) var environment: ResolvedEnvironment?
    private(set) var locations: [Location] = []
    private(set) var tools: [Tool] = []
    private(set) var isLoading = false

    /// PATH des App-Prozesses, wie launchd ihn vergibt – zum Vergleich mit dem aufgelösten PATH.
    let processPath = ProcessInfo.processInfo.environment["PATH"] ?? ""

    private let runner = CommandRunner()
    private let resolver: EnvironmentResolver
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "UpdatyMe", category: "Diagnostics")

    init() {
        resolver = EnvironmentResolver(runner: runner)
    }

    func load(forceRefresh: Bool = false) async {
        isLoading = true
        defer { isLoading = false }

        let environment = forceRefresh ? await resolver.refresh() : await resolver.resolve()
        var tools: [Tool] = []
        for name in Self.toolNames {
            tools.append(Tool(name: name, path: environment.executable(named: name), version: await version(of: name, in: environment)))
        }
        self.environment = environment
        self.tools = tools
        updateLocations(brew: BrewEcosystem(runner: runner, environment: environment).locateBrew())
        log(environment, tools)
    }

    // MARK: - Speicherorte und Caches

    private static var bundleIdentifier: String { Bundle.main.bundleIdentifier ?? "de.df.UpdatyMe" }

    static var httpCacheURL: URL? { try? HTTPDiskCache.defaultDirectory(bundleIdentifier: bundleIdentifier) }
    static var commandCacheURL: URL? { try? CachingCommandRunner.defaultDirectory(bundleIdentifier: bundleIdentifier) }

    private func updateLocations(brew: URL?) {
        let bundleIdentifier = Self.bundleIdentifier
        locations = [
            Location(kind: .store, url: try? InventoryStore.defaultURL(bundleIdentifier: bundleIdentifier), size: nil),
            Location(kind: .httpCache, url: Self.httpCacheURL, size: Self.httpCacheURL.map(Self.directorySize)),
            Location(kind: .commandCache, url: Self.commandCacheURL, size: Self.commandCacheURL.map(Self.directorySize)),
            Location(kind: .toolsConfiguration, url: try? ToolConfiguration.defaultURL(bundleIdentifier: bundleIdentifier), size: nil),
            Location(kind: .homebrew, url: brew, size: nil),
        ]
    }

    /// Leert HTTP- und Befehls-Cache. Inventar, Favoriten, Fixierungen und Verlauf (Store) bleiben.
    /// Der nächste Refresh fragt alle Quellen neu ab.
    func clearCaches() {
        for url in [Self.httpCacheURL, Self.commandCacheURL].compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: url)
        }
        updateLocations(brew: locations.first { $0.kind == .homebrew }?.url)
    }

    static func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    private func version(of name: String, in environment: ResolvedEnvironment) async -> String? {
        guard let command = environment.command(name, ["--version"], timeout: .seconds(10)),
              let result = try? await runner.run(command), result.succeeded else {
            return nil
        }
        return result.stdout.split(separator: "\n").first.map(String.init)
    }

    /// Loggt nur PATH und Tool-Pfade – nie die vollständige Umgebung (kann Secrets enthalten).
    private func log(_ environment: ResolvedEnvironment, _ tools: [Tool]) {
        logger.notice("Process PATH: \(self.processPath, privacy: .public)")
        logger.notice("Source: \(String(describing: environment.source), privacy: .public)")
        logger.notice("Resolved PATH: \(environment.searchPath.joined(separator: ":"), privacy: .public)")
        for tool in tools {
            logger.notice("""
                Tool \(tool.name, privacy: .public): \(tool.path?.path ?? "not found", privacy: .public) \
                \(tool.version ?? "", privacy: .public)
                """)
        }
    }
}
