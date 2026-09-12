import Foundation
import Testing

@testable import Heeler

@MainActor
@Suite("Terminal input controller")
struct TerminalInputControllerTests {
    @Test func singleLinePasteInsertsImmediately() {
        var writes: [Data] = []
        let controller = TerminalInputController()
        _ = controller.beginSession { writes.append($0) }

        #expect(controller.requestPaste("git status") == .inserted)
        #expect(writes == [Data("git status".utf8)])
        #expect(controller.pendingPaste == nil)
    }

    @Test func multilinePasteRequiresReviewAndConfirmsAsOneWrite() throws {
        var writes: [Data] = []
        let controller = TerminalInputController()
        _ = controller.beginSession { writes.append($0) }
        let text = "printf one\nprintf two\n"

        let result = controller.requestPaste(text)

        guard case .requiresReview(let review) = result else {
            Issue.record("expected multiline review")
            return
        }
        #expect(review.lineCount == 3)
        #expect(review.characterCount == text.count)
        #expect(review.preview == text)
        #expect(writes.isEmpty)

        #expect(controller.confirmPaste())
        #expect(writes == [Data(text.utf8)])
        #expect(controller.pendingPaste == nil)
    }

    @Test func reviewedPasteWaitsForTheReplacementWriterAndSubmitsOnce() throws {
        var oldWrites: [Data] = []
        var replacementWrites: [Data] = []
        let controller = TerminalInputController()
        let oldGeneration = controller.beginSession { oldWrites.append($0) }
        let text = "git status\ngit diff"

        #expect(controller.requestPaste(text, bracketedPaste: true).requiresReview)
        let review = try #require(controller.pendingPaste)
        controller.detachSessionForReplacement()
        controller.endSession(oldGeneration, preservingPendingPaste: true)

        #expect(!controller.canConfirmPaste)
        #expect(!controller.confirmPaste())
        #expect(controller.pendingPaste == review)
        #expect(oldWrites.isEmpty)

        _ = controller.beginSession { replacementWrites.append($0) }
        #expect(controller.canConfirmPaste)
        #expect(controller.confirmPaste())
        #expect(
            replacementWrites == [
                TerminalBracketedPaste.start + Data(text.utf8) + TerminalBracketedPaste.end
            ])
        #expect(controller.pendingPaste == nil)
        #expect(!controller.confirmPaste())
        #expect(replacementWrites.count == 1)
    }

    @Test func ordinarySessionEndStillCancelsReviewedPaste() {
        let controller = TerminalInputController()
        let generation = controller.beginSession { _ in }

        #expect(controller.requestPaste("git status\ngit diff").requiresReview)
        controller.endSession(generation)

        #expect(controller.pendingPaste == nil)
        #expect(!controller.canConfirmPaste)
    }

    @Test func cancelIsTheSafeMultilineDefault() {
        var writes: [Data] = []
        let controller = TerminalInputController()
        _ = controller.beginSession { writes.append($0) }
        #expect(controller.requestPaste("one\ntwo").requiresReview)

        controller.cancelPaste()

        #expect(controller.pendingPaste == nil)
        #expect(writes.isEmpty)
    }

    @Test(arguments: [
        "nul\u{0}hidden",
        "escape\u{1B}[31m",
        "control\u{1F}hidden",
        "delete\u{7F}hidden",
        "c1\u{85}hidden",
    ])
    func unsafeClipboardControlsAreRejected(text: String) {
        var writes: [Data] = []
        let controller = TerminalInputController()
        _ = controller.beginSession { writes.append($0) }

        #expect(controller.requestPaste(text) == .rejected)
        #expect(controller.pasteErrorMessage != nil)
        #expect(controller.pendingPaste == nil)
        #expect(writes.isEmpty)
    }

    @Test func pastePreviewIsBoundedWithoutChangingConfirmedContent() {
        var writes: [Data] = []
        let controller = TerminalInputController()
        _ = controller.beginSession { writes.append($0) }
        let text = String(repeating: "x", count: 3_000) + "\nsecond"

        guard case .requiresReview(let review) = controller.requestPaste(text) else {
            Issue.record("expected multiline review")
            return
        }
        #expect(review.preview.count < text.count)
        #expect(review.preview.hasSuffix("…"))

        #expect(controller.confirmPaste())
        #expect(writes == [Data(text.utf8)])
    }

    @Test func snippetsGoOutWholeAndNeverSubmit() {
        var writes: [Data] = []
        let controller = TerminalInputController()
        _ = controller.beginSession { writes.append($0) }

        #expect(controller.insertSnippet("run the tests", bracketedPaste: true))

        #expect(writes == [Data("run the tests".utf8)])
        #expect(!writes.contains { $0.contains(0x0D) })
    }

    @Test func multilineSnippetsAreFramedAsAPasteWhenTheRemoteAskedForIt() {
        var writes: [Data] = []
        let controller = TerminalInputController()
        _ = controller.beginSession { writes.append($0) }

        #expect(controller.insertSnippet("first\nsecond", bracketedPaste: true))

        #expect(
            writes == [
                TerminalBracketedPaste.start + Data("first\nsecond".utf8)
                    + TerminalBracketedPaste.end
            ])
    }

    @Test func withoutBracketedPasteTheMarkersAreNotSent() {
        // The markers would be echoed as literal garbage by an application
        // that never enabled DECSET 2004.
        var writes: [Data] = []
        let controller = TerminalInputController()
        _ = controller.beginSession { writes.append($0) }

        #expect(controller.insertSnippet("first\nsecond", bracketedPaste: false))

        #expect(writes == [Data("first\nsecond".utf8)])
    }

    @Test func reviewedMultilinePasteIsFramedWithTheModeCapturedAtRequestTime() {
        var writes: [Data] = []
        let controller = TerminalInputController()
        _ = controller.beginSession { writes.append($0) }
        let text = "one\ntwo\nthree"

        #expect(controller.requestPaste(text, bracketedPaste: true).requiresReview)
        #expect(controller.confirmPaste())

        #expect(
            writes == [
                TerminalBracketedPaste.start + Data(text.utf8) + TerminalBracketedPaste.end
            ])
    }

    @Test func snippetWithUnsafeControlCharactersIsRefused() {
        var writes: [Data] = []
        let controller = TerminalInputController()
        _ = controller.beginSession { writes.append($0) }

        #expect(!controller.insertSnippet("escape\u{1B}[31m", bracketedPaste: true))
        #expect(writes.isEmpty)
    }

    @Test func snippetsRequireALiveSession() {
        let controller = TerminalInputController()

        #expect(!controller.insertSnippet("continue", bracketedPaste: true))
    }

    @Test func sendRequiresALiveSessionAndWritesRawBytes() {
        let controller = TerminalInputController()
        #expect(!controller.send(Data("n".utf8)))

        var writes: [Data] = []
        _ = controller.beginSession { writes.append($0) }

        #expect(controller.send(Data("n".utf8)))
        #expect(writes == [Data("n".utf8)])
        #expect(!writes.contains { $0.contains(0x0D) })
    }

    @Test func sendObservesPrintableBytesAndClosesTheIndexedLineOnEnter() {
        let controller = TerminalInputController()
        _ = controller.beginSession { _ in }
        let text = "please implement the parser"

        #expect(controller.send(Data(text.utf8)))
        #expect(controller.userMessageIndex.entries.isEmpty)

        #expect(controller.send(Data([0x0D])))
        #expect(controller.userMessageIndex.entries.map(\.rawText) == [text])
    }

    @Test func endingASessionClearsTheUserMessageIndex() {
        let controller = TerminalInputController()
        let generation = controller.beginSession { _ in }
        #expect(controller.send(Data("please implement the parser".utf8)))
        #expect(controller.send(Data([0x0D])))
        #expect(!controller.userMessageIndex.entries.isEmpty)

        controller.endSession(generation)
        #expect(controller.userMessageIndex.entries.isEmpty)
    }

    @Test func aReplacementSessionDoesNotKeepThePredecessorIndex() {
        let controller = TerminalInputController()
        _ = controller.beginSession { _ in }
        #expect(controller.send(Data("please implement the parser".utf8)))
        #expect(controller.send(Data([0x0D])))
        #expect(!controller.userMessageIndex.entries.isEmpty)

        controller.detachSessionForReplacement()
        #expect(controller.userMessageIndex.entries.isEmpty)

        _ = controller.beginSession { _ in }
        #expect(controller.userMessageIndex.entries.isEmpty)
        #expect(controller.send(Data("rewrite the matching tests".utf8)))
        #expect(controller.send(Data([0x0D])))
        #expect(
            controller.userMessageIndex.entries.map(\.rawText)
                == ["rewrite the matching tests"])
    }

    @Test func recordSubmittedDropsWhenTheGenerationIsNoLongerLive() {
        let controller = TerminalInputController()
        let generationA = controller.beginSession { _ in }
        controller.detachSessionForReplacement()
        let generationB = controller.beginSession { _ in }

        controller.recordSubmitted("Fix the failing tests", generation: generationA)
        #expect(controller.userMessageIndex.entries.isEmpty)

        controller.recordSubmitted("rewrite the matching tests", generation: generationB)
        #expect(
            controller.userMessageIndex.entries.map(\.rawText)
                == ["rewrite the matching tests"])
    }

    @Test func sendClosesTheIndexedLineOnLineFeed() {
        let controller = TerminalInputController()
        _ = controller.beginSession { _ in }
        let text = "please implement the parser"

        #expect(controller.send(Data(text.utf8)))
        #expect(controller.send(Data([0x0A])))
        #expect(controller.userMessageIndex.entries.map(\.rawText) == [text])
    }

    @Test func keystrokeEscapeDoesNotDiscardATypedLine() {
        let controller = TerminalInputController()
        _ = controller.beginSession { _ in }

        #expect(controller.send(Data("please implement ".utf8)))
        #expect(controller.send(Data([0x1B])))
        #expect(controller.send(Data("the parser".utf8)))
        #expect(controller.send(Data([0x0D])))
        #expect(
            controller.userMessageIndex.entries.map(\.rawText)
                == ["please implement the parser"])
    }

    @Test func composerDraftEscapeCancelsPendingText() {
        let controller = TerminalInputController()
        _ = controller.beginSession { _ in }

        #expect(controller.insertComposerDraft("please approve"))
        #expect(controller.userMessageIndex.entries.isEmpty)
        #expect(controller.sendEscapeKey())
        #expect(controller.send(Data([0x0D])))
        #expect(controller.userMessageIndex.entries.isEmpty)
    }

    @Test func escapeKeyThenABracketRequestDoesNotKeepComposerInsertedText() {
        let controller = TerminalInputController()
        _ = controller.beginSession { _ in }

        #expect(controller.insertComposerDraft("please approve"))
        #expect(controller.sendEscapeKey())
        #expect(controller.send(Data("[review] do it".utf8)))
        #expect(controller.send(Data([0x0D])))
        #expect(
            controller.userMessageIndex.entries.map(\.rawText) == ["[review] do it"])
    }

    @Test func bracketedPasteWithCRLFIsOneEntryAtSubmit() {
        let controller = TerminalInputController()
        _ = controller.beginSession { _ in }
        let text = "please approve\r\nthen continue"

        #expect(controller.requestPaste(text, bracketedPaste: true).requiresReview)
        #expect(controller.confirmPaste())
        #expect(controller.userMessageIndex.entries.isEmpty)

        #expect(controller.send(Data([0x0D])))
        #expect(controller.userMessageIndex.entries.map(\.rawText) == [text])
    }

    @Test func hardwareEscapeAfterComposerInsertCancelsBeforeABracketRequest() {
        let controller = TerminalInputController()
        _ = controller.beginSession { _ in }

        #expect(controller.insertComposerDraft("please approve"))
        #expect(controller.send(Data([0x1B])))
        #expect(controller.send(Data("[review] do it".utf8)))
        #expect(controller.send(Data([0x0D])))
        #expect(
            controller.userMessageIndex.entries.map(\.rawText) == ["[review] do it"])
    }
}

