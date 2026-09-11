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
