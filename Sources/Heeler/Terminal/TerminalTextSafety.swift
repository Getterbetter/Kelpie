import Foundation

/// The one place that decides what arbitrary text may look like before it is
/// allowed to reach a pane, and how it is framed on the wire. Terminal Paste
/// and Snippets both go through here so they cannot drift into different
/// answers to the same question.
enum TerminalTextSafety {
    /// Tab, line feed, and carriage return are the only control characters
    /// text may carry. Everything else — escapes above all — would be read as
    /// a command by the remote terminal rather than as content.
    static func containsOnlySafeScalars(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 0x09, 0x0A, 0x0D:
                true
            default:
                scalar.properties.generalCategory != .control
            }
        }
    }

    /// Collapses CRLF and lone CR to LF.
    ///
    /// This is the difference that matters for Snippets: the Enter key sends
    /// CR (0x0D), so a carriage return that came in with text pasted from
    /// elsewhere is a submit byte in disguise. LF is not.
    static func normalizingNewlines(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    /// True when `text` contains a CR or LF scalar. Compared on unicode
    /// scalars because Swift treats `"\r\n"` as one `Character`, so a
    /// grapheme `contains("\n")` misses CRLF.
    static func isMultiline(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            scalar.value == 0x0A || scalar.value == 0x0D
        }
    }
}

/// What the software keyboard's *replace this range with this text* means for
/// a pane that has already been sent the range.
///
/// UIKit hands a text view rewrites of text the user has typed: the "."
/// shortcut (two spaces) replaces the trailing space with `". "`, and
/// autocorrection replaces a whole word. A text view edits its own storage;
/// this app has already put those characters on the Host, so a rewrite is only
/// faithful if the replaced characters are taken back first — one DEL (0x7F)
/// each, the byte Backspace already sends — and the new text typed after. The
/// vendored terminal ignores the range and inserts, which lands the stop
/// *after* the space instead of before it.
enum TerminalTextRewrite: Equatable {
    /// Nothing to take back: type the text as it stands.
    case insert(String)
    /// Take `backspaces` characters off the remote line, then type the text.
    case backspaceThenInsert(backspaces: Int, text: String)
    /// Not safely expressible as remote edits; leave it to the plain insert
    /// path rather than guess at DEL bytes.
    case unsupported

    /// Only a suffix of the line this app believes it has typed can be taken
    /// back: DEL walks backwards from the caret and nothing else, so a range
    /// that stops short of the end of the document is refused. Non-printable
    /// replaced text is refused for the same reason — one DEL does not
    /// reliably undo a tab, a control byte, or a character the remote drew in
    /// two cells.
    ///
    /// A hardware keyboard never takes this path: its presses are already
    /// encoded key events, and the "." shortcut is a software-keyboard
    /// behaviour.
    ///
    /// - Parameter caret: the *shadow's* own selection. UIKit's offsets are not
    ///   enough on their own: nothing calls `selectionDidChange` when an arrow
    ///   key moves the remote caret, so UIKit can still be offering a range
    ///   that ends where it last believed the caret was. A take-back is only
    ///   honest when the model and UIKit agree the caret is at the end of the
    ///   line, with nothing selected.
    ///
    /// The alternate screen is deliberately *not* a refusal. The root screen is
    /// always on it — herdr's own TUI puts it there — and the agent TUIs inside
    /// it (claude, codex, grok) draw a line-editing input box that reads DEL as
    /// Backspace, which is exactly where Anthony hit the bug. See ADR 0016.
    static func forReplacement(
        replacedText: String?,
        replacedRangeEnd: Int?,
        documentLength: Int,
        caret: NSRange,
        text: String,
        hasMarkedText: Bool,
        hasHardwareKeyboard: Bool
    ) -> TerminalTextRewrite {
        guard !hasMarkedText, !hasHardwareKeyboard else { return .unsupported }
        guard caret.length == 0, caret.location == documentLength else {
            return .unsupported
        }
        guard let replacedText, let replacedRangeEnd else { return .unsupported }
        guard replacedText.isEmpty || replacedRangeEnd == documentLength else {
            return .unsupported
        }
        if replacedText.isEmpty { return .insert(text) }
        guard replacedText.unicodeScalars.allSatisfy({ (0x20...0x7E).contains($0.value) })
        else { return .unsupported }
        return .backspaceThenInsert(backspaces: replacedText.count, text: text)
    }
}

/// DECSET 2004 framing. Wrapping text tells the remote application it was
/// pasted, so a TUI can take it as one block instead of interpreting each
/// newline as its own key event — and agents that collapse large pastes get
/// the chance to do so.
enum TerminalBracketedPaste {
    static let start = Data([0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E])
    static let end = Data([0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E])

