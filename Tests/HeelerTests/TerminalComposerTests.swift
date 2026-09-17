import Foundation
import Testing
import UIKit

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

    @Test func softNewlineSendsBackslashAndReturnAndStartsOver() {
        var mirror = TerminalComposerMirror()
        _ = mirror.update(to: "first")
        #expect(mirror.softNewline() == Data([0x5C, 0x0D]))
        #expect(mirror.committed == "")
        // The field starts empty again, so the next line is typed in full.
        #expect(mirror.update(to: "second") == Data("second".utf8))
    }

    @Test func softNewlineBringsThePTYUpToDateBeforeTheBreak() {
        var mirror = TerminalComposerMirror()
        _ = mirror.update(to: "fir")
        #expect(mirror.update(to: "first") == Data("st".utf8))
        #expect(mirror.softNewline() == Data([0x5C, 0x0D]))
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

    @Test func enablingWithoutATerminalKeyboardClaimsNothing() throws {
        let control = TerminalComposerControl(defaults: try makeDefaults())
        control.toggle()
        #expect(!control.consumeKeyboardClaim())
    }

    @Test func escapeAndControlChordsStartTheLineOver() throws {
        let control = TerminalComposerControl(defaults: try makeDefaults())
        control.setEnabled(true)
        control.fieldDidChange("half a line")
        control.controlKeyWillBeSent(.controlC)
        #expect(control.mirror.committed == "")
        // Tab and the arrows leave the line as the field describes it.
        control.fieldDidChange("ls /ho")
        control.controlKeyWillBeSent(.tab)
        #expect(control.mirror.committed == "ls /ho")
    }

    @Test func controlKeysAreIgnoredWhileTheComposerIsOff() throws {
        let control = TerminalComposerControl(defaults: try makeDefaults())
        control.fieldDidChange("kept")
        control.controlKeyWillBeSent(.escape)
        #expect(control.mirror.committed == "kept")
    }

    @Test func submitStartsTheLineOver() throws {
        let control = TerminalComposerControl(defaults: try makeDefaults())
        control.fieldDidChange("hello")
        #expect(control.mirror.committed == "hello")
        control.submit("hello")
        #expect(control.mirror.committed == "")
    }

    @Test func softNewlineStartsTheLineOverLikeSubmit() throws {
        let control = TerminalComposerControl(defaults: try makeDefaults())
        control.fieldDidChange("first line")
        control.softNewline("first line")
        #expect(control.mirror.committed == "")
        // A soft newline that catches up on an edit still starts over.
        control.fieldDidChange("second")
        control.softNewline("second line")
        #expect(control.mirror.committed == "")
    }
}

/// The responder and field flows (Open item 30). These need real UIKit
/// objects, so they run in the device host app; nothing here sleeps or waits
/// on a run loop.
@MainActor
@Suite("Composer field")
struct TerminalComposerFieldTests {
    private func makeControl(enabled: Bool) throws -> TerminalComposerControl {
        let name = "TerminalComposerFieldTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        let control = TerminalComposerControl(defaults: defaults)
        control.setEnabled(enabled)
        return control
    }