@Suite("Terminal text safety")
struct TerminalTextSafetyTests {
    @Test(arguments: [
        ("please approve", false),
        ("please\napprove", true),
        ("please\rapprove", true),
        ("please approve\r\nthen continue", true),
    ])
    func isMultilineUsesUnicodeScalars(_ text: String, _ expected: Bool) {
        #expect(TerminalTextSafety.isMultiline(text) == expected)
    }
}

@Suite("Terminal text rewrite")
struct TerminalTextRewriteTests {
    /// `"word "` already typed and already on the Host, with the caret at the
    /// end: the document UIKit rewrites against.
    private func rewrite(
        replaced: String?,
        rangeEnd: Int?,
        documentLength: Int = 5,
        caret: NSRange? = nil,
        text: String,
        hasMarkedText: Bool = false,
        hasHardwareKeyboard: Bool = false
    ) -> TerminalTextRewrite {
        TerminalTextRewrite.forReplacement(
            replacedText: replaced,
            replacedRangeEnd: rangeEnd,
            documentLength: documentLength,
            caret: caret ?? NSRange(location: documentLength, length: 0),
            text: text,
            hasMarkedText: hasMarkedText,
            hasHardwareKeyboard: hasHardwareKeyboard)
    }

    /// The bug in Anthony's words: "double space on ios sends a full stop
    /// after the stop where itd normally put it before the first space".
    @Test func doubleSpaceShortcutTakesTheSpaceBackBeforeTypingTheStop() {
        #expect(
            rewrite(replaced: " ", rangeEnd: 5, text: ". ")
                == .backspaceThenInsert(backspaces: 1, text: ". "))
    }

    @Test func autocorrectionTakesTheWholeWordBack() {
        #expect(
            rewrite(replaced: "teh", rangeEnd: 5, text: "the")
                == .backspaceThenInsert(backspaces: 3, text: "the"))
    }

    @Test func anEmptyRangeIsAPlainInsert() {
        #expect(rewrite(replaced: "", rangeEnd: 5, text: "x") == .insert("x"))
        // An empty range anywhere is still an insert: nothing is taken back.
        #expect(rewrite(replaced: "", rangeEnd: 2, text: "x") == .insert("x"))
    }

    /// DEL only ever walks backwards from the caret, so a range that stops
    /// short of the end of the line cannot be expressed as remote edits.
    @Test func aRangeThatIsNotASuffixIsLeftToThePlainInsertPath() {
        #expect(rewrite(replaced: "or", rangeEnd: 3, text: "ar") == .unsupported)
    }

    @Test func nonPrintableReplacedTextIsLeftToThePlainInsertPath() {
        #expect(rewrite(replaced: "\t", rangeEnd: 5, text: ". ") == .unsupported)
        #expect(rewrite(replaced: "\u{1B}", rangeEnd: 5, text: ". ") == .unsupported)
        // A wide character is one UIKit index and an unknown number of cells.
        #expect(rewrite(replaced: "漢", rangeEnd: 5, text: ". ") == .unsupported)
    }

    @Test func markedTextKeepsGhosttysOwnCompositionPath() {
        #expect(
            rewrite(replaced: " ", rangeEnd: 5, text: ". ", hasMarkedText: true)
                == .unsupported)
    }

    /// The hardware keyboard path is untouched: its presses are already
    /// encoded key events and the "." shortcut is a software-keyboard rule.
    @Test func aHardwareKeyboardIsLeftAlone() {
        #expect(
            rewrite(
                replaced: " ", rangeEnd: 5, text: ". ", hasHardwareKeyboard: true)
                == .unsupported)
    }

    @Test func anUnrecognisedRangeIsLeftToThePlainInsertPath() {
        #expect(rewrite(replaced: nil, rangeEnd: nil, text: ". ") == .unsupported)
        #expect(rewrite(replaced: " ", rangeEnd: nil, text: ". ") == .unsupported)
    }

    /// Nothing tells UIKit that an arrow key moved the remote caret, so its
    /// offsets can still describe the end of the line while the shadow knows
    /// the caret is in the middle of it. The shadow is the one that decides.
    @Test func aCaretAwayFromTheEndOfTheLineRefuses() {
        #expect(
            rewrite(
                replaced: " ", rangeEnd: 5,
                caret: NSRange(location: 3, length: 0), text: ". ")
                == .unsupported)
        // A live selection is not a caret at the end either.
        #expect(
            rewrite(
                replaced: " ", rangeEnd: 5,
                caret: NSRange(location: 4, length: 1), text: ". ")
                == .unsupported)
    }
}

