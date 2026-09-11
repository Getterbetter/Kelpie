import Foundation

/// One 1-based cell on the terminal grid, as ``TerminalGridPointMapper``
/// reports it and as an SGR mouse report would carry it.
struct TerminalGridCell: Hashable, Sendable {
    let column: Int
    let row: Int

    init(column: Int, row: Int) {
        self.column = column
        self.row = row
    }

    /// Row-major order: everything on an earlier row comes first, and within a
    /// row the leftmost column does.
    static func < (lhs: TerminalGridCell, rhs: TerminalGridCell) -> Bool {
        lhs.row == rhs.row ? lhs.column < rhs.column : lhs.row < rhs.row
    }
}

/// A range of terminal cells the user selected by touch, and the text under it.
///
/// Kelpie draws and owns this selection itself. The vendored Ghostty view keeps
/// its selection machinery inside the package — `TerminalSurface`'s mouse entry
/// points are not public and `UITerminalView.selectionRects(for:)` answers with
/// an empty array, so UIKit's own text interaction has nothing to draw — and
/// under herdr's mouse tracking a plain touch is a click for the remote
/// application, not a selection. Everything needed to do it here is already
/// present: ``TerminalGridPointMapper`` turns a point into a cell, and the
/// viewport read turns the grid into rows of text.
///
/// Deliberately pure, and deliberately ignorant of what is on screen: `anchor`
/// and `focus` are wherever the two handles are, in whichever order the user
/// dragged them into, and ``start``/``end`` put them back in reading order.
struct TerminalTouchSelection: Equatable, Sendable {
    /// Where the selection was pinned — the start handle.
    var anchor: TerminalGridCell
    /// Where the selection currently reaches — the end handle.
    var focus: TerminalGridCell

    init(anchor: TerminalGridCell, focus: TerminalGridCell) {
        self.anchor = anchor
        self.focus = focus
    }

    /// The earlier of the two ends, in reading order. Inclusive.
    var start: TerminalGridCell {
        focus < anchor ? focus : anchor
    }

    /// The later of the two ends, in reading order. Inclusive.
    var end: TerminalGridCell {
        focus < anchor ? anchor : focus
    }

    /// `anchor`/`focus` put back into reading order, so that the start handle
    /// is always the one that moves `anchor`.
    var normalized: TerminalTouchSelection {
        TerminalTouchSelection(anchor: start, focus: end)
    }

    /// Whether the selection covers exactly one cell — what a word of one
    /// character, or a stray drag, leaves behind.
    var isSingleCell: Bool {
        start == end
    }

    /// The rows the selection covers, each with the first and last column on
    /// that row, for a grid `width` columns wide.
    ///
    /// Only the first and last rows are partial: everything between them is
    /// selected whole, exactly as a text selection wraps.
    func spans(width: Int) -> [(row: Int, first: Int, last: Int)] {
        guard width >= 1 else { return [] }
        let start = start
        let end = end
        guard start.row >= 1, start.row <= end.row else { return [] }

        if start.row == end.row {
            let first = Self.clamped(start.column, width: width)
            let last = Self.clamped(end.column, width: width)
            guard first <= last else { return [] }
            return [(row: start.row, first: first, last: last)]
        }

        var spans: [(row: Int, first: Int, last: Int)] = [
            (row: start.row, first: Self.clamped(start.column, width: width), last: width),
        ]
        if start.row + 1 <= end.row - 1 {
            for row in (start.row + 1)...(end.row - 1) {
                spans.append((row: row, first: 1, last: width))
            }
        }
        spans.append(
            (row: end.row, first: 1, last: Self.clamped(end.column, width: width)))
        return spans
    }

    /// The selected text, read out of the viewport's rows.
    ///
    /// The first and last rows are cut at the selection's columns and the rows
    /// between them are taken whole; each row loses its trailing spaces,
    /// because the grid pads every row to its width and nobody means to copy
    /// that padding. A row shorter than the span it is asked for contributes
    /// what it has — the viewport read stops where the text does, which is not
    /// where the grid does.
    func text(in rows: [String]) -> String {
        let start = start
        let end = end
        guard start.row <= end.row else { return "" }

        var lines: [String] = []
        for row in start.row...end.row {
            guard row >= 1, row <= rows.count else { continue }
            let characters = Array(rows[row - 1])
            let first = row == start.row ? max(start.column, 1) : 1
            let last = row == end.row ? end.column : characters.count
            guard first <= characters.count, last >= first else {
                lines.append("")
                continue
            }
            let upper = min(last, characters.count)
            lines.append(
                Self.trimmingTrailingSpaces(String(characters[(first - 1)..<upper])))
        }
        return lines.joined(separator: "\n")
    }

    /// The word under `cell`: the longest run of non-whitespace around it on
    /// that row. `nil` when the cell holds whitespace or lies past the end of
    /// the row — a double tap on empty space selects nothing rather than
    /// guessing at a neighbour.
    static func word(at cell: TerminalGridCell, in rows: [String]) -> TerminalTouchSelection? {
        guard cell.row >= 1, cell.row <= rows.count, cell.column >= 1 else { return nil }
        let characters = Array(rows[cell.row - 1])
        let index = cell.column - 1
        guard index < characters.count, !characters[index].isWhitespace else { return nil }

        var first = index
        while first > 0, !characters[first - 1].isWhitespace { first -= 1 }
        var last = index
        while last + 1 < characters.count, !characters[last + 1].isWhitespace { last += 1 }

        return TerminalTouchSelection(
            anchor: TerminalGridCell(column: first + 1, row: cell.row),
            focus: TerminalGridCell(column: last + 1, row: cell.row))
    }

    /// The whole viewport: from the first cell to the end of the last row that
    /// has any text on it.
    static func all(in rows: [String]) -> TerminalTouchSelection? {
        guard
            let lastIndex = rows.lastIndex(where: {
                !trimmingTrailingSpaces($0).isEmpty
            })
        else { return nil }
        let length = trimmingTrailingSpaces(rows[lastIndex]).count
        return TerminalTouchSelection(
            anchor: TerminalGridCell(column: 1, row: 1),
            focus: TerminalGridCell(column: max(length, 1), row: lastIndex + 1))
    }

    private static func clamped(_ column: Int, width: Int) -> Int {
        min(max(column, 1), width)
    }

    private static func trimmingTrailingSpaces(_ line: String) -> String {
        var line = line
        while let last = line.last, last == " " || last == "\t" {
            line.removeLast()
        }
        return line
    }
}
