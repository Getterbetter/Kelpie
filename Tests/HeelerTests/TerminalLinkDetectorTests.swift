import Foundation
import Testing

@testable import Heeler

@MainActor
@Suite("Terminal link detector")
struct TerminalLinkDetectorTests {
    private let rows = [
        "see https://herdr.dev/docs for more",
        "plain text with no link at all",
    ]

    @Test func resolvesAUrlFromAColumnInsideIt() {
        // 1-based: column 5 is the "h" of the link, 20 is inside it.
        #expect(
            TerminalLinkDetector.url(in: rows, column: 5, row: 1)?.absoluteString
                == "https://herdr.dev/docs")
        #expect(
            TerminalLinkDetector.url(in: rows, column: 20, row: 1)?.absoluteString
                == "https://herdr.dev/docs")
    }

    @Test func resolvesTheFirstAndLastColumnOfTheSpan() {
        let line = ["https://herdr.dev"]
        #expect(
            TerminalLinkDetector.url(in: line, column: 1, row: 1)?.absoluteString
                == "https://herdr.dev")
        #expect(
            TerminalLinkDetector.url(in: line, column: 17, row: 1)?.absoluteString
                == "https://herdr.dev")
        #expect(TerminalLinkDetector.url(in: line, column: 18, row: 1) == nil)
    }

    @Test func stripsTrailingSentencePunctuation() {
        let line = ["read (https://herdr.dev/docs), then stop."]
        #expect(
            TerminalLinkDetector.url(in: line, column: 10, row: 1)?.absoluteString
                == "https://herdr.dev/docs")
    }

    @Test func joinsAUrlWrappedOntoTheNextRow() {
        let wrapped = [
            "https://herdr.dev/docs/configuration/keybindings",
            "#prefix and the rest of the line",
        ]
        // The first row fills the grid, which is what makes it a wrap.
        #expect(
            TerminalLinkDetector.url(
                in: wrapped, column: 3, row: 1, width: wrapped[0].count)?.absoluteString
                == "https://herdr.dev/docs/configuration/keybindings#prefix")
    }

    /// A row that merely *ends* with a URL is not a wrap. Viewport reads drop
    /// trailing padding, so the string ending says nothing on its own — only
    /// the grid width does.
    @Test func doesNotJoinAUrlThatEndsShortOfTheGridWidth() {
        let rows = [
            "Server running at https://localhost:3000",
            "Press Ctrl-C to quit",
        ]
        #expect(
            TerminalLinkDetector.url(in: rows, column: 20, row: 1, width: 80)?.absoluteString
                == "https://localhost:3000")
        // And with no width at all, nothing is ever joined.
        #expect(
            TerminalLinkDetector.url(in: rows, column: 20, row: 1)?.absoluteString
                == "https://localhost:3000")
    }

    @Test func doesNotJoinWhenTheNextRowStartsWithSpace() {
        let wrapped = [
            "https://herdr.dev/docs/configuration/keybindings",
            " indented continuation",
        ]
        #expect(
            TerminalLinkDetector.url(
                in: wrapped, column: 3, row: 1, width: wrapped[0].count)?.absoluteString
                == "https://herdr.dev/docs/configuration/keybindings")
    }

    @Test func aCellOutsideAnyLinkResolvesToNothing() {
        #expect(TerminalLinkDetector.url(in: rows, column: 2, row: 1) == nil)
        #expect(TerminalLinkDetector.url(in: rows, column: 40, row: 1) == nil)
        #expect(TerminalLinkDetector.url(in: rows, column: 5, row: 2) == nil)
        #expect(TerminalLinkDetector.url(in: rows, column: 1, row: 3) == nil)
    }

    /// Terminal output is untrusted: only ordinary web links cross, the same
    /// policy the Ghostty open-URL delegate applies.
    @Test(arguments: [
        "ftp://herdr.dev/pub", "file:///etc/passwd", "javascript:alert(1)",
    ])
    func nonWebSchemesAreIgnored(line: String) {
        #expect(TerminalLinkDetector.url(in: [line], column: 3, row: 1) == nil)
    }

    /// The old scheme-anchored search found a URL anywhere inside the tapped
    /// run, and terminal output puts plenty in front of one.
    @Test(arguments: [
        ("](https://herdr.dev/docs)", 10),
        ("url=https://herdr.dev/docs", 10),
        ("see:https://herdr.dev/docs", 12),
    ])
    func resolvesAUrlThatStartsPartWayIntoTheRun(line: String, column: Int) {
        #expect(
            TerminalLinkDetector.url(in: [line], column: column, row: 1)?.absoluteString
                == "https://herdr.dev/docs")
    }

    @Test func resolvesAnAbsoluteHostPath() {
        #expect(
            TerminalLinkDetector.match(in: ["wrote /a/b/c.txt now"], column: 8, row: 1)
                == .hostPath("/a/b/c.txt"))
    }

    @Test func resolvesAHomeRelativeHostPath() {
        #expect(
            TerminalLinkDetector.match(in: ["see ~/x/y.md ok"], column: 6, row: 1)
                == .hostPath("~/x/y.md"))
    }

    /// `file.swift:12:3` is how every compiler and agent names a line; the
    /// line and column are not part of the path.
    @Test(arguments: ["at /a/b.swift:12:3 here", "at /a/b.swift:12 here"])
    func dropsATrailingSourceLocation(line: String) {
        #expect(
            TerminalLinkDetector.match(in: [line], column: 5, row: 1)
                == .hostPath("/a/b.swift"))
    }

    @Test(arguments: ["(/a/b.txt)", "/a/b.txt.", "\"/a/b.txt\","])
    func stripsPunctuationAroundAHostPath(line: String) {
        #expect(
            TerminalLinkDetector.match(in: [line], column: 4, row: 1)
                == .hostPath("/a/b.txt"))
    }

    /// A file-ish last component is the whole rule: without it every
    /// directory herdr prints becomes a tappable dead end. `/dev/null` has no
    /// extension, so it is deliberately not a match.
    @Test(arguments: ["cat /dev/null", "cd /usr/local/bin", "at /Users/anthony"])
    func extensionlessPathsAreNotMatched(line: String) {
        #expect(TerminalLinkDetector.match(in: [line], column: 6, row: 1) == nil)
    }

    /// URL precedence: a URL's own path is not a Host path.
    @Test func aPathInsideAUrlResolvesAsTheUrl() throws {
        let line = ["https://herdr.dev/docs/file.md"]
        let url = try #require(URL(string: "https://herdr.dev/docs/file.md"))
        #expect(TerminalLinkDetector.match(in: line, column: 25, row: 1) == .url(url))
    }

    @Test(arguments: [("//comment/thing.txt", 5), ("/ alone", 1), ("a/b/c.txt", 3)])
    func nonPathsAreNotMatched(line: String, column: Int) {
        #expect(TerminalLinkDetector.match(in: [line], column: column, row: 1) == nil)
    }

    @Test func readsRowsOutOfViewportText() {
        let text = rows.joined(separator: "\n")
        #expect(
            TerminalLinkDetector.url(inViewport: text, column: 6, row: 1)?.absoluteString
                == "https://herdr.dev/docs")
        #expect(TerminalLinkDetector.url(inViewport: text, column: 6, row: 2) == nil)
    }
}