/// The count that stops a DEL the app sent itself being applied twice when its
/// echo comes back a run-loop turn later — and that has to give the count up
/// when the echo never arrives.
@Suite("Terminal shadow delete echoes")
struct TerminalShadowDeleteEchoesTests {
    /// `consumeEcho` mutates, so every answer is taken before it is asserted:
    /// `#expect` captures its expression in a closure, which a mutating call
    /// on a local `var` cannot live inside.
    @Test func anEchoIsConsumedOnceEach() {
        var echoes = TerminalShadowDeleteEchoes()
        echoes.record(now: 100)
        echoes.record(now: 100)
        let first = echoes.consumeEcho(now: 100)
        let second = echoes.consumeEcho(now: 100)
        // A third DEL is the user's, not an echo.
        let third = echoes.consumeEcho(now: 100)
        #expect(first)
        #expect(second)
        #expect(!third)
    }

    /// An echo that never arrives — a surface replaced mid-edit, a pane paused
    /// — must not swallow the next real Backspace, and never the one after.
    @Test func aLostEchoExpiresInsteadOfSwallowingTheNextBackspace() {
        var echoes = TerminalShadowDeleteEchoes()
        echoes.record(now: 100)
        let afterLeash = echoes.consumeEcho(
            now: 100 + TerminalShadowDeleteEchoes.leash + 0.01)
        let later = echoes.consumeEcho(now: 200)
        let pending = echoes.pending
        #expect(!afterLeash)
        #expect(!later)
        #expect(pending == 0)
    }

