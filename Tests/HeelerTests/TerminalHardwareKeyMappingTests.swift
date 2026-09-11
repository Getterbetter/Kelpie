import Foundation
import Testing

@testable import Heeler

@Suite("Terminal hardware key mapping")
struct TerminalHardwareKeyMappingTests {
    private typealias Key = TerminalHardwareKeyMapping.Key
    private typealias Usage = TerminalHardwareKeyMapping.Usage

    private func bytes(_ key: Key) -> [UInt8]? {
        TerminalHardwareKeyMapping.bytes(for: key).map(Array.init)
    }

    @Test func escapeAloneSendsEsc() {
        #expect(bytes(Key(usage: Usage.escape)) == [0x1B])
    }

    @Test func commandPeriodSendsEsc() {
        #expect(bytes(Key(usage: Usage.period, command: true)) == [0x1B])
    }

    @Test func optionBackspaceDeletesAWordBackward() {
        #expect(bytes(Key(usage: Usage.deleteOrBackspace, option: true)) == [0x1B, 0x7F])
        // Shift rides along harmlessly; there is no shifted spelling.
        #expect(
            bytes(Key(usage: Usage.deleteOrBackspace, option: true, shift: true))
                == [0x1B, 0x7F])
    }

    @Test func optionArrowsMoveByWord() {
        #expect(bytes(Key(usage: Usage.leftArrow, option: true)) == [0x1B, 0x62])
        #expect(bytes(Key(usage: Usage.rightArrow, option: true)) == [0x1B, 0x66])
    }

    @Test func optionForwardDeleteDeletesAWordForward() {
        #expect(bytes(Key(usage: Usage.deleteForward, option: true)) == [0x1B, 0x64])
    }

    /// The Magic Keyboard has no Home, End, Page Up or Page Down. Where
    /// iPadOS does not translate Fn+arrow into those usages, ⌘+arrow means
    /// them, exactly as it does in macOS Terminal.
    @Test func commandArrowsSendHomeEndAndPaging() {
        #expect(bytes(Key(usage: Usage.leftArrow, command: true)) == [0x1B, 0x5B, 0x48])
        #expect(bytes(Key(usage: Usage.rightArrow, command: true)) == [0x1B, 0x5B, 0x46])
        #expect(
            bytes(Key(usage: Usage.upArrow, command: true)) == [0x1B, 0x5B, 0x35, 0x7E])
        #expect(
            bytes(Key(usage: Usage.downArrow, command: true)) == [0x1B, 0x5B, 0x36, 0x7E])
    }

    /// Shift+⌘+arrow is a selection everywhere it means anything, and the
    /// legacy forms cannot spell it: Ghostty's encoder keeps that press.
    @Test func shiftedCommandArrowsAreLeftToTheNormalPath() {
        #expect(bytes(Key(usage: Usage.leftArrow, shift: true, command: true)) == nil)
        #expect(bytes(Key(usage: Usage.rightArrow, shift: true, command: true)) == nil)
        #expect(bytes(Key(usage: Usage.upArrow, shift: true, command: true)) == nil)
        #expect(bytes(Key(usage: Usage.downArrow, shift: true, command: true)) == nil)
    }

    /// The usages iPadOS delivers for Fn+arrow — Home 0x4A, Page Up 0x4B,
    /// End 0x4D, Page Down 0x4E — are Ghostty's own table's business.
    @Test func realNavigationUsagesAreLeftToGhostty() {
        for usage: UInt16 in [0x4A, 0x4B, 0x4D, 0x4E] {
            #expect(bytes(Key(usage: usage)) == nil)
            #expect(bytes(Key(usage: usage, command: true)) == nil)
        }
    }

    /// Command is the whole chord: with Option or Control along for the ride
    /// the arrow is something else again.
    @Test func otherModifiersCancelTheCommandArrows() {
        #expect(bytes(Key(usage: Usage.upArrow, option: true, command: true)) == nil)
        #expect(bytes(Key(usage: Usage.upArrow, control: true, command: true)) == nil)
        #expect(bytes(Key(usage: Usage.upArrow)) == nil)
        #expect(bytes(Key(usage: Usage.downArrow, option: true)) == nil)
    }

    @Test func modifiedEscapeIsLeftToTheNormalPath() {
        #expect(bytes(Key(usage: Usage.escape, command: true)) == nil)
        #expect(bytes(Key(usage: Usage.escape, option: true)) == nil)
    }

    @Test func unmodifiedBackspaceIsLeftToTheNormalPath() {
        #expect(bytes(Key(usage: Usage.deleteOrBackspace)) == nil)
    }

    @Test func controlOrCommandCancelsTheOptionChords() {
        #expect(bytes(Key(usage: Usage.deleteOrBackspace, control: true, option: true)) == nil)
        #expect(bytes(Key(usage: Usage.deleteOrBackspace, option: true, command: true)) == nil)
        #expect(bytes(Key(usage: Usage.leftArrow, control: true, option: true)) == nil)
    }

    @Test func periodWithoutCommandIsLeftToTheNormalPath() {
        #expect(bytes(Key(usage: Usage.period)) == nil)
        #expect(bytes(Key(usage: Usage.period, option: true)) == nil)
    }

    @Test func unmappedKeysAreLeftToTheNormalPath() {
        // "a" (0x04) and Return (0x28), modified and not.
        #expect(bytes(Key(usage: 0x04)) == nil)
        #expect(bytes(Key(usage: 0x04, option: true)) == nil)
        #expect(bytes(Key(usage: 0x28, option: true)) == nil)
    }
}
