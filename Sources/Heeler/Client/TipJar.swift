import Foundation
import Observation
import StoreKit

/// The three tips, smallest first. The raw value is the App Store Connect
/// product id, and this enum is the only place in the app that spells one.
///
/// All three are **consumables**: a tip is a thank-you and unlocks nothing, so
/// there is nothing to restore and no entitlement to record. That is also why
/// the app never asks `Transaction.currentEntitlements` — a finished consumable
/// leaves no trace there by design.
enum TipTier: String, CaseIterable, Sendable {
    case small = "TME.Kelpie.tip.small"
    case medium = "TME.Kelpie.tip.medium"
    case large = "TME.Kelpie.tip.large"

    /// Every product id Kelpie asks the App Store about, small → large.
    static var productIDs: [String] { allCases.map(\.rawValue) }

    /// The tier a StoreKit product id names, or `nil` for anything else —
    /// including a product from a future build that this one cannot sell.
    static func tier(for productID: String) -> TipTier? {
        TipTier(rawValue: productID)
    }

    /// Same string as `rawValue`; named for what it is at the call sites that
    /// hand it to StoreKit.
    var productID: String { rawValue }
}

/// Owns the tip jar's StoreKit work so no view has to import StoreKit.
///
/// Created once where the other client stores live (`ContentView`) and passed
/// down explicitly, the way `HardwareKeyboardObserver` is: the sheet comes and
/// goes, and re-fetching three products every time it opens would put a spinner
/// in front of a courtesy.
@MainActor
@Observable
final class TipJarStore {
    /// What the sheet should be showing. `thanked` is the end of a successful
    /// purchase and is cleared by the next `load()`, so reopening the sheet
    /// does not reopen on somebody's old thank-you.
    enum Phase: Equatable, Sendable {
        case idle
        case loading
        case purchasing(TipTier)
        case thanked
    }

    /// The copy shown when the products cannot be fetched — no account, no
    /// network, or the products not yet approved in App Store Connect. All of
    /// those look the same from here and none of them is the user's problem.
    static let unavailableMessage = "Tips aren't available right now."

    private(set) var phase: Phase = .idle

    /// Loaded tiers, small → large. Only tiers the App Store actually returned
    /// a product for; empty until `load()` succeeds.
    private(set) var tiers: [TipTier] = []

    /// Non-nil when the products could not be loaded. Carries
    /// ``unavailableMessage``; the failure reason is deliberately not shown.
    private(set) var loadError: String?

    /// Non-nil when a purchase failed for a reason worth saying out loud. A
    /// cancel and a pending (Ask to Buy) purchase both leave this nil.
    private(set) var purchaseError: String?

    @ObservationIgnored private var products: [TipTier: Product] = [:]

    /// The `Transaction.updates` listener, started once in `init`. Held only so
    /// `deinit` can cancel it; `deinit` is nonisolated and nothing else touches
    /// it, so the unchecked spelling is the honest one (same as
    /// `HardwareKeyboardObserver.observers`).
    @ObservationIgnored private nonisolated(unsafe) var updates: Task<Void, Never>?

    init() {
        // StoreKit delivers transactions that completed outside a `purchase()`
        // call here — one approved by Ask to Buy, or finished while the app was
        // away. A consumable that is never finished is re-delivered forever, so
        // every tip that arrives is finished on sight.
        updates = Task { [weak self] in
            for await update in Transaction.updates {
                guard let self else { return }
                await self.finishIfTip(update)
            }
        }
    }

    deinit {
        updates?.cancel()
    }

    /// Fetches the three products, once per process. Also the sheet's reset:
    /// every presentation starts on the tier list rather than on the last
    /// purchase's outcome.
    func load() async {
        purchaseError = nil
        phase = .idle
        guard products.isEmpty else { return }

        phase = .loading
        defer { phase = .idle }
        do {
            let fetched = try await Product.products(for: TipTier.productIDs)
            var byTier: [TipTier: Product] = [:]
            for product in fetched {
                guard let tier = TipTier.tier(for: product.id) else { continue }
                byTier[tier] = product
            }
            products = byTier
            // `TipTier.allCases` is the order, not the order the App Store
            // happened to answer in.
            tiers = TipTier.allCases.filter { byTier[$0] != nil }
            loadError = tiers.isEmpty ? Self.unavailableMessage : nil
        } catch {
            products = [:]
            tiers = []
            loadError = Self.unavailableMessage
        }
    }

    /// The App Store's own name for a tier, localized. Empty before `load()`.
    func displayName(for tier: TipTier) -> String {
        products[tier]?.displayName ?? ""
    }

    /// The price in the user's storefront and currency, formatted by StoreKit.
    /// Never derive this from a number in the app — the App Store owns it.
    func displayPrice(for tier: TipTier) -> String {
        products[tier]?.displayPrice ?? ""
    }

    /// Buys one tip. A cancel and a pending purchase are answered by simply
    /// returning to the tier list: neither is a failure the user needs told.
    func purchase(_ tier: TipTier) async {
        if case .purchasing = phase { return }
        guard let product = products[tier] else { return }

        purchaseError = nil
        phase = .purchasing(tier)
        do {
            switch try await product.purchase() {
            case .success(let verification):
                switch verification {
                case .verified(let transaction):
                    await transaction.finish()
                    phase = .thanked
                case .unverified(let transaction, _):
                    // Finished anyway: a tip unlocks nothing, and an
                    // unfinished consumable is re-delivered on every launch.
                    await transaction.finish()
                    phase = .idle
                    purchaseError = "The App Store couldn't verify that tip."
                }
            case .userCancelled, .pending:
                phase = .idle
            @unknown default:
                phase = .idle
            }
        } catch {
            phase = .idle
            purchaseError = "That tip didn't go through."
        }
    }

    /// Finishes a tip that arrived outside `purchase(_:)`, verified or not:
    /// a tip unlocks nothing, so there is nothing to protect by leaving an
    /// unverified one pending, and an unfinished consumable is re-delivered
    /// on every launch. Products this build does not sell are left alone.
    private func finishIfTip(_ update: VerificationResult<Transaction>) async {
        let transaction = switch update {
        case .verified(let transaction): transaction
        case .unverified(let transaction, _): transaction
        }
        guard TipTier.tier(for: transaction.productID) != nil else { return }
        await transaction.finish()
    }
}
