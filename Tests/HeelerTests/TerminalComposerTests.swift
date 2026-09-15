import Foundation
import Testing

@testable import Heeler

@Suite("Composer mirror")
struct TerminalComposerMirrorTests {
    private let del = Data([0x7F])

    @Test func typingSendsOnlyTheNewTail() {
        var mirror = TerminalComposerMirror()
        #expect(mirror.update(to: "he") == Data("he".utf8))
        #expect(mirror.update(to: "hel") == Data("l".utf8))
        #expect(mirror.committed == "hel")
    }

    @Test func unchangedTextSendsNothing() {
        var mirror = TerminalComposerMirror()
        _ = mirror.update(to: "same")
        #expect(mirror.update(to: "same").isEmpty)
    }

    @Test func autocorrectIsDeletesThenTheCorrectedTail() {
        var mirror = TerminalComposerMirror()
        _ = mirror.update(to: "teh")
        // "t" is kept; "eh" comes off; "he" goes on.
        #expect(mirror.update(to: "the") == del + del + Data("he".utf8))
    }

    @Test func backspaceIsOneDelete() {
        var mirror = TerminalComposerMirror()
        _ = mirror.update(to: "hello")
        #expect(mirror.update(to: "hell") == del)
    }

    @Test func midLineEditRetypesFromTheChange() {
        var mirror = TerminalComposerMirror()
        _ = mirror.update(to: "abcd")
        #expect(mirror.update(to: "aXcd") == del + del + del + Data("Xcd".utf8))
    }

    @Test func accentedCharacterIsOneCharacterEachWay() {
        var mirror = TerminalComposerMirror()
        _ = mirror.update(to: "caf")
        #expect(mirror.update(to: "café") == Data("é".utf8))
        #expect(mirror.update(to: "caf") == del)
    }

    @Test func submitSendsReturnAndStartsOver() {
        var mirror = TerminalComposerMirror()
        _ = mirror.update(to: "ls")
        #expect(mirror.submit() == Data([0x0D]))
        #expect(mirror.committed == "")
        // The next line is typed in full, not diffed against the old one.
        #expect(mirror.update(to: "ls -la") == Data("ls -la".utf8))
    }

    @Test func resetRetypesTheWholeField() {
        var mirror = TerminalComposerMirror()
        _ = mirror.update(to: "draft")
        mirror.reset()
        #expect(mirror.update(to: "draft") == Data("draft".utf8))
    }

    @Test func controlCharactersNeverReachThePTY() {
        #expect(TerminalComposerMirror.sanitized("a\nb\tc\rd") == "a b c d")
        #expect(TerminalComposerMirror.sanitized("x\u{1B}[Ay\u{7F}") == "x[Ay")
        var mirror = TerminalComposerMirror()
        #expect(mirror.update(to: "one\ntwo") == Data("one two".utf8))
        #expect(mirror.committed == "one two")
    }

    @Test func dictationChunkLandsAsOneTail() {
        var mirror = TerminalComposerMirror()
        _ = mirror.update(to: "Fix the ")
        #expect(mirror.update(to: "Fix the failing test") == Data("failing test".utf8))
    }
}

@MainActor
@Suite("Composer control")
struct TerminalComposerControlTests {
    private func makeDefaults() throws -> UserDefaults {
        let name = "TerminalComposerControlTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func offByDefaultAndPersistsTheToggle() throws {
        let defaults = try makeDefaults()
        let control = TerminalComposerControl(defaults: defaults)
        #expect(!control.isEnabled)
        control.toggle()
        #expect(control.isEnabled)
        #expect(defaults.bool(forKey: TerminalComposerControl.defaultsKey))
        #expect(TerminalComposerControl(defaults: defaults).isEnabled)
    }

    @Test func activeOnlyWithoutAHardwareKeyboard() throws {
        let control = TerminalComposerControl(defaults: try makeDefaults())
        control.setEnabled(true)
        #expect(control.isActive)
        control.isAvailable = false
        #expect(!control.isActive)
        #expect(control.isEnabled)
    }

    @Test func keyboardClaimIsConsumedOnce() throws {
        let control = TerminalComposerControl(defaults: try makeDefaults())
        // No terminal holds the keyboard, so enabling claims nothing.
        control.toggle()
        #expect(!control.consumeKeyboardClaim())
        #expect(!control.consumeKeyboardClaim())
    }

    @Test func submitStartsTheLineOver() throws {
        let control = TerminalComposerControl(defaults: try makeDefaults())
        control.fieldDidChange("hello")
        #expect(control.mirror.committed == "hello")
        control.submit("hello")
        #expect(control.mirror.committed == "")
    }
}
