import Foundation

/// Which held hardware keys ``HeelerTerminalView`` repeats itself, and how
/// fast.
///
/// UIKit reports a held hardware key once: one `pressesBegan`, then nothing
/// until the release. Auto-repeat belongs to the text input system, and the
/// terminal keeps every key off that path (the vendored package answers each
/// press itself and swallows the system's echo), so on the iPad a held
/// letter, Backspace or arrow typed exactly once (SASh, 2026-10-20).
/// libghostty-spm fixed this upstream in `56510302` and `5a025555`
/// (2026-09-25/28), after the vendored `7e45d27`, by generating the repeat in
/// the view. Until Kelpie re-vendors past those commits the subclass does the
/// same (``HeelerTerminalView/startKeyRepeat(for:)``), and this is its policy,
/// a port of upstream's `TerminalKeyRepeat`. **When the re-vendor lands, this
/// file and the subclass's repeat must go**, or every held key repeats twice.
enum TerminalHardwareKeyRepeat {
    /// iPadOS exposes the user's Key Repeat setting to no app, so these
    /// follow AppKit's defaults.
    static let initialDelay: TimeInterval = 0.4
    static let interval: TimeInterval = 0.05

    /// Caps Lock and the eight modifier usages (HID 0xE0–0xE7). Holding one
    /// is not typing, and pressing one leaves a running repeat alone.
    static func isModifier(usage: UInt16) -> Bool {
        usage == 0x39 || (0xE0 ... 0xE7).contains(usage)
    }

    /// Whether a held key repeats.
    ///
    /// A ⌘ chord is a shortcut, not typing. A key that is also a registered
    /// `UIKeyCommand` — the package's Ctrl combos and Escape, Kelpie's
    /// Shift+Tab — is delivered by that command: a repeat of its press would
    /// double the command's own, or repeat a press the claim dropped. A key
    /// the input method owns (marked text on screen, or a text key under a
    /// composing input mode) is loaned to it, and a repeat would loan it
    /// again.
    static func repeats(
        usage: UInt16,
        charactersIgnoringModifiers: String,
        control: Bool,
        option: Bool,
        shift: Bool,
        command: Bool,
        hasMarkedText: Bool,
        inputModeUsesComposition: Bool
    ) -> Bool {
        if isModifier(usage: usage) || command || hasMarkedText { return false }
        if isKeyCommand(
            usage: usage,
            charactersIgnoringModifiers: charactersIgnoringModifiers,
            control: control,
            option: option,
            shift: shift)
        {
            return false
        }
        if inputModeUsesComposition,
            typesText(charactersIgnoringModifiers: charactersIgnoringModifiers)
        {
            return false
        }
        return true
    }

    /// The keys a priority `UIKeyCommand` claims ahead of `pressesBegan`:
    /// Escape under any non-⌘ modifier set (the package's
    /// `escapeKeyCommands`, matched on its characters because iPadOS spells
    /// ⌘. as an Escape press with the period's keycode), Ctrl plus any key
    /// that types a character (`controlKeyCommands`), and Kelpie's bare
    /// Shift+Tab (round 17).
    static func isKeyCommand(
        usage: UInt16,
        charactersIgnoringModifiers: String,
        control: Bool,
        option: Bool,
        shift: Bool
    ) -> Bool {
        if usage == TerminalHardwareKeyMapping.Usage.escape
            || charactersIgnoringModifiers == Self.escapeInput
        {
            return true
        }
        if control, typesText(charactersIgnoringModifiers: charactersIgnoringModifiers) {
            return true
        }
        return usage == TerminalHardwareKeyMapping.Usage.tab && shift && !control && !option
    }

    /// Whether a key types a printable character, judged by its characters
    /// ignoring modifiers. A function key — named by UIKit
    /// (`UIKeyInputLeftArrow`) or a private-use scalar (U+F702) — types none,
    /// nor does a key that reports no characters, nor one that reports a
    /// control character (Backspace's U+0008, Tab's U+0009): the package
    /// registers Ctrl commands for letters, digits and symbols only, and
    /// loans the input method only printable keys
    /// (`TerminalIMEComposition.shouldDeferKey`).
    static func typesText(charactersIgnoringModifiers: String) -> Bool {
        let text = charactersIgnoringModifiers
        if text.isEmpty || text.hasPrefix("UIKeyInput") { return false }
        if text.count == 1, let scalar = text.unicodeScalars.first,
            (0xF700 ... 0xF8FF).contains(scalar.value) || scalar.value < 0x20 || scalar.value == 0x7F
        {
            return false
        }
        return true
    }

    /// The input modes whose hardware text keys the package loans to the
    /// input method (`TerminalIMEComposition.languageUsesComposition`).
    static func inputModeUsesComposition(primaryLanguage: String?) -> Bool {
        guard let primaryLanguage else { return false }
        let language = primaryLanguage.lowercased()
        return language.hasPrefix("zh") || language.hasPrefix("ja") || language.hasPrefix("ko")
    }

    /// `UIKeyCommand.inputEscape`, spelled out so the policy stays UIKit-free.
    private static let escapeInput = "UIKeyInputEscape"
}
