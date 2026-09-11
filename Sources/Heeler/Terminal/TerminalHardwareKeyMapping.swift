import Foundation

/// The bytes the app sends itself for hardware key combinations that would
/// otherwise never reach the remote PTY.
///
/// Two independent causes put these combos here rather than on the normal
/// Ghostty key path:
///
/// 1. `UITerminalView` is a `UITextInput` first responder, so on iPadOS the
///    text-input system consumes Escape — and Cmd+`.`, its system Escape
///    equivalent — before `pressesBegan` ever runs, exactly as it does for
///    Ctrl+letter chords. The vendored package answers that for Ctrl by
///    registering `UIKeyCommand`s with `wantsPriorityOverSystemBehavior`;
///    nothing registers `UIKeyCommand.inputEscape`, so Escape is lost.
/// 2. Option-modified presses *do* reach Ghostty's key path with the alt bit
///    set, but the surface runs with Ghostty's default
///    `macos-option-as-alt = false`, so alt is never turned into an ESC
///    prefix and Option+Backspace lands on the PTY as a plain `0x7F`.
///    Switching that config on would change Option+letter composition for
///    every other key, so the word-wise editing combos are mapped here
///    instead.
///
/// The table below is the legacy/xterm encoding of each combo, written raw to
/// the PTY and so bypassing Ghostty's key encoder entirely. A client that had
/// negotiated the Kitty keyboard protocol would expect the CSI u forms and
/// would not recognise these — acceptable here, because the client on this
/// screen is herdr's ratatui TUI, which reads the legacy encodings.
///
/// Kept UIKit-free and `Sendable` so the table itself is unit-testable; the
/// view layer translates a `UIPress` into a ``Key`` before asking.
enum TerminalHardwareKeyMapping {
    /// One physical key plus the modifiers held with it. `usage` is a raw
    /// `UIKeyboardHIDUsage` value.
    struct Key: Hashable, Sendable {
        let usage: UInt16
        let control: Bool
        let option: Bool
        let shift: Bool
        let command: Bool

        init(
            usage: UInt16,
            control: Bool = false,
            option: Bool = false,
            shift: Bool = false,
            command: Bool = false
        ) {
            self.usage = usage
            self.control = control
            self.option = option
            self.shift = shift
            self.command = command
        }
    }

    /// Raw `UIKeyboardHIDUsage` values for the keys in the table.
    enum Usage {
        static let escape: UInt16 = 0x29
        static let period: UInt16 = 0x37
        static let deleteOrBackspace: UInt16 = 0x2A
        static let deleteForward: UInt16 = 0x4C
        static let rightArrow: UInt16 = 0x4F
        static let leftArrow: UInt16 = 0x50
    }

    /// The bytes the app sends for combinations UIKit or Ghostty would
    /// otherwise lose; `nil` leaves the press to the normal path.
    static func bytes(for key: Key) -> Data? {
        switch key.usage {
        case Usage.escape:
            // Escape alone. Any modifier makes it a different combination,
            // and Ghostty's encoder still owns those.
            guard !key.control, !key.option, !key.shift, !key.command else { return nil }
            return Data([0x1B])
        case Usage.period:
            // Cmd+. is iPadOS's Escape equivalent. Kept even though UIKit may
            // already fold it into `inputEscape`, because whichever spelling
            // arrives resolves to the same byte.
            guard key.command, !key.control, !key.option, !key.shift else { return nil }
            return Data([0x1B])
        case Usage.deleteOrBackspace:
            // ESC DEL: delete word backward in readline, zsh, fish and
            // Claude Code.
            guard isAltEditingChord(key) else { return nil }
            return Data([0x1B, 0x7F])
        case Usage.leftArrow:
            // ESC b: word left.
            guard isAltEditingChord(key) else { return nil }
            return Data([0x1B, 0x62])
        case Usage.rightArrow:
            // ESC f: word right.
            guard isAltEditingChord(key) else { return nil }
            return Data([0x1B, 0x66])
        case Usage.deleteForward:
            // ESC d: delete word forward. Fn+Delete on the Magic Keyboard.
            guard isAltEditingChord(key) else { return nil }
            return Data([0x1B, 0x64])
        default:
            return nil
        }
    }

    /// Option held, and neither Control nor Command. Shift is allowed: it
    /// selects nothing on a PTY, and the legacy encodings have no shifted
    /// spelling to choose between.
    private static func isAltEditingChord(_ key: Key) -> Bool {
        key.option && !key.control && !key.command
    }
}
