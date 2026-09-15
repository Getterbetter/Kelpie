import SwiftUI
import UIKit

/// herdr's own client, full screen: its workspaces sidebar, tabs and panes,
/// exactly as they look in a desktop terminal. The iPad's job here is to make
/// that surface reachable — nothing of Heeler's native Console (Agent
/// switcher, Composer, message-jump) is on it, because herdr already draws its
/// own equivalents.
///
/// The keyboard chrome appears only when there is no hardware keyboard: a
/// Magic Keyboard makes every key redundant and the screen space expensive.
/// It is one row and one row only — ``TerminalKeyBar``, riding the software
/// keyboard itself, drawn as keyboard keys and carrying Paste. A second row
/// of app content above it read as a stack of unrelated bars.
struct HerdrClientView: View {
    let store: HerdrClientStore
    let terminal: TerminalSettings
    let activity: AppActivityCoordinator
    let hardwareKeyboard: HardwareKeyboardObserver
    /// A tapped absolute path on the Host, for the file viewer the screen above owns.
    let onHostPathTap: (String) -> Void
    /// Owned by the view above so the media store built alongside `store` can
    /// read the live bracketed-paste mode from the same handle this screen
    /// drives the keyboard with.
    let keyboardControl: TerminalKeyboardControl
    let media: HerdrMediaStagingStore

    @State private var keyboardInset = TerminalKeyboardInset()
    @Environment(\.colorScheme) private var colorScheme
    /// One Ghostty surface the screen has mounted: the store's pipeline it
    /// belongs to and the byte feed it draws.
    private struct MountedSurface: Identifiable {
        let id: TerminalSurfaceID
        let feed: TerminalByteFeed
    }
    /// The surface for the store's current pipeline. State rather than a
    /// read of the store, so a replacement mounts one frame after the store
    /// announces it and the outgoing surface is never dismantled first.
    @State private var currentSurface: MountedSurface?
    /// The surface a replacement retired, kept mounted over the new one so
    /// its last frame stays on screen until the replacement paints. A
    /// reconnect after the background grace period, or after the Console
    /// cover, otherwise shows a blank terminal under a Connecting card
    /// (Open item 35). Ghostty draws only when bytes arrive, and a retired
    /// feed is silent, so the frame holds. Its surface is not snapshotted:
    /// `snapshotView` of the Metal layer came back blank on the device.
    @State private var retiredSurface: MountedSurface?
    /// Whether the current surface has ever painted. Only such a surface is
    /// worth retiring; a replacement that never went live is blank.
    @State private var currentSurfaceHasBeenLive = false
    /// Whether the Connecting card has earned its place. A reconnect that
    /// finishes inside ``connectingCardDelay`` never shows one; the card is
    /// for a wait the user can notice, not for every return from the
    /// background (Open item 35).
    @State private var showsConnectingCard = false
    private static let connectingCardDelay = Duration.seconds(1)
    /// Ghostty presents the new surface's first frame a beat after its first
    /// bytes arrive; releasing the old surface on the bytes alone flashes
    /// blank.
    private static let retiredSurfaceReleaseDelay = Duration.milliseconds(150)

    /// Bottom to top: the current surface, then the retired one over it.
    private var mountedSurfaces: [MountedSurface] {
        [currentSurface, retiredSurface].compactMap { $0 }
    }

    /// One builder for both, returning the same view type whichever role the
    /// surface plays: a `ForEach` keeps a surface's UIKit view across the
    /// move from current to retired only while its content stays one type.
    private func screen(for surface: MountedSurface) -> TerminalScreenView {
        var screen = terminalScreen(feed: surface.feed)
        guard surface.id != store.terminalID else { return screen }
        // Retired: draws its last frame and nothing else. Disabling input
        // dismisses its keyboard, as dismantling the view used to.
        screen.isLocalInputEnabled = false
        screen.keyboardControl = nil
        screen.claimsKeyboard = nil
        screen.onSizeChanged = nil
        screen.onSend = nil
        screen.onScroll = nil
        screen.onPaste = nil
        screen.onStageItems = nil
        screen.onHostPathTap = nil
        screen.onFontSizeChanged = nil
        return screen
    }

