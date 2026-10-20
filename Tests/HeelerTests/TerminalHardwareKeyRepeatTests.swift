import Foundation
import Testing

@testable import Heeler

/// The policy behind ``HeelerTerminalView``'s own hardware key repeat: which
/// held keys repeat, which are left to the key commands and shortcuts that
/// already own them, and the pace.
@Suite("Terminal hardware key repeat")
struct TerminalHardwareKeyRepeatTests {
    private typealias Repeat = TerminalHardwareKeyRepeat
    private typealias Usage = TerminalHardwareKeyMapping.Usage

    private static let letterA: UInt16 = 0x04
    private static let digit1: UInt16 = 0x1E
    private static let capsLock: UInt16 = 0x39
    private static let leftControl: UInt16 = 0xE0
    private static let rightGUI: UInt16 = 0xE7

    private func repeats(
        usage: UInt16,
        characters: String = "a",
        control: Bool = false,
        option: Bool = false,
        shift: Bool = false,
        command: Bool = false,
        hasMarkedText: Bool = false,
        inputModeUsesComposition: Bool = false
    ) -> Bool {
        Repeat.repeats(
            usage: usage,
            charactersIgnoringModifiers: characters,
            control: control,
            option: option,
            shift: shift,
            command: command,
            hasMarkedText: hasMarkedText,
            inputModeUsesComposition: inputModeUsesComposition)
    }

    @Test func typingKeysRepeat() {
        #expect(repeats(usage: Self.letterA))
        #expect(repeats(usage: Self.digit1, characters: "1"))
        #expect(repeats(usage: Self.letterA, characters: "a", shift: true))
        #expect(repeats(usage: 0x2C, characters: " "))
    }

    @Test func editingAndNavigationKeysRepeat() {
        #expect(repeats(usage: Usage.deleteOrBackspace, characters: "\u{8}"))
        #expect(repeats(usage: Usage.deleteForward, characters: "\u{F728}"))
        #expect(repeats(usage: Usage.leftArrow, characters: "UIKeyInputLeftArrow"))
        #expect(repeats(usage: Usage.upArrow, characters: "UIKeyInputUpArrow"))
        #expect(repeats(usage: 0x28, characters: "\r"))
        #expect(repeats(usage: Usage.tab, characters: "\t"))
    }

    @Test func modifierKeysNeverRepeatAndLeaveARunningRepeatAlone() {
        for usage in [Self.capsLock, Self.leftControl, 0xE1, 0xE2, 0xE3, 0xE4, 0xE5, 0xE6, Self.rightGUI] {
            #expect(Repeat.isModifier(usage: usage))
            #expect(!repeats(usage: usage, characters: ""))
        }
        #expect(!Repeat.isModifier(usage: Self.letterA))
        #expect(!Repeat.isModifier(usage: Usage.escape))
    }

    @Test func commandChordsAreShortcutsNotTyping() {
        #expect(!repeats(usage: Self.letterA, command: true))
        #expect(!repeats(usage: Usage.leftArrow, characters: "UIKeyInputLeftArrow", command: true))
        #expect(!repeats(usage: Usage.period, characters: ".", command: true))
    }

    @Test func keysDeliveredAsKeyCommandsDoNotRepeat() {
        // The vendored package claims Escape and every Ctrl combo that types
        // a character as a priority `UIKeyCommand`; a repeat of the press
        // would double the command's own delivery.
        #expect(!repeats(usage: Usage.escape, characters: "UIKeyInputEscape"))
        #expect(!repeats(usage: Usage.escape, characters: "UIKeyInputEscape", shift: true))
        // iPadOS spells ⌘. as an Escape press with the period's keycode.
        #expect(!repeats(usage: Usage.period, characters: "UIKeyInputEscape"))
        #expect(!repeats(usage: Self.letterA, characters: "a", control: true))
        #expect(!repeats(usage: Self.digit1, characters: "1", control: true))
        #expect(!repeats(usage: Self.letterA, characters: "a", control: true, shift: true))
        // Kelpie's own Shift+Tab command (round 17).
        #expect(!repeats(usage: Usage.tab, characters: "\t", shift: true))
    }

    @Test func controlledFunctionKeysAreNotKeyCommandsAndRepeat() {
        #expect(repeats(usage: Usage.leftArrow, characters: "UIKeyInputLeftArrow", control: true))
        #expect(repeats(usage: Usage.deleteOrBackspace, characters: "\u{8}", control: true))
        #expect(repeats(usage: Usage.tab, characters: "\t", control: true, shift: true))
    }

    @Test func optionWordKeysRepeat() {
        // Option+arrow and Option+Backspace are Kelpie's own bytes
        // (`TerminalHardwareKeyMapping`); a held one repeats like the plain key.
        #expect(repeats(usage: Usage.leftArrow, characters: "UIKeyInputLeftArrow", option: true))
        #expect(repeats(usage: Usage.deleteOrBackspace, characters: "\u{8}", option: true))
        #expect(repeats(usage: Self.letterA, characters: "a", option: true))
    }

    @Test func compositionKeepsItsKeys() {
        // With marked text every key is the input method's.
        #expect(!repeats(usage: Self.letterA, hasMarkedText: true))
        #expect(!repeats(usage: Usage.leftArrow, characters: "UIKeyInputLeftArrow", hasMarkedText: true))
        // Under a composing input mode (zh/ja/ko) a text key is loaned to the
        // input method before any composition exists; a function key is not.
        #expect(!repeats(usage: Self.letterA, inputModeUsesComposition: true))
        #expect(repeats(usage: Usage.leftArrow, characters: "UIKeyInputLeftArrow", inputModeUsesComposition: true))
        #expect(repeats(usage: Usage.deleteOrBackspace, characters: "\u{8}", inputModeUsesComposition: true))
    }

    @Test func composingInputModesMatchTheVendoredRule() {
        #expect(Repeat.inputModeUsesComposition(primaryLanguage: "zh-Hans"))
        #expect(Repeat.inputModeUsesComposition(primaryLanguage: "ja-JP"))
        #expect(Repeat.inputModeUsesComposition(primaryLanguage: "KO"))
        #expect(!Repeat.inputModeUsesComposition(primaryLanguage: "en-US"))
        #expect(!Repeat.inputModeUsesComposition(primaryLanguage: "bg"))
        #expect(!Repeat.inputModeUsesComposition(primaryLanguage: nil))
    }

    @Test func typesTextFiltersFunctionKeys() {
        #expect(Repeat.typesText(charactersIgnoringModifiers: "a"))
        #expect(Repeat.typesText(charactersIgnoringModifiers: " "))
        #expect(!Repeat.typesText(charactersIgnoringModifiers: ""))
        // Control characters are keys, not text: no Ctrl command is
        // registered for them and the input method is not loaned them.
        #expect(!Repeat.typesText(charactersIgnoringModifiers: "\u{8}"))
        #expect(!Repeat.typesText(charactersIgnoringModifiers: "\t"))
        #expect(!Repeat.typesText(charactersIgnoringModifiers: "\u{7F}"))
        #expect(!Repeat.typesText(charactersIgnoringModifiers: "UIKeyInputLeftArrow"))
        #expect(!Repeat.typesText(charactersIgnoringModifiers: "UIKeyInputEscape"))
        #expect(!Repeat.typesText(charactersIgnoringModifiers: "\u{F728}"))
    }

    @Test func paceFollowsAppKitDefaults() {
        #expect(Repeat.initialDelay == 0.4)
        #expect(Repeat.interval == 0.05)
    }
}
