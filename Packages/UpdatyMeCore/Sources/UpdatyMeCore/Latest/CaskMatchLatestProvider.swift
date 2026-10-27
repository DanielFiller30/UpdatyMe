import Foundation

/// Neueste Version manuell installierter Apps über einen passenden Homebrew-Cask
/// (`formulae.brew.sh/api/cask.json`, Abgleich über den installierten App-Namen).
///
/// Nur eindeutige Treffer zählen. Varianten mit `@` (z. B. `1password@beta`) werden ignoriert, wenn es
/// genau einen Cask ohne `@` gibt. Echte Namenskonflikte ergeben keinen Treffer.
/// Verglichen wird ohne Cask-Build-Zusatz (`4.96.3,244472` → `4.96.3`), weil App-Versionen ihn nicht tragen.
public actor CaskMatchLatestProvider: LatestVersionProvider {
    public static let source = "Homebrew Cask"
    public static let apiURL = URL(string: "https://formulae.brew.sh/api/cask.json")!

    struct Cask: Decodable {
        var token: String
        var version: String
        var homepage: URL?
        var artifacts: [BrewInfo.Artifact]

        enum CodingKeys: String, CodingKey {
            case token, version, homepage, artifacts
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            token = try container.decode(String.self, forKey: .token)
            version = try container.decode(String.self, forKey: .version)
            homepage = (try? container.decodeIfPresent(String.self, forKey: .homepage)).flatMap { $0.flatMap(URL.init(string:)) }
            artifacts = (try? container.decodeIfPresent([Lossy<BrewInfo.Artifact>].self, forKey: .artifacts))?
                .compactMap(\.value) ?? []
        }
    }

    /// Überspringt einzelne nicht dekodierbare Elemente statt die ganze Liste zu verwerfen.
    struct Lossy<Value: Decodable>: Decodable {
        var value: Value?

        init(from decoder: any Decoder) throws {
            value = try? Value(from: decoder)
        }
    }

    /// Ergebnis des Abgleichs für einen App-Namen.
    public enum Match: Sendable, Equatable {
        case unique(token: String, version: String, homepage: URL?)
        case ambiguous([String])
        case none
    }

    private let http: CachingHTTPClient
    private var index: [String: [Cask]]?

    public init(http: CachingHTTPClient) {
        self.http = http
    }

    public func latest(for item: InstalledItem) async throws -> RemoteVersion? {
        guard let path = item.installPath else { return nil }
        let index = try await loadIndex()
        guard case .unique(let token, let version, let homepage) = Self.match(appName: (path as NSString).lastPathComponent, in: index) else {
            return nil
        }
        if version == "latest" {
            return RemoteVersion(itemID: item.id, version: version, source: "\(Self.source) \(token)",
                                 releaseNotesURL: homepage, assessment: .undeterminable)
        }
        let main = String(version.split(separator: ",", maxSplits: 1).first ?? "")
        let assessment: RemoteVersion.Assessment = Self.isShortenedPrefix(item.installedVersion, of: main)
            ? .undeterminable : .compareVersions
        return RemoteVersion(itemID: item.id, version: main, source: "\(Self.source) \(token)",
                             releaseNotesURL: homepage, assessment: assessment)
    }

    /// `2026.2` gegenüber `2026.2.1.8`: Die App kürzt ihre Version ab; ob sie veraltet ist, lässt sich
    /// beim heuristischen Cask-Abgleich nicht ehrlich sagen.
    static func isShortenedPrefix(_ installed: String, of latest: String) -> Bool {
        let installedParts = installed.split(separator: ".")
        let latestParts = latest.split(separator: ".")
        guard installedParts.count >= 2, installedParts.count < latestParts.count else { return false }
        return zip(installedParts, latestParts).allSatisfy { $0 == $1 }
    }

    /// Cask-Token aus `RemoteVersion.source` dieses Providers („Homebrew Cask <token>“).
    public static func token(fromSource source: String) -> String? {
        let prefix = "\(Self.source) "
        guard source.hasPrefix(prefix) else { return nil }
        let token = String(source.dropFirst(prefix.count))
        return token.isEmpty ? nil : token
    }

    static func match(appName: String, in index: [String: [Cask]]) -> Match {
        let candidates = index[appName.lowercased()] ?? []
        if candidates.count == 1, let cask = candidates.first {
            return .unique(token: cask.token, version: cask.version, homepage: cask.homepage)
        }
        let primary = candidates.filter { !$0.token.contains("@") }
        if primary.count == 1, let cask = primary.first {
            return .unique(token: cask.token, version: cask.version, homepage: cask.homepage)
        }
        return candidates.isEmpty ? .none : .ambiguous(candidates.map(\.token).sorted())
    }

    /// App-Dateiname (wie installiert, also nach `target`) → Casks.
    static func buildIndex(_ data: Data) throws -> [String: [Cask]] {
        let casks: [Cask]
        do {
            casks = try JSONDecoder().decode([Lossy<Cask>].self, from: data).compactMap(\.value)
        } catch {
            throw InventoryError.unexpectedOutput(source: "cask.json", detail: String(describing: error))
        }
        var index: [String: [Cask]] = [:]
        for cask in casks {
            let names = Set(BrewEcosystem.appPaths(from: cask.artifacts).map { ($0 as NSString).lastPathComponent.lowercased() })
            for name in names {
                index[name, default: []].append(cask)
            }
        }
        return index
    }

    private func loadIndex() async throws -> [String: [Cask]] {
        if let index { return index }
        let response = try await http.get(Self.apiURL)
        let built = try Self.buildIndex(response.body)
        index = built
        return built
    }
}
