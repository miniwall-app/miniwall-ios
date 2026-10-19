#if canImport(StoreKit) && os(iOS)
import Foundation
import MiniwallCore
import StoreKit

@available(iOS 15.0, macOS 12.0, *)
extension Miniwall {
    /// Turns StoreKit products into `products` for ``PresentOptions``, keyed by your package ids:
    /// `Miniwall.products(from: ["monthly": monthlyProduct, "annual": annualProduct])`.
    /// Prices, currencies, periods and introductory offers come from the App Store; Miniwall never sells.
    public static func products(from storeProducts: [String: Product]) -> [String: ProductInfo] {
        storeProducts.mapValues { product in
            let currency = product.priceFormatStyle.currencyCode
            let period = product.subscription.map { Self.period(from: $0.subscriptionPeriod) } ?? Period.lifetime
            let offer = product.subscription?.introductoryOffer.map {
                ProductInfo.Offer(price: NSDecimalNumber(decimal: $0.price).doubleValue, period: Self.period(from: $0.period))
            }
            return ProductInfo(price: NSDecimalNumber(decimal: product.price).doubleValue, currency: currency, period: period,
                               title: product.displayName, offer: offer)
        }
    }

    static func period(from p: Product.SubscriptionPeriod) -> Period {
        switch p.unit {
        case .day: return .every(.day, count: p.value)
        case .week: return .every(.week, count: p.value)
        case .month: return .every(.month, count: p.value)
        case .year: return .every(.year, count: p.value)
        @unknown default: return .every(.month, count: p.value)
        }
    }

    /// A ready `onPurchase` for StoreKit 2: buys the product of the tapped package and finishes
    /// verified transactions. Returns false when the user cancels or the purchase is pending (Ask to Buy,
    /// strong customer authentication: the screen stays open and the result arrives later through
    /// `Transaction.updates`, which your app listens to). A transaction StoreKit could not verify is not
    /// finished: this throws a ``MiniwallError`` (the screen reports it to `onError`) and StoreKit
    /// delivers the transaction again, so your app can verify it and decide. Optional: use your own billing code instead.
    public static func storeKitPurchase(_ storeProducts: [String: Product]) -> (PurchaseRequest) async throws -> Bool {
        { request in
            guard let product = storeProducts[request.packageId] else {
                throw MiniwallError("Miniwall: no StoreKit product for package \(request.packageId)")
            }
            switch try await product.purchase() {
            case let .success(verification):
                guard case let .verified(transaction) = verification else { throw MiniwallError("Miniwall: the App Store could not verify the purchase") }
                await transaction.finish()
                return true
            case .userCancelled:
                return false
            case .pending:
                // Waiting for approval: nothing was bought yet, so this is not a success. The app handles the
                // transaction when it arrives in `Transaction.updates`.
                return false
            @unknown default:
                // A result this SDK version does not know: treat it as not bought rather than granting access.
                return false
            }
        }
    }

    /// A ready `onRestore` for StoreKit 2: syncs with the App Store and reports whether any verified entitlement
    /// is active. Entitlements StoreKit could not verify are ignored (they do not count as restored).
    public static func storeKitRestore() -> () async throws -> Bool {
        {
            try await AppStore.sync()
            for await result in Transaction.currentEntitlements {
                if case .verified = result { return true }
            }
            return false
        }
    }
}
#endif
