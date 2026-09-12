import SwiftUI
import UIKit

/// The zero-Host screen, and the same content again behind the menu's Setup
/// Guide. Kelpie's first run needs the *Mac* set up — herdr running, Remote
/// Login on, the pairing plugin installed — and nothing in the app used to
/// say so: the Console's "No Hosts" panel offered Add Host and left the rest
/// to guesswork. This view leads with the plugin and the Pairing Code, and
/// keeps manual SSH as the secondary way in.
///
/// Content only. Presenting Scan to Pair, the paste entry or the manual form
/// is the presenter's job, reported through ``Action``.
struct WelcomeView: View {
    enum Presentation {
        /// The app's root, with no navigation chrome of its own.
        case root
        /// A sheet from the Kelpie menu, with a title and Done.
        case sheet
    }

    enum Action {
        case pasteCode
        case scanCode
        case addManually
    }

    let hosts: HostStore
    let presentation: Presentation
    let onAction: (Action) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        switch presentation {
        case .root:
            content
        case .sheet:
            NavigationStack {
                content
                    .navigationTitle("Setup Guide")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { dismiss() }
                        }
                    }
            }
        }
    }

    private var content: some View {
        ScrollView {
            VStack(spacing: 28) {
                hero
                macSection
                iPadSection
                Text("Notifications need the same plugin; nothing else is required on the Mac.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.vertical, 32)
        }
        .background(Color(.systemGroupedBackground))
    }

    private var hero: some View {
        VStack(spacing: 12) {
            Image(systemName: "server.rack")
                .font(.largeTitle)
                .foregroundStyle(.tint)
            Text("Kelpie")
                .font(.largeTitle.bold())
            Text("herdr on your Mac, full screen on your iPad or iPhone.")
                .font(.title3)
                .multilineTextAlignment(.center)
            Text(
                "You need a Mac with herdr running and Remote Login turned on. "
                    + "Kelpie connects over SSH, opens herdr's own screen, and keeps it there.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var macSection: some View {
        card(title: "On your Mac") {
            VStack(alignment: .leading, spacing: 20) {
                SetupStep(
                    number: 1,
                    title: "Turn on Remote Login",
                    description:
                        "System Settings → General → Sharing → Remote Login. The Pairing Code "
                        + "pins this Mac's SSH host key, so this must be on before you make a code.",
                    command: nil)
                SetupStep(
                    number: 2,
                    title: "Install the pairing plugin",
                    description: "Run this once in any terminal on the Mac.",
                    command: "herdr plugin install ZingerLittleBee/Heeler/plugin --ref main --yes")
                SetupStep(
                    number: 3,
                    title: "Make a Pairing Code",
                    description:
                        "The popup opens inside herdr's own window, not in the shell. Press Return "
                        + "to make a code, then press C to copy it. With iCloud clipboard on, it is "
                        + "already on this device.",
                    command: "herdr plugin action invoke heeler.pair")
            }
        }
    }

    private var iPadSection: some View {
        card(title: "On this device") {
            VStack(alignment: .leading, spacing: 14) {
                Text("Pair with the code you just copied, or add the Mac over SSH yourself.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button {
                    onAction(.pasteCode)
                } label: {
                    Label("Paste Pairing Code", systemImage: "doc.on.clipboard")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                Button {
                    onAction(.scanCode)
                } label: {
                    Label("Scan QR Code", systemImage: "qrcode.viewfinder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                Button("Add manually over SSH") { onAction(.addManually) }
                    .buttonStyle(.borderless)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func card<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.title3.bold())
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(.background, in: RoundedRectangle(cornerRadius: 16))
    }
}

/// One numbered step in the Mac checklist, with the command it runs (if any)
/// in a copyable row.
private struct SetupStep: View {
    let number: Int
    let title: String
    let description: String
    let command: String?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(String(number))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(minWidth: 26, minHeight: 26)
                .background(Circle().fill(.tint))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.headline)
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let command {
                    CommandRow(command: command)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Not combined: the Copy button inside a command row must stay its
        // own VoiceOver element.
    }
}

/// A shell command, selectable and horizontally scrollable so a narrow screen
/// never forces a wrap mid-flag, with a Copy button that confirms itself.
private struct CommandRow: View {
    let command: String

    @State private var didCopy = false
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            ScrollView(.horizontal) {
                Text(command)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)
            Button {
                copy()
            } label: {
                Label(
                    didCopy ? "Copied" : "Copy",
                    systemImage: didCopy ? "checkmark" : "doc.on.doc")
                    .font(.footnote)
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(didCopy ? "Copied" : "Copy command")
        }
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
        .onDisappear { resetTask?.cancel() }
    }

    private func copy() {
        UIPasteboard.general.string = command
        didCopy = true
        resetTask?.cancel()
        resetTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1_500))
            guard !Task.isCancelled else { return }
            didCopy = false
        }
    }
}
