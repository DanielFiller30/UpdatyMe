import Foundation

/// Neueste Version von Sparkle-Apps aus deren Appcast (`SUFeedURL`).
///
/// Auswahl wie Sparkle: Einträge mit eigenem Kanal (`sparkle:channel`, z. B. Beta) und Einträge, deren
/// `minimumSystemVersion` über dem laufenden macOS liegt, werden ignoriert; der höchste
/// `sparkle:version` gewinnt (Einträge sind nicht zwingend sortiert).
///
/// Bewertung: Mit `shortVersionString` wird die Anzeige-Version verglichen. Ohne ihn ist
/// `sparkle:version` eine Build-Nummer und wird – wie bei Sparkle – mit `CFBundleVersion` verglichen.
public struct SparkleLatestProvider: LatestVersionProvider {
    public static let source = "Sparkle"

    private let http: CachingHTTPClient
    private let systemVersion: String

    /// - Parameter systemVersion: Laufendes macOS, z. B. `26.7.1`.
    public init(http: CachingHTTPClient, systemVersion: String) {
        self.http = http
        self.systemVersion = systemVersion
    }

    public func latest(for item: InstalledItem) async throws -> RemoteVersion? {
        guard let feed = item.metadata[InstalledItem.MetadataKey.sparkleFeedURL].flatMap(URL.init(string:)) else {
            return nil
        }
        let response = try await http.get(feed)
        let items = try AppcastParser.parse(response.body)
        guard let best = Self.bestItem(in: items, systemVersion: systemVersion) else {
            return nil
        }
        return Self.remoteVersion(for: item, appcastItem: best, fetchedAt: response.validatedAt)
    }

    static func bestItem(in items: [AppcastItem], systemVersion: String) -> AppcastItem? {
        items
            .filter { $0.channel == nil && $0.version != nil }
            .filter { item in
                guard let minimum = item.minimumSystemVersion else { return true }
                return VersionComparator.compare(minimum, systemVersion) != .orderedDescending
            }
            .max { lhs, rhs in
                VersionComparator.compare(lhs.version ?? "", rhs.version ?? "", scheme: .build) == .orderedAscending
            }
    }

    static func remoteVersion(for item: InstalledItem, appcastItem: AppcastItem, fetchedAt: Date) -> RemoteVersion? {
        let releaseNotes = appcastItem.releaseNotesLink
        if let short = appcastItem.shortVersionString {
            return RemoteVersion(itemID: item.id, version: short, source: source, releaseNotesURL: releaseNotes,
                                 releaseDate: appcastItem.publicationDate, fetchedAt: fetchedAt)
        }
        guard let build = appcastItem.version else { return nil }
        let assessment: RemoteVersion.Assessment
        switch item.metadata[InstalledItem.MetadataKey.bundleVersion].flatMap({ VersionComparator.compare($0, build, scheme: .build) }) {
        case .orderedAscending?: assessment = .outdated
        case .orderedSame?, .orderedDescending?: assessment = .upToDate
        case nil: assessment = .undeterminable
        }
        return RemoteVersion(itemID: item.id, version: build, source: source, releaseNotesURL: releaseNotes,
                             releaseDate: appcastItem.publicationDate, fetchedAt: fetchedAt, assessment: assessment)
    }
}

/// Ein Eintrag eines Sparkle-Appcasts.
public struct AppcastItem: Sendable, Hashable {
    public var title: String?
    /// `sparkle:version` (Build, verglichen mit `CFBundleVersion`).
    public var version: String?
    /// `sparkle:shortVersionString` (Anzeige-Version).
    public var shortVersionString: String?
    public var minimumSystemVersion: String?
    public var channel: String?
    public var releaseNotesLink: URL?
    public var publicationDate: Date?
}

/// Liest Appcasts. Sparkle-Angaben können als Attribut von `<enclosure>` oder als eigenes Element stehen.
public enum AppcastParser {
    public static func parse(_ data: Data) throws -> [AppcastItem] {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.delegate = delegate
        guard parser.parse() else {
            throw InventoryError.unexpectedOutput(
                source: "Appcast",
                detail: parser.parserError.map(String.init(describing:)) ?? "invalid XML"
            )
        }
        return delegate.items
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var items: [AppcastItem] = []
        private var current: AppcastItem?
        private var text = ""

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            text = ""
            switch name {
            case "item":
                current = AppcastItem()
            case "enclosure":
                if let version = attributes["sparkle:version"] { current?.version = version }
                if let short = attributes["sparkle:shortVersionString"] { current?.shortVersionString = short }
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            defer { text = "" }
            guard current != nil else { return }
            switch name {
            case "item":
                if let item = current { items.append(item) }
                current = nil
            case "title": current?.title = value
            case "sparkle:version": if !value.isEmpty { current?.version = value }
            case "sparkle:shortVersionString": if !value.isEmpty { current?.shortVersionString = value }
            case "sparkle:minimumSystemVersion": current?.minimumSystemVersion = value
            case "sparkle:channel": if !value.isEmpty { current?.channel = value }
            case "sparkle:releaseNotesLink": current?.releaseNotesLink = URL(string: value)
            case "pubDate": current?.publicationDate = Self.rfc822.date(from: value)
            default: break
            }
        }

        private static let rfc822: DateFormatter = {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
            return formatter
        }()
    }
}
