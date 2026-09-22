import CryptoKit
import Foundation

struct ExperimentConfiguration: Codable, Sendable {
    let key: String
    let salt: String
    let configVersion: Int
    let exposurePct: Int
    let variants: [Variant]

    struct Variant: Codable, Sendable {
        let name: String
        let bucketStart: Int
        let bucketEnd: Int

        enum CodingKeys: String, CodingKey {
            case name
            case bucketStart = "bucket_start"
            case bucketEnd = "bucket_end"
        }
    }

    enum CodingKeys: String, CodingKey {
        case key, salt, variants
        case configVersion = "config_version"
        case exposurePct = "exposure_pct"
    }

    var isValid: Bool {
        guard !key.isEmpty, !salt.isEmpty, configVersion > 0,
              (0...100).contains(exposurePct), variants.count >= 2,
              variants.filter({ $0.name == "control" }).count == 1,
              Set(variants.map(\.name)).count == variants.count else { return false }
        var nextBucket = 0
        for variant in variants.sorted(by: { $0.bucketStart < $1.bucketStart }) {
            guard !variant.name.isEmpty, variant.bucketStart == nextBucket,
                  variant.bucketEnd >= variant.bucketStart, variant.bucketEnd < 10_000 else { return false }
            nextBucket = variant.bucketEnd + 1
        }
        return nextBucket == 10_000
    }

    func variant(for anonymousID: String) -> String? {
        guard Self.bucket("expose:\(key):\(salt):\(anonymousID)") < exposurePct * 100 else { return nil }
        let bucket = Self.bucket("split:\(key):\(salt):\(anonymousID)")
        return variants.first { $0.bucketStart <= bucket && bucket <= $0.bucketEnd }?.name
    }

    static func bucket(_ input: String) -> Int {
        let prefix = SHA256.hash(data: Data(input.utf8)).prefix(4)
        return Int(prefix.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } % 10_000)
    }
}
