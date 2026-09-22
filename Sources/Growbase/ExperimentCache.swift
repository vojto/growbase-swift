import CryptoKit
import Foundation

/// Persisted settings belong to one server/app and expire after 24 hours.
/// Network coordination and save-before-adopt remain owned by GrowbaseClient.
struct ExperimentCache: Codable, Sendable {
    let source: String
    var fetchedAt: Date
    let etag: String?
    let experiments: [ExperimentConfiguration]

    func experiment(for key: String, source: String, at date: Date = Date()) -> ExperimentConfiguration? {
        guard self.source == source, isFresh(at: date),
              let experiment = experiments.first(where: { $0.key == key }),
              experiment.isValid else { return nil }
        return experiment
    }

    static func source(baseURL: URL, trackingKey: String) -> String {
        SHA256.hash(data: Data("\(baseURL.absoluteString)\n\(trackingKey)".utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    private func isFresh(at date: Date) -> Bool {
        date.timeIntervalSince(fetchedAt) < 24 * 60 * 60 && date >= fetchedAt
    }
}