    private func terminalScreen(feed: TerminalByteFeed) -> TerminalScreenView {
        var screen = TerminalScreenView(feed: feed)
        screen.onSizeChanged = { cols, rows in
            store.viewDidResize(cols: cols, rows: rows)
        }
        screen.onSend = { store.send($0) }
        screen.onHostPathTap = { onHostPathTap($0) }
        screen.onScroll = { sequence, rows in
            store.scroll(sequence, rows: rows)
        }
        screen.onPaste = { text, bracketed in
            store.requestPaste(text, bracketedPaste: bracketed)
        }
        // Pasted and dropped photos and files: uploaded to the Host, then
        // their paths typed here.
        let media = self.media
        screen.onStageItems = { providers in
            Task { @MainActor in
                media.stage(await MediaIntake.loadItems(from: providers))
            }
        }
        // A hardware keyboard's keys only reach the PTY through a terminal
        // that holds first responder, and holding it raises no software
        // keyboard while one is attached.
        screen.claimsKeyboard = { hardwareKeyboard.isConnected }
        screen.keyboardControl = keyboardControl
        // With a hardware keyboard attached the bar is absent: iPadOS docks
        // an accessory at the bottom of the screen, nowhere near a keyboard
        // that has the keys already.
        screen.showsKeyBar = !hardwareKeyboard.isConnected
        // Open item 30, Stage 0: let iOS correct and predict what the
        // on-screen keyboard types. A correction arrives as a rewrite of the
        // last word, which `HeelerTerminalView.replace` already turns into
        // DELs and a retype (round 12); a prediction tap is a plain insert.
        screen.textInputStyle = .assisted
        screen.isLocalInputEnabled = true
        // Scroll-to-dismiss asks this on every pan: a Magic Keyboard docked
        // mid-session must keep its first responder through a scroll.
        screen.isHardwareKeyboardConnected = { hardwareKeyboard.isConnected }
        screen.theme = terminal.themes.theme
        screen.fontSize = terminal.zoom.fontSize
        screen.fontFamily = terminal.fonts.familyName
        screen.onFontSizeChanged = { terminal.zoom.setFontSize($0) }
        return screen
    }

    /// The shell terminal's keyboard arithmetic, reused verbatim.
    private var keyboardPresentation: AgentComposerKeyboardPresentation {
        guard !hardwareKeyboard.isConnected else { return .hidden }
        return ShellTerminalView.keyboardPresentation(
            mode: .text,
            insetHeight: keyboardInset.height,
            keyboardIsUp: keyboardControl.isKeyboardUp)
    }

    private var keyboardLayout: AgentComposerKeyboardLayout {
        AgentComposerKeyboardLayout(
            currentHeight: keyboardInset.height,
            lastPresentedHeight: keyboardInset.lastPresentedHeight,
            presentation: keyboardPresentation)
    }

    private var isTerminalLive: Bool { store.terminalStatus == .live }

    private var isPresentingConnecting: Bool {
        store.statusPresentation?.kind == .connecting
    }

    var body: some View {
        ZStack {
            ForEach(mountedSurfaces) { surface in
                let isRetired = surface.id != store.terminalID
                screen(for: surface)
                    .allowsHitTesting(!isRetired)
                    .accessibilityHidden(isRetired)
            }
        }
            .overlay { statusOverlay }
            .padding(.bottom, keyboardLayout.contentInset)
            // After the keyboard inset: an overlay applied before it aligns
            // to the un-inset frame and ends up behind the input row.
            .overlay(alignment: .bottom) { HerdrMediaStagingBar(media: media) }
            // Keyboard avoidance is owned by `TerminalKeyboardInset`; UIKit's
            // keyboard safe area would resize Ghostty a second time.
            .ignoresSafeArea(.keyboard, edges: .bottom)
            // Since upstream's 4b697cb the inset measures the keyboard against
            // the window it is handed and nothing else: without this line every
            // keyboard frame measures nil and the terminal never insets
            // (Open item 34).
            .terminalKeyboardInsetWindow(keyboardInset)
            // herdr's own layout wants every column: the surface runs to both
            // edges, and the theme's background paints under them.
            .ignoresSafeArea(.container, edges: .horizontal)
            .background(
                terminal.themes.selection(for: colorScheme)
                    .surfaceBackground(for: colorScheme)
                    .ignoresSafeArea()
            )
            .toolbar(.hidden, for: .navigationBar)
            .statusBarHidden(false)
            .sheet(
                isPresented: Binding(
                    get: { store.pendingPaste != nil },
                    set: { if !$0 { store.cancelPaste() } })
            ) {
                pasteReviewSheet
            }
            .alert(
                "Paste Blocked",
                isPresented: Binding(
                    get: { store.pasteErrorMessage != nil },
                    set: { if !$0 { store.clearPasteError() } })
            ) {
                Button("OK", role: .cancel) { store.clearPasteError() }
            } message: {
                Text(store.pasteErrorMessage ?? "")
            }
            .onChange(of: activity.activationCount, initial: true) { _, _ in
                store.didBecomeActive(
                    afterPossibleSuspension: activity.lastAbsenceMayHaveSuspended)
            }
            .onChange(of: store.terminalID, initial: true) { _, id in
                let outgoing = currentSurface
                currentSurface = MountedSurface(id: id, feed: store.terminalFeed)
                if let outgoing, outgoing.id != id, currentSurfaceHasBeenLive {
                    retiredSurface = outgoing
                }
                currentSurfaceHasBeenLive = false
            }
            .onChange(of: isTerminalLive) { _, isLive in
                if isLive { currentSurfaceHasBeenLive = true }
            }
            .task(id: isTerminalLive) {
                guard isTerminalLive, retiredSurface != nil else { return }
                try? await Task.sleep(for: Self.retiredSurfaceReleaseDelay)
                guard !Task.isCancelled else { return }
                retiredSurface = nil
            }
            .task(id: isPresentingConnecting) {
                showsConnectingCard = false
                guard isPresentingConnecting else { return }
                try? await Task.sleep(for: Self.connectingCardDelay)
                guard !Task.isCancelled else { return }
                showsConnectingCard = true
            }
            // A recovered terminal is a fresh surface with no keyboard raised.
            .onChange(of: store.terminalID) { _, _ in
                if hardwareKeyboard.isConnected { keyboardControl.requestKeyboard() }
            }
            .onChange(of: hardwareKeyboard.isConnected, initial: true) { _, isConnected in
                if isConnected { keyboardControl.requestKeyboard() }
            }
    }

