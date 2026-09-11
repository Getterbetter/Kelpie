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

    /// The columns the selection may not leave, or nil for the whole grid.
    ///
    /// herdr draws several panes and a sidebar side by side on one grid, and a
    /// multi-row selection that ran the full width would take the sidebar and
    /// the neighbouring pane with it. The bounds are the pane the selection
    /// started in, found once when it is made (see ``paneBounds(around:in:)``)
    /// and kept, because the pane cannot move under a live selection — a
    /// resize clears it.
    var columnBounds: ClosedRange<Int>?

    init(
        anchor: TerminalGridCell,
        focus: TerminalGridCell,
        columnBounds: ClosedRange<Int>? = nil
    ) {
        self.anchor = anchor
        self.focus = focus
        self.columnBounds = columnBounds
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
        TerminalTouchSelection(anchor: start, focus: end, columnBounds: columnBounds)
    }

    /// `column` brought inside the pane, for a handle dragged out of it.
    func clampedColumn(_ column: Int) -> Int {
        guard let columnBounds else { return max(column, 1) }
        return min(max(column, columnBounds.lowerBound), columnBounds.upperBound)
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
    func spans(
        width: Int, bounds: ClosedRange<Int>? = nil
    ) -> [(row: Int, first: Int, last: Int)] {
        guard width >= 1 else { return [] }
        let lower = max(bounds?.lowerBound ?? 1, 1)
        let upper = min(bounds?.upperBound ?? width, width)
        guard lower <= upper else { return [] }
        let start = start
        let end = end
        guard start.row >= 1, start.row <= end.row else { return [] }

        func clamp(_ column: Int) -> Int { min(max(column, lower), upper) }

        if start.row == end.row {
            let first = clamp(start.column)
            let last = clamp(end.column)
            guard first <= last else { return [] }
            return [(row: start.row, first: first, last: last)]
        }

        var spans: [(row: Int, first: Int, last: Int)] = [
            (row: start.row, first: clamp(start.column), last: upper),
        ]
        if start.row + 1 <= end.row - 1 {
            for row in (start.row + 1)...(end.row - 1) {
                spans.append((row: row, first: lower, last: upper))
            }
        }
        spans.append((row: end.row, first: lower, last: clamp(end.column)))
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
    func text(in rows: [String], bounds: ClosedRange<Int>? = nil) -> String {
        let lowerBound = max(bounds?.lowerBound ?? 1, 1)
        let upperBound = bounds?.upperBound ?? Int.max
        guard lowerBound <= upperBound else { return "" }
        let start = start
        let end = end
        guard start.row <= end.row else { return "" }

        func clamp(_ column: Int) -> Int {
            min(max(column, lowerBound), upperBound)
        }

        var lines: [String] = []
        for row in start.row...end.row {
            guard row >= 1, row <= rows.count else { continue }
            let characters = Array(rows[row - 1])
            let first = row == start.row ? clamp(start.column) : lowerBound
            let requested = row == end.row ? clamp(end.column) : upperBound
            let last = min(requested, characters.count)
            guard first <= characters.count, last >= first else {
                lines.append("")
                continue
            }
            lines.append(
                Self.trimmingTrailingSpaces(String(characters[(first - 1)..<last])))
        }
        return lines.joined(separator: "\n")
    }

    /// The vertical rules a TUI draws between its panes. herdr's own borders
    /// are `│`; the rest are what other box-drawing styles reach for, plus
    /// ASCII `|` for a pane drawn without them.
    static let paneBorderCharacters: Set<Character> = [
        "│", "┃", "║", "┆", "┇", "┊", "┋", "╎", "╏", "|",
    ]

    /// The columns of the pane `cell` sits in: everything strictly between the
    /// nearest vertical border to its left and the nearest one to its right,
    /// on the cell's own row.
    ///
    /// A side with no border is open — the lower bound is 1, the upper bound
    /// `Int.max` — and ``spans(width:bounds:)`` clamps that to the grid. Only
    /// the anchor's row is read: it is the row the user pointed at, and the
    /// rows above and below may be split differently (a pane's own content can
    /// draw its own rules), so a per-row scan would make the selection's edges
    /// wander.
    static func paneBounds(
        around cell: TerminalGridCell, in rows: [String]
    ) -> ClosedRange<Int> {
        guard cell.row >= 1, cell.row <= rows.count else { return 1...Int.max }
        let characters = Array(rows[cell.row - 1])
        guard !characters.isEmpty else { return 1...Int.max }
        let index = min(max(cell.column - 1, 0), characters.count - 1)

        var lower = 1
        var left = index
        while left > 0 {
            left -= 1
            if paneBorderCharacters.contains(characters[left]) {
                lower = left + 2
                break
            }
        }

        var upper = Int.max
        var right = index
        while right + 1 < characters.count {
            right += 1
            if paneBorderCharacters.contains(characters[right]) {
                upper = right
                break
            }
        }

        guard lower <= upper else { return lower...lower }
        return lower...upper
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

        // The pane the word sits in is found now, once: it is what keeps a
        // selection dragged down several rows out of the sidebar.
        let bounds = paneBounds(around: cell, in: rows)
        let unbounded = bounds.lowerBound == 1 && bounds.upperBound == Int.max
        return TerminalTouchSelection(
            anchor: TerminalGridCell(column: first + 1, row: cell.row),
            focus: TerminalGridCell(column: last + 1, row: cell.row),
            columnBounds: unbounded ? nil : bounds)
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

    private static func trimmingTrailingSpaces(_ line: String) -> String {
        var line = line
        while let last = line.last, last == " " || last == "\t" {
            line.removeLast()
        }
        return line
    }
}
