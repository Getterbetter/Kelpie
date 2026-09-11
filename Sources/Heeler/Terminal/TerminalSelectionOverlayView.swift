import UIKit

/// Draws the touch selection over the terminal grid, with the two draggable
/// handles iPadOS uses everywhere else.
///
/// It sits above the Ghostty surface as a plain subview and paints nothing of
/// its own but the highlight: the grid underneath keeps rendering exactly as
/// before, and nothing here ever reaches the PTY. Only the handles take
/// touches — ``point(inside:with:)`` refuses everything else, so a tap or a
/// scroll anywhere over the highlight still belongs to the terminal.
@MainActor
final class TerminalSelectionOverlayView: UIView {
    /// The selection to draw, or `nil` to show nothing.
    var selection: TerminalTouchSelection? {
        didSet {
            guard selection != oldValue else { return }
            refresh()
        }
    }

    /// Where the grid currently sits inside the terminal. Read on every draw
    /// and every drag rather than stored, because a resize moves every cell.
    var gridMetrics: (() -> TerminalGridPointMapper)?

    /// Fires while a handle is dragged, and once when a drag ends.
    var onSelectionChanged: ((TerminalTouchSelection?) -> Void)?

    /// Fires when a handle drag finishes, so the owner can bring the edit menu
    /// back — it is hidden for the duration of the drag, as UIKit's own is.
    var onDragFinished: ((TerminalTouchSelection?) -> Void)?

    /// Whether a handle is being dragged right now.
    private(set) var isDraggingHandle = false

    /// Where the dragged handle's own cell sits relative to the finger, taken
    /// once when the drag begins. The knob is drawn a knob's height clear of
    /// the row it marks, so without this a grab of the knob would move the
    /// selection a whole row the moment the finger did.
    private var dragGrabOffset = CGSize.zero

    private let startHandle = SelectionHandleView(knobAbove: true)
    private let endHandle = SelectionHandleView(knobAbove: false)

    /// The diameter of a handle's knob, which sets how far the handle reaches
    /// beyond the row it marks.
    private static let knobDiameter: CGFloat = 10
    private static let minimumTouchTarget: CGFloat = 44
    private static let highlightAlpha: CGFloat = 0.3
    private static let highlightCornerRadius: CGFloat = 3

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
        insetsLayoutMarginsFromSafeArea = false
        // The overlay itself must stay transparent to touches; only the two
        // handles answer, which `point(inside:with:)` enforces.
        isUserInteractionEnabled = true

        for (handle, label) in [
            (startHandle, "Selection start"), (endHandle, "Selection end"),
        ] {
            handle.isHidden = true
            handle.accessibilityLabel = label
            addSubview(handle)
        }
        startHandle.onAdjust = { [weak self] columns in
            self?.adjustStart(byColumns: columns)
        }
        endHandle.onAdjust = { [weak self] columns in
            self?.adjustEnd(byColumns: columns)
        }

