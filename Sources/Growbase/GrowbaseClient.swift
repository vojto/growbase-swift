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
    private let experimentSource: String
    private let session: URLSession
    private let stateStore: StateStore
    private let encoder: JSONEncoder
    private let shouldAutomaticallyFlush: Bool
    private let queueLimit: Int
    private var state: ClientState
    private var isFlushing = false
    private var retryTask: Task<Void, Never>?
    private var retryAttempt = 0
    private var experimentsRefreshTask: Task<Void, Never>?
    private var exposedExperiments: Set<String> = []

    // MARK: Lifecycle

    public init(baseURL: URL, trackingKey: String) throws {
        guard let scheme = baseURL.scheme, ["http", "https"].contains(scheme), baseURL.host != nil else {
            throw GrowbaseClientError.invalidBaseURL
        }
        guard !trackingKey.isEmpty else { throw GrowbaseClientError.invalidTrackingKey }

        let storageURL = try StateStore.defaultStorageURL()
        try self.init(
            baseURL: baseURL,
            trackingKey: trackingKey,
            session: .shared,
            storageURL: storageURL,
            automaticallyFlush: true
        )
        Task { await self.flush() }
        Task { await self.refreshExperiments() }
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
        self.experimentSource = ExperimentCache.source(baseURL: baseURL, trackingKey: trackingKey)
        self.session = session
        self.stateStore = StateStore(url: storageURL)
        self.encoder = Self.makeEncoder()
        self.shouldAutomaticallyFlush = automaticallyFlush
        self.queueLimit = maximumQueueSize
        var state = try stateStore.load()
        state.trimQueue(to: maximumQueueSize)
        self.state = state
        try stateStore.save(state)
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
        try updateState { $0.enqueue(.event(event), maximumCount: queueLimit) }
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
            $0.enqueue(.identify(identify), maximumCount: queueLimit)
            $0.appUserID = userID
        }
        startFlush()
    }

    public func reset() throws {
        try updateState {
            $0.anonymousID = UUID().uuidString
            $0.appUserID = nil
        }
        exposedExperiments.removeAll()
    }

    // MARK: Experiments

    /// Refresh at launch and whenever the app returns to the foreground.
    /// Network failures retain the last configuration, usable for up to 24 hours.
    public func refreshExperiments() async {
        if let task = experimentsRefreshTask {
            await task.value
            return
        }
        let task = Task { await fetchExperiments() }
        experimentsRefreshTask = task
        await task.value
        experimentsRefreshTask = nil
    }

    /// Evaluate only when the experience will be shown. A successful evaluation
    /// queues one exposure per experiment per client lifetime (or after reset).
    /// nil means to show control without recording an exposure.
    public func variant(for key: String) throws -> String? {
        guard let experiment = state.experimentCache?.experiment(for: key, source: experimentSource),
              let variant = experiment.variant(for: state.anonymousID) else { return nil }

        if !exposedExperiments.contains(key) {
            try track("$experiment_exposure", properties: [
                "experiment": .string(key),
                "variant": .string(variant),
                "config_version": .number(Double(experiment.configVersion)),
            ])
            exposedExperiments.insert(key)
        }
        return variant
    }

    // MARK: Delivery

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

    // MARK: Testing

    var queuedItemCount: Int { state.queue.count }

    // MARK: Experiment settings

    private func fetchExperiments() async {
        var request = URLRequest(url: baseURL.appendingPathComponent("/api/experiments"))
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 10
        request.setValue("Bearer \(trackingKey)", forHTTPHeaderField: "Authorization")
        let cache = state.experimentCache.flatMap { $0.source == experimentSource ? $0 : nil }
        if let etag = cache?.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }

        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { return }
            if response.statusCode == 304, var cache {
                cache.fetchedAt = Date()
                try updateState { $0.experimentCache = cache }
            } else if response.statusCode == 200 {
                let experiments = try JSONDecoder().decode([ExperimentConfiguration].self, from: data)
                guard experiments.allSatisfy(\.isValid),
                      Set(experiments.map(\.key)).count == experiments.count else { return }
                let updated = ExperimentCache(source: experimentSource, fetchedAt: Date(),
                    etag: response.value(forHTTPHeaderField: "ETag"), experiments: experiments)
                try updateState { $0.experimentCache = updated }
            } else if [401, 403].contains(response.statusCode) {
                try updateState { $0.experimentCache = nil }
            }
        } catch {
            // Keep the last successfully saved configuration on network or disk failure.
        }
    }

    // MARK: Sending

    private enum SendResult { case acknowledge, drop, retry, stop }

    private func startFlush() {
        guard shouldAutomaticallyFlush, retryTask == nil else { return }
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

    /// Applies `mutate` to a copy of the state and only adopts it once it has been persisted,
    /// so a failed write leaves the in-memory state untouched.
    private func updateState(_ mutate: (inout ClientState) -> Void) throws {
        var proposedState = state
        mutate(&proposedState)
        try stateStore.save(proposedState)
        state = proposedState
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
