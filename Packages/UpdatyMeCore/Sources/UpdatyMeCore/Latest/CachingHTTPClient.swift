import Foundation

/// GET-Client mit TTL- und ETag-Cache auf Platte.
///
/// - Innerhalb der TTL (Standard 6 h) wird **kein** Request gesendet.
/// - Danach bedingter Request (`If-None-Match` / `If-Modified-Since`); `304` verlängert den Eintrag.
/// - Gleichzeitige Anfragen an dieselbe URL teilen sich einen Request.
/// - Netzwerk- und Statusfehler werden geworfen; abgelaufene Daten werden nicht still als aktuell
///   ausgeliefert (Status `unknown` statt falsch „aktuell“).
public actor CachingHTTPClient {
    public struct Response: Sendable, Hashable {
        public enum Origin: Sendable, Hashable {
            /// Aus dem Cache, ohne Request (innerhalb der TTL).
            case cache
            /// Server bestätigte den Cache per `304`.
            case revalidated
            /// Neu geladen.
            case network
        }

        public var body: Data
        public var origin: Origin
        /// Zeitpunkt, zu dem die Daten zuletzt vom Server bestätigt wurden.
        public var validatedAt: Date
    }

    public static let defaultTTL: Duration = .seconds(6 * 60 * 60)

    private let transport: any HTTPTransport
    private let cache: HTTPDiskCache
    private let ttl: Duration
    private let now: @Sendable () -> Date
    private let userAgent: String
    private var inFlight: [URL: Task<Response, any Error>] = [:]

    public init(
        transport: any HTTPTransport = URLSessionTransport(),
        cache: HTTPDiskCache,
        ttl: Duration = CachingHTTPClient.defaultTTL,
        userAgent: String = "UpdatyMe",
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.transport = transport
        self.cache = cache
        self.ttl = ttl
        self.userAgent = userAgent
        self.now = now
    }

    /// - Parameters:
    ///   - headers: Zusätzliche Header (z. B. `Accept`, später `Authorization`). Sie sind nicht Teil
    ///     des Cache-Schlüssels; Schlüssel ist allein die URL.
    ///   - ttl: Abweichende TTL für diese Anfrage.
    public func get(_ url: URL, headers: [String: String] = [:], ttl: Duration? = nil) async throws -> Response {
        if let entry = cache.entry(for: url), isFresh(entry, ttl: ttl ?? self.ttl) {
            return Response(body: entry.body, origin: .cache, validatedAt: entry.storedAt)
        }
        if let task = inFlight[url] {
            return try await task.value
        }
        let task = Task { try await self.fetch(url, headers: headers) }
        inFlight[url] = task
        defer { inFlight[url] = nil }
        return try await task.value
    }

    /// Entfernt den Cache-Eintrag, damit der nächste Aufruf neu lädt.
    public func invalidate(_ url: URL) {
        cache.remove(url)
    }

    /// Lässt alle Einträge ablaufen; die nächsten Aufrufe fragen (bedingt per ETag) neu an.
    public func expireAll() {
        cache.expireAll()
    }

    private func fetch(_ url: URL, headers: [String: String]) async throws -> Response {
        let cached = cache.entry(for: url)

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if let etag = cached?.etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        if let lastModified = cached?.lastModified {
            request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
        }

        let response = try await transport.send(request)
        let timestamp = now()

        switch response.statusCode {
        case 304:
            guard var entry = cached else { throw HTTPError.unexpectedStatus(304, url) }
            entry.storedAt = timestamp
            entry.etag = response.headers["etag"] ?? entry.etag
            entry.lastModified = response.headers["last-modified"] ?? entry.lastModified
            try? cache.store(entry)
            return Response(body: entry.body, origin: .revalidated, validatedAt: timestamp)
        case 200..<300:
            let entry = HTTPDiskCache.Entry(
                url: url,
                etag: response.headers["etag"],
                lastModified: response.headers["last-modified"],
                storedAt: timestamp,
                body: response.body
            )
            // Ein nicht schreibbarer Cache darf den Abruf nicht scheitern lassen.
            try? cache.store(entry)
            return Response(body: response.body, origin: .network, validatedAt: timestamp)
        default:
            throw HTTPError.unexpectedStatus(response.statusCode, url)
        }
    }

    private func isFresh(_ entry: HTTPDiskCache.Entry, ttl: Duration) -> Bool {
        let age = now().timeIntervalSince(entry.storedAt)
        let (seconds, attoseconds) = ttl.components
        return age >= 0 && age < Double(seconds) + Double(attoseconds) / 1e18
    }
}
