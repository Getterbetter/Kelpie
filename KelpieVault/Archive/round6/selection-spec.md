# Kelpie round 6A — touch text selection with handles (app-side)

Project: /Users/anthonytopalides/Developer/Kelpie, branch `kelpie`, clean tree at `447ef31`. Swift 6 strict concurrency, no force unwraps / `try!` outside tests, iOS 18+. Read the Kelpie section of `CLAUDE.md` and `docs/adr/0016-ipad-pointer-input.md` first. **Never edit `Packages/GhosttyTerminal`.**

**File ownership (a runner is editing `Sources/Heeler/Terminal/TerminalKeyTrace.swift` in parallel — do not touch it):** you own `Sources/Heeler/Terminal/**` except that file, new files under `Sources/Heeler/Terminal/`, `Tests/HeelerTests/**`, `CHANGELOG.md` (append at the end of `[Unreleased]` → `### Added`), and you run `xcodegen generate` after adding files. Do not touch `Sources/Heeler/Client/**`, `project.yml`, `KelpieVault/`, docs.

## Why app-side

On the device, touch selection stops at one word and cannot be extended; the user wants iPadOS-style handles. The vendored Ghostty view's selection machinery is internal to the package (`TerminalSurface.sendMouseButton/sendMousePos/hasSelection` are not public; `UITerminalView.selectionRects(for:)` returns `[]`, so UIKit's `UITextInteraction` has nothing to draw), and under herdr's mouse tracking a plain local click is forwarded to the PTY rather than selecting. So Kelpie draws and owns the selection itself: it already maps points to cells (`TerminalGridPointMapper`, `Sources/Heeler/Terminal/TerminalMouseReporting.swift`) and reads the viewport text (`terminalSession.readViewportText()`, used by `linkMatch(at:)` in `TerminalScreenView.swift`). Trackpad/mouse selection (Ghostty's own) stays as it is.

## 1. `Sources/Heeler/Terminal/TerminalTouchSelection.swift` (new, pure, testable)

```swift
struct TerminalGridCell: Hashable, Sendable { let column: Int; let row: Int }   // reuse the existing cell type if one exists in TerminalMouseReporting.swift
struct TerminalTouchSelection: Equatable, Sendable {
    var anchor: TerminalGridCell
    var focus: TerminalGridCell
    /// Row-major start/end, inclusive.
    var start: TerminalGridCell { get }
    var end: TerminalGridCell { get }
    /// Per-row spans [(row, firstColumn, lastColumn)] for a grid `width` columns wide.
    func spans(width: Int) -> [(row: Int, first: Int, last: Int)]
    /// The selected text from viewport rows: partial first/last rows, whole middle rows, trailing spaces trimmed per row, rows joined with "\n". A row's text shorter than the span is clamped.
    func text(in rows: [String]) -> String
    /// Word under `cell`: the maximal run of non-whitespace around it on that row (nil on whitespace or beyond the row).
    static func word(at cell: TerminalGridCell, in rows: [String]) -> TerminalTouchSelection?
}
```
Reuse `TerminalLinkDetector`'s viewport-to-rows splitting if it has one (grep `rows(inViewport` / `split`); do not duplicate. Tests in `Tests/HeelerTests/TerminalTouchSelectionTests.swift`: normalization when focus precedes anchor; single-row span; three-row span text; trailing-space trimming; word at start/middle/end of a run; whitespace → nil; text when a row is shorter than the span.

## 2. `Sources/Heeler/Terminal/TerminalSelectionOverlayView.swift` (new, UIKit)

A transparent `UIView` laid over the terminal (added as a subview of `HeelerTerminalView`, above the surface, `isUserInteractionEnabled` only on the handle views, ignoring safe area, resized with the terminal's bounds):
- Draws the highlight as one rounded rect per span in `tintColor` at 0.3 alpha (span rects from the grid mapper: cell width/height × columns/rows, honouring the terminal's padding the mapper already knows).
- Two handle views in the iOS style: a 2 pt vertical bar the cell height plus a 10 pt filled circle, tint colour, the start handle's knob above the first span, the end handle's knob below the last span; each handle has a 44×44 pt hit area (`hitTest` override or a larger clear frame). Handles are draggable (`UIPanGestureRecognizer`, direct touch only): dragging the start handle sets `anchor` to the cell under the finger, dragging the end handle sets `focus`; the model normalises; the overlay redraws.
- `var selection: TerminalTouchSelection?` — nil hides everything.
- `onSelectionChanged: ((TerminalTouchSelection?) -> Void)?` for the owner.
- Accessibility labels "Selection start" / "Selection end", adjustable.

## 3. Gestures and menu in `HeelerTerminalView` (`TerminalScreenView.swift`)

- **Double tap (direct touch, one finger)** on the terminal selects the word under the finger: `TerminalTouchSelection.word(at:in:)` from the current viewport rows → overlay shows. Add a `UITapGestureRecognizer` with `numberOfTapsRequired = 2`, `allowedTouchTypes = [direct]`. Do **not** make the existing single-tap recogniser `require(toFail:)` it — a terminal click must stay immediate; the first tap of the pair sends its click as today and that is accepted (say so in a comment). If a double tap lands on whitespace, do nothing.
- **Two-finger long-press** (currently presents `TerminalTextSelectionPresenter`'s read-only sheet): keep the sheet code but route the gesture to the same word selection with handles; if there is no word under the fingers, fall back to the sheet. Update the doc comment on the presenter.
- While a selection exists: show `UIEditMenuInteraction` anchored to the selection's last span with **Copy** (writes `selection.text(in: rows)` to `UIPasteboard.general.string`, then clears the selection) and **Select All** (anchor at (1,1), focus at the last non-empty row's last column). The system Copy action (`copy(_:)`, Cmd+C on a hardware keyboard) must copy the touch selection when one exists, and otherwise defer to the vendored `copy(_:)`; `canPerformAction(copy:)` returns true when a touch selection exists.
- Clear the selection on: a single tap outside the handles, any key press reaching `pressesBegan`, touch scrolling, a resize, `resignFirstResponder`, and when the terminal's viewport text no longer contains the selected text (check lazily at copy time only: if the text under the cells changed, copy what is there now — do not poll).
- The selection does not send anything to the PTY. Herdr's mouse tracking is unaffected. Trackpad clicks/drags go to Ghostty as today.
- Keep ADR 0016 behaviours intact: one-finger drag scrolls, one-finger long-press is a right click, trackpad right-click is claimed.

## 4. Housekeeping

- `xcodegen generate` after adding the two files.
- `CHANGELOG.md` `[Unreleased]` → Added: "Touch text selection with handles: double-tap a word, drag the handles to extend, then Copy from the menu or with Cmd+C. Selection is drawn by Kelpie over the terminal grid, so it works even while herdr tracks the mouse. (Kelpie)".
- Build for the device in the background, log to a file, read only the tail:
```
S=/private/tmp/claude-501/-Users-anthonytopalides-Developer-Kelpie/2beb8609-5f8f-488c-8847-4514dad12a4b/scratchpad/build-6a
mkdir -p $S
xcodebuild build -project Heeler.xcodeproj -scheme Heeler -configuration Release -destination 'platform=iOS,id=09D7738D-2173-55EF-8966-A9C3EA1D0514' -clonedSourcePackagesDirPath $S/kelpie-spm -derivedDataPath $S/kelpie-dd -allowProvisioningUpdates > $S/build.log 2>&1
```
Never the simulator. Fix errors in your files only. Do NOT install and do NOT commit. Write `report.md` in your folder as you go. Return at most 300 words: files (paths), the build tail line, anything skipped and why.