    private var themePalette: TerminalThemePalette {
        terminal.themes.selection(for: colorScheme).palette(for: colorScheme)
    }

    @ViewBuilder
    private var statusOverlay: some View {
        if let presentation = store.statusPresentation {
            switch presentation.kind {
            case .connecting where !showsConnectingCard:
                EmptyView()
            case .connecting:
                TerminalStatusDialog(
                    glyph: .progress,
                    title: presentation.title,
                    message: presentation.message,
                    palette: themePalette,
                    dimsBackground: presentation.dimsBackground
                ) {
                    // A reconnecting Host keeps the spinner — recovery really
                    // is running — but the wait is the user's to cut short.
                    if presentation.offersReconnect {
                        Button("Reconnect") { store.reconnect() }
                            .buttonStyle(.borderedProminent)
                    }
                }
            case .ended:
                TerminalStatusDialog(
                    glyph: .symbol("cable.connector.slash"),
                    title: presentation.title,
                    message: presentation.message,
                    palette: themePalette,
                    dimsBackground: presentation.dimsBackground
                ) {
                    Button("Reconnect") { store.reconnect() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    @ViewBuilder
    private var pasteReviewSheet: some View {
        if let review = store.pendingPaste {
            NavigationStack {
                VStack(alignment: .leading, spacing: 12) {
                    Text("\(review.lineCount) lines, \(review.characterCount) characters")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    ScrollView {
                        Text(review.preview)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(12)
                    .background(.quaternary, in: .rect(cornerRadius: 10))
                }
                .padding()
                .navigationTitle("Review Paste")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", role: .cancel) { store.cancelPaste() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Paste") { store.confirmPaste() }
                            .disabled(!store.canConfirmPaste)
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
    }
}

/// The Client's staging chrome: one capsule over herdr's own surface, with
/// whatever commands the operation allows. It reports the same states the
/// Agent terminal's status bar does, because it reports the same store — the
/// Client just has no Composer to hang them under.
private struct HerdrMediaStagingBar: View {
    let media: HerdrMediaStagingStore

    /// A finished upload has already typed its path into the pane; the bar
    /// only says so, and then gets out of the way.
    private var completedPath: String? {
        guard case .completed(let outcome) = media.staging.state else { return nil }
        return outcome.path
    }

    var body: some View {
        if let presentation = media.presentation {
            HStack(spacing: 12) {
                Label(presentation.title, systemImage: presentation.icon)
                    .font(.subheadline)
                    .lineLimit(3)
                ForEach(presentation.commands, id: \.self) { command in
                    button(for: command)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
            .padding(.bottom, 16)
            .padding(.horizontal, 16)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(presentation.accessibilityLabel)
            .task(id: completedPath) {
                guard completedPath != nil else { return }
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                media.perform(.dismiss)
            }
        }
    }

    @ViewBuilder
    private func button(for command: ComposerStagingStore.Command) -> some View {
        switch command {
        case .cancel:
            Button("Cancel", role: .cancel) { media.perform(command) }
        case .retry:
            Button("Retry") { media.perform(command) }
        case .copyPath:
            Button("Copy Path") { media.perform(command) }
        case .dismiss:
            Button("Dismiss", role: .cancel) { media.perform(command) }
        }
    }
}