    @Test func anEchoStillInsideTheLeashIsConsumed() {
        var echoes = TerminalShadowDeleteEchoes()
        echoes.record(now: 100)
        let consumed = echoes.consumeEcho(
            now: 100 + TerminalShadowDeleteEchoes.leash - 0.01)
        #expect(consumed)
    }

    /// Any other write means the echoes have been overtaken.
    @Test func anyOtherInputGivesTheCountUp() {
        var echoes = TerminalShadowDeleteEchoes()
        echoes.record(now: 100)
        echoes.record(now: 100)
        echoes.reset()
        let consumed = echoes.consumeEcho(now: 100)
        #expect(!consumed)
    }

    /// A rewrite takes back a word, not a paragraph.
    @Test func theCountIsBounded() {
        var echoes = TerminalShadowDeleteEchoes()
        for _ in 0..<1_000 { echoes.record(now: 100) }
        let pending = echoes.pending
        #expect(pending == TerminalShadowDeleteEchoes.maximum)
    }
}

/// The app's model of the line it has typed, and what each write does to it.
///
/// This is what ``TerminalTextRewrite`` counts its DELs against, so a model
/// that has silently stopped describing the line is how a rewrite over-deletes
/// (round 12, finding 6).
@Suite("Terminal input shadow")
struct TerminalInputShadowTests {
    private func typed(_ text: String) -> TerminalInputShadow {
        var shadow = TerminalInputShadow()
        shadow.apply(.insert(text))
        return shadow
    }

