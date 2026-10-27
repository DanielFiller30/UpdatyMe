import Foundation

/// Weitere Tools aus einer JSON-Konfiguration – ohne Codeänderung (Plan Abschnitt 4).
///
/// ```json
/// { "tools": [ {
///     "id": "gh", "name": "GitHub CLI",
///     "command": "gh", "arguments": ["--version"], "versionPattern": "gh version (\\S+)",
///     "latest": { "type": "github", "repository": "cli/cli", "tagPattern": "v(.+)" }
/// } ] }
/// ```
/// `latest.type`: `github` (`repository`, optional `tagPattern`), `npm` (`package`), `pypi` (`package`),
/// `url` (`url`, `pattern`). Ohne `latest` bleibt der Status „unbekannt“.
public struct ToolConfiguration: Sendable, Codable, Hashable {
    public struct Tool: Sendable, Codable, Hashable {
        public var id: String
        public var name: String
        /// Programmname (Suche im PATH) oder absoluter Pfad.
        public var command: String
        public var arguments: [String]
        /// Regulärer Ausdruck; erste Gruppe (sonst ganzer Treffer) ist die Version.
        public var versionPattern: String
        public var latest: LatestSource?

        public init(id: String, name: String, command: String, arguments: [String] = ["--version"],
                    versionPattern: String, latest: LatestSource? = nil) {
            self.id = id
            self.name = name
            self.command = command
            self.arguments = arguments
            self.versionPattern = versionPattern
            self.latest = latest
        }

        enum CodingKeys: String, CodingKey { case id, name, command, arguments, versionPattern, latest }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            name = try container.decodeIfPresent(String.self, forKey: .name) ?? id
            command = try container.decode(String.self, forKey: .command)
            arguments = try container.decodeIfPresent([String].self, forKey: .arguments) ?? ["--version"]
            versionPattern = try container.decode(String.self, forKey: .versionPattern)
            latest = try container.decodeIfPresent(LatestSource.self, forKey: .latest)
        }
    }

    public enum LatestSource: Sendable, Codable, Hashable {
        case github(repository: String, tagPattern: String?)
        case npm(package: String)
        case pypi(package: String)
        case url(URL, pattern: String)

        enum CodingKeys: String, CodingKey { case type, repository, tagPattern, package, url, pattern }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(String.self, forKey: .type) {
            case "github":
                self = .github(repository: try container.decode(String.self, forKey: .repository),
                               tagPattern: try container.decodeIfPresent(String.self, forKey: .tagPattern))
            case "npm": self = .npm(package: try container.decode(String.self, forKey: .package))
            case "pypi": self = .pypi(package: try container.decode(String.self, forKey: .package))
            case "url":
                self = .url(try container.decode(URL.self, forKey: .url), pattern: try container.decode(String.self, forKey: .pattern))
            case let other:
                throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown latest type '\(other)'")
            }
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .github(let repository, let tagPattern):
                try container.encode("github", forKey: .type)
                try container.encode(repository, forKey: .repository)
                try container.encodeIfPresent(tagPattern, forKey: .tagPattern)
            case .npm(let package):
                try container.encode("npm", forKey: .type)
                try container.encode(package, forKey: .package)
            case .pypi(let package):
                try container.encode("pypi", forKey: .type)
                try container.encode(package, forKey: .package)
            case .url(let url, let pattern):
                try container.encode("url", forKey: .type)
                try container.encode(url, forKey: .url)
                try container.encode(pattern, forKey: .pattern)
            }
        }
    }

    public var tools: [Tool]

    public init(tools: [Tool]) {
        self.tools = tools
    }

    /// `~/Library/Application Support/<bundleIdentifier>/tools.json`
    public static func defaultURL(bundleIdentifier: String) throws -> URL {
        try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("tools.json")
    }
}

/// Erfasst die konfigurierten Tools. Fehlende Datei → keine Einträge. Ungültiges JSON → Fehler der
/// Quelle (Banner). Ein einzelnes fehlerhaftes Tool (Programm fehlt, Muster passt nicht) erscheint mit
/// Status „unbekannt“ und dem Grund in `metadata["configError"]` (Code, siehe `ConfigError`) sowie
/// `metadata["configErrorDetail"]`, damit es nicht still verschwindet.
/// Von Brew verwaltete Programme (Cellar, Caskroom) werden übersprungen (sie sind schon Brew-Einträge).
public struct ConfiguredToolsEcosystem: InventoryProvider {
    public static let id: EcosystemID = .configuredTools
    public static let errorKey = "configError"
    public static let errorDetailKey = "configErrorDetail"

    /// Codes für `metadata["configError"]`; die App übersetzt sie.
    public enum ConfigError: String, Sendable {
        case commandNotFound, invalidPattern, versionNotFound
    }
    public static let latestKey = "configLatest"

    private let configuration: URL
    private let environment: ResolvedEnvironment
    private let runner: any CommandRunning

    public init(configuration: URL, environment: ResolvedEnvironment, runner: any CommandRunning) {
        self.configuration = configuration
        self.environment = environment
        self.runner = runner
    }

    public func scan() async throws -> [InstalledItem] {
        guard FileManager.default.fileExists(atPath: configuration.path) else { return [] }
        let tools: [ToolConfiguration.Tool]
        do {
            tools = try JSONDecoder().decode(ToolConfiguration.self, from: Data(contentsOf: configuration)).tools
        } catch {
            throw InventoryError.unexpectedOutput(source: configuration.lastPathComponent, detail: String(describing: error))
        }

        var items: [InstalledItem] = []
        for tool in tools {
            var metadata: [String: String] = [:]
            metadata[Self.latestKey] = (try? JSONEncoder().encode(tool.latest)).flatMap { String(data: $0, encoding: .utf8) }
            let executable = tool.command.hasPrefix("/") ? (DevTools.isExecutable(tool.command) ? tool.command : nil)
                : environment.executable(named: tool.command)?.path
            guard let executable else {
                metadata[Self.errorKey] = ConfigError.commandNotFound.rawValue
                metadata[Self.errorDetailKey] = tool.command
                items.append(item(tool, version: "", path: nil, metadata: metadata))
                continue
            }
            // Von Brew verwaltet (Formula oder Cask) → bereits ein Brew-Eintrag.
            let real = DevTools.realPath(executable)
            if real.contains("/Cellar/") || real.contains("/Caskroom/") { continue }
            guard (try? NSRegularExpression(pattern: tool.versionPattern)) != nil else {
                metadata[Self.errorKey] = ConfigError.invalidPattern.rawValue
                metadata[Self.errorDetailKey] = tool.versionPattern
                items.append(item(tool, version: "", path: executable, metadata: metadata))
                continue
            }
            let output = await DevTools.versionOutput(runner, executable: executable, arguments: tool.arguments, environment: environment)
            guard let output, let version = DevTools.firstMatch(tool.versionPattern, in: output) else {
                metadata[Self.errorKey] = ConfigError.versionNotFound.rawValue
                metadata[Self.errorDetailKey] = ([tool.command] + tool.arguments).joined(separator: " ")
                items.append(item(tool, version: "", path: executable, metadata: metadata))
                continue
            }
            items.append(item(tool, version: version, path: executable, metadata: metadata))
        }
        return items
    }

    private func item(_ tool: ToolConfiguration.Tool, version: String, path: String?, metadata: [String: String]) -> InstalledItem {
        DevTools.runtime(Self.id, identifier: tool.id, name: tool.name, version: version, path: path, source: .config,
                         kind: .cli, metadata: metadata)
    }
}
