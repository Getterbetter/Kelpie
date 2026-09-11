import Testing

@testable import Heeler

/// The product ids are a contract with App Store Connect: once a consumable is
/// created there its id can never be reused or renamed. These tests pin the
/// three literals and the order they are offered in, so a rename shows up here
/// rather than as three products that silently fail to load on device.
///
/// Pure logic — nothing here touches StoreKit.
@Suite("Tip jar tiers")
struct TipJarTests {
    @Test func tierForEachShippingProductID() {
        #expect(TipTier.tier(for: "TME.Kelpie.tip.small") == .small)
        #expect(TipTier.tier(for: "TME.Kelpie.tip.medium") == .medium)
        #expect(TipTier.tier(for: "TME.Kelpie.tip.large") == .large)
    }

    @Test func tierForAnUnknownProductIDIsNil() {
        #expect(TipTier.tier(for: "TME.Kelpie.tip.enormous") == nil)
        #expect(TipTier.tier(for: "") == nil)
        // Right suffix, wrong bundle prefix: not one of ours.
        #expect(TipTier.tier(for: "tip.small") == nil)
    }

    @Test func tiersAreOrderedSmallToLarge() {
        #expect(TipTier.allCases == [.small, .medium, .large])
        #expect(
            TipTier.productIDs == [
                "TME.Kelpie.tip.small",
                "TME.Kelpie.tip.medium",
                "TME.Kelpie.tip.large",
            ])
    }

    @Test func productIDRoundTripsThroughTier() {
        for tier in TipTier.allCases {
            #expect(TipTier.tier(for: tier.productID) == tier)
        }
    }
}
