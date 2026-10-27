import Foundation
import UpdatyMeCore

/// Ersetzt das Netzwerk in Tests: liefert pro URL hinterlegte Antworten der Reihe nach
/// (die letzte wird wiederholt) und protokolliert alle Requests.
public actor MockHTTPTransport: HTTPTransport {
    public enum MockError: Error, Sendable, Equatable {
        case unstubbedURL(URL)
    }

    private var responses: [URL: [Result<HTTPResponse, URLError>]] = [:]
    private var delay: Duration?
    public private(set) var requests: [URLRequest] = []

    public init() {}

    public func stub(_ url: URL, _ responses: HTTPResponse...) {
        self.responses[url, default: []] += responses.map { .success($0) }
    }

    public func stub(_ url: URL, error: URLError) {
        responses[url, default: []].append(.failure(error))
    }

    /// Verzögert jede Antwort, z. B. um gleichzeitige Anfragen zu testen.
    public func setDelay(_ delay: Duration?) {
        self.delay = delay
    }

    public func send(_ request: URLRequest) async throws -> HTTPResponse {
        requests.append(request)
        let url = request.url ?? URL(fileURLWithPath: "/")
        guard var queue = responses[url], let next = queue.first else {
            throw MockError.unstubbedURL(url)
        }
        if queue.count > 1 {
            queue.removeFirst()
            responses[url] = queue
        }
        if let delay {
            try await Task.sleep(for: delay)
        }
        return try next.get()
    }
}
