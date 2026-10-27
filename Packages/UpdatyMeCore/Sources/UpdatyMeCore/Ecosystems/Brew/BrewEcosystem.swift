import Foundation

/// Erfasst installierte Homebrew-Formulae und -Casks über `brew info --json=v2 --installed`.
public struct BrewEcosystem: InventoryProvider {
    public static let id: EcosystemID = .brew
    public static let knownPrefixes = ["/opt/homebrew", "/usr/local"]
    /// Metadaten-Schlüssel: Von Brew notierte Version, wenn `installedVersion` die echte App-Version ist.
    public static let brewRecordedVersionKey = "brewRecordedVersion"

    /// Metadaten-Schlüssel: Muster, das aus Brews Cask-Version die vergleichbare Version zieht.
    public static let latestVersionPatternKey = "brewLatestVersionPattern"

    /// Selbst-aktualisierende Casks ohne App, deren echte Version das Tool selbst liefert.
    struct VersionCommand: Sendable {
        var token: String
        /// Relativ zum Brew-Präfix.
        var executable: String
        var arguments: [String]
        var pattern: String
        /// Zieht die vergleichbare Version aus Brews Cask-Version (z. B. `py314_26.9.4-0` → `26.9.4`).
        var latestPattern: String?
    }

    static let versionCommands: [VersionCommand] = [
        VersionCommand(token: "gcloud-cli", executable: "share/google-cloud-sdk/bin/gcloud", arguments: ["version"],
                       pattern: #"Google Cloud SDK (\S+)"#),
        VersionCommand(token: "miniconda", executable: "Caskroom/miniconda/base/bin/conda", arguments: ["--version"],
                       pattern: #"conda (\S+)"#, latestPattern: #"_(\d+(?:\.\d+)+)"#),
    ]

    /// Liest `CFBundleShortVersionString` (sonst `CFBundleVersion`) einer App; `nil`, wenn nicht lesbar.
    public typealias AppVersionReader = @Sendable (_ appPath: String) -> String?

    private let runner: any CommandRunning
    private let environment: ResolvedEnvironment
    private let knownPrefixes: [String]
    private let appVersion: AppVersionReader

    public init(
        runner: any CommandRunning,
        environment: ResolvedEnvironment,
        knownPrefixes: [String] = BrewEcosystem.knownPrefixes,
        appVersion: @escaping AppVersionReader = BrewEcosystem.bundleVersion(atPath:)
    ) {
        self.runner = runner
        self.environment = environment
        self.knownPrefixes = knownPrefixes
        self.appVersion = appVersion
    }

    public static func bundleVersion(atPath path: String) -> String? {
        let url = URL(fileURLWithPath: path).appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return nil
        }
        let version = (plist["CFBundleShortVersionString"] as? String) ?? (plist["CFBundleVersion"] as? String)
        return version.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
    }

    /// `brew` aus dem aufgelösten PATH, sonst aus den bekannten Präfixen.
    public func locateBrew() -> URL? {
        if let brew = environment.executable(named: "brew") {
            return brew
        }
        return knownPrefixes
            .map { URL(fileURLWithPath: $0).appendingPathComponent("bin/brew") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    public func scan() async throws -> [InstalledItem] {
        guard let brew = locateBrew() else {
            throw InventoryError.toolNotFound("Homebrew")
        }
        // `brew shellenv` setzt HOMEBREW_PREFIX; sonst liegt brew in <prefix>/bin/brew. Symlinks werden
        // bewusst nicht aufgelöst (/usr/local/bin/brew zeigt nach /usr/local/Homebrew, der Cellar liegt in /usr/local).
        let prefix = environment.variables["HOMEBREW_PREFIX"]
            ?? brew.deletingLastPathComponent().deletingLastPathComponent().path
        let command = Command(
            executable: brew,
            arguments: ["info", "--json=v2", "--installed"],
            environment: environment.processEnvironment,
            timeout: .seconds(120)
        )
        let output = try await runner.runChecked(command).stdout
        var items = try Self.parseInstalled(Data(output.utf8), prefix: prefix).map(usingRealAppVersion)
        for index in items.indices {
            items[index] = await usingToolVersion(items[index], prefix: prefix)
        }
        return items
    }

    /// Für bekannte selbst-aktualisierende Casks ohne App (gcloud, miniconda) die echte Version über das
    /// Tool selbst lesen; Brews Wert bleibt in den Metadaten.
    func usingToolVersion(_ item: InstalledItem, prefix: String) async -> InstalledItem {
        guard item.source == .cask, item.installPath == nil,
              let spec = Self.versionCommands.first(where: { $0.token == item.metadata[InstalledItem.MetadataKey.brewFullName] }) else {
            return item
        }
        let executable = "\(prefix)/\(spec.executable)"
        guard FileManager.default.isExecutableFile(atPath: executable),
              let output = await DevTools.versionOutput(runner, executable: executable, arguments: spec.arguments, environment: environment),
              let version = DevTools.firstMatch(spec.pattern, in: output) else {
            return item
        }
        var item = item
        item.metadata[Self.brewRecordedVersionKey] = item.installedVersion
        item.metadata[Self.latestVersionPatternKey] = spec.latestPattern
        item.installedVersion = version
        return item
    }

    /// Selbst-aktualisierende Casks (`auto_updates`) aktualisieren die App ohne Brew; Brews notierte
    /// Version ist dann veraltet. Lesbare App-Version ersetzt sie, Brews Wert bleibt in den Metadaten.
    func usingRealAppVersion(_ item: InstalledItem) -> InstalledItem {
        guard item.source == .cask, item.metadata["autoUpdates"] == "true",
              let path = item.installPath, let version = appVersion(path) else {
            return item
        }
        var item = item
        item.metadata[Self.brewRecordedVersionKey] = item.installedVersion
        item.installedVersion = version
        return item
    }

    // MARK: - Parser

    static func parseInstalled(_ data: Data, prefix: String) throws -> [InstalledItem] {
        let info: BrewInfo
        do {
            info = try JSONDecoder().decode(BrewInfo.self, from: data)
        } catch {
            throw InventoryError.unexpectedOutput(source: "brew info", detail: String(describing: error))
        }
        return info.formulae.compactMap { formulaItem($0, prefix: prefix) } + info.casks.map(caskItem)
    }

    static func formulaItem(_ formula: BrewInfo.Formula, prefix: String) -> InstalledItem? {
        let versions = formula.installed.map(\.version)
        guard let version = installedVersion(linkedKeg: formula.linkedKeg, installed: versions) else { return nil }
        let installedOnRequest = formula.installed.first { $0.version == version }?.installedOnRequest ?? false

        var metadata: [String: String] = [
            InstalledItem.MetadataKey.brewFullName: formula.fullName,
            InstalledItem.MetadataKey.brewTap: formula.tap ?? "",
            InstalledItem.MetadataKey.brewPinned: String(formula.pinned),
            "installedOnRequest": String(installedOnRequest),
            "kegOnly": String(formula.kegOnly),
            "installedVersions": versions.joined(separator: ","),
        ]
        metadata["homepage"] = formula.homepage
        metadata["description"] = formula.desc

        return InstalledItem(
            id: InstalledItem.makeID(ecosystem: id, identifier: "formula/\(formula.fullName)"),
            name: formula.name,
            kind: installedOnRequest ? .cli : .package,
            ecosystem: id,
            installedVersion: version,
            installPath: "\(prefix)/Cellar/\(formula.name)/\(version)",
            source: .brew,
            status: formula.pinned ? .pinned : .unknown,
            updateCapability: .auto,
            metadata: metadata
        )
    }

    static func caskItem(_ cask: BrewInfo.Cask) -> InstalledItem {
        let appPaths = appPaths(from: cask.artifacts)
        var metadata: [String: String] = [
            InstalledItem.MetadataKey.brewFullName: cask.fullToken,
            InstalledItem.MetadataKey.brewTap: cask.tap ?? "",
            InstalledItem.MetadataKey.brewPinned: String(cask.pinned ?? false),
            "autoUpdates": String(cask.autoUpdates ?? false),
        ]
        metadata[InstalledItem.MetadataKey.caskAppPaths] = appPaths.isEmpty ? nil : appPaths.joined(separator: "\n")
        metadata["homepage"] = cask.homepage
        metadata["description"] = cask.desc

        return InstalledItem(
            id: InstalledItem.makeID(ecosystem: id, identifier: "cask/\(cask.fullToken)"),
            name: cask.name.first ?? cask.token,
            kind: appPaths.isEmpty ? .cli : .app,
            ecosystem: id,
            installedVersion: cask.installed ?? "",
            installPath: appPaths.first,
            source: .cask,
            status: cask.pinned == true ? .pinned : .unknown,
            updateCapability: .auto,
            metadata: metadata
        )
    }

    /// Verlinkte Version, sonst die höchste installierte.
    static func installedVersion(linkedKeg: String?, installed: [String]) -> String? {
        if let linkedKeg, installed.contains(linkedKeg) {
            return linkedKeg
        }
        return installed.max { lhs, rhs in
            VersionComparator.compare(lhs, rhs) == .orderedAscending
        }
    }

    /// App-Pfade aus den Cask-Artefakten. Zwei Formate:
    /// - aktuell: `{"app": ["Foo.app"], "target": "/Applications/Foo.app"}`
    /// - älter: `{"app": ["Foo.app", {"target": "Bar.app"}]}`
    /// Relative Ziele liegen in `/Applications` (Brew-Standard-`appdir`).
    static func appPaths(from artifacts: [BrewInfo.Artifact]) -> [String] {
        var paths: [String] = []
        for artifact in artifacts {
            guard let entries = artifact.app else { continue }
            var names: [String] = []
            for entry in entries {
                switch entry {
                case .name(let name):
                    names.append(name)
                case .options(let target):
                    if !names.isEmpty, !target.isEmpty { names[names.count - 1] = target }
                }
            }
            if let target = artifact.target, names.count == 1 {
                names = [target]
            }
            paths += names.map { $0.hasPrefix("/") ? $0 : "/Applications/\($0)" }
        }
        return paths
    }
}

/// Ausschnitt aus `brew info --json=v2`; nur die genutzten Felder.
struct BrewInfo: Decodable {
    struct Formula: Decodable {
        struct Installed: Decodable {
            var version: String
            var installedOnRequest: Bool?

            enum CodingKeys: String, CodingKey {
                case version
                case installedOnRequest = "installed_on_request"
            }
        }

        var name: String
        var fullName: String
        var tap: String?
        var installed: [Installed]
        var linkedKeg: String?
        var pinned: Bool
        var kegOnly: Bool
        var desc: String?
        var homepage: String?

        enum CodingKeys: String, CodingKey {
            case name, tap, installed, pinned, desc, homepage
            case fullName = "full_name"
            case linkedKeg = "linked_keg"
            case kegOnly = "keg_only"
        }
    }

    struct Cask: Decodable {
        var token: String
        var fullToken: String
        var name: [String]
        var tap: String?
        var installed: String?
        var autoUpdates: Bool?
        var pinned: Bool?
        var artifacts: [Artifact]
        var desc: String?
        var homepage: String?

        enum CodingKeys: String, CodingKey {
            case token, name, tap, installed, pinned, artifacts, desc, homepage
            case fullToken = "full_token"
            case autoUpdates = "auto_updates"
        }
    }

    /// Ein Artefakt ist ein Objekt mit genau einer Art (`app`, `binary`, `zap`, …). Nur `app` wird gelesen.
    struct Artifact: Decodable {
        enum AppEntry: Decodable {
            case name(String)
            case options(target: String)

            init(from decoder: any Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let name = try? container.decode(String.self) {
                    self = .name(name)
                } else {
                    self = .options(target: (try? container.decode([String: String].self))?["target"] ?? "")
                }
            }
        }

        var app: [AppEntry]?
        var target: String?

        enum CodingKeys: String, CodingKey {
            case app, target
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            app = try? container.decodeIfPresent([AppEntry].self, forKey: .app)
            target = try? container.decodeIfPresent(String.self, forKey: .target)
        }
    }

    var formulae: [Formula]
    var casks: [Cask]
}
