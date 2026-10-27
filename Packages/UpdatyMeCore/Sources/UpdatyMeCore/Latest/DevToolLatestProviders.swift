import Foundation

extension CachingHTTPClient {
    func json<T: Decodable>(_ type: T.Type, from url: URL, source: String) async throws -> (T, Date) {
        let response = try await get(url, headers: ["Accept": "application/json"])
        do {
            return (try JSONDecoder().decode(T.self, from: response.body), response.validatedAt)
        } catch {
            throw InventoryError.unexpectedOutput(source: source, detail: String(describing: error))
        }
    }
}

/// Ein Eintrag von endoflife.date (`/api/<produkt>.json`). `eol`/`lts` sind Datum oder `false`.
struct EndOfLifeCycle: Decodable {
    var cycle: String
    var latest: String?
    var eol: Date?

    enum CodingKeys: String, CodingKey { case cycle, latest, eol }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let text = try? container.decode(String.self, forKey: .cycle) {
            cycle = text
        } else {
            cycle = String(try container.decode(Int.self, forKey: .cycle))
        }
        latest = try? container.decodeIfPresent(String.self, forKey: .latest)
        eol = (try? container.decodeIfPresent(String.self, forKey: .eol)).flatMap { $0.flatMap(Self.date) }
    }

    static func date(_ string: String) -> Date? {
        try? Date(string, strategy: Date.ISO8601FormatStyle().year().month().day())
    }
}

// MARK: - Node

/// Neueste Node-Version aus `nodejs.org/dist/index.json`, EOL aus endoflife.date.
///
/// - `current`: neueste Version insgesamt.
/// - `lts`: neueste Version der eigenen Linie, solange diese eine LTS-Linie ohne erreichtes EOL ist –
///   oder eine Current-Linie oberhalb der neuesten LTS, die noch unterstützt wird (sonst stünde dort eine
///   niedrigere „neueste“ Version). Andernfalls die neueste LTS-Version. Eine neuere LTS-Linie erscheint
///   als Hinweis (`newerReleaseLine`); gibt es keine, die neueste Current-Linie.
public struct NodeLatestProvider: LatestVersionProvider {
    public enum Channel: String, Sendable, CaseIterable, Codable {
        case lts, current
    }

    public static let indexURL = URL(string: "https://nodejs.org/dist/index.json")!
    public static let endOfLifeURL = URL(string: "https://endoflife.date/api/nodejs.json")!

    struct Release: Decodable {
        var version: String
        var isLTS: Bool

        enum CodingKeys: String, CodingKey { case version, lts }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decode(String.self, forKey: .version)
            isLTS = (try? container.decode(String.self, forKey: .lts)) != nil
        }

        var number: String { NodeEcosystem.normalize(version) }
        var major: String { String(number.split(separator: ".").first ?? "") }
    }

    private let http: CachingHTTPClient
    private let channel: Channel
    private let today: Date

    public init(http: CachingHTTPClient, channel: Channel, today: Date = Date()) {
        self.http = http
        self.channel = channel
        self.today = today
    }

    public func latest(for item: InstalledItem) async throws -> RemoteVersion? {
        let (releases, fetchedAt) = try await http.json([Release].self, from: Self.indexURL, source: "nodejs.org")
        // EOL ist eine Zusatzinformation; fehlt sie, bleibt die Versionsermittlung gültig.
        let cycles = (try? await http.json([EndOfLifeCycle].self, from: Self.endOfLifeURL, source: "endoflife.date"))?.0 ?? []
        return Self.remoteVersion(for: item, releases: releases, cycles: cycles, channel: channel, today: today, fetchedAt: fetchedAt)
    }

    static func remoteVersion(for item: InstalledItem, releases: [Release], cycles: [EndOfLifeCycle],
                              channel: Channel, today: Date, fetchedAt: Date) -> RemoteVersion? {
        let major = String(item.installedVersion.split(separator: ".").first ?? "")
        let eol = cycles.first { $0.cycle == major }?.eol
        func newest(_ candidates: [Release]) -> Release? {
            candidates.max { VersionComparator.compare($0.number, $1.number) == .orderedAscending }
        }

        let latest: Release?
        var newerLine: String?
        switch channel {
        case .current:
            latest = newest(releases)
        case .lts:
            let supported = eol.map { $0 > today } ?? true
            let lineIsLTS = releases.contains { $0.major == major && $0.isLTS } && supported
            let newestLTSMajor = newest(releases.filter(\.isLTS)).flatMap { Int($0.major) } ?? 0
            let aheadOfLTS = (Int(major) ?? 0) > newestLTSMajor && supported
            latest = lineIsLTS || aheadOfLTS ? newest(releases.filter { $0.major == major }) : newest(releases.filter(\.isLTS))
            if let own = Int(major) {
                // Neuere LTS-Linie, sonst die neueste Linie überhaupt (Current).
                let newestLTSLine = newest(releases.filter(\.isLTS)).flatMap { Int($0.major) }
                let newestLine = newest(releases).flatMap { Int($0.major) }
                if let other = newestLTSLine, other > own {
                    newerLine = String(other)
                } else if let other = newestLine, other > own {
                    newerLine = String(other)
                }
            }
        }
        guard let latest else { return nil }
        return RemoteVersion(itemID: item.id, version: latest.number, channel: channel == .lts ? .lts : .current,
                             source: "nodejs.org", releaseNotesURL: URL(string: "https://nodejs.org/en/blog/release/\(latest.version)"),
                             fetchedAt: fetchedAt, endOfLife: eol, newerReleaseLine: newerLine)
    }
}

