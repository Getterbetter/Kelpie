import GhosttyTerminal
import UIKit

/// Raw byte sequences for the control keys the key bar sends. Upstream's
/// quick keys go through Ghostty's own encoder; the bar's `bytes` accessor
/// stays for the encoding tests.
private enum TerminalEscapeSequences {
    static let newLine: [UInt8] = [0x0A]
    static let escape: [UInt8] = [0x1B]
    static let tab: [UInt8] = [0x09]
    static let shiftTab: [UInt8] = [0x1B, 0x5B, 0x5A]
    static let homeNormal: [UInt8] = [0x1B, 0x5B, 0x48]
    static let homeApplication: [UInt8] = [0x1B, 0x4F, 0x48]
    static let pageUp: [UInt8] = [0x1B, 0x5B, 0x35, 0x7E]
    static let upNormal: [UInt8] = [0x1B, 0x5B, 0x41]
    static let upApplication: [UInt8] = [0x1B, 0x4F, 0x41]
    static let pageDown: [UInt8] = [0x1B, 0x5B, 0x36, 0x7E]
    static let endNormal: [UInt8] = [0x1B, 0x5B, 0x46]
    static let endApplication: [UInt8] = [0x1B, 0x4F, 0x46]
    static let backspace: [UInt8] = [0x7F]
    static let leftNormal: [UInt8] = [0x1B, 0x5B, 0x44]
    static let leftApplication: [UInt8] = [0x1B, 0x4F, 0x44]
    static let downNormal: [UInt8] = [0x1B, 0x5B, 0x42]
    static let downApplication: [UInt8] = [0x1B, 0x4F, 0x42]
    static let rightNormal: [UInt8] = [0x1B, 0x5B, 0x43]
    static let rightApplication: [UInt8] = [0x1B, 0x4F, 0x43]
    static let enter: [UInt8] = [0x0D]
}

/// One-shot sticky modifiers for the terminal key surfaces (issue #270).
/// Tapping Ctrl, Alt, or Shift arms the modifier for the next key only;
/// firing any key consumes and clears it.
/// There is deliberately no lock mode.
struct TerminalKeyModifiers: OptionSet, Sendable, Hashable {
    let rawValue: UInt8

    static let control = Self(rawValue: 1 << 0)
    static let option = Self(rawValue: 1 << 1)
    static let shift = Self(rawValue: 1 << 2)
}

extension TerminalKeyModifiers {
    /// Labels follow the full keyboard's US layout. Ghostty encodes input.
    func characterText(_ character: Character) -> String {
        guard contains(.shift) else { return String(character) }
        let unshifted = Array("`1234567890-=[]\\;',./")
        let shifted = Array("~!@#$%^&*()_+{}|:\"<>?")
        if let index = unshifted.firstIndex(of: character) {
            return String(shifted[index])
        }
        return String(character).uppercased()
    }
}

enum TerminalKeyboardMode: Int {
    case text
    case controls

    /// iPad draws a floating input-assistant bar (predictions, IME
    /// candidates, dictation) under any first responder whose software
    /// keyboard is suppressed, so the Keys and tools docks there release
    /// first responder instead of hiding the keyboard in place. iPhone shows
    /// no such bar and keeps the in-place switch, which preserves the IME
    /// session across the dock and back.
    @MainActor static let controlsReleaseFirstResponder =
        UIDevice.current.userInterfaceIdiom == .pad
}

/// Function keys exposed by the full keyboard.
enum TerminalFunctionKey: Int, CaseIterable, Hashable {
    case f1 = 1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12

    var title: String { "F\(rawValue)" }
}

/// Terminal controls and characters exposed by the shared full keyboard.
/// In Composer mode these explicit actions bypass the draft while the
/// Ghostty surface itself remains display-only.
enum AgentQuickKey: Hashable {
    case escape
    case tab
    case shiftTab
    case shiftEnter
    case left
    case up
    case down
    case right
    case enter
    case backspace

    case home
    case end
    case insert
    case forwardDelete
    case function(TerminalFunctionKey)
    case character(Character)
    case pageUp
    case pageDown

    var title: String? {
        switch self {
        case .escape: "Esc"
        case .tab: "Tab"
        case .shiftTab: "⇧Tab"
        case .shiftEnter: "⇧Enter"
        case .enter: "Enter"
        case .backspace: "Backspace"
        case .home: "Home"
        case .end: "End"
        case .insert: "Insert"
        case .forwardDelete: "Forward Delete"
        case .function(let key): key.title
        case .character(let character): character == " " ? "Space" : String(character)
        case .pageUp: "PgUp"
        case .pageDown: "PgDn"
        case .left, .up, .down, .right: nil
        }
    }

