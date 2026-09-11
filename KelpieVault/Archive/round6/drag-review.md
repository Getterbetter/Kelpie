# Review — one-finger long-press-then-drag as a left mouse drag

Scope: only the held-drag piece. Touch selection handles, double tap, ⌘C, the overlay
and its edit menu were excluded as already reviewed. No build, no tests run.

Files read: `docs/adr/0016-ipad-pointer-input.md`,
`Sources/Heeler/Terminal/TerminalScreenView.swift` (2430–2520 plus every call site of
`heldPointerDrag`, `didReportRightClickForTouch`, `rightClickTouch`,
`gestureRecognizerShouldBegin`, `installTouchScrolling`, `touchesBegan/Moved/Ended/
Cancelled`, `didMoveToWindow`, `setLocalInputEnabled`, `terminalDidResize`),
`Sources/Heeler/Terminal/TerminalTouchScroll.swift`,
`Sources/Heeler/Terminal/TerminalMouseReporting.swift` (unchanged since 447ef31),
`Tests/HeelerTests/TerminalMouseReportingTests.swift`, `CHANGELOG.md`.

## What checks out

1. **SGR bytes.** Press `ESC [ < 0;col;row M`, motion `ESC [ < 32;col;row M`
   (`Button.left.rawValue 0 + motionFlag 32`), release `ESC [ < 0;col;row m` with the
   lower-case terminator — all three match xterm. `remoteRightClickSequence` is
   untouched, and the new test asserts press+release is byte-identical to
   `remoteClickSequence`. Legacy: press 32, motion 64 (`0 + 32` motion `+ 32` bias),
   release 35 (`3 + 32`, button identity correctly dropped, terminator stays `M`);
   coordinates go through `UInt8(clamping: min(v, 223) + 32)`, so bounded, and
   `cell(at:)` clamps to `1...columns/rows` so no under-run. All three new methods
   return nil unless `tracksMouse`, and the test proves the nil-before-1002h and
   nil-after-1002l cases.
2. **State machine.** `.began` records origin + origin cell, haptic, sets
   `didReportRightClickForTouch = true`. Press is emitted once, lazily, on the first
   `.changed` past the slop, measured `distance(location, held.origin)` from the
   **origin point** (correct), and `lastCell` is seeded to `originCell` so the origin
   cell never gets a redundant motion report. Motion only when
   `cell != last`. `.ended` with `lastCell == nil` sends the right click at
   `held.origin` (not the lift point — correct) and never a release; `.ended` with a
   drag sends only the release and never a right click. `.cancelled`/`.failed` release
   at `lastCell`. `defer { heldPointerDrag = held }` in `.changed` writes back on every
   early return. `.failed` cannot follow `.began` anyway. Tap suppression still works:
   `handleHerdrTap` guards `didReportRightClickForTouch`, which `touchesBegan` resets
   only when the recognizer is back at `.possible`.
3. **Arbitration.** `touchScrollGesture` refused while `heldPointerDrag != nil`;
   `rightClickGesture`/`textSelectionGesture` still gated on `tracksMouse` and
   Ghostty's own long press still refused while `tracksMouse` — none of that changed.
   `textSelectionGesture.numberOfTouchesRequired = 2` and the double tap are untouched
   by this diff. The link claim only ever takes `.indirectPointer` touches, so a finger
   hold cannot interact with it.
4. **`tracksMouse == false`.** `.began` returns before setting `heldPointerDrag`, and
   `gestureRecognizerShouldBegin` refuses `rightClickGesture` outright, so Ghostty's own
   long-press selection path is reached exactly as before; the three new encoders return
   nil. Byte-for-byte unchanged.
5. **Haptic and docs.** Medium impact on `.began`; the doc comment states the
   menu-on-lift trade explicitly, and the CHANGELOG entry says "still opens herdr's
   menu, on release".
6. **Swift 6 / safety.** `HeldPointerDrag` is a private nested struct on a
   `@MainActor`-inherited `UIView` subclass, touched only from main-actor gesture
   callbacks. No force unwraps, no `try!`; every optional is `guard let`.

## Findings

### Should fix