// MARK: - Python

/// Neuester Patch derselben Python-Linie aus endoflife.date; neuere Linie als Hinweis.
/// Das Python der Xcode-/Command-Line-Tools (`source == .system`) liefert Apple; es lässt sich nicht selbst
/// aktualisieren. Version und EOL werden gezeigt, der Status bleibt aber „unbekannt“.
/// Für uv zählt nur, was uv herunterladen kann (`uv python list --only-downloads`): python-build-standalone
/// hinkt python.org hinterher, `uv python install <neueste python.org-Version>` schlüge sonst fehl.
public struct PythonLatestProvider: LatestVersionProvider {
    public static let endOfLifeURL = URL(string: "https://endoflife.date/api/python.json")!

    private let http: CachingHTTPClient
    private let runner: (any CommandRunning)?
    private let environment: ResolvedEnvironment?

    /// - Parameter runner: Sollte ein `CachingCommandRunner` sein; ohne Runner/Umgebung gilt für uv endoflife.date.
    public init(http: CachingHTTPClient, runner: (any CommandRunning)? = nil, environment: ResolvedEnvironment? = nil) {
        self.http = http
        self.runner = runner
        self.environment = environment
    }

    public func latest(for item: InstalledItem) async throws -> RemoteVersion? {
        let (cycles, fetchedAt) = try await http.json([EndOfLifeCycle].self, from: Self.endOfLifeURL, source: "endoflife.date")
        guard var remote = Self.remoteVersion(for: item, cycles: cycles, fetchedAt: fetchedAt) else { return nil }
        if item.source == .uv, let runner, let environment {
            guard let uv = environment.executable(named: "uv") else { throw InventoryError.toolNotFound("uv") }
            let command = Command(executable: uv, arguments: ["python", "list", "--output-format", "json", "--only-downloads"],
                                  environment: environment.processEnvironment, timeout: .seconds(60))
            let output = try await runner.runChecked(command).stdout
            guard let available = try Self.newestUvDownload(for: item.installedVersion, in: Data(output.utf8)) else { return nil }
            remote.version = available
            remote.source = "uv"
        }
        return remote
    }

    static func remoteVersion(for item: InstalledItem, cycles: [EndOfLifeCycle], fetchedAt: Date) -> RemoteVersion? {
        let parts = item.installedVersion.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        let line = "\(parts[0]).\(parts[1])"
        guard let cycle = cycles.first(where: { $0.cycle == line }), let latest = cycle.latest else { return nil }
        let newest = cycles.map(\.cycle).max { VersionComparator.compare($0, $1) == .orderedAscending }
        let newerLine = newest.flatMap { VersionComparator.compare($0, line) == .orderedDescending ? $0 : nil }
        return RemoteVersion(itemID: item.id, version: latest, source: "endoflife.date",
                             releaseNotesURL: URL(string: "https://www.python.org/downloads/release/python-\(latest.replacingOccurrences(of: ".", with: ""))/"),
                             fetchedAt: fetchedAt, assessment: item.source == .system ? .undeterminable : .compareVersions,
                             endOfLife: cycle.eol, newerReleaseLine: newerLine)
    }

