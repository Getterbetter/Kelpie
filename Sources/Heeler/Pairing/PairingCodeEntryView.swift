import SwiftUI
import UIKit

/// The paste-first entry for a Pairing Code. Scanning the QR needs the Mac's
/// herdr window in front of the camera; copying the code and pasting it works
/// across the room, and with iCloud universal clipboard it is already on this
/// iPad by the time the popup closes. So paste is the primary action, typing
/// the code is the fallback, and the camera is one tap away.
///
/// Every route here ends in `PairingScanStore.submit(scannedCode:)` — the
/// same parse the scanner uses, so the two can never disagree.
struct PairingCodeEntryView: View {
    let store: PairingScanStore
    let onScanInstead: () -> Void

    @State private var typedCode = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(spacing: 8) {
                    Image(systemName: "doc.on.clipboard")
                        .font(.largeTitle)
                        .foregroundStyle(.tint)
                    Text("Paste the Pairing Code")
                        .font(.title2.bold())
                        .multilineTextAlignment(.center)
                    Text(
                        "Press C in herdr's pairing popup on the Mac to copy it. "
                            + "With iCloud clipboard on it is already here.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                Button {
                    submit(UIPasteboard.general.string)
                } label: {
                    Label("Paste", systemImage: "doc.on.clipboard")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                if let message = store.scanFailureMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 10) {
                    TextField("Or type it here", text: $typedCode, axis: .vertical)
                        .font(.system(.footnote, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .lineLimit(3...6)
                        .padding(10)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                    Button("Continue") { submit(typedCode) }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .frame(maxWidth: .infinity)
                        .disabled(
                            typedCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                Button("Scan QR Code instead") { onScanInstead() }
                    .buttonStyle(.borderless)
            }
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.vertical, 28)
        }
    }

    private func submit(_ candidate: String?) {
        let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return }
        store.submit(scannedCode: trimmed)
    }
}
