import Foundation
import Synchronization
import Testing
import UpdatyMeCore
import UpdatyMeCoreTestSupport

@Suite("CachingHTTPClient")
struct CachingHTTPClientTests {
    static let url = URL(string: "https://registry.npmjs.org/npm/latest")!
    static let body = Data(#"{"version":"11.6.2"}"#.utf8)

    /// Steuerbare Uhr für TTL-Tests.
    final class TestClock: Sendable {
        private let current = Mutex(Date(timeIntervalSince1970: 1_800_000_000))
        var now: Date { current.withLock { $0 } }
        func advance(by seconds: TimeInterval) { current.withLock { $0 += seconds } }
    }

    struct Setup: ~Copyable {
        let directory: TemporaryDirectory
        let transport = MockHTTPTransport()
        let clock = TestClock()
        let client: CachingHTTPClient

        init(ttl: Duration = CachingHTTPClient.defaultTTL) throws {
            let directory = try TemporaryDirectory()
            let clock = clock
            client = CachingHTTPClient(
                transport: transport,
                cache: HTTPDiskCache(directory: directory.url.appendingPathComponent("http")),
                ttl: ttl,
                now: { clock.now }
            )
            self.directory = directory
        }

        func makeClient() -> CachingHTTPClient {
            let clock = clock
            return CachingHTTPClient(
                transport: transport,
                cache: HTTPDiskCache(directory: directory.url.appendingPathComponent("http")),
                now: { clock.now }
            )
        }
    }

    static func ok(etag: String? = "\"v1\"", body: Data = body) -> HTTPResponse {
        var headers = ["Last-Modified": "Mon, 26 Oct 2026 10:00:00 GMT"]
        headers["ETag"] = etag
        return HTTPResponse(statusCode: 200, headers: headers, body: body)
    }

    @Test func secondRequestWithinTTLHitsNoNetwork() async throws {
        let setup = try Setup()
        await setup.transport.stub(Self.url, Self.ok())

        let first = try await setup.client.get(Self.url)
        setup.clock.advance(by: 6 * 3600 - 1)
        let second = try await setup.client.get(Self.url)

        #expect(first.origin == .network)
        #expect(second.origin == .cache)
        #expect(second.body == Self.body)
        #expect(await setup.transport.requests.count == 1)
    }

    @Test func cacheSurvivesNewClientInstance() async throws {
        let setup = try Setup()
        await setup.transport.stub(Self.url, Self.ok())
        _ = try await setup.client.get(Self.url)

        let response = try await setup.makeClient().get(Self.url)
        #expect(response.origin == .cache)
        #expect(response.body == Self.body)
        #expect(await setup.transport.requests.count == 1)
    }

    @Test func revalidatesWithETagAfterTTL() async throws {
        let setup = try Setup()
        await setup.transport.stub(Self.url, Self.ok(), HTTPResponse(statusCode: 304))
        _ = try await setup.client.get(Self.url)

        setup.clock.advance(by: 6 * 3600)
        let revalidated = try await setup.client.get(Self.url)
        #expect(revalidated.origin == .revalidated)
        #expect(revalidated.body == Self.body)
        #expect(revalidated.validatedAt == setup.clock.now)

        let conditional = try #require(await setup.transport.requests.last)
        #expect(conditional.value(forHTTPHeaderField: "If-None-Match") == "\"v1\"")
        #expect(conditional.value(forHTTPHeaderField: "If-Modified-Since") == "Mon, 26 Oct 2026 10:00:00 GMT")

        // 304 verlängert die TTL: nächster Aufruf ohne Request.
        setup.clock.advance(by: 60)
        #expect(try await setup.client.get(Self.url).origin == .cache)
        #expect(await setup.transport.requests.count == 2)
    }

    @Test func replacesEntryWhenContentChanged() async throws {
        let setup = try Setup()
        let newBody = Data(#"{"version":"11.7.0"}"#.utf8)
        await setup.transport.stub(Self.url, Self.ok(), Self.ok(etag: "\"v2\"", body: newBody), HTTPResponse(statusCode: 304))
        _ = try await setup.client.get(Self.url)

        setup.clock.advance(by: 6 * 3600)
        let changed = try await setup.client.get(Self.url)
        #expect(changed.origin == .network)
        #expect(changed.body == newBody)

        setup.clock.advance(by: 6 * 3600)
        _ = try await setup.client.get(Self.url)
        let conditional = try #require(await setup.transport.requests.last)
        #expect(conditional.value(forHTTPHeaderField: "If-None-Match") == "\"v2\"")
    }

    @Test func firstRequestIsUnconditionalAndSendsHeaders() async throws {
        let setup = try Setup()
        await setup.transport.stub(Self.url, Self.ok(etag: nil))
        _ = try await setup.client.get(Self.url, headers: ["Accept": "application/json"])

        let request = try #require(await setup.transport.requests.first)
        #expect(request.value(forHTTPHeaderField: "If-None-Match") == nil)
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "UpdatyMe")
    }

    @Test func errorStatusThrowsAndKeepsOldEntry() async throws {
        let setup = try Setup()
        await setup.transport.stub(Self.url, Self.ok(), HTTPResponse(statusCode: 503), HTTPResponse(statusCode: 304))
        _ = try await setup.client.get(Self.url)

        setup.clock.advance(by: 6 * 3600)
        await #expect(throws: HTTPError.unexpectedStatus(503, Self.url)) {
            _ = try await setup.client.get(Self.url)
        }
        // Alter Eintrag samt ETag bleibt für die nächste Revalidierung erhalten.
        #expect(try await setup.client.get(Self.url).origin == .revalidated)
    }

