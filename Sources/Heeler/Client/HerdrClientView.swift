import SwiftUI
import UIKit

/// herdr's own client, full screen: its workspaces sidebar, tabs and panes,
/// exactly as they look in a desktop terminal. The iPad's job here is to make
/// that surface reachable — nothing of Heeler's native Console (Agent
/// switcher, Composer, message-jump) is on it, because herdr already draws its
/// own equivalents.
///
/// The keyboard chrome is the shell terminal's, and it appears only when there
/// is no hardware keyboard: a Magic Keyboard makes every key on the pad
/// redundant and the screen space expensive.
struct HerdrClientView: View {
    let store: HerdrClientStore
    let terminal: TerminalSettings
    let activity: AppActivityCoordinator
    let hardwareKeyboard: HardwareKeyboardObserver

    @State private var keyboardControl = TerminalKeyboardControl()
    @State private var keyboardMode: TerminalKeyboardMode = .text
    @State private var keyboardInset = TerminalKeyboardInset()
    @Environment(\.colorScheme) private var colorScheme

    private var terminalScreen: TerminalScreenView {
        var screen = TerminalScreenView(feed: store.terminalFeed)
        screen.onSizeChanged = { cols, rows in
            store.viewDidResize(cols: cols, rows: rows)
        }
        screen.onSend = { store.send($0) }
        screen.onScroll = { sequence, rows in
            store.scroll(sequence, rows: rows)
        }
        screen.onPaste = { text, bracketed in
            store.requestPaste(text, bracketedPaste: bracketed)
        }
        // A hardware keyboard's keys only reach the PTY through a terminal
        // that holds first responder, and holding it raises no software
        // keyboard while one is attached.
        screen.claimsKeyboard = { hardwareKeyboard.isConnected }
        screen.keyboardControl = keyboardControl
        screen.isLocalInputEnabled = true
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
            mode: keyboardMode,
            insetHeight: keyboardInset.height,
            keyboardIsUp: keyboardControl.isKeyboardUp)
    }

    private var keyboardLayout: AgentComposerKeyboardLayout {
        AgentComposerKeyboardLayout(
            currentHeight: keyboardInset.height,
            lastPresentedHeight: keyboardInset.lastPresentedHeight,
            presentation: keyboardPresentation)
    }

    private var isKeysDockPresented: Bool {
        keyboardMode == .controls && !hardwareKeyboard.isConnected
    }

    var body: some View {
        terminalScreen
            .id(store.terminalID)
            .overlay { statusOverlay }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if keyboardPresentation != .hidden {
                    ShellTerminalInputRow(
                        mode: Binding(
                            get: { keyboardMode },
                            set: { setKeyboardMode($0) }),
                        paste: { keyboardControl.paste($0) },
                        insertNewLine: {
                            UIDevice.current.playInputClick()
                            keyboardControl.sendNewLine()
                        })
                }
            }
            .padding(.bottom, keyboardLayout.contentInset)
            .overlay(alignment: .bottom) {
                ShellTerminalKeysDock(
                    settings: terminal,
                    height: keyboardLayout.availableToolsHeight,
                    sendControlKey: { keyboardControl.sendControlKey($0) })
                .opacity(isKeysDockPresented ? 1 : 0)
                .allowsHitTesting(isKeysDockPresented)
                .accessibilityHidden(!isKeysDockPresented)
            }
            // Keyboard avoidance is owned by `TerminalKeyboardInset`; UIKit's
            // keyboard safe area would resize Ghostty a second time.
            .ignoresSafeArea(.keyboard, edges: .bottom)
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
            // A recovered terminal is a fresh surface with no keyboard raised;
            // app-side mode state has to follow it back to Text.
            .onChange(of: store.terminalID) { _, _ in
                setKeyboardMode(.text)
                if hardwareKeyboard.isConnected { keyboardControl.requestKeyboard() }
            }
            .onChange(of: hardwareKeyboard.isConnected, initial: true) { _, isConnected in
                if isConnected {
                    setKeyboardMode(.text)
                    keyboardControl.requestKeyboard()
                }
            }
    }

    private func setKeyboardMode(_ mode: TerminalKeyboardMode) {
        guard mode != keyboardMode else { return }
        switch mode {
        case .controls:
            keyboardInset.pauseHeightCapture()
        case .text:
            keyboardInset.resumeHeightCapture()
        }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            keyboardMode = mode
        }
        keyboardControl.setKeyboardMode(mode)
    }

    private var themePalette: TerminalThemePalette {
        terminal.themes.selection(for: colorScheme).palette(for: colorScheme)
    }

    @ViewBuilder
    private var statusOverlay: some View {
        if let presentation = TerminalStatusPresentation(status: store.terminalStatus) {
            switch presentation.kind {
            case .connecting:
                TerminalStatusDialog(
                    glyph: .progress,
                    title: presentation.title,
                    message: presentation.message,
                    palette: themePalette,
                    dimsBackground: presentation.dimsBackground)
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
