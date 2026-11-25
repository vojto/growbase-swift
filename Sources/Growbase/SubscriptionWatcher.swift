#if canImport(StoreKit)
import StoreKit
#endif

/*
 * Finds the App Store subscriptions this device owns and reports each one's
 * original transaction ID. Apple's server notifications only carry that ID,
 * so this is what ties revenue to a Growbase customer.
 * Reads StoreKit at launch and then listens for new purchases. It only reads:
 * it never finishes transactions, so it works next to RevenueCat or any
 * other purchase code.
 */
final class SubscriptionWatcher: Sendable {
    private let task: Task<Void, Never>

    // MARK: Lifecycle

    init(onSubscription: @escaping @Sendable (String) async -> Void) {
        task = Task {
            #if canImport(StoreKit)
            for await result in Transaction.currentEntitlements {
                await Self.report(result, to: onSubscription)
            }
            for await result in Transaction.updates {
                await Self.report(result, to: onSubscription)
            }
            #endif
        }
    }

    deinit {
        task.cancel()
    }

    // MARK: Private

    #if canImport(StoreKit)
    private static func report(
        _ result: VerificationResult<Transaction>,
        to onSubscription: @Sendable (String) async -> Void
    ) async {
        guard case .verified(let transaction) = result, transaction.productType == .autoRenewable else { return }
        await onSubscription(String(transaction.originalID))
    }
    #endif
}
