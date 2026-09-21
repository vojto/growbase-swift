import Foundation

/// Reads and writes the durable identity and queue. The client owns the in-memory state.
struct StateStore {
    let url: URL

    func load() throws -> ClientState {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return ClientState(anonymousID: UUID().uuidString)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ClientState.self, from: Data(contentsOf: url))
    }

    func save(_ state: ClientState) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(state).write(to: url, options: .atomic)
    }

    static func defaultStorageURL() throws -> URL {
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("GrowbaseClient", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent("state.json")
    }
}