    var systemImageName: String? {
        switch self {
        case .left: "arrow.left"
        case .up: "arrow.up"
        case .down: "arrow.down"
        case .right: "arrow.right"
        default: nil
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .escape: "Escape"
        case .tab: "Tab"
        case .shiftTab: "Shift Tab"
        case .shiftEnter: "Shift Enter"
        case .left: "Left Arrow"
        case .up: "Up Arrow"
        case .down: "Down Arrow"
        case .right: "Right Arrow"
        case .enter: "Enter"
        case .backspace: "Backspace"
        case .home: "Home"
        case .end: "End"
        case .insert: "Insert"
        case .forwardDelete: "Forward Delete"
        case .function(let key): key.title
        case .character(let character): character == " " ? "Space" : String(character)
        case .pageUp: "Page Up"
        case .pageDown: "Page Down"
        }
    }
}

enum TerminalControlKey: Equatable, CaseIterable {
    case escape
    case tab
    /// Back-tab. The key bar owns it; it is deliberately absent from ``rows``,
    /// which is the Console's control pad.
    case shiftTab
    case controlC
    case controlD
    case controlZ
    case home
    case pageUp
    case up
    case pageDown
    case end
    case backspace
    case left
    case down
    case right
    case enter

    /// Backspace takes the top row's right edge, where the iOS keyboard puts it
    /// and where a thumb finds it without looking. It trades places with ⌃Z
    /// rather than crowding in, so the rows stay evenly sized.
    static let rows: [[Self]] = [
        [.escape, .tab, .controlC, .controlD, .backspace],
        [.home, .pageUp, .up, .pageDown, .end],
        [.controlZ, .left, .down, .right, .enter],
    ]

    var title: String? {
        switch self {
        case .escape: "Esc"
        case .tab: "Tab"
        case .shiftTab: "⇧Tab"
        case .controlC: "⌃C"
        case .controlD: "⌃D"
        case .controlZ: "⌃Z"
        case .home: "Home"
        case .pageUp: "PgUp"
        case .pageDown: "PgDn"
        case .end: "End"
        case .up, .backspace, .left, .down, .right, .enter: nil
        }
    }

    var systemImageName: String? {
        switch self {
        case .up: "arrow.up"
        case .backspace: "delete.left"
        case .left: "arrow.left"
        case .down: "arrow.down"
        case .right: "arrow.right"
        case .enter: "return"
        default: nil
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .escape: "Escape"
        case .tab: "Tab"
        case .shiftTab: "Shift Tab"
        case .controlC: "Control C"
        case .controlD: "Control D"
        case .controlZ: "Control Z"
        case .home: "Home"
        case .pageUp: "Page Up"
        case .up: "Up Arrow"
        case .pageDown: "Page Down"
        case .end: "End"
        case .backspace: "Backspace"
        case .left: "Left Arrow"
        case .down: "Down Arrow"
        case .right: "Right Arrow"
        case .enter: "Enter"
        }
    }

    var repeats: Bool {
        switch self {
        case .home, .pageUp, .up, .pageDown, .end, .backspace, .left, .down, .right:
            true
        case .escape, .tab, .shiftTab, .controlC, .controlD, .controlZ, .enter:
            false
        }
    }

    func bytes(applicationCursor: Bool) -> [UInt8] {
        switch self {
        case .escape: TerminalEscapeSequences.escape
        case .tab: TerminalEscapeSequences.tab
        case .shiftTab: TerminalEscapeSequences.shiftTab
        case .controlC: [0x03]
        case .controlD: [0x04]
        case .controlZ: [0x1A]
        case .home:
            applicationCursor
                ? TerminalEscapeSequences.homeApplication : TerminalEscapeSequences.homeNormal
        case .pageUp: TerminalEscapeSequences.pageUp
        case .up:
            applicationCursor
                ? TerminalEscapeSequences.upApplication : TerminalEscapeSequences.upNormal
        case .pageDown: TerminalEscapeSequences.pageDown
        case .end:
            applicationCursor
                ? TerminalEscapeSequences.endApplication : TerminalEscapeSequences.endNormal
        case .backspace: TerminalEscapeSequences.backspace
        case .left:
            applicationCursor
                ? TerminalEscapeSequences.leftApplication : TerminalEscapeSequences.leftNormal
        case .down:
            applicationCursor
                ? TerminalEscapeSequences.downApplication : TerminalEscapeSequences.downNormal
        case .right:
            applicationCursor
                ? TerminalEscapeSequences.rightApplication : TerminalEscapeSequences.rightNormal
        case .enter: TerminalEscapeSequences.enter
        }
    }
}