    @Test func classifiesTheWritesItCanModel() {
        #expect(TerminalShadowInput.classify(Data("ab".utf8)) == .insert("ab"))
        #expect(TerminalShadowInput.classify(Data([0x7F])) == .deleteBackward)
        #expect(TerminalShadowInput.classify(Data([0x1B, 0x5B, 0x44])) == .moveLeft)
        #expect(TerminalShadowInput.classify(Data([0x1B, 0x4F, 0x43])) == .moveRight)
        #expect(TerminalShadowInput.classify(Data([0x1B, 0x5B, 0x48])) == .moveToLineStart)
        #expect(TerminalShadowInput.classify(Data([0x1B, 0x5B, 0x46])) == .moveToLineEnd)
        #expect(TerminalShadowInput.classify(Data()) == .ignore)
    }

    /// Esc, a word-wise editing chord, an agent's own encoding: anything the
    /// model cannot describe empties it rather than letting it drift.
    @Test(arguments: [
        [0x1B] as [UInt8],  // Escape
        [0x1B, 0x7F],  // Option+Backspace, delete word backward
        [0x1B, 0x62],  // ESC b, word left
        [0x1B, 0x5B, 0x41],  // Up arrow: history recall replaces the line
        [0x03],  // Ctrl+C
    ])
    func anUnmodelledWriteEmptiesTheShadow(bytes: [UInt8]) {
        #expect(TerminalShadowInput.classify(Data(bytes)) == .reset)
        var shadow = typed("hello")
        shadow.apply(TerminalShadowInput.classify(Data(bytes)))
        #expect(shadow.text.isEmpty)
        #expect(shadow.selection == NSRange(location: 0, length: 0))
    }

