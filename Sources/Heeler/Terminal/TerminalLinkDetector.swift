import Foundation

/// Finds what a tap on one terminal cell landed on, from the viewport's text
/// alone: a web URL, or a path to a file on the Host.
///
/// libghostty reports a link only when it decides one was activated, and on
/// iOS nothing ever activates one: there is no "link at this point" query in
/// `ghostty.h` and no cmd-click to fire the action. So a tap is resolved here,
/// against the same viewport text the selection sheet reads. It has to be:
/// herdr hit-tests URL clicks itself and opens them with `open` **on the Mac**,
/// which is not where the person tapping is. A path is the same problem one
/// step further on — the file the agent just wrote is on the Host, and the
/// person who wants to look at it is holding an iPad.
///
/// Deliberately pure. Wrapped URLs are the terminal-specific knowledge it does
/// carry: a URL that fills a row to its last cell continues on the next one,
/// and nothing in the text says so.
///
/// Cell width is the piece it does not. Rows are indexed by grapheme here
/// while the grid mapper counts cells, so a wide glyph — a CJK character, a
/// two-cell emoji — or a tab earlier in the row shifts every link to its right
/// by a column per glyph. Rare in herdr's TUI, and a cell-width map is not
/// worth its cost until it is not.
enum TerminalLinkDetector {
    /// What the cell under a tap belongs to.
    enum Match: Equatable {
        case url(URL)
        /// An absolute (or `~`-relative) path on the Host, exactly as it was
        /// written. Expansion and existence are the Host's business.
        case hostPath(String)
    }

    /// Characters `https?://[^\s<>"'`]+` stops at.
    private static func isTerminator(_ character: Character) -> Bool {
        character.isWhitespace || "<>\"'`".contains(character)
    }

    /// Trailing sentence punctuation: prose ends "see https://x.dev." far more
    /// often than a URL ends in a full stop.
    private static let trailingPunctuation: Set<Character> = [
        ".", ",", ";", ":", "!", "?", ")", "]", "}", "'", "\"",
    ]

    /// Punctuation a path is commonly wrapped in — `(/tmp/out.log)`,
    /// `[~/notes.md]` — none of which is part of the path.
    private static let leadingPunctuation: Set<Character> = ["(", "[", "{", "'", "\"", "<"]