**S1 — `TerminalScreenView.swift:2516` — the drag slop is ~4 pt, below UIKit's own
stationary tolerance.**
`max(4, min(terminalCellSize.width, terminalCellSize.height) / 2)` takes the *minimum*
dimension, which on a monospace grid is always the cell **width** (default metrics
`CGSize(width: 8, height: 16)`, line 715; a real iPad cell is ~7–9 pt wide). So the
threshold is 3.5–4.5 pt, floored at 4. The same recognizer is configured with
`allowableMovement = 10` (line 2093) — i.e. UIKit itself treats up to 10 pt of drift as
"the finger did not move". A held finger routinely drifts more than 4 pt as the contact
patch flattens over the 0.5 s press.
*Why it matters:* a hold meant as a right click then silently becomes a one-or-two-cell
left drag — press and release at almost the same cell, which herdr reads as a **left
click**, not a context menu. That is the exact failure the feature's own doc comment
promises it avoids ("so that the hand's own tremor never turns a menu into a resize"),
and on a menu-bearing cell a stray left click activates something instead of opening
anything. Suggest keying off the cell *height* (`terminalCellSize.height / 2`) or
flooring at the recognizer's own `allowableMovement`.
*Confidence:* high that the value is ~4 pt and contradicts its comment; medium-high that
it is perceptible in use.

**S2 — `TerminalScreenView.swift:2467, 2476, 2484, 2493 — the drag writes to the PTY
without the `isLocalInputEnabled` guard.**
`.began` checks `isLocalInputEnabled` (2458), and both `clickTouch(at:)` (1970) and
`rightClickTouch(at:)` (1985) check it, but `.changed`, `.ended` and `.cancelled` call
`terminalSession.sendInput(...)` directly. `setLocalInputEnabled(false)` (1273) can land
mid-hold — it is driven from the SwiftUI updater when the console cover appears or the
client detaches — and it neither cancels the recognizer nor clears `heldPointerDrag`.
*Why it matters:* input the app has declared disabled still reaches the remote PTY, and
it is a *press* that may never get its matching release. Inconsistent with every other
input path in this class.
*Confidence:* high on the code gap; medium on how often the flip lands inside a hold.

**S3 — `TerminalScreenView.swift:1526–1533 — `didMoveToWindow` does not tear down an
in-flight hold.**
Losing the window clears the touch selection and calls
`responderGate.invalidateTouches()` — whose own doc comment
(`TerminalTouchScroll.swift:101`) says "A view leaving its window may never see
`touchesCancelled`" — but `heldPointerDrag` is left as it was. If the recognizer's
`.cancelled` does not arrive, two things stick: the left button stays **down** on the
remote (herdr keeps dragging a border), and `gestureRecognizerShouldBegin`
(`TerminalScreenView.swift:1686`) refuses `touchScrollGesture` forever, so touch
scrolling is dead for the life of the view.
*Why it matters:* both failure modes are unrecoverable without a new view, and the class
already encodes the belief that window loss can swallow cancellation.
*Confidence:* medium — UIKit usually does deliver `.cancelled` when a recognizer's view
leaves the hierarchy, so this may be belt-and-braces; the cost of the guard is two
lines.

### Optional

- `docs/adr/0016-ipad-pointer-input.md:36–52` still describes the one-finger hold as
  sending `remoteRightClickSequence` on the press, with no mention of the drag or of the
  menu moving to lift. CLAUDE.md points readers at this ADR as the record for iPad
  pointer input, so it now under-describes the behaviour. The trade is argued well in the
  Swift doc comment; a few lines appended to the ADR would put it where the project says
  to look.
- `terminalDidResize` (2785) clears the touch selection but leaves `heldPointerDrag`
  holding an `originCell`/`lastCell` measured against the old grid. A resize mid-drag is
  vanishingly rare and the release still goes out, so this is cosmetic.
- Nothing exercises the state machine itself — the new tests cover only the three
  encoders. The slop comparison and the "motion only on cell change" rule are pure
  logic and could be lifted into a small value type the way
  `TerminalTouchScrollAccumulator` was, if the drag is expected to grow.
- `gestureRecognizerShouldBegin`'s new guard reads `heldPointerDrag == nil`, which is
  nil whenever `.began` bailed early (local input disabled, or no cell) even though the
  long press did begin. Harmless today, but the flag and the payload are doing one job
  between them.

## Not checked

- No build, no test run (instructed). Byte assertions were verified by reading the
  encoder, not by executing the suite.
- No device behaviour: the actual finger-drift magnitude behind S1, whether UIKit
  delivers `.cancelled` on window loss behind S3, and whether herdr acts on the motion
  reports at all are all empirical questions this review could not settle.
- The touch-selection handles, the double tap, `copy(_:)`/⌘C, `TerminalTouchSelection`,
  `TerminalSelectionOverlayView` and their tests were out of scope and were read only
  where they touch the hold path.
