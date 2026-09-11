import SwiftUI

/// The tip jar sheet: three consumable In-App Purchases that buy nothing.
///
/// Deliberately plain. Kelpie is free and the tip is a courtesy, so the screen
/// says so in two sentences and then gets out of the way — no pleading, no
/// badge, no "supporter" tier. Every StoreKit type stays behind ``TipJarStore``;
/// this view only ever sees strings and a ``TipTier``.
struct TipJarView: View {
    let store: TipJarStore

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            // A ScrollView, not a fixed VStack: at the largest Dynamic Type
            // sizes three labelled buttons do not fit a form sheet, and
            // scrolling is the right answer rather than shrinking the text.
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if store.phase == .thanked {
                        thanks
                    } else {
                        blurb
                        tipButtons
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .navigationTitle("Tip the developer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(store.phase == .thanked ? "Done" : "Close") { dismiss() }
                }
            }
        }
        // iPad presents sheets as page-sized forms; `presentationDetents`
        // only applies in compact width, so the size is set here instead.
        .presentationSizing(.form)
        .task { await store.load() }
    }

    private var blurb: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Kelpie is free and open source, and it stays that way.")
            Text("A tip just says thanks. It unlocks nothing.")
        }
        .font(.body)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var tipButtons: some View {
        if let loadError = store.loadError {
            Text(loadError)
                .font(.body)
                .foregroundStyle(.secondary)
        } else if store.phase == .loading {
            ProgressView()
                .frame(maxWidth: .infinity, alignment: .center)
        } else {
            VStack(spacing: 12) {
                ForEach(store.tiers, id: \.self) { tier in
                    tipButton(tier)
                }
            }
            if let purchaseError = store.purchaseError {
                Text(purchaseError)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func tipButton(_ tier: TipTier) -> some View {
        let isPurchasing = store.phase == .purchasing(tier)
        return Button {
            Task { await store.purchase(tier) }
        } label: {
            // ViewThatFits so a long localized name and price stack instead of
            // truncating once Dynamic Type runs out of row.
            ViewThatFits(in: .horizontal) {
                HStack {
                    Text(store.displayName(for: tier))
                    Spacer(minLength: 12)
                    trailing(for: tier, isPurchasing: isPurchasing)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(store.displayName(for: tier))
                    trailing(for: tier, isPurchasing: isPurchasing)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
        // Only the tier being bought shows a spinner, but no tier is tappable
        // while the App Store sheet is up.
        .disabled(isPurchasingAnything)
        .accessibilityLabel(
            "\(store.displayName(for: tier)), \(store.displayPrice(for: tier))")
    }

    @ViewBuilder
    private func trailing(for tier: TipTier, isPurchasing: Bool) -> some View {
        if isPurchasing {
            ProgressView()
        } else {
            Text(store.displayPrice(for: tier))
                .foregroundStyle(.secondary)
        }
    }

    private var isPurchasingAnything: Bool {
        if case .purchasing = store.phase { return true }
        return false
    }

    private var thanks: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Thank you", systemImage: "heart")
                .font(.title2)
            Text("That's genuinely appreciated. Nothing about Kelpie has changed.")
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview {
    TipJarView(store: TipJarStore())
}
