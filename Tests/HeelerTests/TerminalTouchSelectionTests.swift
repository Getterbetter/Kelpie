import Foundation
import Testing

@testable import Heeler

@Suite("Terminal touch selection")
struct TerminalTouchSelectionTests {
    private let rows = [
        "the quick brown fox",
        "jumped over",
        "the lazy dog       ",
    ]

    private func cell(_ column: Int, _ row: Int) -> TerminalGridCell {
        TerminalGridCell(column: column, row: row)
    }

    @Test func normalizesWhenTheFocusPrecedesTheAnchor() {
        let selection = TerminalTouchSelection(anchor: cell(5, 3), focus: cell(2, 1))
        #expect(selection.start == cell(2, 1))
        #expect(selection.end == cell(5, 3))
        #expect(selection.normalized.anchor == cell(2, 1))
        #expect(selection.normalized.focus == cell(5, 3))
    }

    @Test func normalizesWithinOneRow() {
        let selection = TerminalTouchSelection(anchor: cell(9, 2), focus: cell(4, 2))
        #expect(selection.start == cell(4, 2))
        #expect(selection.end == cell(9, 2))
    }

    @Test func spansOneRowFromTheFirstToTheLastColumn() {
        let selection = TerminalTouchSelection(anchor: cell(5, 1), focus: cell(9, 1))
        let spans = selection.spans(width: 20)
        #expect(spans.count == 1)
        #expect(spans.first?.row == 1)
        #expect(spans.first?.first == 5)
        #expect(spans.first?.last == 9)
    }

    @Test func spansThreeRowsWithWholeMiddleRows() {
        let selection = TerminalTouchSelection(anchor: cell(5, 1), focus: cell(3, 3))
        let spans = selection.spans(width: 20)
        #expect(spans.count == 3)
        #expect(spans.map(\.row) == [1, 2, 3])
        #expect(spans.map(\.first) == [5, 1, 1])
        #expect(spans.map(\.last) == [20, 20, 3])
    }

    @Test func clampsSpanColumnsToTheGridWidth() {
        let selection = TerminalTouchSelection(anchor: cell(0, 1), focus: cell(99, 1))
        let spans = selection.spans(width: 20)
        #expect(spans.count == 1)
        #expect(spans.first?.first == 1)
        #expect(spans.first?.last == 20)
        #expect(selection.spans(width: 0).isEmpty)
    }

    @Test func readsTheTextOfAThreeRowSpan() {
        let selection = TerminalTouchSelection(anchor: cell(5, 1), focus: cell(8, 3))
        #expect(selection.text(in: rows) == "quick brown fox\njumped over\nthe lazy")
    }

    @Test func readsTheTextOfASingleRowSpan() {
        let selection = TerminalTouchSelection(anchor: cell(11, 1), focus: cell(15, 1))
        #expect(selection.text(in: rows) == "brown")
    }

    @Test func trimsTrailingSpacesFromEachRow() {
        let padded = ["first row    ", "second row      "]
        let selection = TerminalTouchSelection(anchor: cell(1, 1), focus: cell(16, 2))
        #expect(selection.text(in: padded) == "first row\nsecond row")
    }

    @Test func clampsTextWhenARowIsShorterThanTheSpan() {
        let selection = TerminalTouchSelection(anchor: cell(1, 1), focus: cell(40, 2))
        #expect(selection.text(in: ["short", "tiny"]) == "short\ntiny")
    }

    @Test func readsAnEmptyLineWhenARowEndsBeforeTheSpanBegins() {
        let selection = TerminalTouchSelection(anchor: cell(8, 1), focus: cell(4, 2))
        #expect(selection.text(in: ["abc", "defgh"]) == "\ndefg")
    }

    @Test func findsTheWordFromItsFirstMiddleAndLastCell() {
        let expected = TerminalTouchSelection(anchor: cell(5, 1), focus: cell(9, 1))
        for column in [5, 7, 9] {
            #expect(TerminalTouchSelection.word(at: cell(column, 1), in: rows) == expected)
        }
        #expect(expected.text(in: rows) == "quick")
    }

    @Test func findsAWordAtTheStartAndTheEndOfARow() {
        #expect(
            TerminalTouchSelection.word(at: cell(1, 1), in: rows)
                == TerminalTouchSelection(anchor: cell(1, 1), focus: cell(3, 1)))
        #expect(
            TerminalTouchSelection.word(at: cell(19, 1), in: rows)
                == TerminalTouchSelection(anchor: cell(17, 1), focus: cell(19, 1)))
    }

    @Test func findsNoWordOnWhitespaceOrPastTheRow() {
        // Column 4 is the space between "the" and "quick".
        #expect(TerminalTouchSelection.word(at: cell(4, 1), in: rows) == nil)
        #expect(TerminalTouchSelection.word(at: cell(40, 1), in: rows) == nil)
        #expect(TerminalTouchSelection.word(at: cell(1, 9), in: rows) == nil)
        #expect(TerminalTouchSelection.word(at: cell(0, 1), in: rows) == nil)
    }

    @Test func selectsEverythingUpToTheLastRowWithText() {
        let selection = TerminalTouchSelection.all(in: rows)
        #expect(selection?.start == cell(1, 1))
        // Row 3 is padded to 19 columns but its text ends at 12.
        #expect(selection?.end == cell(12, 3))
        #expect(TerminalTouchSelection.all(in: ["", "   "]) == nil)
        #expect(TerminalTouchSelection.all(in: []) == nil)
    }
}
