import Foundation

/// Finds the URL under one terminal cell, from the viewport's text alone.
///
/// libghostty reports a link only when it decides one was activated, and on
/// iOS nothing ever activates one: there is no "link at this point" query in
/// `ghostty.h` and no cmd-click to fire the action. So a tap is resolved here,
/// against the same viewport text the selection sheet reads. It has to be:
/// herdr hit-tests URL clicks itself and opens them with `open` **on the Mac**,
/// which is not where the person tapping is.
///
/// Deliberately pure. Wrapped URLs are the one piece of terminal-specific
/// knowledge: a URL that fills a row to its last cell continues on the next
/// one, and nothing in the text says so.
enum TerminalLinkDetector {
    /// Characters `https?://[^\s<>"'`]+` stops at.
    private static func isTerminator(_ character: Character) -> Bool {
        character.isWhitespace || "<>\"'`".contains(character)
    }

    /// Trailing sentence punctuation: prose ends "see https://x.dev." far more
    /// often than a URL ends in a full stop.
    private static let trailingPunctuation: Set<Character> = [
        ".", ",", ";", ":", "!", "?", ")", "]", "}", "'", "\"",
    ]

    /// `column` and `row` are 1-based, as they come off the grid mapper (and
    /// as an SGR mouse report would carry them). `width` is the grid's column
    /// count: a URL only continues on the next row if it reached the last
    /// column, and a row's *string* ends wherever the viewport read stopped
    /// padding it, which is not the same thing. Without a width, nothing is
    /// ever joined — a wrong URL is worse than a truncated one.
    static func url(inViewport text: String, column: Int, row: Int, width: Int? = nil) -> URL? {
        url(in: text.components(separatedBy: "\n"), column: column, row: row, width: width)
    }

    static func url(in rows: [String], column: Int, row: Int, width: Int? = nil) -> URL? {
        guard row >= 1, row <= rows.count, column >= 1 else { return nil }
        let characters = Array(rows[row - 1])
        let index = column - 1
        guard index < characters.count, let span = span(covering: index, in: characters) else {
            return nil
        }
        var link = String(characters[span])
        if let width, span.upperBound >= width, row < rows.count {
            let continuation = Array(rows[row]).prefix { !isTerminator($0) }
            link += String(continuation)
        }
        while let last = link.last, trailingPunctuation.contains(last) {
            link.removeLast()
        }
        return TerminalLinkPolicy.url(for: link)
    }

    /// The match covering `index`, leftmost-first and non-overlapping, as the
    /// pattern would find it.
    private static func span(
        covering index: Int, in characters: [Character]
    ) -> Range<Int>? {
        var start = 0
        while start < characters.count {
            guard schemeLength(at: start, in: characters) != nil else {
                start += 1
                continue
            }
            var end = start
            while end < characters.count, !isTerminator(characters[end]) { end += 1 }
            if (start..<end).contains(index) { return start..<end }
            if end > index { return nil }
            start = end
        }
        return nil
    }

    /// The length of `http://` or `https://` at `start`, or nil.
    private static func schemeLength(at start: Int, in characters: [Character]) -> Int? {
        for scheme in ["http://", "https://"] {
            let end = start + scheme.count
            guard end <= characters.count else { continue }
            if String(characters[start..<end]) == scheme { return scheme.count }
        }
        return nil
    }
}
