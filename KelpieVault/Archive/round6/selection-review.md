# Review — round 6A touch text selection (fresh context)

Reviewed: `git diff` on `kelpie` over 447ef31 (excluding `KelpieVault/`, `TerminalKeyTrace.swift`),
plus `Sources/Heeler/Terminal/TerminalTouchSelection.swift`,
`Sources/Heeler/Terminal/TerminalSelectionOverlayView.swift`,
`Tests/HeelerTests/TerminalTouchSelectionTests.swift`.
Against builder5/spec.md and `docs/adr/0016-ipad-pointer-input.md`. No build run (builder log: BUILD SUCCEEDED).

## should-fix

### 1. ⌘C races the blanket clear in `pressesBegan`
`Sources/Heeler/Terminal/TerminalScreenView.swift:2206-2209` (`clearTouchSelection()` first line of
`pressesBegan`) vs `:1455` (`copy(_:)`).
The comment asserts "⌘C has already run by the time a press arrives here". Nothing in this file
guarantees that: the ⌘V note at `:1417-1425` says the *same* key event reaches both `pressesBegan`
and UIKit's editing shortcut and "whichever arrives first in a run-loop turn wins". If the press
path runs first, the selection is nil by the time `copy(_:)` is reached, so it falls through to
`super.copy(sender)` (Ghostty's pointer selection, always empty for a finger) and nothing is copied —
while ⌘C is also forwarded to Ghostty. The CHANGELOG advertises Cmd+C.
Fix shape (as the brief anticipated): mirror ⌘V. Add `isCopyShortcut(_:)` next to `isPasteShortcut`
(`:2363`), and inside the press loop, before anything else:
`if Self.isCopyShortcut(press) { if touchSelection != nil { copyTouchSelection() }; continue }`;
move the unconditional `clearTouchSelection()` to after that check so a ⌘C press never clears first.
Also add the press to `forwardablePresses`' skip list so the release does not reach Ghostty.
Confidence: medium-high (the ordering is genuinely undefined; the failure mode is certain if the
press wins).

### 2. Both taps of a double tap are still reported — two clicks, and a link opens twice
`TerminalScreenView.swift:2056-2059` (`tapGesture`, no failure requirement — correct per spec) and
`:2411` (`handleHerdrDoubleTapGesture`), with `handleTap(at:)` at `:2520`.
The spec accepted *one* stray click ("the first tap of the pair sends its click as today"), and the
new doc comment at `:2400-2404` repeats that. But a 1-tap `UITapGestureRecognizer` recognizes on
**every** tap, so the second tap fires `handleHerdrTap` again: herdr receives two left clicks at the
cell (a double click to the TUI's menu/row logic), and if the cell is a link, `handleTap` takes the
`linkMatch` branch on both taps and calls `open(match)` twice — double-tapping a URL to select it
opens it twice on the iPad (or pushes the Host file viewer twice).
Fix shape: suppress the report for the second tap — e.g. in `handleHerdrTap`, bail when the
recognizer's touch had `tapCount >= 2` (record it in `touchesBegan`, which already inspects touches),
the same way `didReportRightClickForTouch` suppresses the hold's release.
Confidence: high for the double-open, high for the double click.

### 3. Handle drags map the finger, not the handle, so a knob grab is off by a row
`Sources/Heeler/Terminal/TerminalSelectionOverlayView.swift:212`
(`metrics.cell(at: gesture.location(in: self))`), with placement at `:181-191`.
`place` centres the 44×h box on `rowRect.midY`, and the knob is drawn 10 pt *above* the bar for the
start handle (`:304-313`) / below it for the end handle. The knob is the visible grab target, so the
finger sits outside the row the handle marks; because the drag uses the absolute touch point with no
grab offset, touching the start knob and dragging sideways immediately moves `anchor` to the row
above (and the end handle to the row below). Cell heights are ~16-24 pt, so this is a whole row.
Fix shape: on `.began`, record `delta = handleCenterOrMarkedCellPoint − touch.location`; on
`.changed`, map `gesture.location(in: self) + delta`. (UIKit's own handles do exactly this.)
Confidence: medium-high — geometry is unambiguous; the size of the effect depends on whether the
user grabs the knob or the bar.

## optional (nits — ignorable)

- `TerminalScreenView.swift:1499-1502`: the overlay is a *subview*, but libghostty parks its content
  as a raw `IOSurfaceLayer` sublayer of this view's layer (see `TerminalOrphanSurfaceLayers.swift:20`).
  A surface attach/rebuild appends its layer on top; only the next `layoutSubviews` re-raises the
  overlay. Consider re-raising from `terminalDidAttachSurface` too. (Low risk: a selection is made
  long after attach, and `terminalDidResize` clears it.)
- Dead API: `TerminalSelectionOverlayView.onSelectionChanged` (`:26`) is never assigned by the owner
  (`installTouchSelection` sets only `onDragFinished`); `isDraggingHandle` (`:33`) and
  `TerminalTouchSelection.isSingleCell` (`:64`) are never read. The `onDragFinished` doc (`:28`)
  claims the menu "is hidden for the duration of the drag" — nothing hides it.
- `TerminalScreenView.swift:2444-2452`: `presentSelectionEditMenu` calls `dismissMenu()` then
  `presentEditMenu` in the same run-loop turn; invoked from the Select All action this may swallow
  the re-present. Worth checking on device.
- `TerminalTouchSelection.swift:167-173`: trims trailing tabs as well as spaces (spec said spaces);
  harmless, arguably better.
- `TerminalTouchSelection.swift:113-121`: a row index past `rows.count` is skipped entirely while an
  existing-but-short row contributes `""`. Inconsistent, no practical effect.

## Checked and sound

- **Cell geometry round trip.** `TerminalSelectionOverlayView.rect(forRow:first:last:metrics:)`
  (`:143-155`) uses exactly `TerminalGridPointMapper.gridOrigin` + `(n-1)·cellSize`, which
  `cell(at:)` (`TerminalMouseReporting.swift:98-106`) inverts with `floor` — cell → rect → point →
  same cell holds for every cell, padding included. `lastSpanRect` anchors the menu at the last
  span's bottom-centre. Overlay tracks bounds via `autoresizingMask` *and* `layoutSubviews`; font
  zoom goes through `terminalDidResize`, which clears.
- **Gesture conflicts.** No `require(toFail:)` added anywhere, so no tap is delayed (spec's explicit
  requirement). `doubleTapGesture` is direct-touch, 2 taps, 1 finger, `cancelsTouchesInView = false`.
  The overlay's `point(inside:)` (`:115`) returns true only inside a visible handle frame, so the
  highlight swallows neither taps nor scrolls, and handle touches never reach `touchesBegan`.
  `gestureRecognizer(_:shouldReceive:)` (`TerminalScreenView.swift:1717-1725`) is scoped by
  *location* (handle frames) rather than by recognizer, which is right here: every recognizer that
  matters (`touchScrollGesture`, `tapGesture`, `rightClickGesture`, `textSelectionGesture`,
  `doubleTapGesture`, and Ghostty's own long press at `UITerminalView+Interaction.swift:445`) has
  this view as delegate, and all of them must stand down over a handle. The handles' own pans carry
  no delegate, so they are unaffected. ADR 0016 paths (one-finger hold = right click, two-finger
  hold, trackpad claim, pointer scroll) are untouched apart from the intended two-finger reroute.
- **Model.** Normalization across rows and within a row, 1/2/3-row spans, width clamping, per-row
  trailing-space trimming, no trailing newline, short-row clamping, `word(at:)` at run start/middle/
  end + whitespace/out-of-range → nil, `all(in:)` last non-empty row: all correct by reading, and all
  covered by the new suite. Row indexing (`components(separatedBy: "\n")`, 1-based) matches
  `TerminalLinkDetector`'s existing convention, so the two agree about what row a cell is on.
- **Copy/menu.** `copy(_:)` prefers the touch selection and defers to `super` otherwise;
  `canPerformAction(copy:)` returns true only when a touch selection exists; Copy re-reads the
  viewport at copy time (spec's lazy staleness rule), clears, then writes the pasteboard; Select All
  keeps the selection.
- **Clearing.** `touchesBegan` (direct touches only, handles excluded by hit-testing), `pressesBegan`,
  `scrollTouch`, `terminalDidResize`, `resignFirstResponder`, `didMoveToWindow(nil)`. Handle drags
  and menu presentation do not clear.
- **Isolation / cycles / unwraps.** Overlay and handle view are `@MainActor`; model is `Sendable`.
  `gridMetrics`, `onDragFinished`, `onAdjust` and both `UIAction`s capture `[weak self]`; no retain
  cycle. No force unwraps or `try!` (only `fatalError` in unavailable `init(coder:)`, as elsewhere).
- **Project + CHANGELOG.** `Heeler.xcodeproj/project.pbxproj` adds both sources to the Heeler target's
  Sources phase and the Terminal group, and the test file to the HeelerTests phase and group —
  correct. CHANGELOG entry is in Kelpie's `[Unreleased] → Added`, matches the spec's wording
  (accuracy depends on finding 1).

## Not checked

- No build or device run: gesture ordering, the ⌘C delivery order, `UIEditMenuInteraction`'s own
  internal recognizers (it may install gestures on the view that interact with the hold gestures),
  z-order against the live `IOSurfaceLayer`, handle legibility at accessibility text sizes, and
  VoiceOver adjustable behaviour are all unverified in practice.
- The new XCTest/swift-testing suite was not executed (builder reports the simulator is unusable and
  `build-for-testing` fails on a pre-existing unrelated file).
