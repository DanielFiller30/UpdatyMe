import Foundation

public struct HTTPResponse: Sendable, Hashable {
    public var statusCode: Int
    /// Header-Namen in Kleinschreibung.
    public var headers: [String: String]
    public var body: Data

    public init(statusCode: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.statusCode = statusCode
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { _, last in last })
        self.body = body
    }
}

/// Netzwerkzugriff hinter einem Protokoll, damit Tests ohne Netz laufen.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResponse
}

public enum HTTPError: Error, Sendable, Hashable {
    case notHTTP(URL)
    case unexpectedStatus(Int, URL)
}

/// `URLSession` ohne eigenen URL-Cache: Caching übernimmt ausschließlich `CachingHTTPClient`,
/// sonst könnte URLSession 304-Antworten unbemerkt durch eigene Kopien ersetzen.
public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(timeout: TimeInterval = 30) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = timeout
        session = URLSession(configuration: configuration)
    }

    public func send(_ request: URLRequest) async throws -> HTTPResponse {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw HTTPError.notHTTP(request.url ?? URL(fileURLWithPath: "/"))
        }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let key = key as? String, let value = value as? String {
                headers[key] = value
            }
        }
        return HTTPResponse(statusCode: http.statusCode, headers: headers, body: data)
    }
}
