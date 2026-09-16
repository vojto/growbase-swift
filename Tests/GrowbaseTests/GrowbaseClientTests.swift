import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import Growbase

@Suite(.serialized)
struct GrowbaseClientTests {
    @Test func persistsEventsAndSendsThemAfterRecreation() async throws {
        let storageURL = temporaryStorageURL()
        let session = makeSession()
        MockURLProtocol.responses = [200]

        var analytics: GrowbaseClient? = try GrowbaseClient(
            baseURL: URL(string: "https://example.com")!,
            trackingKey: "key",
            session: session,
            storageURL: storageURL
        )
        try await analytics?.track("opened", properties: ["source": "notification"])
        analytics = nil

        let restored = try GrowbaseClient(
            baseURL: URL(string: "https://example.com")!,
            trackingKey: "key",
            session: session,
            storageURL: storageURL
        )
        await restored.flush()

        let requests = MockURLProtocol.requests
        #expect(requests.count == 1)
        #expect(requests[0].url?.path == "/api/events")
        let body = try requestBody(requests[0])
        #expect(body["name"] as? String == "opened")
        #expect((body["properties"] as? [String: Any])?["source"] as? String == "notification")
        #expect(requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer key")
    }

    @Test func identifyAndResetPreserveQueuedIdentitySnapshots() async throws {
        let storageURL = temporaryStorageURL()
        MockURLProtocol.responses = Array(repeating: 200, count: 5)
        let analytics = try GrowbaseClient(
            baseURL: URL(string: "https://example.com")!,
            trackingKey: "key",
            session: makeSession(),
            storageURL: storageURL
        )

        try await analytics.track("before")
        try await analytics.identify("user-1")
        try await analytics.track("signed_in")
        try await analytics.reset()
        try await analytics.track("after_logout")
        await analytics.flush()

        let requests = MockURLProtocol.requests
        #expect(requests.map(\.url!.path) == ["/api/events", "/api/identify", "/api/events", "/api/events"])
        let bodies = try requests.map(requestBody)
        let firstAnonymousID = bodies[0]["anonymous_id"] as? String
        #expect(bodies[0]["app_user_id"] == nil)
        #expect(bodies[1]["anonymous_id"] as? String == firstAnonymousID)
        #expect(bodies[1]["app_user_id"] as? String == "user-1")
        #expect(bodies[2]["anonymous_id"] as? String == firstAnonymousID)
        #expect(bodies[2]["app_user_id"] as? String == "user-1")
        #expect(bodies[3]["anonymous_id"] as? String != firstAnonymousID)
        #expect(bodies[3]["app_user_id"] == nil)
    }

    @Test func authenticationFailureRetainsQueue() async throws {
        let storageURL = temporaryStorageURL()
        let session = makeSession()
        MockURLProtocol.responses = [401, 200]
        let analytics = try GrowbaseClient(
            baseURL: URL(string: "https://example.com")!, trackingKey: "key",
            session: session, storageURL: storageURL
        )
        try await analytics.track("opened")
        await analytics.flush()

        let restored = try GrowbaseClient(
            baseURL: URL(string: "https://example.com")!, trackingKey: "key",
            session: session, storageURL: storageURL
        )
        await restored.flush()
        let requests = MockURLProtocol.requests
        #expect(requests.count == 2)
        let firstID = try requestBody(try #require(requests.first))["event_id"] as? String
        let lastID = try requestBody(try #require(requests.last))["event_id"] as? String
        #expect(firstID == lastID)
    }

    @Test func serverFailureRetriesQueuedEvent() async throws {
        let session = makeSession()
        MockURLProtocol.responses = [500, 200]
        let analytics = try GrowbaseClient(
            baseURL: URL(string: "https://example.com")!, trackingKey: "key",
            session: session, storageURL: temporaryStorageURL()
        )
        try await analytics.track("opened")

        await analytics.flush()
        await analytics.flush()

        let requests = MockURLProtocol.requests
        #expect(requests.count == 2)
        let firstID = try requestBody(try #require(requests.first))["event_id"] as? String
        let lastID = try requestBody(try #require(requests.last))["event_id"] as? String
        #expect(firstID == lastID)
    }

    @Test func rejectsOversizedValuesAndPayloads() async throws {
        let analytics = try GrowbaseClient(
            baseURL: URL(string: "https://example.com")!, trackingKey: "key",
            session: makeSession(), storageURL: temporaryStorageURL()
        )
        await #expect(throws: GrowbaseClientError.self) {
            try await analytics.track(String(repeating: "a", count: 256))
        }
        await #expect(throws: GrowbaseClientError.self) {
            try await analytics.track("large", properties: ["value": .string(String(repeating: "a", count: 70_000))])
        }
        await #expect(throws: GrowbaseClientError.invalidValue("event name")) {
            try await analytics.track(" \n ")
        }
        await #expect(throws: GrowbaseClientError.invalidValue("property")) {
            try await analytics.track("nested", properties: ["object": ["items": ["valid", "bad\0value"]]])
        }
        await #expect(throws: GrowbaseClientError.invalidValue("property")) {
            try await analytics.track("key", properties: ["bad\0key": true])
        }
        await #expect(throws: GrowbaseClientError.invalidValue("user ID")) {
            try await analytics.identify("\0")
        }
        #expect(await analytics.queuedItemCount == 0)
    }

    @Test func persistsAnonymousIdentityDuringInitialization() throws {
        let storageURL = temporaryStorageURL()
        _ = try GrowbaseClient(
            baseURL: URL(string: "https://example.com")!, trackingKey: "key",
            session: makeSession(), storageURL: storageURL
        )
        #expect(FileManager.default.fileExists(atPath: storageURL.path))
    }

    @Test func requiresResetBeforeChangingIdentifiedUser() async throws {
        let analytics = try GrowbaseClient(
            baseURL: URL(string: "https://example.com")!, trackingKey: "key",
            session: makeSession(), storageURL: temporaryStorageURL()
        )
        try await analytics.identify("user-1")
        await #expect(throws: GrowbaseClientError.identityConflict) {
            try await analytics.identify("user-2")
        }
        #expect(await analytics.queuedItemCount == 1)
    }

    @Test func failedPersistenceDoesNotMutateMemory() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("growbase-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let analytics = try GrowbaseClient(
            baseURL: URL(string: "https://example.com")!, trackingKey: "key",
            session: makeSession(), storageURL: directory.appendingPathComponent("state.json")
        )
        try FileManager.default.removeItem(at: directory)

        await #expect(throws: Error.self) { try await analytics.track("opened") }
        #expect(await analytics.queuedItemCount == 0)
    }

    private func temporaryStorageURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("growbase-tests-\(UUID().uuidString).json")
    }

    private func makeSession() -> URLSession {
        MockURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func requestBody(_ request: URLRequest) throws -> [String: Any] {
        let data = try #require(request.httpBody ?? request.httpBodyStream.flatMap(read))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func read(_ stream: InputStream) -> Data? {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responses: [Int] = []
    nonisolated(unsafe) static var requests: [URLRequest] = []
    private static let lock = NSLock()

    static func reset() {
        lock.withLock {
            responses = []
            requests = []
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let status = Self.lock.withLock { () -> Int in
            Self.requests.append(request)
            return Self.responses.isEmpty ? 200 : Self.responses.removeFirst()
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