    /// A mounted field in a key window: `becomeFirstResponder` is refused
    /// outside one, and every responder flow here turns on it.
    private func mountField(_ control: TerminalComposerControl)
        -> (field: TerminalComposerTextView, window: UIWindow)
    {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 420, height: 800))
        let field = TerminalComposerTextView()
        field.control = control
        control.field = field
        field.frame = CGRect(x: 0, y: 0, width: 420, height: 44)
        window.addSubview(field)
        window.makeKeyAndVisible()
        return (field, window)
    }

    /// Undoes ``mountField``: a key window left visible with a focused
    /// field keeps the keyboard tied to it, and the keyboard-layout-guide
    /// tests in `TerminalAttachTests` then never see their own window settle.
    private func unmount(_ mounted: (field: TerminalComposerTextView, window: UIWindow)) {
        mounted.field.resignFirstResponder()
        mounted.window.isHidden = true
    }

    // MARK: Focus

    @Test func focusFieldIsRefusedWhileTheComposerIsNotActive() throws {
        let control = try makeControl(enabled: false)
        let mounted = mountField(control)
        defer { unmount(mounted) }
        #expect(!control.focusField())
        #expect(!mounted.field.isFirstResponder)
        control.setEnabled(true)
        control.isAvailable = false
        #expect(!control.focusField())
        #expect(!mounted.field.isFirstResponder)
        #expect(!control.fieldHoldsKeyboard)
    }

    @Test func focusAndResignMoveTheKeyboardOntoAndOffTheField() throws {
        let control = try makeControl(enabled: true)
        let mounted = mountField(control)
        defer { unmount(mounted) }
        #expect(control.focusField())
        #expect(mounted.field.isFirstResponder)
        #expect(control.fieldHoldsKeyboard)
        #expect(control.resignField())
        #expect(!mounted.field.isFirstResponder)
        #expect(!control.fieldHoldsKeyboard)
        // Nothing to give back the second time.
        #expect(!control.resignField())
    }

    @Test func focusFieldIsRefusedWithNoFieldMounted() throws {
        let control = try makeControl(enabled: true)
        #expect(!control.focusField())
        #expect(!control.resignField())
    }

    // MARK: The keyboard claim

    @Test func theKeyboardClaimIsAnsweredOnceAtMost() throws {
        let control = try makeControl(enabled: false)
        // Enabled with no terminal holding the keyboard: nothing to claim,
        // and a second ask still answers no.
        control.toggle()
        #expect(control.isEnabled)
        #expect(!control.consumeKeyboardClaim())
        #expect(!control.consumeKeyboardClaim())
        // Turning it off again leaves no claim behind either.
        control.toggle()
        #expect(!control.consumeKeyboardClaim())
    }

    // MARK: The handoff freeze

    @Test func theHandoffFreezesTheInsetUntilItsOwnIdEndsIt() throws {
        let control = try makeControl(enabled: true)
        let inset = TerminalKeyboardInset()
        control.keyboardInset = inset
        let id = control.beginKeyboardHandoff()
        #expect(inset.isHoldingHandoffHeight)
        #expect(inset.activeResponderHandoffID == id)
        // A stale id is a no-op: the freeze the current handoff owns stays.
        control.endKeyboardHandoff(UUID())
        #expect(inset.isHoldingHandoffHeight)
        control.endKeyboardHandoff(id)
        #expect(!inset.isHoldingHandoffHeight)
    }

    @Test func aHandoffWithoutAnInsetIsHarmless() throws {
        let control = try makeControl(enabled: true)
        let id = control.beginKeyboardHandoff()
        control.endKeyboardHandoff(id)
        #expect(control.keyboardInset == nil)
    }

    // MARK: Typing from the key bar

    @Test func symbolKeysTypeIntoTheFieldOnlyWhileItIsActive() throws {
        let control = try makeControl(enabled: false)
        let mounted = mountField(control)
        defer { unmount(mounted) }
        #expect(!control.typeIntoField("|"))
        #expect(mounted.field.text.isEmpty)
        control.setEnabled(true)
        control.isAvailable = false
        #expect(!control.typeIntoField("|"))
        #expect(mounted.field.text.isEmpty)
        control.isAvailable = true
        #expect(control.typeIntoField("|"))
        #expect(mounted.field.text == "|")
    }

    @Test func symbolKeysGoNowhereWithNoFieldMounted() throws {
        let control = try makeControl(enabled: true)
        #expect(!control.typeIntoField("~"))
    }

    // MARK: Control keys

    @Test func aControlChordClearsTheFieldOnlyWhileTheComposerIsOn() throws {
        let control = try makeControl(enabled: true)
        let mounted = mountField(control)
        defer { unmount(mounted) }
        mounted.field.text = "half a line"
        control.fieldDidChange(mounted.field.text)
        control.controlKeyWillBeSent(.controlC)
        #expect(mounted.field.text.isEmpty)
        #expect(control.mirror.committed.isEmpty)

        control.setEnabled(false)
        mounted.field.text = "kept"
        control.fieldDidChange("kept")
        control.controlKeyWillBeSent(.escape)
        #expect(mounted.field.text == "kept")
        #expect(control.mirror.committed == "kept")
    }

    // MARK: Backspace

    @Test func backspaceOnAnEmptyFieldReachesTheRemoteLine() throws {
        let control = try makeControl(enabled: true)
        let mounted = mountField(control)
        defer { unmount(mounted) }
        control.fieldDidChange("typed before the composer")
        #expect(control.focusField())
        mounted.field.text = ""
        mounted.field.deleteBackward()
        // The remote line is no longer the one the mirror described, so the
        // next diff retypes in full.
        #expect(control.mirror.committed.isEmpty)
        #expect(mounted.field.text.isEmpty)
    }

    @Test func backspaceWithTextEditsTheFieldAndLeavesTheMirrorAlone() throws {
        let control = try makeControl(enabled: true)
        let mounted = mountField(control)
        defer { unmount(mounted) }
        #expect(control.focusField())
        mounted.field.text = "abc"
        control.fieldDidChange("abc")
        mounted.field.deleteBackward()
        #expect(mounted.field.text == "ab")
        #expect(control.mirror.committed == "abc")
    }

    // MARK: The delegate

    @Test func returnSubmitsAndClearsTheField() throws {
        let control = try makeControl(enabled: true)
        let mounted = mountField(control)
        defer { unmount(mounted) }
        let coordinator = TerminalComposerView.Coordinator(control: control)
        mounted.field.delegate = coordinator
        mounted.field.text = "ls -la"
        control.fieldDidChange(mounted.field.text)
        let allowed = coordinator.textView(
            mounted.field, shouldChangeTextIn: NSRange(location: 6, length: 0),
            replacementText: "\n")
        #expect(!allowed)
        #expect(mounted.field.text.isEmpty)
        #expect(control.mirror.committed.isEmpty)
    }

    @Test func aPastedBlockIsAllowedAndLandsSanitized() throws {
        let control = try makeControl(enabled: true)
        let mounted = mountField(control)
        defer { unmount(mounted) }
        let coordinator = TerminalComposerView.Coordinator(control: control)
        mounted.field.delegate = coordinator
        let paste = "one\ntwo\tthree"
        let allowed = coordinator.textView(
            mounted.field, shouldChangeTextIn: NSRange(location: 0, length: 0),
            replacementText: paste)
        #expect(allowed)
        mounted.field.text = paste
        coordinator.textViewDidChange(mounted.field)
        // The field keeps the paste; the PTY's line never sees a control byte.
        #expect(control.mirror.committed == "one two three")
    }

    // MARK: The soft newline

    @Test func theSoftNewlineKeyClearsTheFieldAndStartsTheLineOver() throws {
        let control = try makeControl(enabled: true)
        let mounted = mountField(control)
        defer { unmount(mounted) }
        mounted.field.text = "first line"
        control.fieldDidChange(mounted.field.text)
        #expect(control.softNewlineFromKeyBar())
        #expect(mounted.field.text.isEmpty)
        #expect(control.mirror.committed.isEmpty)
    }

    @Test func theSoftNewlineKeyDoesNothingWhileTheComposerIsNotActive() throws {
        let control = try makeControl(enabled: false)
        let mounted = mountField(control)
        defer { unmount(mounted) }
        mounted.field.text = "kept"
        #expect(!control.softNewlineFromKeyBar())
        #expect(mounted.field.text == "kept")
        control.setEnabled(true)
        control.isAvailable = false
        #expect(!control.softNewlineFromKeyBar())
        #expect(mounted.field.text == "kept")
    }
}
