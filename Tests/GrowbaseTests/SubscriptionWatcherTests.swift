import Foundation
import Testing
@testable import Growbase

struct SubscriptionWatcherTests {
    /// A purchase made inside the app may never reach the updates listener, so
    /// the watcher must find it on the next activation instead.
    @Test func checksCurrentSubscriptionsOnEveryActivation() async throws {
        let owned = Locked<[String]>(["1000"])
        let reported = Locked<[String]>([])
        let (activations, activate) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let (updates, _) = AsyncStream<String>.makeStream()

        let watcher = SubscriptionWatcher(
            activations: activations,
            currentSubscriptions: { AsyncStream { continuation in
                owned.value.forEach { continuation.yield($0) }
                continuation.finish()
            } },
            updates: updates,
            onSubscription: { id in reported.mutate { $0.append(id) } }
        )

        activate.yield()
        try await waitUntil { reported.value == ["1000"] }

        owned.value = ["1000", "2000"]
        activate.yield()
        try await waitUntil { reported.value == ["1000", "1000", "2000"] }
        _ = watcher
    }

    @Test func reportsTransactionUpdates() async throws {
        let reported = Locked<[String]>([])
        let (updates, update) = AsyncStream<String>.makeStream()

        let watcher = SubscriptionWatcher(
            activations: AsyncStream { $0.finish() },
            currentSubscriptions: { AsyncStream { $0.finish() } },
            updates: updates,
            onSubscription: { id in reported.mutate { $0.append(id) } }
        )

        update.yield("3000")
        try await waitUntil { reported.value == ["3000"] }
        _ = watcher
    }
}

private final class Locked<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) { storage = value }

    var value: Value {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }

    func mutate(_ change: (inout Value) -> Void) {
        lock.withLock { change(&storage) }
    }
}

private func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<200 {
        if condition() { return }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    Issue.record("Condition not met in time")
}