    /// Neueste CPython-Version derselben Linie, die uv herunterladen kann (Standardvariante, ohne Vorabversionen,
    /// außer die installierte ist selbst eine). `nil`, wenn uv für die Linie nichts anbietet.
    static func newestUvDownload(for installed: String, in data: Data) throws -> String? {
        struct Download: Decodable {
            struct Parts: Decodable { var major: Int; var minor: Int }
            var version: String
            var versionParts: Parts
            var implementation: String
            var variant: String?
            enum CodingKeys: String, CodingKey { case version, versionParts = "version_parts", implementation, variant }
        }
        let downloads: [Download]
        do {
            downloads = try JSONDecoder().decode([Download].self, from: data)
        } catch {
            throw InventoryError.unexpectedOutput(source: "uv python list", detail: String(describing: error))
        }
        let parts = installed.split(separator: ".")
        guard parts.count >= 2, let major = Int(parts[0]), let minor = Int(parts[1]) else { return nil }
        let isPrerelease: (String) -> Bool = { $0.contains { $0.isLetter } }
        let allowPrerelease = isPrerelease(installed)
        return downloads
            .filter { $0.implementation == "cpython" && ($0.variant ?? "default") == "default"
                && $0.versionParts.major == major && $0.versionParts.minor == minor
                && (allowPrerelease || !isPrerelease($0.version)) }
            .map(\.version)
            .max { VersionComparator.compare($0, $1) == .orderedAscending }
    }
}

// MARK: - Java

/// Neueste GA-Version derselben Java-Hauptversion vom selben Hersteller (foojay Disco API);
/// neuere LTS-Hauptversion als Hinweis. Unbekannter Hersteller → `nil`.
public struct JavaLatestProvider: LatestVersionProvider {
    struct Packages: Decodable {
        struct Package: Decodable {
            var javaVersion: String
            enum CodingKeys: String, CodingKey { case javaVersion = "java_version" }
        }
        var result: [Package]
    }

    struct MajorVersions: Decodable {
        struct Major: Decodable {
            var majorVersion: Int
            var termOfSupport: String
            enum CodingKeys: String, CodingKey { case majorVersion = "major_version", termOfSupport = "term_of_support" }
        }
        var result: [Major]
    }

    private let http: CachingHTTPClient
    private let architecture: String

    public init(http: CachingHTTPClient, architecture: String = JavaLatestProvider.currentArchitecture) {
        self.http = http
        self.architecture = architecture
    }

    public static var currentArchitecture: String {
        #if arch(arm64)
        "aarch64"
        #else
        "x64"
        #endif
    }

    static func packagesURL(major: String, distribution: String, architecture: String) -> URL? {
        var components = URLComponents(string: "https://api.foojay.io/disco/v3.0/packages")
        components?.queryItems = [
            .init(name: "version", value: major), .init(name: "distribution", value: distribution),
            .init(name: "architecture", value: architecture), .init(name: "package_type", value: "jdk"),
            .init(name: "operating_system", value: "macos"), .init(name: "latest", value: "available"),
            .init(name: "release_status", value: "ga"),
        ]
        return components?.url
    }

    static let majorVersionsURL = URL(string: "https://api.foojay.io/disco/v3.0/major_versions?ea=false&ga=true&maintained=true")!

