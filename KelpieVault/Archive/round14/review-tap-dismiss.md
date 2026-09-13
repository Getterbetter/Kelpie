# Review — tap-to-dismiss (open item 24)

Reviewed: `git diff` over `Sources/Heeler/Terminal/TerminalTouchScroll.swift`,
`Sources/Heeler/Terminal/TerminalScreenView.swift`,
`Tests/HeelerTests/TerminalAttachTests.swift`, `CHANGELOG.md`, plus the
surrounding gesture wiring in `TerminalScreenView.swift`. No build, no test run
(per brief).

## Verdict

The spec is met. Every removed symbol is gone with no reader left; the deferred
task is MainActor-isolated, weak-captured, checks `Task.isCancelled`, and uses
the constant. Findings below are gaps at the edges of the cancel set and one
user-visible claim in the CHANGELOG — none of them break the main path.

## Correctness findings

1. **should-fix — Sources/Heeler/Terminal/TerminalScreenView.swift:3116-3118
   (with 1943-1949).** A pan refused by `gestureRecognizerShouldBegin`
   (`heldPointerDrag != nil`, or `|vx| >= |vy|`) never reaches `.began`, so it
   never calls `cancelPendingKeyboardDismiss()`; UIKit sends no action message
   for `.failed`, so the `.cancelled, .failed` branch (3125) does not catch it
   either. A horizontal or diagonal drag begun within the 350 ms grace loses
   the keyboard mid-drag and resizes the viewport under the finger — exactly
   the resize the grace exists to avoid. Confidence: high on the code path,
   medium-high on the UIKit `.failed` semantics (documented: no action message
   for Failed).

2. **should-fix — Sources/Heeler/Terminal/TerminalScreenView.swift:2814-2818 /
   2910-2912.** The two long-press cancel sites are Kelpie's own recognizers,
   and both `rightClickGesture` and `textSelectionGesture` are gated on
   `modeTracker.tracksMouse` (1971-1976). On an alternate screen that does
   *not* track mouse — where a tap does reach `handleTap` and can schedule —
   selection is Ghostty's own long press (1977-1982), which has no cancel site.
   A hold-to-select started within the grace drops the keyboard mid-selection.
   Confidence: medium (depends on which agents leave mouse tracking off).

3. **should-fix — CHANGELOG.md:60-63.** "A tap on the terminal text puts the
   software keyboard away" overstates what ships. In the normal buffer without
   mouse tracking, `gestureRecognizerShouldBegin` (1951-1965) only lets a tap
   through for tracksMouse / alt screen / running momentum / the input band /
   a URL, so a tap on a plain shell's output never reaches `handleTap` and
   cannot dismiss. Combined with scroll-dismiss being gone, a plain shell whose
   keyboard was raised from the input row now has **no** touch route to put it
   down (it had one before this change). The builder flagged the gate and left
   it alone, which is the right scope call; the changelog sentence is the part
   that should be narrowed, or the gap accepted explicitly. Confidence: high.

4. **nit — Sources/Heeler/Terminal/TerminalScreenView.swift:1398-1400.** The
   cancel sits *after* `guard isLocalInputEnabled else { return }`, so a
   keyboard request while local input is disabled does not call off a pending
   dismissal. Harmless in practice (nothing is raised either), but it is the
   one cancel site that can be skipped silently.

5. **nit — Sources/Heeler/Terminal/TerminalScreenView.swift:3142-3150.** No
   cancellation on `willMove(toWindow:)`/teardown. Safe as written: `weak
   self`, and `dismissKeyboardForTap()` is a no-op on a detached view
   (`isFirstResponder` false, `window` nil), so this is a note, not a fix.

## Checked and clean

- `touchScrollTravelY`, `didScrollDuringTouchGesture`,
  `didDismissKeyboardForTouchScroll`, `TerminalScrollKeyboardDismiss`,
  `dismissKeyboardForTouchScrollIfNeeded`, `travelThreshold`,
  `alreadyDismissedDuringGesture`: zero hits across `Sources/`, `Tests/`,
  `docs/`, `scripts/` (only `KelpieVault/Open items.md:44`,
  `Testing status.md:66`, `Kelpie.md:15`, `resume.md:26` still describe the old
  behaviour — round close-out, not code).
- No retain cycle: `Task { @MainActor [weak self] in … }`, `HeelerTerminalView`
  is `@MainActor` via `UIView`, so the schedule/cancel pair and the stored
  handle are all main-actor state. Swift 6 clean; no nonisolated capture.
- Assignment ordering is safe: the body cannot run before
  `pendingKeyboardDismiss = Task {…}` completes, because the scheduler is
  already on the main actor.
- `Task.isCancelled` is checked after the sleep (3146), and the sleep uses
  `TerminalTapKeyboardDismiss.doubleTapGrace` (TerminalTouchScroll.swift:325).
- Dismissal body is the specified `isFirstResponder ? dismissKeyboard() :
  window?.endEditing(true)` (3157-3168).
- URL branch untouched and returns before any scheduling (3053-3064); a
  `.haltMomentum` tap never schedules (3067-3069, and `shouldDismiss` rejects
  it); an input-band / alt-screen-bottom tap takes the `raisesKeyboard` branch
  and calls `requestKeyboard()`, which cancels.
- Hardware-keyboard exemption still reads the same `hasHardwareKeyboard` probe
  (TerminalScreenView.swift:759ff), unchanged.
- `TerminalTapAction` is already `Equatable` (TerminalTouchScroll.swift:5), so
  `action == .report(raisesKeyboard: false)` and the test's `#expect`
  comparisons type-check.
- Tests are in the file's Swift Testing style (`@Test func` + `#expect`), the
  local `dismisses` helper covers all five spec cases, and the pre-existing
  `theTapThatHaltsAFlickDoesNothingElse` (Tests:1223-1237) is unaffected.
- CHANGELOG entry replaced in place under `## [Unreleased]` → `### Added`
  (line 56-63), which is where the round-12b entry lived.

## Could not check

- No compile or test run (brief said review only), so "tests compile" is a
  read-level judgement, not a verified build.
- Device behaviour of the 350 ms grace against the real double-tap and the
  vendored Ghostty recognizers — only reasoning from the code.
- Whether any CI script asserts an executed-test count for
  `TerminalAttachTests` (grep of `scripts/run-ci-ios-tests.sh` found no count
  for this suite, but I did not read the whole script's assertion table).

## Style notes (ignorable)

- `handleTap` already knows `raisesKeyboard == false` in the `else if`, so
  passing `action` into `shouldDismiss` re-derives it. Harmless; the pure
  function is the testable seam, so the redundancy is arguably the point.
- `_ = scrollTouch(translationY:)` (3120) discards a result the old code used;
  fine, though `@discardableResult` on `scrollTouch` would read cleaner.
- `TerminalTapKeyboardDismiss`'s doc comment keeps the iPhone/iPadOS framing
  from the old enum; the behaviour is not idiom-gated (as the scout's map
  already flagged for round 12b), so the second paragraph slightly oversells a
  restriction that is not in the code.