    /// The bytes to write for `text`, framed only when the remote application
    /// asked for framing. Without DECSET 2004 the markers would be echoed as
    /// literal garbage, which is worse than the problem they solve.
    static func encode(_ text: String, bracketed: Bool) -> Data {
        let body = Data(text.utf8)
        guard bracketed else { return body }
        return start + body + end
    }
}

/// What one write to the PTY means for the app's shadow of the current line.
///
/// The shadow exists so UIKit has a document to rewrite against (see
/// ``TerminalTextRewrite``) and so Backspace can watch a selection shrink and
/// keep its key repeat. It is only ever a model: the real line lives on the
/// Host, and the only evidence this side has of what happened to it is the
/// bytes the app sent. Anything those bytes cannot be read as — an escape
/// sequence for a key this does not model, a control byte, a chord — means the
/// model has stopped describing the line, and the honest answer is to say so
/// rather than to keep counting against a fiction. ``reset`` is that answer:
/// the shadow empties, and every rewrite refuses until typing rebuilds it.
///
/// Deliberately pure, and deliberately small. Only the edits a person makes to
/// a line they are typing are modelled — move, delete, type.
enum TerminalShadowInput: Equatable {
    /// Nothing was written.
    case ignore
    /// Printable text (and newlines) went out and lands at the caret.
    case insert(String)
    /// One DEL: the character before the caret is gone.
    case deleteBackward
    case moveLeft
    case moveRight
    /// Home and End, in the legacy spellings ``TerminalHardwareKeyMapping``
    /// writes and Ghostty's own encoder produces.
    case moveToLineStart
    case moveToLineEnd
    /// Unmodelled. Drop the shadow rather than let it drift.
    case reset

    /// Byte sequences this understands. CSI (`ESC [`) and SS3 (`ESC O`) forms
    /// both appear: a terminal in application-cursor-key mode (DECCKM, which
    /// every full-screen agent TUI sets) sends the SS3 spelling of the arrows.
    private static let sequences: [([UInt8], TerminalShadowInput)] = [
        ([0x1B, 0x5B, 0x44], .moveLeft),
        ([0x1B, 0x4F, 0x44], .moveLeft),
        ([0x1B, 0x5B, 0x43], .moveRight),
        ([0x1B, 0x4F, 0x43], .moveRight),
        ([0x1B, 0x5B, 0x48], .moveToLineStart),
        ([0x1B, 0x4F, 0x48], .moveToLineStart),
        ([0x1B, 0x5B, 0x31, 0x7E], .moveToLineStart),
        ([0x1B, 0x5B, 0x37, 0x7E], .moveToLineStart),
        ([0x1B, 0x5B, 0x46], .moveToLineEnd),
        ([0x1B, 0x4F, 0x46], .moveToLineEnd),
        ([0x1B, 0x5B, 0x34, 0x7E], .moveToLineEnd),
        ([0x1B, 0x5B, 0x38, 0x7E], .moveToLineEnd),
    ]

    static func classify(_ data: Data) -> TerminalShadowInput {
        if data.isEmpty { return .ignore }
        if data.elementsEqual([0x7F]) { return .deleteBackward }
        if data.first == 0x1B {
            for (bytes, edit) in sequences where data.elementsEqual(bytes) { return edit }
            // Every other escape sequence — Esc itself, a word-wise editing
            // chord, a cursor save, an agent's own key encoding — does
            // something to the line this cannot describe.
            return .reset
        }
        guard !data.contains(0x7F),
            !data.contains(where: { $0 < 0x20 && $0 != 0x0A && $0 != 0x0D }),
            let text = String(data: data, encoding: .utf8)
        else { return .reset }
        return .insert(text)
    }
}

/// The app's model of the line it has typed into the pane, and the caret in it.
///
/// Kept in UTF-16 units because that is the unit `UITextInput` counts in, and
/// trimmed to the current line — everything before the last newline has been
/// executed and is no longer editable by Backspace.
struct TerminalInputShadow: Equatable {
    private(set) var text = ""
    private(set) var selection = NSRange(location: 0, length: 0)

    var length: Int { (text as NSString).length }

    /// Empties the model. Called when a write arrives that it cannot describe:
    /// an empty document refuses every rewrite, which is the safe direction.
    mutating func reset() {
        text = ""
        selection = NSRange(location: 0, length: 0)
    }

    /// Moves the caret, clamping at both ends: the shadow holds the typed line
    /// and nothing either side of it.
    mutating func setSelection(_ range: NSRange) {
        let length = self.length
        let location = min(max(range.location, 0), length)
        let end = min(max(range.location + range.length, location), length)
        selection = NSRange(location: location, length: end - location)
    }