        let startPan = UIPanGestureRecognizer(
            target: self, action: #selector(handleStartDrag(_:)))
        let endPan = UIPanGestureRecognizer(
            target: self, action: #selector(handleEndDrag(_:)))
        for (pan, handle) in [(startPan, startHandle), (endPan, endHandle)] {
            pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            pan.maximumNumberOfTouches = 1
            handle.addGestureRecognizer(pan)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    /// Recomputes the handles and repaints. Call after anything that moves the
    /// grid under a live selection.
    func refresh() {
        layoutHandles()
        setNeedsDisplay()
    }

    /// Whether `point`, in this view's coordinates, lands on a handle. The
    /// owner's own recognizers ask, so a drag of a handle is never also read
    /// as a scroll or a tap on the terminal.
    func containsHandle(at point: CGPoint) -> Bool {
        guard selection != nil else { return false }
        for handle in [startHandle, endHandle] where !handle.isHidden {
            if handle.frame.contains(point) { return true }
        }
        return false
    }

    /// The rect of the selection's last span, where the edit menu is anchored.
    var lastSpanRect: CGRect? {
        guard let selection, let metrics = gridMetrics?() else { return nil }
        guard
            let span = selection.spans(
                width: metrics.columns, bounds: selection.columnBounds
            ).last
        else { return nil }
        return rect(forRow: span.row, first: span.first, last: span.last, metrics: metrics)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutHandles()
    }

    override func point(inside point: CGPoint, with _: UIEvent?) -> Bool {
        containsHandle(at: point)
    }

    /// Whether `view` is this overlay or one of its handles.
    ///
    /// A touch that hit-tests to a handle still travels up the responder chain
    /// to the terminal, whose touch-down dismisses the selection — which made
    /// the selection vanish the moment a handle was grabbed. The terminal asks
    /// this before dismissing.
    func owns(_ view: UIView?) -> Bool {
        guard let view else { return false }
        return view === self || view.isDescendant(of: self)
    }

    // The overlay is the end of the line for the touches it accepts: without
    // these, `UIView`'s default forwards them to the next responder.
    override func touchesBegan(_: Set<UITouch>, with _: UIEvent?) {}
    override func touchesMoved(_: Set<UITouch>, with _: UIEvent?) {}
    override func touchesEnded(_: Set<UITouch>, with _: UIEvent?) {}
    override func touchesCancelled(_: Set<UITouch>, with _: UIEvent?) {}

    override func tintColorDidChange() {
        super.tintColorDidChange()
        startHandle.tintColor = tintColor
        endHandle.tintColor = tintColor
        setNeedsDisplay()
    }

    override func draw(_: CGRect) {
        guard let selection, let metrics = gridMetrics?() else { return }
        tintColor.withAlphaComponent(Self.highlightAlpha).setFill()
        for span in selection.spans(
            width: metrics.columns, bounds: selection.columnBounds)
        {
            guard
                let rect = rect(
                    forRow: span.row, first: span.first, last: span.last, metrics: metrics)
            else { continue }
            UIBezierPath(roundedRect: rect, cornerRadius: Self.highlightCornerRadius).fill()
        }
    }

    // MARK: - Geometry

    /// The rect covering `first...last` on `row`, in this view's coordinates.
    /// Mirrors ``TerminalGridPointMapper``'s mapping the other way, padding
    /// included, so the highlight lands on the same cells a touch would.
    private func rect(
        forRow row: Int, first: Int, last: Int, metrics: TerminalGridPointMapper
    ) -> CGRect? {
        guard metrics.cellSize.width > 0, metrics.cellSize.height > 0,
            row >= 1, first >= 1, last >= first
        else { return nil }
        let origin = metrics.gridOrigin
        return CGRect(
            x: origin.x + CGFloat(first - 1) * metrics.cellSize.width,
            y: origin.y + CGFloat(row - 1) * metrics.cellSize.height,
            width: CGFloat(last - first + 1) * metrics.cellSize.width,
            height: metrics.cellSize.height)
    }

    /// The middle of `cell`, which is what a handle marks and what the drag
    /// keeps under the finger's grab point.
    private func center(of cell: TerminalGridCell, metrics: TerminalGridPointMapper)
        -> CGPoint?
    {
        guard
            let rect = rect(
                forRow: cell.row, first: cell.column, last: cell.column, metrics: metrics)
        else { return nil }
        return CGPoint(x: rect.midX, y: rect.midY)
    }

    private func layoutHandles() {
        guard let selection, let metrics = gridMetrics?() else {
            startHandle.isHidden = true
            endHandle.isHidden = true
            return
        }
        let spans = selection.spans(
            width: metrics.columns, bounds: selection.columnBounds)
        guard let firstSpan = spans.first, let lastSpan = spans.last,
            let firstRect = rect(
                forRow: firstSpan.row, first: firstSpan.first, last: firstSpan.last,
                metrics: metrics),
            let lastRect = rect(
                forRow: lastSpan.row, first: lastSpan.first, last: lastSpan.last,
                metrics: metrics)
        else {
            startHandle.isHidden = true
            endHandle.isHidden = true
            return
        }

        place(startHandle, atX: firstRect.minX, rowRect: firstRect)
        place(endHandle, atX: lastRect.maxX, rowRect: lastRect)
    }

    private func place(_ handle: SelectionHandleView, atX x: CGFloat, rowRect: CGRect) {
        let barHeight = max(rowRect.height, 8)
        handle.barHeight = barHeight
        handle.isHidden = false
        let height = max(
            Self.minimumTouchTarget, barHeight + Self.knobDiameter * 2 + 4)
        handle.bounds = CGRect(
            x: 0, y: 0, width: Self.minimumTouchTarget, height: height)
        handle.center = CGPoint(x: x, y: rowRect.midY)
        handle.setNeedsDisplay()
    }

    // MARK: - Dragging

    @objc private func handleStartDrag(_ gesture: UIPanGestureRecognizer) {
        drag(gesture, movingAnchor: true)
    }

    @objc private func handleEndDrag(_ gesture: UIPanGestureRecognizer) {
        drag(gesture, movingAnchor: false)
    }

    /// Dragging the start handle moves `anchor`, the end handle moves `focus`.
    /// The two are only put back into reading order when the drag ends, so a
    /// handle dragged past its partner keeps following the finger instead of
    /// swapping out from under it mid-gesture.
    private func drag(_ gesture: UIPanGestureRecognizer, movingAnchor: Bool) {
        guard var selection, let metrics = gridMetrics?() else { return }
        switch gesture.state {
        case .began, .changed:
            let location = gesture.location(in: self)
            if gesture.state == .began {
                isDraggingHandle = true
                let grabbed = movingAnchor ? selection.anchor : selection.focus
                let center = center(of: grabbed, metrics: metrics) ?? location
                dragGrabOffset = CGSize(
                    width: center.x - location.x, height: center.y - location.y)
            }
            let point = CGPoint(
                x: location.x + dragGrabOffset.width,
                y: location.y + dragGrabOffset.height)
            guard let cell = metrics.cell(at: point) else { return }
            // A handle dragged out of its pane stops at the border.
            let moved = TerminalGridCell(
                column: selection.clampedColumn(cell.column), row: cell.row)
            if movingAnchor {
                selection.anchor = moved
            } else {
                selection.focus = moved
            }
            self.selection = selection
            onSelectionChanged?(selection)
        case .ended, .cancelled, .failed:
            isDraggingHandle = false
            dragGrabOffset = .zero
            self.selection = selection.normalized
            onSelectionChanged?(self.selection)
            onDragFinished?(self.selection)
        default:
            break
        }
    }

    private func adjustStart(byColumns columns: Int) {
        guard var selection else { return }
        selection.anchor = Self.shifted(selection.anchor, byColumns: columns)
        self.selection = selection.normalized
        onSelectionChanged?(self.selection)
    }

    private func adjustEnd(byColumns columns: Int) {
        guard var selection else { return }
        selection.focus = Self.shifted(selection.focus, byColumns: columns)
        self.selection = selection.normalized
        onSelectionChanged?(self.selection)
    }

    private static func shifted(_ cell: TerminalGridCell, byColumns columns: Int)
        -> TerminalGridCell
    {
        TerminalGridCell(column: max(1, cell.column + columns), row: cell.row)
    }
}

/// One selection handle: a thin bar the height of a cell with a round knob at
/// one end, drawn in the tint colour. Its bounds are at least 44×44 so the
/// knob is grabbable, and everything is drawn relative to the centre, which is
/// pinned to the middle of the cell edge it marks.
@MainActor
private final class SelectionHandleView: UIView {
    var barHeight: CGFloat = 16 {
        didSet { setNeedsDisplay() }
    }

    /// Whether the knob sits above the bar (the start handle) or below it.
    private let knobAbove: Bool

    /// Moves this end of the selection one column at a time for VoiceOver.
    var onAdjust: ((Int) -> Void)?

    private static let barWidth: CGFloat = 2
    private static let knobDiameter: CGFloat = 10

    init(knobAbove: Bool) {
        self.knobAbove = knobAbove
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
        isAccessibilityElement = true
        accessibilityTraits = .adjustable
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    // A handle's touches belong to its own pan recognizer and to nothing
    // else. `UIView`'s default implementation passes them to the next
    // responder — the overlay, then the terminal, whose touch-down clears the
    // very selection this handle is dragging.
    override func touchesBegan(_: Set<UITouch>, with _: UIEvent?) {}
    override func touchesMoved(_: Set<UITouch>, with _: UIEvent?) {}
    override func touchesEnded(_: Set<UITouch>, with _: UIEvent?) {}
    override func touchesCancelled(_: Set<UITouch>, with _: UIEvent?) {}

    override func accessibilityIncrement() {
        onAdjust?(1)
    }

    override func accessibilityDecrement() {
        onAdjust?(-1)
    }

    override func draw(_: CGRect) {
        tintColor.setFill()

        let bar = CGRect(
            x: bounds.midX - Self.barWidth / 2,
            y: bounds.midY - barHeight / 2,
            width: Self.barWidth,
            height: barHeight)
        UIBezierPath(roundedRect: bar, cornerRadius: Self.barWidth / 2).fill()

        let knobCenterY =
            knobAbove
            ? bar.minY - Self.knobDiameter / 2
            : bar.maxY + Self.knobDiameter / 2
        let knob = CGRect(
            x: bounds.midX - Self.knobDiameter / 2,
            y: knobCenterY - Self.knobDiameter / 2,
            width: Self.knobDiameter,
            height: Self.knobDiameter)
        UIBezierPath(ovalIn: knob).fill()
    }
}