/// Suppresses the software keyboard while the terminal keeps first responder:
/// a zero-height input view replaces the system keyboard without resigning,
/// so the IME session — and its candidate row on return — survives the switch.
/// Shared with the Composer, whose tools mode pioneered the arrangement.
final class TerminalSuppressedSoftKeyboardView: UIView {
    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: 0)
    }
}

extension HeelerTerminalView {
    /// Read from the installed input view, so the mode can never disagree
    /// with what UIKit is actually presenting.
    var keyboardMode: TerminalKeyboardMode {
        inputView is TerminalSuppressedSoftKeyboardView ? .controls : .text
    }

    /// Hooks the terminal into the keyboard's lifecycle, observed through
    /// `notificationCenter`.
    ///
    /// Production observes the process-wide default: UIKit posts keyboard
    /// notifications there, and there is no per-window center to move to.
    /// What keeps one window's keyboard from ending another window's handoff
    /// is the receiving end — a terminal heeds a transition event only for
    /// its own keyboard (see `textKeyboardFrameDidChange`) — because on iPad
    /// two of the app's windows can each hold a live terminal (#157). Tests
    /// pass a center of their own, the same seam `TerminalKeyboardInset`
    /// takes, so a keyboard settling in a neighbouring test cannot reach this
    /// terminal at all.
    /// There is nothing to balance: the center drops an observer that
    /// deallocates.
    func installKeyboardSwitcher(notificationCenter: NotificationCenter = .default) {
        installInputAssistantStyle()
        notificationCenter.addObserver(
            self, selector: #selector(textKeyboardFrameDidChange(_:)),
            name: UIResponder.keyboardDidChangeFrameNotification, object: nil)
    }

    /// Switches between the system keyboard and the Keys dock the way the
    /// Composer does: the first responder never changes, and Keys mode only
    /// suppresses the software keyboard with a zero-height input view while
    /// the app-side dock occupies the measured keyboard footprint behind it.
    /// Replacing the keyboard with a real input view was tried first and cost
    /// the switch its stability: UIKit removes the candidate row before the
    /// swap lands, everything riding the keyboard dips, and the IME's
    /// candidate row never comes back for a composition still in flight.
    func setKeyboardMode(_ mode: TerminalKeyboardMode) {
        guard mode != keyboardMode else { return }

        switch mode {
        case .text:
            setTerminalInputView(nil)
        case .controls:
            setTerminalInputView(TerminalSuppressedSoftKeyboardView())
        }
        guard isFirstResponder else { return }
        // Where Keys releases first responder the owner resigns next; reloading
        // here would present the suppressed keyboard's assistant bar first.
        if mode == .controls, TerminalKeyboardMode.controlsReleaseFirstResponder { return }
        UIView.performWithoutAnimation {
            reloadInputViews()
        }
    }

    /// Composer quick keys are explicit terminal actions. They remain usable
    /// while ordinary local terminal input is disabled. Ghostty owns encoding
    /// and emits both press and release events for negotiated keyboard modes.
    @discardableResult
    func sendQuickKey(_ key: AgentQuickKey, modifiers: TerminalKeyModifiers = []) -> Bool {
        guard let press = Self.keyPress(key, modifiers: modifiers) else { return false }
        return sendKey(press)
    }

    /// The key bar's control keys. Routed through the quick-key encoder so
    /// the bar, the Console's pad and the hardware keys all encode the same
    /// way; ⌃C/⌃D/⌃Z are the letter with Control armed.
    func sendControlKey(_ key: TerminalControlKey) {
        guard isLocalInputEnabled else { return }
        switch key {
        case .controlC: sendQuickKey(.character("c"), modifiers: .control)
        case .controlD: sendQuickKey(.character("d"), modifiers: .control)
        case .controlZ: sendQuickKey(.character("z"), modifiers: .control)
        case .escape: sendQuickKey(.escape)
        case .tab: sendQuickKey(.tab)
        case .shiftTab: sendQuickKey(.shiftTab)
        case .home: sendQuickKey(.home)
        case .pageUp: sendQuickKey(.pageUp)
        case .up: sendQuickKey(.up)
        case .pageDown: sendQuickKey(.pageDown)
        case .end: sendQuickKey(.end)
        case .backspace: sendQuickKey(.backspace)
        case .left: sendQuickKey(.left)
        case .down: sendQuickKey(.down)
        case .right: sendQuickKey(.right)
        case .enter: sendQuickKey(.enter)
        }
    }