    /// The longest extension treated as one: `.markdown` is nine characters,
    /// and past that a dotted word is prose, not a filename.
    private static let maximumExtensionLength = 10

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
        guard
            case .url(let url)? = match(in: rows, column: column, row: row, width: width)
        else { return nil }
        return url
    }

    static func match(
        inViewport text: String, column: Int, row: Int, width: Int? = nil
    ) -> Match? {
        match(
            in: text.components(separatedBy: "\n"), column: column, row: row, width: width)
    }

    /// URLs win: `https://…` contains slashes and dots, so a path rule loose
    /// enough to be useful would otherwise claim half of one — and a URL's own
    /// path is not a Host path.
    static func match(in rows: [String], column: Int, row: Int, width: Int? = nil) -> Match? {
        if let url = urlMatch(in: rows, column: column, row: row, width: width) {
            return .url(url)
        }
        guard let token = token(in: rows, column: column, row: row, width: width) else {
            return nil
        }
        // Terminal prose wraps paths in brackets and quotes — `(/tmp/out.log)`,
        // `"~/notes.md"` — and neither the wrapper nor the sentence's
        // punctuation is part of what was tapped.
        let leading = leadingPunctuationCount(token.text)
        guard let path = hostPath(trimmed(strippingLeadingPunctuation(token.text)))
        else { return nil }
        // The cell has to be on the path itself, not on the wrapper around it
        // or on the `:12:3` a compiler appended. Agent output is dense with
        // `(see /tmp/out.log)` and `main.swift:12:3`, and a tap on the bracket
        // or on the line number is not a tap on the file (round 12,
        // finding 5).
        let offset = column - 1 - token.start
        guard offset >= leading, offset < leading + path.count else { return nil }
        return .hostPath(path)
    }

    /// The Host path a *selection* names, for the Open on Host menu item.
    ///
    /// One token only: a selection that spans whitespace is prose, and the
    /// same wrappers and source locations are stripped as on the tap path.
    static func hostPath(inSelectedText text: String) -> String? {
        let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, !token.contains(where: isTerminator) else { return nil }
        return hostPath(trimmed(strippingLeadingPunctuation(token)))
    }

    /// The URL covering the tapped cell, found anywhere inside the run rather
    /// than only at its start: terminal output writes `url=https://…`,
    /// `](https://…)` and `see:https://…`, and the scheme is what marks the
    /// beginning of the link, not the whitespace before it.
    private static func urlMatch(
        in rows: [String], column: Int, row: Int, width: Int?
    ) -> URL? {
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
        return TerminalLinkPolicy.url(for: trimmed(link))
    }

    /// The scheme-anchored match covering `index`, leftmost-first and
    /// non-overlapping, as the pattern would find it.
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

    /// The whitespace-delimited run of characters the tapped cell is part of,
    /// joined with the next row when it reached the grid's last column.
    /// The run and where it starts, so the caller can tell which of its
    /// characters the tapped cell actually landed on.
    private struct Token {
        let text: String
        /// 0-based index of the run's first character in its row.
        let start: Int
    }

    private static func token(
        in rows: [String], column: Int, row: Int, width: Int?
    ) -> Token? {
        guard row >= 1, row <= rows.count, column >= 1 else { return nil }
        let characters = Array(rows[row - 1])
        let index = column - 1
        guard index < characters.count, !isTerminator(characters[index]) else { return nil }
        var start = index
        while start > 0, !isTerminator(characters[start - 1]) { start -= 1 }
        var end = index
        while end < characters.count, !isTerminator(characters[end]) { end += 1 }
        var token = String(characters[start..<end])
        if let width, end >= width, row < rows.count {
            let continuation = Array(rows[row]).prefix { !isTerminator($0) }
            token += String(continuation)
        }
        return Token(text: token, start: start)
    }

    private static func trimmed(_ token: String) -> String {
        var token = token
        while let last = token.last, trailingPunctuation.contains(last) {
            token.removeLast()
        }
        return token
    }

    private static func strippingLeadingPunctuation(_ token: String) -> String {
        String(token.dropFirst(leadingPunctuationCount(token)))
    }

    private static func leadingPunctuationCount(_ token: String) -> Int {
        token.prefix { leadingPunctuation.contains($0) }.count
    }

    /// An absolute Unix path whose last component looks like a file: a name
    /// with an extension. The extension is what keeps the rule honest —
    /// `/usr/local/bin` and `/Users/anthony` are directories nobody means to
    /// preview, and herdr's own output is full of them.
    private static func hostPath(_ candidate: String) -> String? {
        let path = strippingSourceLocation(candidate)
        guard path.hasPrefix("/") || path.hasPrefix("~/") else { return nil }
        // `//` at the front is a URL that lost its scheme, or a comment.
        guard !path.hasPrefix("//"), !path.contains("://") else { return nil }
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard let name = components.last, hasFileExtension(String(name)) else { return nil }
        return path
    }

    /// `Sources/App/File.swift:12:3` is how every compiler, linter and agent
    /// names a line in a file, and the line and column are not part of the
    /// path. Only a trailing all-digit `:n` or `:n:m` is dropped, so a path
    /// that genuinely contains a colon keeps it.
    private static func strippingSourceLocation(_ path: String) -> String {
        var components = path.split(separator: ":", omittingEmptySubsequences: false)
        guard components.count >= 2 else { return path }
        var dropped = 0
        while dropped < 2, components.count > 1,
            let last = components.last, !last.isEmpty, last.allSatisfy(\.isNumber)
        {
            components.removeLast()
            dropped += 1
        }
        return dropped == 0 ? path : components.joined(separator: ":")
    }

    /// `name.ext`, where the extension is short and alphanumeric. Dotfiles
    /// without a second dot (`.zshrc`) are names, not extensions, and are
    /// deliberately excluded: a tap on one is far more often a mention of the
    /// directory it sits in.
    private static func hasFileExtension(_ name: String) -> Bool {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return false }
        let stem = name[name.startIndex..<dot]
        let ext = name[name.index(after: dot)...]
        guard !stem.isEmpty, !stem.allSatisfy({ $0 == "." }) else { return false }
        guard !ext.isEmpty, ext.count <= maximumExtensionLength else { return false }
        return ext.allSatisfy { $0.isLetter || $0.isNumber }
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
