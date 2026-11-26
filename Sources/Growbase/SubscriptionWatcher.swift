import Foundation
#if canImport(StoreKit)
import StoreKit
#endif
#if canImport(UIKit) && !os(watchOS)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/*
 * Finds the App Store subscriptions this device owns and reports each one's
 * original transaction ID. Apple's server notifications only carry that ID,
 * so this is what ties revenue to a Growbase customer.
 * Reads the current subscriptions at launch and again every time the app
 * becomes active, and listens for transaction updates. Apple doesn't always
 * send a purchase made inside the app to the updates listener, but the App
 * Store purchase sheet makes the app inactive, so the check that runs when
 * the sheet closes picks the new subscription up.
 * It only reads: it never finishes transactions, so it works next to any
 * purchase code.
 */
final class SubscriptionWatcher: Sendable {
    typealias Report = @Sendable (String) async -> Void

    private let tasks: [Task<Void, Never>]

    // MARK: Lifecycle

    /// - Parameters:
    ///   - activations: yields each time the subscriptions should be checked.
    ///   - currentSubscriptions: reads the original transaction IDs owned now.
    ///   - updates: original transaction IDs of new transactions as they arrive.
    init(
        activations: AsyncStream<Void>,
        currentSubscriptions: @escaping @Sendable () -> AsyncStream<String>,
        updates: AsyncStream<String>,
        onSubscription: @escaping Report
    ) {
        tasks = [
            Task {
                for await _ in activations {
                    for await id in currentSubscriptions() { await onSubscription(id) }
                }
            },
            Task {
                for await id in updates { await onSubscription(id) }
            },
        ]
    }

    convenience init(onSubscription: @escaping Report) {
        self.init(
            activations: Self.appActivations(),
            currentSubscriptions: Self.storeKitCurrentSubscriptions,
            updates: Self.storeKitUpdates(),
            onSubscription: onSubscription
        )
    }

    deinit {
        tasks.forEach { $0.cancel() }
    }

    // MARK: Sources

    /// Yields once now and again whenever the app becomes active. Activations
    /// that pile up during a slow check collapse into one.
    static func appActivations() -> AsyncStream<Void> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            continuation.yield()
            #if canImport(UIKit) && !os(watchOS)
            let name = UIApplication.didBecomeActiveNotification
            #elseif canImport(AppKit)
            let name = NSApplication.didBecomeActiveNotification
            #endif
            #if (canImport(UIKit) && !os(watchOS)) || canImport(AppKit)
            let task = Task {
                for await _ in NotificationCenter.default.notifications(named: name) { continuation.yield() }
            }
            continuation.onTermination = { _ in task.cancel() }
            #endif
        }
    }

    private static func storeKitCurrentSubscriptions() -> AsyncStream<String> {
        AsyncStream { continuation in
            let task = Task {
                #if canImport(StoreKit)
                for await result in Transaction.currentEntitlements {
                    if let id = subscriptionID(result) { continuation.yield(id) }
                }
                #endif
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func storeKitUpdates() -> AsyncStream<String> {
        AsyncStream { continuation in
            let task = Task {
                #if canImport(StoreKit)
                for await result in Transaction.updates {
                    if let id = subscriptionID(result) { continuation.yield(id) }
                }
                #endif
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    #if canImport(StoreKit)
    private static func subscriptionID(_ result: VerificationResult<Transaction>) -> String? {
        guard case .verified(let transaction) = result, transaction.productType == .autoRenewable else { return nil }
        return String(transaction.originalID)
    }
    #endif
}