    func sendNewLine() {
        guard isLocalInputEnabled else { return }
        sendQuickKey(.shiftEnter)
    }

    private static func keyPress(
        _ key: AgentQuickKey, modifiers: TerminalKeyModifiers
    ) -> TerminalKeyPress? {
        var flags: TerminalInputModifiers = []
        if modifiers.contains(.control) { flags.insert(.ctrl) }
        if modifiers.contains(.option) { flags.insert(.alt) }
        if modifiers.contains(.shift) { flags.insert(.shift) }

        // The existing multiline action is Ctrl-J (LF in legacy mode).
        // Keep that action when Shift is armed on the full keyboard's Enter.
        if key == .shiftEnter || (key == .enter && modifiers.contains(.shift)) {
            flags.remove(.shift)
            flags.insert(.ctrl)
            return TerminalKeyPress(.j, modifiers: flags)
        }

        let terminalKey: TerminalKey
        switch key {
        case .escape: terminalKey = .escape
        case .tab: terminalKey = .tab
        case .shiftTab:
            terminalKey = .tab
            flags.insert(.shift)
        case .shiftEnter: terminalKey = .j
        case .left: terminalKey = .arrowLeft
        case .up: terminalKey = .arrowUp
        case .down: terminalKey = .arrowDown
        case .right: terminalKey = .arrowRight
        case .enter: terminalKey = .enter
        case .backspace: terminalKey = .backspace
        case .home: terminalKey = .home
        case .end: terminalKey = .end
        case .insert: terminalKey = .insert
        case .forwardDelete: terminalKey = .delete
        case .pageUp: terminalKey = .pageUp
        case .pageDown: terminalKey = .pageDown
        case .character(let character):
            return TerminalKeyPress(typing: character, modifiers: flags)
        case .function(let function):
            terminalKey = switch function {
            case .f1: .f1
            case .f2: .f2
            case .f3: .f3
            case .f4: .f4
            case .f5: .f5
            case .f6: .f6
            case .f7: .f7
            case .f8: .f8
            case .f9: .f9
            case .f10: .f10
            case .f11: .f11
            case .f12: .f12
            }
        }
        return TerminalKeyPress(terminalKey, modifiers: flags)
    }

    /// herdr's own prefix — Ctrl+B, one byte — followed by the letter that
    /// names the command: `n`/`p` for tabs, `b` for the sidebar, `z` for zoom.
    /// Sent as one write, the way a keyboard sends them back to back.
    func sendHerdrPrefixed(_ letter: Character) {
        guard isLocalInputEnabled else { return }
        terminalSession.sendInput(Data([0x02] + Array(letter.utf8)))
    }

    @objc private func textKeyboardFrameDidChange(_ notification: Notification) {
        if notificationSettlesOwnKeyboard(notification) {
            keyboardFrameDidSettle()
        }
    }

    /// Whether a keyboard frame event is this terminal's own settle signal.
    /// Keyboard notifications are process-wide, and on iPad a second window
    /// of the app can hold a live terminal of its own (#157): the event
    /// belongs to this terminal's keyboard only while this terminal is first
    /// responder, and only when the reported end frame leaves the keyboard
    /// covering this terminal's window. A frame on its way out belongs to a
    /// different transition — the other window's, say — and must not end
    /// this terminal's handoff. A post carrying no frame cannot establish
    /// ownership and is ignored.
    private func notificationSettlesOwnKeyboard(_ notification: Notification) -> Bool {
        guard isFirstResponder, let window, window.isKeyWindow else { return false }
        guard let endFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey]
            as? CGRect
        else { return false }
        let frameInWindow = window.convert(endFrame, from: window.screen.coordinateSpace)
        return TerminalKeyboardInset.keyboardFrame(
            frameInWindow,
            matches: keyboardLayoutFrameProvider?(window)
                ?? TerminalKeyboardInset.keyboardLayoutGuideFrame(in: window) ?? .zero,
            in: window)
    }
}

extension TerminalKeyboardControl {
    /// The Kelpie menu's herdr commands. Routed through the handle like every
    /// other piece of chrome outside the terminal, so a Host switch cannot
    /// leave the menu typing into a dead surface.
    func sendHerdrPrefixed(_ letter: Character) {
        terminal?.sendHerdrPrefixed(letter)
    }
}
