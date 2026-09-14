import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum GrowbaseAnalyticsError: Error, Equatable {
    case invalidBaseURL
    case invalidTrackingKey
    case invalidValue(String)
    case valueTooLong(String)
    case payloadTooLarge
    case identityConflict
}

public actor GrowbaseAnalytics {
    private static let maximumPayloadSize = 64 * 1024
    private static let maximumStringSize = 255

    private let baseURL: URL
    private let trackingKey: String
    private let session: URLSession
    private let storageURL: URL
    private let encoder: JSONEncoder
    private let automaticallyFlush: Bool
    private var state: State
    private var isFlushing = false
    private var retryTask: Task<Void, Never>?
    private var retryAttempt = 0

    // MARK: Lifecycle

    public init(baseURL: URL, trackingKey: String) throws {
        guard let scheme = baseURL.scheme, ["http", "https"].contains(scheme), baseURL.host != nil else {
            throw GrowbaseAnalyticsError.invalidBaseURL
        }
        guard !trackingKey.isEmpty else { throw GrowbaseAnalyticsError.invalidTrackingKey }

        let storageURL = try Self.defaultStorageURL(baseURL: baseURL, trackingKey: trackingKey)
        self.baseURL = baseURL
        self.trackingKey = trackingKey
        self.session = .shared
        self.storageURL = storageURL
        self.encoder = Self.makeEncoder()
        self.automaticallyFlush = true
        self.state = try Self.loadState(from: storageURL)
        try Self.write(state, to: storageURL, using: encoder)
        Task { await self.flush() }
    }

    init(baseURL: URL, trackingKey: String, session: URLSession, storageURL: URL, automaticallyFlush: Bool = false) throws {
        self.baseURL = baseURL
        self.trackingKey = trackingKey
        self.session = session
        self.storageURL = storageURL
        self.encoder = Self.makeEncoder()
        self.automaticallyFlush = automaticallyFlush
        self.state = try Self.loadState(from: storageURL)
        try Self.write(state, to: storageURL, using: encoder)
    }

    // MARK: Public

    public func track(_ name: String, properties: [String: JSONValue] = [:]) throws {
        try Self.validate(name, field: "event name")
        try Self.validate(properties: properties)
        let event = EventPayload(
            eventID: UUID().uuidString,
            name: name,
            occurredAt: Date(),
            anonymousID: state.anonymousID,
            appUserID: state.appUserID,
            properties: properties
        )
        try validateSize(of: event)
        var proposedState = state
        proposedState.queue.append(.event(event))
        try commit(proposedState)
        startFlush()
    }

    public func identify(_ userID: String) throws {
        try Self.validate(userID, field: "user ID")
        guard state.appUserID == nil || state.appUserID == userID else {
            throw GrowbaseAnalyticsError.identityConflict
        }
        let identify = IdentifyPayload(anonymousID: state.anonymousID, appUserID: userID)
        try validateSize(of: identify)
        var proposedState = state
        proposedState.queue.append(.identify(identify))
        proposedState.appUserID = userID
        try commit(proposedState)
        startFlush()
    }

    public func reset() throws {
        var proposedState = state
        proposedState.anonymousID = UUID().uuidString
        proposedState.appUserID = nil
        try commit(proposedState)
    }

    public func flush() async {
        guard !isFlushing else { return }
        isFlushing = true
        defer { isFlushing = false }

        while let item = state.queue.first {
            switch await send(item) {
            case .acknowledge, .drop:
                var proposedState = state
                proposedState.queue.removeFirst()
                guard (try? commit(proposedState)) != nil else { return }
                retryAttempt = 0
            case .retry:
                scheduleRetry()
                return
            case .stop:
                return
            }
        }
    }

    // MARK: Sending

    private func startFlush() {
        guard automaticallyFlush, retryTask == nil else { return }
        Task { await flush() }
    }

    private func send(_ item: QueueItem) async -> SendResult {
        do {
            var request = URLRequest(url: baseURL.appendingPathComponent(item.path))
            request.httpMethod = "POST"
            request.setValue("Bearer \(trackingKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try item.requestBody(using: encoder)

            let (_, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { return .retry }
            switch response.statusCode {
            case 200..<300: return .acknowledge
            case 400, 409, 413, 422: return .drop
            case 401, 403: return .stop
            case 429, 500...599: return .retry
            default: return .drop
            }
        } catch {
            return .retry
        }
    }

    private func scheduleRetry() {
        guard retryTask == nil else { return }
        retryAttempt = min(retryAttempt + 1, 6)
        let nanoseconds = UInt64(min(pow(2.0, Double(retryAttempt - 1)), 60) * 1_000_000_000)
        retryTask = Task {
            try? await Task.sleep(nanoseconds: nanoseconds)
            retryFinished()
            await flush()
        }
    }

    private func retryFinished() {
        retryTask = nil
    }

    // MARK: Persistence

    private func commit(_ proposedState: State) throws {
        try Self.write(proposedState, to: storageURL, using: encoder)
        state = proposedState
    }

    private static func write(_ state: State, to url: URL, using encoder: JSONEncoder) throws {
        try encoder.encode(state).write(to: url, options: .atomic)
    }

    private static func loadState(from url: URL) throws -> State {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return State(anonymousID: UUID().uuidString)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(State.self, from: Data(contentsOf: url))
    }

    private static func defaultStorageURL(baseURL: URL, trackingKey: String) throws -> URL {
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("GrowbaseAnalytics", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let scope = stableHash(baseURL.absoluteString + "\u{0}" + trackingKey)
        return root.appendingPathComponent("\(scope).json")
    }

    private static func stableHash(_ value: String) -> String {
        value.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }.description
    }

    // MARK: Validation

    private static func validate(_ value: String, field: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !value.contains("\0") else {
            throw GrowbaseAnalyticsError.invalidValue(field)
        }
        guard value.lengthOfBytes(using: .utf8) <= maximumStringSize else {
            throw GrowbaseAnalyticsError.valueTooLong(field)
        }
    }

    private static func validate(properties: [String: JSONValue]) throws {
        for (key, value) in properties {
            guard !key.contains("\0") else { throw GrowbaseAnalyticsError.invalidValue("property") }
            try validate(property: value)
        }
    }

    private static func validate(property: JSONValue) throws {
        switch property {
        case .string(let value):
            guard !value.contains("\0") else { throw GrowbaseAnalyticsError.invalidValue("property") }
        case .object(let value):
            try validate(properties: value)
        case .array(let value):
            try value.forEach { try validate(property: $0) }
        case .number, .bool, .null:
            break
        }
    }

    private func validateSize<T: Encodable>(of payload: T) throws {
        guard try encoder.encode(payload).count <= Self.maximumPayloadSize else {
            throw GrowbaseAnalyticsError.payloadTooLarge
        }
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    var queuedItemCount: Int { state.queue.count }
}

private extension GrowbaseAnalytics {
    struct State: Codable {
        var anonymousID: String
        var appUserID: String?
        var queue: [QueueItem] = []
    }

    enum QueueItem: Codable {
        case event(EventPayload)
        case identify(IdentifyPayload)

        var path: String {
            switch self {
            case .event: "/api/events"
            case .identify: "/api/identify"
            }
        }

        func requestBody(using encoder: JSONEncoder) throws -> Data {
            switch self {
            case .event(let payload): try encoder.encode(payload)
            case .identify(let payload): try encoder.encode(payload)
            }
        }
    }

    struct EventPayload: Codable {
        let eventID: String
        let name: String
        let occurredAt: Date
        let anonymousID: String
        let appUserID: String?
        let properties: [String: JSONValue]

        enum CodingKeys: String, CodingKey {
            case eventID = "event_id"
            case name
            case occurredAt = "occurred_at"
            case anonymousID = "anonymous_id"
            case appUserID = "app_user_id"
            case properties
        }
    }

    struct IdentifyPayload: Codable {
        let anonymousID: String
        let appUserID: String

        enum CodingKeys: String, CodingKey {
            case anonymousID = "anonymous_id"
            case appUserID = "app_user_id"
        }
    }

    enum SendResult { case acknowledge, drop, retry, stop }
}
