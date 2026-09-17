import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum GrowbaseClientError: Error, Equatable {
    case invalidBaseURL
    case invalidTrackingKey
    case invalidValue(String)
    case valueTooLong(String)
    case payloadTooLarge
    case identityConflict
}

public actor GrowbaseClient {
    private static let maximumPayloadSize = 64 * 1024
    private static let maximumQueueSize = 1_000
    private static let maximumStringSize = 255

    private let baseURL: URL
    private let trackingKey: String
    private let session: URLSession
    private let storageURL: URL
    private let encoder: JSONEncoder
    private let automaticallyFlush: Bool
    private let maximumQueueSize: Int
    private var state: State
    private var isFlushing = false
    private var retryTask: Task<Void, Never>?
    private var retryAttempt = 0

    // MARK: Lifecycle

    public init(baseURL: URL, trackingKey: String) throws {
        guard let scheme = baseURL.scheme, ["http", "https"].contains(scheme), baseURL.host != nil else {
            throw GrowbaseClientError.invalidBaseURL
        }
        guard !trackingKey.isEmpty else { throw GrowbaseClientError.invalidTrackingKey }

        let storageURL = try Self.defaultStorageURL()
        try self.init(
            baseURL: baseURL,
            trackingKey: trackingKey,
            session: .shared,
            storageURL: storageURL,
            automaticallyFlush: true
        )
        Task { await self.flush() }
    }

    init(
        baseURL: URL,
        trackingKey: String,
        session: URLSession,
        storageURL: URL,
        automaticallyFlush: Bool = false,
        maximumQueueSize: Int = GrowbaseClient.maximumQueueSize
    ) throws {
        self.baseURL = baseURL
        self.trackingKey = trackingKey
        self.session = session
        self.storageURL = storageURL
        self.encoder = Self.makeEncoder()
        self.automaticallyFlush = automaticallyFlush
        self.maximumQueueSize = maximumQueueSize
        var state = try Self.loadState(from: storageURL)
        Self.trimQueue(&state.queue, to: maximumQueueSize)
        self.state = state
        try Self.write(state, to: storageURL, using: encoder)
    }

    // MARK: Testing

    var queuedItemCount: Int { state.queue.count }

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
        try updateState { enqueue(.event(event), in: &$0) }
        startFlush()
    }

    public func identify(_ userID: String, email: String? = nil) throws {
        try Self.validate(userID, field: "user ID")
        if let email { try Self.validate(email, field: "email") }
        guard state.appUserID == nil || state.appUserID == userID else {
            throw GrowbaseClientError.identityConflict
        }
        let identify = IdentifyPayload(anonymousID: state.anonymousID, appUserID: userID, email: email)
        try validateSize(of: identify)
        try updateState {
            enqueue(.identify(identify), in: &$0)
            $0.appUserID = userID
        }
        startFlush()
    }

    public func reset() throws {
        try updateState {
            $0.anonymousID = UUID().uuidString
            $0.appUserID = nil
        }
    }

    public func flush() async {
        guard !isFlushing else { return }
        isFlushing = true
        defer { isFlushing = false }

        while let item = state.queue.first {
            switch await send(item) {
            case .acknowledge, .drop:
                guard (try? updateState { $0.queue.removeFirst() }) != nil else { return }
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
            retryTask = nil
            await flush()
        }
    }

    // MARK: Persistence

    private func enqueue(_ item: QueueItem, in state: inout State) {
        state.queue.append(item)
        Self.trimQueue(&state.queue, to: maximumQueueSize)
    }

    private static func trimQueue(_ queue: inout [QueueItem], to maximumSize: Int) {
        while queue.count > maximumSize {
            if let oldestEventIndex = queue.firstIndex(where: \.isEvent) {
                queue.remove(at: oldestEventIndex)
            } else {
                queue.removeFirst()
            }
        }
    }

    /// Applies `mutate` to a copy of the state and only adopts it once it has been persisted,
    /// so a failed write leaves the in-memory state untouched.
    private func updateState(_ mutate: (inout State) -> Void) throws {
        var proposedState = state
        mutate(&proposedState)
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

    private static func defaultStorageURL() throws -> URL {
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("GrowbaseClient", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent("state.json")
    }

    // MARK: Validation

    private static func validate(_ value: String, field: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !value.contains("\0") else {
            throw GrowbaseClientError.invalidValue(field)
        }
        guard value.lengthOfBytes(using: .utf8) <= maximumStringSize else {
            throw GrowbaseClientError.valueTooLong(field)
        }
    }

    private static func validate(properties: [String: JSONValue]) throws {
        for (key, value) in properties {
            guard !key.contains("\0") else { throw GrowbaseClientError.invalidValue("property") }
            try validate(property: value)
        }
    }

    private static func validate(property: JSONValue) throws {
        switch property {
        case .string(let value):
            guard !value.contains("\0") else { throw GrowbaseClientError.invalidValue("property") }
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
            throw GrowbaseClientError.payloadTooLarge
        }
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension GrowbaseClient {
    struct State: Codable {
        var anonymousID: String
        var appUserID: String?
        var queue: [QueueItem] = []
    }

    enum QueueItem: Codable {
        case event(EventPayload)
        case identify(IdentifyPayload)

        var isEvent: Bool {
            if case .event = self { true } else { false }
        }

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
        let email: String?

        enum CodingKeys: String, CodingKey {
            case anonymousID = "anonymous_id"
            case appUserID = "app_user_id"
            case email
        }
    }

    enum SendResult { case acknowledge, drop, retry, stop }
}
