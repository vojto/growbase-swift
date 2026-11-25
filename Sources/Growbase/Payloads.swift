import Foundation

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

struct SubscriptionPayload: Codable {
    let anonymousID: String
    let appUserID: String?
    let originalTransactionID: String

    enum CodingKeys: String, CodingKey {
        case anonymousID = "anonymous_id"
        case appUserID = "app_user_id"
        case originalTransactionID = "original_transaction_id"
    }
}