    public func latest(for item: InstalledItem) async throws -> RemoteVersion? {
        let major = String(item.installedVersion.split(separator: ".").first ?? "")
        guard let distribution = item.metadata["distribution"],
              let url = Self.packagesURL(major: major, distribution: distribution, architecture: architecture) else { return nil }
        let (packages, fetchedAt) = try await http.json(Packages.self, from: url, source: "foojay")
        guard let newest = packages.result.map(\.javaVersion).max(by: { VersionComparator.compare($0, $1) == .orderedAscending }) else {
            return nil
        }
        let majors = (try? await http.json(MajorVersions.self, from: Self.majorVersionsURL, source: "foojay"))?.0.result ?? []
        let newerLTS = majors.filter { $0.termOfSupport.uppercased() == "LTS" && $0.majorVersion > (Int(major) ?? .max) }
            .map(\.majorVersion).max()
        // „25.0.4.1+1“: Build-Zusatz ist für den Vergleich ohne Bedeutung.
        let version = String(newest.split(separator: "+").first ?? "")
        return RemoteVersion(itemID: item.id, version: version, source: "foojay (\(distribution))", fetchedAt: fetchedAt,
                             newerReleaseLine: newerLTS.map(String.init))
    }
}

// MARK: - Paket-Registries

/// Neueste Version aus npm, PyPI oder crates.io (Paketname aus `metadata.packageName`).
public struct RegistryLatestProvider: LatestVersionProvider {
    public enum Registry: String, Sendable {
        case npm, pypi, crates
    }

    private let http: CachingHTTPClient
    private let registry: Registry

    public init(http: CachingHTTPClient, registry: Registry) {
        self.http = http
        self.registry = registry
    }

    public func latest(for item: InstalledItem) async throws -> RemoteVersion? {
        let name = item.metadata[InstalledItem.MetadataKey.packageName] ?? item.name
        return try await Self.lookup(name, in: registry, http: http, itemID: item.id)
    }

    static func lookup(_ name: String, in registry: Registry, http: CachingHTTPClient, itemID: InstalledItem.ID) async throws -> RemoteVersion? {
        guard let url = url(for: name, in: registry) else { return nil }
        let version: String?
        let fetchedAt: Date
        switch registry {
        case .npm:
            struct Latest: Decodable { var version: String }
            let result = try await http.json(Latest.self, from: url, source: "npm")
            (version, fetchedAt) = (result.0.version, result.1)
        case .pypi:
            struct Project: Decodable { struct Info: Decodable { var version: String }; var info: Info }
            let result = try await http.json(Project.self, from: url, source: "PyPI")
            (version, fetchedAt) = (result.0.info.version, result.1)
        case .crates:
            struct Crate: Decodable {
                struct Info: Decodable {
                    var maxStableVersion: String?
                    var newestVersion: String?
                    enum CodingKeys: String, CodingKey { case maxStableVersion = "max_stable_version", newestVersion = "newest_version" }
                }
                var crate: Info
            }
            let result = try await http.json(Crate.self, from: url, source: "crates.io")
            (version, fetchedAt) = (result.0.crate.maxStableVersion ?? result.0.crate.newestVersion, result.1)
        }
        guard let version, !version.isEmpty else { return nil }
        return RemoteVersion(itemID: itemID, version: version, source: registry.title, releaseNotesURL: pageURL(for: name, in: registry),
                             fetchedAt: fetchedAt)
    }

    static func url(for name: String, in registry: Registry) -> URL? {
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? name
        return switch registry {
        case .npm: URL(string: "https://registry.npmjs.org/\(encoded)/latest")
        case .pypi: URL(string: "https://pypi.org/pypi/\(encoded)/json")
        case .crates: URL(string: "https://crates.io/api/v1/crates/\(encoded)")
        }
    }

    static func pageURL(for name: String, in registry: Registry) -> URL? {
        switch registry {
        case .npm: URL(string: "https://www.npmjs.com/package/\(name)")
        case .pypi: URL(string: "https://pypi.org/project/\(name)/")
        case .crates: URL(string: "https://crates.io/crates/\(name)")
        }
    }
}

extension RegistryLatestProvider.Registry {
    var title: String {
        switch self {
        case .npm: "npm"
        case .pypi: "PyPI"
        case .crates: "crates.io"
        }
    }
}

// MARK: - Rust

/// Neueste stabile Rust-Version aus dem offiziellen Kanal-Manifest. Nur für `stable`-Toolchains;
/// beta/nightly und fest gewählte Versionen (`1.80.0`) haben keine sinnvolle „neueste Version“.
public struct RustLatestProvider: LatestVersionProvider {
    public static let channelURL = URL(string: "https://static.rust-lang.org/dist/channel-rust-stable.toml")!

