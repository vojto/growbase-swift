import Foundation

struct ClientState: Codable {
    var anonymousID: String
    var appUserID: String?
    var queue: [QueueItem] = []

    mutating func enqueue(_ item: QueueItem, maximumCount: Int) {
        queue.append(item)
        trimQueue(to: maximumCount)
    }

    mutating func trimQueue(to maximumCount: Int) {
        while queue.count > maximumCount {
            queue.remove(at: queue.firstIndex(where: \.isEvent) ?? queue.startIndex)
        }
    }
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