    /// Text the app just typed, landing at the caret — which then sits *after*
    /// it, not at the end of the line. The difference is the whole point once
    /// arrow keys move the caret: a rewrite is only allowed when the range it
    /// replaces ends at the caret, and a caret parked at the end of a line the
    /// user has moved into the middle of would let DELs fall on the wrong
    /// characters (round 12, finding 6).
    mutating func commit(_ committed: String) {
        let storage = NSMutableString(string: text)
        storage.replaceCharacters(in: selection, with: committed)
        var caret = selection.location + (committed as NSString).length
        let joined = storage as String

        // Everything up to the last newline has been executed: Backspace
        // cannot reach it, so it is not part of the line any more.
        if let lineBreak = joined.rangeOfCharacter(from: .newlines, options: .backwards) {
            let dropped = lineBreak.upperBound.utf16Offset(in: joined)
            text = String(joined[lineBreak.upperBound...])
            caret -= dropped
        } else {
            text = joined
        }
        setSelection(NSRange(location: caret, length: 0))
    }

    /// What a DEL takes off: the selection when there is one, otherwise the
    /// whole composed character before the caret. `nil` at the start of the
    /// line, where DEL reaches text the shadow does not hold.
    var deletionRange: NSRange? {
        if selection.length > 0 { return selection }
        guard selection.location > 0 else { return nil }
        return (text as NSString).rangeOfComposedCharacterSequence(
            at: selection.location - 1)
    }

    mutating func delete(in range: NSRange) {
        let storage = NSMutableString(string: text)
        guard range.location >= 0, range.length >= 0,
            range.location + range.length <= storage.length
        else { return }
        storage.deleteCharacters(in: range)
        text = storage as String
        selection = NSRange(location: range.location, length: 0)
    }

    /// `UITextInput`'s `text(in:)`: `nil` for a range the model does not hold,
    /// which is how a rewrite learns that UIKit's offsets have gone stale.
    func substring(in range: NSRange) -> String? {
        let storage = text as NSString
        guard range.location >= 0, range.length >= 0,
            range.location + range.length <= storage.length
        else { return nil }
        return storage.substring(with: range)
    }

    /// Applies one classified write. Cursor moves walk whole composed
    /// characters, so a flag or a combining sequence is one step either way.
    mutating func apply(_ edit: TerminalShadowInput) {
        switch edit {
        case .ignore:
            break
        case .insert(let committed):
            commit(committed)
        case .deleteBackward:
            guard let deletionRange else { break }
            delete(in: deletionRange)
        case .moveLeft:
            guard selection.location > 0 else {
                setSelection(NSRange(location: 0, length: 0))
                break
            }
            let previous = (text as NSString).rangeOfComposedCharacterSequence(
                at: selection.location - 1)
            setSelection(NSRange(location: previous.location, length: 0))
        case .moveRight:
            let storage = text as NSString
            guard selection.location < storage.length else {
                setSelection(NSRange(location: storage.length, length: 0))
                break
            }
            let next = storage.rangeOfComposedCharacterSequence(at: selection.location)
            setSelection(NSRange(location: next.location + next.length, length: 0))
        case .moveToLineStart:
            setSelection(NSRange(location: 0, length: 0))
        case .moveToLineEnd:
            setSelection(NSRange(location: length, length: 0))
        case .reset:
            reset()
        }
    }
}

/// DELs the app has already applied to its own shadow, waiting for their echo.
///
/// ``TerminalSessionCallbackBridge/send(_:)`` hops to the next run-loop turn,
/// so a DEL the app sends comes back through the same callback every other
/// write takes and would delete a second time. Counting them is what stops
/// that — but a count with no way out is worse than the double delete: one
/// echo that never arrives (a surface replaced mid-edit, a pane paused) would
/// swallow the echo of the *next* real Backspace, and the one after that,
/// forever. So the count expires two ways: a short leash, and any other write
/// at all, which means the echoes are no longer coming.
struct TerminalShadowDeleteEchoes: Equatable {
    /// Long enough for a run-loop hop under load, short enough that a lost
    /// echo costs at most one mis-counted Backspace.
    static let leash: TimeInterval = 0.5
    /// A rewrite takes back a word, not a paragraph.
    static let maximum = 64

    private(set) var pending = 0
    private var expiry: TimeInterval = 0

    /// The app just applied a DEL to the shadow and is about to write it.
    mutating func record(now: TimeInterval) {
        pending = min(pending + 1, Self.maximum)
        expiry = now + Self.leash
    }

    /// Whether this DEL is the echo of one already applied. Expired echoes are
    /// dropped first, so a stale count never swallows a real Backspace.
    mutating func consumeEcho(now: TimeInterval) -> Bool {
        if now > expiry { reset() }
        guard pending > 0 else { return false }
        pending -= 1
        return true
    }

    /// Any write that is not a DEL: whatever was owed has been overtaken.
    mutating func reset() {
        pending = 0
        expiry = 0
    }
}
