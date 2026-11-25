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

    @Test func linksEachSubscriptionOnceWithTheCurrentIdentity() async throws {
        MockURLProtocol.responses = [200, 200]
        let analytics = try GrowbaseClient(
            baseURL: URL(string: "https://example.com")!,
            trackingKey: "key",
            session: makeSession(),
            storageURL: temporaryStorageURL()
        )

        try await analytics.identify("user-1")
        try await analytics.linkSubscription(originalTransactionID: "2000000812345678")
        try await analytics.linkSubscription(originalTransactionID: "2000000812345678")
        await analytics.flush()

        let requests = MockURLProtocol.requests
        #expect(requests.map(\.url!.path) == ["/api/identify", "/api/subscriptions"])
        let body = try requestBody(requests[1])
        #expect(body["original_transaction_id"] as? String == "2000000812345678")
        #expect(body["app_user_id"] as? String == "user-1")
        #expect(body["anonymous_id"] as? String != nil)
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

    @Test func correctedTrackingKeyRetriesQueue() async throws {
        let storageURL = temporaryStorageURL()
        let session = makeSession()
        MockURLProtocol.responses = [401, 200]
        let analytics = try GrowbaseClient(
            baseURL: URL(string: "https://example.com")!, trackingKey: "incorrect-key",
            session: session, storageURL: storageURL
        )
        try await analytics.track("opened")
        await analytics.flush()

        let restored = try GrowbaseClient(
            baseURL: URL(string: "https://example.com")!, trackingKey: "corrected-key",
            session: session, storageURL: storageURL
        )
        await restored.flush()
        let requests = MockURLProtocol.requests
        #expect(requests.count == 2)
        #expect(requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer incorrect-key")
        #expect(requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer corrected-key")
        let firstID = try requestBody(try #require(requests.first))["event_id"] as? String
        let lastID = try requestBody(try #require(requests.last))["event_id"] as? String
        #expect(firstID == lastID)
    }

    @Test func persistsIdentifyEmailAfterRecreation() async throws {
        let storageURL = temporaryStorageURL()
        let session = makeSession()
        MockURLProtocol.responses = [401, 200]
        var analytics: GrowbaseClient? = try GrowbaseClient(
            baseURL: URL(string: "https://example.com")!, trackingKey: "key",
            session: session, storageURL: storageURL
        )
        try await analytics?.identify("user-1", email: "person@example.com")
        await analytics?.flush()
        analytics = nil

        let restored = try GrowbaseClient(
            baseURL: URL(string: "https://example.com")!, trackingKey: "key",
            session: session, storageURL: storageURL
        )
        await restored.flush()

        let bodies = try MockURLProtocol.requests.map(requestBody)
        #expect(bodies.count == 2)
        #expect(bodies.allSatisfy { $0["app_user_id"] as? String == "user-1" })
        #expect(bodies.allSatisfy { $0["email"] as? String == "person@example.com" })
    }

    @Test func retriesIdentifyEmailAfterServerFailure() async throws {
        let session = makeSession()
        MockURLProtocol.responses = [500, 200]
        let analytics = try GrowbaseClient(
            baseURL: URL(string: "https://example.com")!, trackingKey: "key",
            session: session, storageURL: temporaryStorageURL()
        )
        try await analytics.identify("user-1", email: "person@example.com")

        await analytics.flush()
        await analytics.flush()

        let bodies = try MockURLProtocol.requests.map(requestBody)
        #expect(bodies.count == 2)
        #expect(bodies.allSatisfy { $0["email"] as? String == "person@example.com" })
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
        await #expect(throws: GrowbaseClientError.invalidValue("email")) {
            try await analytics.identify("user-1", email: " ")
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

    @Test func fullQueueDiscardsOldestEventBeforeIdentity() async throws {
        let storageURL = temporaryStorageURL()
        let analytics = try GrowbaseClient(
            baseURL: URL(string: "https://example.com")!,
            trackingKey: "key",
            session: makeSession(),
            storageURL: storageURL,
            maximumQueueSize: 3
        )

        try await analytics.track("oldest")
        try await analytics.identify("user-1")
        try await analytics.track("newer")
        try await analytics.track("newest")
        #expect(await analytics.queuedItemCount == 3)

        let restored = try GrowbaseClient(
            baseURL: URL(string: "https://example.com")!,
            trackingKey: "key",
            session: makeSession(),
            storageURL: storageURL,
            maximumQueueSize: 2
        )
        #expect(await restored.queuedItemCount == 2)

        await restored.flush()

        let requests = MockURLProtocol.requests
        #expect(requests.map(\.url!.path) == ["/api/identify", "/api/events"])
        #expect(try requestBody(requests[1])["name"] as? String == "newest")
    }

    @Test func experimentAssignmentMatchesRubyAndSupportsMultipleVariants() throws {
        // These values are also produced by Ruby's SHA256.hexdigest[0, 8].to_i(16) % 10_000.
        #expect(ExperimentConfiguration.bucket("expose:prompt:salt:install-123") == 7614)
        #expect(ExperimentConfiguration.bucket("split:prompt:salt:install-123") == 8108)
        let experiment = try JSONDecoder().decode([ExperimentConfiguration].self, from: experimentJSON()).first!
        #expect(experiment.isValid)
        #expect(experiment.variant(for: "install-123") == "long_prompt")
        let variants = Set((0..<100).compactMap { experiment.variant(for: "install-\($0)") })
        #expect(variants == ["control", "short_prompt", "long_prompt"])
    }

    @Test func experimentExposureIsDurableAndDeduplicatedThroughLogin() async throws {
        let storageURL = temporaryStorageURL()
        let session = makeSession()
        MockURLProtocol.body = experimentJSON()
        let client = try GrowbaseClient(baseURL: URL(string: "https://example.com")!, trackingKey: "key",
            session: session, storageURL: storageURL)
        #expect(try await client.variant(for: "prompt") == nil)
        await client.refreshExperiments()
        let variant = try await client.variant(for: "prompt")
        #expect(variant != nil)
        try await client.identify("account")
        #expect(try await client.variant(for: "prompt") == variant)
        #expect(await client.queuedItemCount == 2)

        let restored = try GrowbaseClient(baseURL: URL(string: "https://example.com")!, trackingKey: "key",
            session: session, storageURL: storageURL)
        #expect(try await restored.variant(for: "prompt") == variant)
        await restored.flush()
        let events = try MockURLProtocol.requests.filter { $0.url?.path == "/api/events" }.map(requestBody)
        #expect(events.count == 2)
        #expect(events.allSatisfy { $0["name"] as? String == "$experiment_exposure" })
        let properties = try #require(events.first?["properties"] as? [String: Any])
        #expect(properties["variant"] as? String == variant)
        #expect(properties["experiment"] as? String == "prompt")
        #expect(properties["config_version"] as? Int == 1)
    }

    @Test func experimentRefreshHonorsETagAndStopping() async throws {
        let session = makeSession()
        MockURLProtocol.body = experimentJSON()
        MockURLProtocol.headers = ["ETag": "config-1"]
        let client = try GrowbaseClient(baseURL: URL(string: "https://example.com")!, trackingKey: "key",
            session: session, storageURL: temporaryStorageURL())
        await client.refreshExperiments()
        #expect(try await client.variant(for: "prompt") != nil)
        MockURLProtocol.responses = [304]
        await client.refreshExperiments()
        #expect(MockURLProtocol.requests.last?.value(forHTTPHeaderField: "If-None-Match") == "config-1")
        #expect(try await client.variant(for: "prompt") != nil)
        MockURLProtocol.body = Data("[]".utf8)
        await client.refreshExperiments()
        #expect(try await client.variant(for: "prompt") == nil)
        #expect(await client.queuedItemCount == 1)
    }

    @Test func experimentGateExcludesWithoutExposureAndResetRecordsNewIdentity() async throws {
        let session = makeSession()
        MockURLProtocol.body = experimentJSON(exposurePct: 0)
        let client = try GrowbaseClient(baseURL: URL(string: "https://example.com")!, trackingKey: "key",
            session: session, storageURL: temporaryStorageURL())
        await client.refreshExperiments()
        #expect(try await client.variant(for: "prompt") == nil)
        #expect(try await client.variant(for: "missing") == nil)
        #expect(await client.queuedItemCount == 0)
        MockURLProtocol.body = experimentJSON()
        await client.refreshExperiments()
        #expect(try await client.variant(for: "prompt") != nil)
        try await client.reset()
        #expect(try await client.variant(for: "prompt") != nil)
        await client.flush()
        let events = try MockURLProtocol.requests.filter { $0.url?.path == "/api/events" }.map(requestBody)
        #expect(events.count == 2)
        #expect(events[0]["anonymous_id"] as? String != events[1]["anonymous_id"] as? String)
    }

    @Test func experimentCacheExpiresAndDoesNotLeakAcrossConfigurations() async throws {
        let session = makeSession()
        let storageURL = temporaryStorageURL()
        MockURLProtocol.body = experimentJSON()
        let client = try GrowbaseClient(baseURL: URL(string: "https://example.com")!, trackingKey: "key",
            session: session, storageURL: storageURL)
        await client.refreshExperiments()
        let otherApp = try GrowbaseClient(baseURL: URL(string: "https://example.com")!, trackingKey: "other-key",
            session: session, storageURL: storageURL)
        #expect(try await otherApp.variant(for: "prompt") == nil)

        let store = StateStore(url: storageURL)
        var state = try store.load()
        state.experimentCache?.fetchedAt = Date().addingTimeInterval(-25 * 60 * 60)
        try store.save(state)
        let restored = try GrowbaseClient(baseURL: URL(string: "https://example.com")!, trackingKey: "key",
            session: session, storageURL: storageURL)
        #expect(try await restored.variant(for: "prompt") == nil)
        #expect(await restored.queuedItemCount == 0)
    }

    @Test func experimentFailuresKeepCacheButUnauthorizedClearsIt() async throws {
        let session = makeSession()
        let storageURL = temporaryStorageURL()
        MockURLProtocol.body = experimentJSON()
        let client = try GrowbaseClient(baseURL: URL(string: "https://example.com")!, trackingKey: "key",
            session: session, storageURL: storageURL)
        await client.refreshExperiments()
        let variant = try await client.variant(for: "prompt")
        MockURLProtocol.responses = [500]
        await client.refreshExperiments()
        #expect(try await client.variant(for: "prompt") == variant)
        MockURLProtocol.body = Data("invalid json".utf8)
        await client.refreshExperiments()
        #expect(try await client.variant(for: "prompt") == variant)
        MockURLProtocol.responses = [401]
        await client.refreshExperiments()
        #expect(try await client.variant(for: "prompt") == nil)
        #expect(try StateStore(url: storageURL).load().experimentCache == nil)
    }

    @Test func experimentDoesNotAdoptUnsavedExposure() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let session = makeSession()
        MockURLProtocol.body = experimentJSON()
        let client = try GrowbaseClient(baseURL: URL(string: "https://example.com")!, trackingKey: "key",
            session: session, storageURL: directory.appendingPathComponent("state.json"))
        await client.refreshExperiments()
        try FileManager.default.removeItem(at: directory)
        await #expect(throws: Error.self) { try await client.variant(for: "prompt") }
        #expect(await client.queuedItemCount == 0)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #expect(try await client.variant(for: "prompt") != nil)
        #expect(await client.queuedItemCount == 1)
    }

    @Test func legacyStateWithoutExperimentsStillLoads() throws {
        let legacy = Data(#"{"anonymousID":"existing-install","queue":[]}"#.utf8)
        let state = try JSONDecoder().decode(ClientState.self, from: legacy)
        #expect(state.anonymousID == "existing-install")
        #expect(state.experimentCache == nil)
    }

    @Test func malformedExperimentRangesDoNotReplaceGoodCache() async throws {
        let session = makeSession()
        let client = try GrowbaseClient(baseURL: URL(string: "https://example.com")!, trackingKey: "key",
            session: session, storageURL: temporaryStorageURL())
        MockURLProtocol.body = experimentJSON()
        await client.refreshExperiments()
        let variant = try await client.variant(for: "prompt")
        MockURLProtocol.body = Data(String(decoding: experimentJSON(), as: UTF8.self)
            .replacingOccurrences(of: "\"bucket_start\":3333", with: "\"bucket_start\":3334").utf8)
        await client.refreshExperiments()
        #expect(try await client.variant(for: "prompt") == variant)
    }

    private func experimentJSON(exposurePct: Int = 100) -> Data {
        Data("""
        [{"key":"prompt","salt":"salt","config_version":1,"exposure_pct":\(exposurePct),"variants":[
          {"name":"control","bucket_start":0,"bucket_end":3332},
          {"name":"short_prompt","bucket_start":3333,"bucket_end":6665},
          {"name":"long_prompt","bucket_start":6666,"bucket_end":9999}
        ]}]
        """.utf8)
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
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var headers: [String: String] = [:]
    private static let lock = NSLock()

    static func reset() {
        lock.withLock {
            responses = []
            requests = []
            body = Data()
            headers = [:]
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let status = Self.lock.withLock { () -> Int in
            Self.requests.append(request)
            return Self.responses.isEmpty ? 200 : Self.responses.removeFirst()
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: Self.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
