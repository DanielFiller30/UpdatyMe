import Foundation

/// Neueste Version von App-Store-Apps über die iTunes Lookup API (`itunes.apple.com/lookup?bundleId=`).
/// Kein Treffer → `nil` (Status `unknown`).
public struct AppStoreLatestProvider: LatestVersionProvider {
    public static let source = "App Store"

    struct Lookup: Decodable {
        struct Result: Decodable {
            var version: String?
            var trackViewUrl: URL?
            var currentVersionReleaseDate: String?
        }

        var results: [Result]
    }

    private let http: CachingHTTPClient
    private let country: String

    /// - Parameter country: Zweistelliger Store-Ländercode, z. B. `de`.
    public init(http: CachingHTTPClient, country: String) {
        self.http = http
        self.country = country.lowercased()
    }

    public func latest(for item: InstalledItem) async throws -> RemoteVersion? {
        guard let bundleIdentifier = item.metadata[InstalledItem.MetadataKey.bundleIdentifier],
              let url = Self.lookupURL(bundleIdentifier: bundleIdentifier, country: country) else {
            return nil
        }
        let response = try await http.get(url)
        let lookup: Lookup
        do {
            lookup = try JSONDecoder().decode(Lookup.self, from: response.body)
        } catch {
            throw InventoryError.unexpectedOutput(source: "iTunes Lookup", detail: String(describing: error))
        }
        guard let result = lookup.results.first, let version = result.version, !version.isEmpty else {
            return nil
        }
        return RemoteVersion(
            itemID: item.id,
            version: version,
            source: Self.source,
            releaseNotesURL: result.trackViewUrl,
            releaseDate: result.currentVersionReleaseDate.flatMap { try? Date($0, strategy: .iso8601) },
            fetchedAt: response.validatedAt
        )
    }

    static func lookupURL(bundleIdentifier: String, country: String) -> URL? {
        var components = URLComponents(string: "https://itunes.apple.com/lookup")
        components?.queryItems = [
            URLQueryItem(name: "bundleId", value: bundleIdentifier),
            URLQueryItem(name: "country", value: country),
        ]
        return components?.url
    }
}