/// Round 12, finding 5: a tap on a Host path used to be swallowed whole and
/// never reached herdr, and the path rule was loose enough to fire on ordinary
/// agent output. The tap now goes to herdr and the file viewer is offered from
/// the selection menu; the matcher is tightened so the cell has to be on the
/// path itself.
@Suite("Terminal host path matching")
struct TerminalHostPathMatchingTests {
    @Test func theCellHasToLandOnThePathNotOnItsWrapper() {
        // Inside the path: a match.
        #expect(
            TerminalLinkDetector.match(in: ["(/a/b.txt)"], column: 4, row: 1)
                == .hostPath("/a/b.txt"))
        // On the opening bracket, and on the closing one: not the path.
        #expect(TerminalLinkDetector.match(in: ["(/a/b.txt)"], column: 1, row: 1) == nil)
        #expect(TerminalLinkDetector.match(in: ["(/a/b.txt)"], column: 10, row: 1) == nil)
    }

    /// `main.swift:12:3` — the line and column are the compiler's, not the
    /// file's, and a tap on them is not a tap on the file.
    @Test func theCellHasToLandOnThePathNotOnASourceLocation() {
        let line = ["at /a/b.swift:12:3 here"]
        #expect(
            TerminalLinkDetector.match(in: line, column: 8, row: 1)
                == .hostPath("/a/b.swift"))
        // Column 15 is the `2` of `:12`.
        #expect(TerminalLinkDetector.match(in: line, column: 15, row: 1) == nil)
    }

    /// The Open on Host menu item reads the selection, which is the same
    /// whitespace-delimited run the tap path resolves.
    @Test func aSelectionResolvesTheSamePathTheTapPathWould() {
        #expect(TerminalLinkDetector.hostPath(inSelectedText: "/a/b.txt") == "/a/b.txt")
        #expect(TerminalLinkDetector.hostPath(inSelectedText: " ~/x/y.md ") == "~/x/y.md")
        #expect(
            TerminalLinkDetector.hostPath(inSelectedText: "(/a/b.swift:12:3)")
                == "/a/b.swift")
    }

    /// A selection that spans whitespace is prose, not a filename, and a
    /// directory is not a file to preview.
    @Test(arguments: ["wrote /a/b.txt now", "/usr/local/bin", "b.txt", "", "   "])
    func aSelectionThatIsNotOnePathOffersNothing(text: String) {
        #expect(TerminalLinkDetector.hostPath(inSelectedText: text) == nil)
    }
}