    @Test func networkErrorIsNotHiddenByStaleCache() async throws {
        let setup = try Setup()
        await setup.transport.stub(Self.url, Self.ok())
        await setup.transport.stub(Self.url, error: URLError(.notConnectedToInternet))
        _ = try await setup.client.get(Self.url)

        setup.clock.advance(by: 6 * 3600)
        await #expect(throws: URLError.self) { _ = try await setup.client.get(Self.url) }
    }

    @Test func doesNotCacheErrors() async throws {
        let setup = try Setup()
        await setup.transport.stub(Self.url, HTTPResponse(statusCode: 404), Self.ok())
        await #expect(throws: HTTPError.unexpectedStatus(404, Self.url)) { _ = try await setup.client.get(Self.url) }
        #expect(try await setup.client.get(Self.url).origin == .network)
    }

    @Test func perRequestTTLOverridesDefault() async throws {
        let setup = try Setup()
        await setup.transport.stub(Self.url, Self.ok(), HTTPResponse(statusCode: 304))
        _ = try await setup.client.get(Self.url)
        setup.clock.advance(by: 120)

        #expect(try await setup.client.get(Self.url, ttl: .seconds(60)).origin == .revalidated)
    }

    @Test func invalidateForcesReload() async throws {
        let setup = try Setup()
        await setup.transport.stub(Self.url, Self.ok())
        _ = try await setup.client.get(Self.url)
        await setup.client.invalidate(Self.url)

        let response = try await setup.client.get(Self.url)
        #expect(response.origin == .network)
        let request = try #require(await setup.transport.requests.last)
        #expect(request.value(forHTTPHeaderField: "If-None-Match") == nil)
    }

    @Test func concurrentRequestsShareOneNetworkCall() async throws {
        let setup = try Setup()
        await setup.transport.stub(Self.url, Self.ok())
        await setup.transport.setDelay(.milliseconds(200))

        let client = setup.client
        let bodies = try await withThrowingTaskGroup(of: Data.self) { group in
            for _ in 0..<5 {
                group.addTask { try await client.get(Self.url).body }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        #expect(bodies == Array(repeating: Self.body, count: 5))
        #expect(await setup.transport.requests.count == 1)
    }

    @Test func diskCacheIgnoresIncompleteEntries() throws {
        let directory = try TemporaryDirectory()
        let cache = HTTPDiskCache(directory: directory.url)
        let entry = HTTPDiskCache.Entry(url: Self.url, etag: "x", lastModified: nil, storedAt: Date(), body: Self.body)
        try cache.store(entry)
        #expect(cache.entry(for: Self.url) == entry)

        let bodies = try FileManager.default.contentsOfDirectory(atPath: directory.url.path).filter { $0.hasSuffix(".body") }
        try FileManager.default.removeItem(at: directory.url.appendingPathComponent(try #require(bodies.first)))
        #expect(cache.entry(for: Self.url) == nil)
    }
}