    private let http: CachingHTTPClient

    public init(http: CachingHTTPClient) {
        self.http = http
    }

    public func latest(for item: InstalledItem) async throws -> RemoteVersion? {
        guard let toolchain = item.metadata["toolchain"], RustEcosystem.channel(of: toolchain) == "stable" else { return nil }
        let response = try await http.get(Self.channelURL)
        guard let version = Self.stableVersion(in: String(decoding: response.body, as: UTF8.self)) else {
            throw InventoryError.unexpectedOutput(source: "channel-rust-stable.toml", detail: "no [pkg.rustc] version")
        }
        return RemoteVersion(itemID: item.id, version: version, source: "static.rust-lang.org",
                             releaseNotesURL: URL(string: "https://blog.rust-lang.org/releases/"), fetchedAt: response.validatedAt)
    }

    static func stableVersion(in manifest: String) -> String? {
        DevTools.firstMatch(#"\[pkg\.rustc\]\s*\nversion = "(\d+\.\d+\.\d+)"#, in: manifest)
    }
}

// MARK: - gcloud

/// Neueste Google-Cloud-CLI-Version aus dem offiziellen Komponenten-Manifest.
public struct GcloudLatestProvider: LatestVersionProvider {
    public static let componentsURL = URL(string: "https://dl.google.com/dl/cloudsdk/channels/rapid/components-2.json")!

    private let http: CachingHTTPClient

    public init(http: CachingHTTPClient) {
        self.http = http
    }

    public func latest(for item: InstalledItem) async throws -> RemoteVersion? {
        struct Manifest: Decodable {
            var version: String
            var releaseNotesURL: URL?
            enum CodingKeys: String, CodingKey { case version, releaseNotesURL = "release_notes_url" }
        }
        let (manifest, fetchedAt) = try await http.json(Manifest.self, from: Self.componentsURL, source: "dl.google.com")
        return RemoteVersion(itemID: item.id, version: manifest.version, source: "Google Cloud SDK",
                             releaseNotesURL: manifest.releaseNotesURL, fetchedAt: fetchedAt)
    }
}

// MARK: - Konfigurierte Tools

/// Neueste Version konfigurierter Tools gemäß `latest` in `tools.json`.
public struct ConfiguredToolLatestProvider: LatestVersionProvider {
    private let http: CachingHTTPClient

    public init(http: CachingHTTPClient) {
        self.http = http
    }

    public func latest(for item: InstalledItem) async throws -> RemoteVersion? {
        guard item.metadata[ConfiguredToolsEcosystem.errorKey] == nil,
              let json = item.metadata[ConfiguredToolsEcosystem.latestKey],
              let source = try? JSONDecoder().decode(ToolConfiguration.LatestSource.self, from: Data(json.utf8)) else {
            return nil
        }
        switch source {
        case .npm(let package):
            return try await RegistryLatestProvider.lookup(package, in: .npm, http: http, itemID: item.id)
        case .pypi(let package):
            return try await RegistryLatestProvider.lookup(package, in: .pypi, http: http, itemID: item.id)
        case .github(let repository, let tagPattern):
            struct Release: Decodable {
                var tagName: String
                var htmlURL: URL?
                enum CodingKeys: String, CodingKey { case tagName = "tag_name", htmlURL = "html_url" }
            }
            guard let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else { return nil }
            let (release, fetchedAt) = try await http.json(Release.self, from: url, source: "GitHub")
            guard let version = DevTools.firstMatch(tagPattern ?? #"^v?(.+)$"#, in: release.tagName) else { return nil }
            return RemoteVersion(itemID: item.id, version: version, source: "GitHub \(repository)", releaseNotesURL: release.htmlURL,
                                 fetchedAt: fetchedAt)
        case .url(let url, let pattern):
            let response = try await http.get(url)
            guard let version = DevTools.firstMatch(pattern, in: String(decoding: response.body, as: UTF8.self)) else { return nil }
            return RemoteVersion(itemID: item.id, version: version, source: url.host ?? url.absoluteString, fetchedAt: response.validatedAt)
        }
    }
}
