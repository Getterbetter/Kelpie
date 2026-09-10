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

    @Test func readsRowsOutOfViewportText() {
        let text = rows.joined(separator: "\n")
        #expect(
            TerminalLinkDetector.url(inViewport: text, column: 6, row: 1)?.absoluteString
                == "https://herdr.dev/docs")
        #expect(TerminalLinkDetector.url(inViewport: text, column: 6, row: 2) == nil)
    }
}