    /// The rewrite still fires on a line that was only ever typed.
    @Test func aRewriteStillFiresAfterPlainTyping() {
        let shadow = typed("word ")
        #expect(
            TerminalTextRewrite.forReplacement(
                replacedText: shadow.substring(in: NSRange(location: 4, length: 1)),
                replacedRangeEnd: 5,
                documentLength: shadow.length,
                caret: shadow.selection,
                text: ". ",
                hasMarkedText: false,
                hasHardwareKeyboard: false)
                == .backspaceThenInsert(backspaces: 1, text: ". "))
    }

    /// And refuses after one it could not model — the escape left the model
    /// describing a line that no longer exists, so there is nothing honest to
    /// count DELs against.
    @Test func aRewriteRefusesAfterAnUnmodelledEscape() {
        var shadow = typed("word ")
        shadow.apply(TerminalShadowInput.classify(Data([0x1B, 0x62])))
        #expect(
            TerminalTextRewrite.forReplacement(
                replacedText: shadow.substring(in: NSRange(location: 4, length: 1)),
                replacedRangeEnd: 5,
                documentLength: shadow.length,
                caret: shadow.selection,
                text: ". ",
                hasMarkedText: false,
                hasHardwareKeyboard: false)
                == .unsupported)
    }

    /// Anthony's case: type a word, go back to fix it, and let the keyboard
    /// rewrite. The caret is no longer at the end of the line, so the range
    /// UIKit offers is not a suffix and the DELs never go out.
    @Test func arrowingBackMovesTheCaretSoARewriteIsNoLongerASuffix() {
        var shadow = typed("hello wrold")
        for _ in 0..<3 { shadow.apply(.moveLeft) }
        #expect(shadow.selection == NSRange(location: 8, length: 0))
        #expect(shadow.text == "hello wrold")
        #expect(
            TerminalTextRewrite.forReplacement(
                replacedText: shadow.substring(in: NSRange(location: 6, length: 2)),
                replacedRangeEnd: 8,
                documentLength: shadow.length,
                caret: shadow.selection,
                text: "or",
                hasMarkedText: false,
                hasHardwareKeyboard: false)
                == .unsupported)
    }

    /// The stale-caret case: nothing calls `selectionDidChange` when an arrow
    /// key moves the remote caret, so UIKit can still offer a range that ends
    /// at the end of the document. Arrow left, then the double-space shortcut,
    /// and the rewrite must refuse — the DELs would land mid-line.
    @Test func arrowLeftThenADoubleSpaceRefuses() {
        var shadow = typed("word ")
        shadow.apply(.moveLeft)
        #expect(shadow.selection == NSRange(location: 4, length: 0))
        #expect(
            TerminalTextRewrite.forReplacement(
                replacedText: " ",
                replacedRangeEnd: shadow.length,
                documentLength: shadow.length,
                caret: shadow.selection,
                text: ". ",
                hasMarkedText: false,
                hasHardwareKeyboard: false)
                == .unsupported)
    }

    /// Typing after a cursor move lands where the caret is, and leaves the
    /// caret after it — not at the end of the line, which is what would let a
    /// later rewrite delete characters the user never meant.
    @Test func typingLandsAtTheCaretAndLeavesItThere() {
        var shadow = typed("abc")
        shadow.apply(.moveLeft)
        shadow.apply(.insert("x"))
        #expect(shadow.text == "abxc")
        #expect(shadow.selection == NSRange(location: 3, length: 0))
    }

    /// DEL never takes more than the model holds: at the start of the line
    /// there is nothing to take, because the prompt is not the app's to edit.
    @Test func deleteNeverTakesMoreThanTheShadowHolds() {
        var shadow = typed("ab")
        for _ in 0..<6 { shadow.apply(.deleteBackward) }
        #expect(shadow.text.isEmpty)
        #expect(shadow.selection == NSRange(location: 0, length: 0))
        #expect(shadow.deletionRange == nil)
    }

    @Test func homeAndEndPutTheCaretAtTheEndsOfTheTypedLine() {
        var shadow = typed("abcd")
        shadow.apply(.moveToLineStart)
        #expect(shadow.selection == NSRange(location: 0, length: 0))
        shadow.apply(.moveLeft)
        #expect(shadow.selection == NSRange(location: 0, length: 0))
        shadow.apply(.moveToLineEnd)
        #expect(shadow.selection == NSRange(location: 4, length: 0))
        shadow.apply(.moveRight)
        #expect(shadow.selection == NSRange(location: 4, length: 0))
    }

    /// Enter executes the line, so nothing before it is editable any more.
    @Test func aNewlineStartsTheLineAgain() {
        var shadow = typed("ls -la")
        shadow.apply(.insert("\r"))
        #expect(shadow.text.isEmpty)
        shadow.apply(.insert("next"))
        #expect(shadow.text == "next")
        #expect(shadow.selection == NSRange(location: 4, length: 0))
    }

    /// A range the model does not hold answers nil, which is how a rewrite
    /// learns UIKit's offsets have gone stale.
    @Test func substringRefusesRangesTheShadowDoesNotHold() {
        let shadow = typed("abc")
        #expect(shadow.substring(in: NSRange(location: 1, length: 2)) == "bc")
        #expect(shadow.substring(in: NSRange(location: 2, length: 9)) == nil)
        #expect(shadow.substring(in: NSRange(location: -1, length: 1)) == nil)
    }
}
