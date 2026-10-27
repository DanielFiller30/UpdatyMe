import CryptoKit
import Foundation

/// Plattencache für HTTP-Antworten: pro URL eine Metadaten-Datei (`<sha256>.json`) und der rohe
/// Body (`<sha256>.body`). Große Antworten wie `cask.json` bleiben so unkodiert.
public struct HTTPDiskCache: Sendable {
    public struct Entry: Sendable, Hashable, Codable {
        public var url: URL
        public var etag: String?
        public var lastModified: String?
        /// Zeitpunkt des letzten Abrufs oder der letzten erfolgreichen Revalidierung (304).
        public var storedAt: Date
        public var body: Data

        enum CodingKeys: String, CodingKey {
            case url, etag, lastModified, storedAt
        }

        public init(url: URL, etag: String?, lastModified: String?, storedAt: Date, body: Data) {
            self.url = url
            self.etag = etag
            self.lastModified = lastModified
            self.storedAt = storedAt
            self.body = body
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            url = try container.decode(URL.self, forKey: .url)
            etag = try container.decodeIfPresent(String.self, forKey: .etag)
            lastModified = try container.decodeIfPresent(String.self, forKey: .lastModified)
            storedAt = try container.decode(Date.self, forKey: .storedAt)
            body = Data()
        }
    }

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// `~/Library/Caches/<bundleIdentifier>/http`
    public static func defaultDirectory(bundleIdentifier: String) throws -> URL {
        try FileManager.default
            .url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("http", isDirectory: true)
    }

    /// `nil`, wenn kein vollständiger Eintrag existiert oder er unlesbar ist.
    public func entry(for url: URL) -> Entry? {
        let (metaURL, bodyURL) = fileURLs(for: url)
        guard let meta = try? Data(contentsOf: metaURL),
              var entry = try? JSONDecoder().decode(Entry.self, from: meta),
              entry.url == url,
              let body = try? Data(contentsOf: bodyURL) else {
            return nil
        }
        entry.body = body
        return entry
    }

    /// Schreibt erst den Body, dann die Metadaten (beides atomar). Ein Abbruch dazwischen
    /// hinterlässt höchstens einen alten, aber konsistenten Eintrag.
    public func store(_ entry: Entry) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let (metaURL, bodyURL) = fileURLs(for: entry.url)
        try entry.body.write(to: bodyURL, options: .atomic)
        try JSONEncoder().encode(entry).write(to: metaURL, options: .atomic)
    }

    public func remove(_ url: URL) {
        let (metaURL, bodyURL) = fileURLs(for: url)
        try? FileManager.default.removeItem(at: metaURL)
        try? FileManager.default.removeItem(at: bodyURL)
    }

    /// Markiert alle Einträge als abgelaufen. Body und ETag bleiben, damit die nächste Abfrage
    /// bedingt erfolgt (`304` statt erneutem Download).
    public func expireAll() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for metaURL in files where metaURL.pathExtension == "json" {
            guard let data = try? Data(contentsOf: metaURL),
                  var entry = try? JSONDecoder().decode(Entry.self, from: data) else { continue }
            entry.storedAt = .distantPast
            try? JSONEncoder().encode(entry).write(to: metaURL, options: .atomic)
        }
    }

    public func removeAll() throws {
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    private func fileURLs(for url: URL) -> (meta: URL, body: URL) {
        let key = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return (directory.appendingPathComponent("\(key).json"), directory.appendingPathComponent("\(key).body"))
    }
}
