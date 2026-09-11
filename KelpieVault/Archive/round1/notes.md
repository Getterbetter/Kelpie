---
source: "delegate-20260910-191536/ipad/notes.md — round 1 build notes, 2026-09-10 22:40"
---

# Kelpie iPad pointer/scroll/layout — build notes

## Reading findings (before code)

- Ghostty `handleIndirectPointerTouches` (Packages/GhosttyTerminal/.../UITerminalView+Interaction.swift:146-278):
  on RIGHT `.began` it only records `pendingSelectionMenuPoint` (from `selectionMenuPoint(at:)`, or the
  location when it is inside a previous pointer drag-selection rect); on `.ended`, if that is nil it sends
  `sendMouseButton(PRESS, RIGHT)` then `RELEASE` to the surface. So nulling `selectionMenuPoint` is enough.
- 1c answer: libghostty encodes the mouse report inside `surface.sendMouseButton` (ghostty's
  Surface.zig mouseButtonCallback -> mouse report writer), and the bytes leave through the surface's
  write callback, i.e. `TerminalSessionCallbackBridge.send` -> `onSend` -> `TerminalAttachInputQueue` ->
  SSH channel write (HeelerSSHTransport.swift:2296). Same path Heeler's own `clickTouch` uses via
  `terminalSession.sendInput`. No fallback interception needed.
- Caveat (not in spec, left alone): if a pointer drag-selection rect is still live, Ghostty stores a
  pending menu point on right `.began` regardless of `selectionMenuPoint`, and on `.ended` swallows the
  click when the menu point resolves to nil. Only reachable after a left-drag with the pointer while a
  TUI owns the mouse; the next right-click after any tap (drag < 2pt clears the rect) works.
- 2d: `InMemoryTerminalSession.readViewportText()` IS public and reachable. But
  `TerminalTextSelectionRequest`'s memberwise init is internal to the package, so a subclass cannot
  construct one to call `terminalDidRequestTextSelection`. Implemented by calling Heeler's own
  `TerminalTextSelectionPresenter` (which is all `terminalDidRequestTextSelection` does) through a new
  text/anchorRange overload — no package edit, same sheet.

## Per spec item

1. **Right-click via pointer — done.** `HeelerTerminalView.selectionMenuPoint(at:)` and
   `contextMenuInteraction(_:configurationForMenuAtLocation:)` both return nil while
   `modeTracker.tracksMouse`. 1c: no fallback needed (see finding above).
2. **Touch long press = right click — done.** `TerminalMouseEncoding.Button.right = 2`,
   `TerminalModeTracker.remoteRightClickSequence(column:row:)`,
   `HeelerTerminalView.rightClickTouch(at:)`, `rightClickGesture` (direct, 1 touch, 0.5s,
   allowableMovement 10), medium haptic. `gestureRecognizerShouldBegin` refuses ours unless
   tracksMouse and refuses Ghostty's long press while tracksMouse. The release is also stopped
   from arriving as a tap (`didReportRightClickForTouch`) — herdr would read that as picking a
   menu row. 2d done via `textSelectionGesture` (2 touches) + `TerminalTextSelectionPresenter`
   text overload (see finding above).
3. **Trackpad / wheel scroll — done.** `pointerScrollGesture`: scroll types continuous+discrete,
   indirectPointer touches, simultaneous recognition, ignores events with touches down, feeds
   `scrollTouch(translationY:)` with the finger pan's sign convention, stops momentum on .began.
   Wrapped in `#if !targetEnvironment(macCatalyst)`.
4. **Layout.** No horizontal padding or inset exists around `TerminalScreenView` in either
   AgentTerminalView (`terminalSurface`, AgentTerminalView.swift:789) or ShellTerminalView
   (body, ShellTerminalView.swift:91) — nothing to remove; both already paint the terminal
   background behind the surface (`surfaceBackground(for:)`), and the Agent one extends it under
   the top safe area with `.ignoresSafeArea(.container, edges: .top)`. Added
   `columnVisibility` to ConsoleView's NavigationSplitView, driven by `preferredColumnVisibility`
   (`.detailOnly` on regular width with a terminal open, `.automatic` otherwise; compact width
   always `.automatic`, so iPhone is untouched). Applied with `.onChange(..., initial: true)`
   so a manual sidebar toggle is not fought.
   Item 4 answer (resize on sidebar toggle / rotation): yes — Ghostty's `UITerminalView`
   re-syncs the surface from every `layoutSubviews` pass (`UITerminalView+Lifecycle.swift:119`
   -> `core.fitToSize()`) and reports through the viewport callback;
   `HeelerTerminalView.layoutSubviews` (TerminalScreenView.swift:1279) forwards to
   super unless a keyboard-transition freeze is in force, and the callback reaches
   `TerminalSessionCallbackBridge.resize` -> `onSizeChanged` ->
   `AttachTerminalStore.viewDidResize`. A sidebar show/hide and a rotation are both bounds
   changes, so both lay out and both report.
   Keyboard accessory / control pad: no change needed. `TerminalControlPadView` (TerminalKeyboard
   .swift:244) is `UIStackView`s with `distribution = .fillEqually` pinned to the view's leading
   and trailing anchors, so it already spreads to whatever width it is given — at 1180pt the keys
   simply get wider. Nothing is fixed to a phone width.
5. **Hardware keyboard — read only, nothing broken.** Item 5 answer: Ghostty claims Ctrl combos
   twice over (UIKeyCommand list with `wantsPriorityOverSystemBehavior`, plus `pressesBegan` ->
   `handleKeyPress`), so Ctrl+B reaches the PTY; arrows, Esc and Tab go through the same
   `handleKeyPress` -> libghostty key encoder; command-modified keys are deliberately not
   suppressed (`shouldSuppressUIKeyInput` returns false when isCommandModified), so Cmd+C/Cmd+V
   fall to the responder chain's `copy(_:)`/`paste(_:)`. Heeler's `pressesBegan` override
   swallows only ⌘+ / ⌘= / ⌘- / ⌘_ (font zoom, by design) and forwards everything else.
6. **Tests — added** `rightButtonReportsAsButtonTwo` and
   `rightClicksOnlyReportWhileTheApplicationTracksTheMouse` to
   Tests/HeelerTests/TerminalMouseReportingTests.swift.
7. **Housekeeping** — CHANGELOG "Kelpie" section at the top; docs/adr/0016-ipad-pointer-input.md.

## Blocker found (pre-existing, not fixed — project.yml is off limits)

`xcodebuild test` fails before running anything: `TEST_HOST` in the generated project is
`$(BUILT_PRODUCTS_DIR)/Heeler.app/Heeler`, but the rebrand set `PRODUCT_NAME: Kelpie`, so the
built product is `Kelpie.app`. xcodegen derives TEST_HOST from the *target* name, so the fix
belongs in project.yml (an explicit `TEST_HOST`/`BUNDLE_LOADER` under the HeelerTests target)
plus a regenerated project — both out of scope here. Tests were run with
`'TEST_HOST=$(BUILT_PRODUCTS_DIR)/Kelpie.app/Kelpie'` on the command line instead.

## Commits (branch kelpie, never pushed)

- bb1aece feat(terminal): iPad pointer and touch input reach herdr (items 1-3, 6)
- b1c0fe4 feat(console): an open terminal fills the iPad window (item 4)
- b81f3c8 docs: record the iPad pointer decisions (item 7)

Trailer deviation: the session's harness attribution instruction ("this replaces any earlier
attribution guidance") names `Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>`,
so that line is used instead of the spec's `Claude Fable 5.1`. The `Claude-Session:` line is the
spec's, unchanged.

## Test run

**Gap: tests could not be RUN on the iPad simulator on this machine.** Two attempts
(ipad/test-mouse.log, ipad/test.log) built fine and then stalled 17 and 21 minutes in the
app-launch step, both ending `Failed to launch app with identifier: TME.Kelpie ... Error
Domain=NSMachErrorDomain Code=-308 "(ipc/mig) server died"` from
`IDELaunchiPhoneSimulatorLauncher`. That is a CoreSimulator/host failure, not a code failure —
the same products launch fine on iPhone. Note the second attempt also needed
`Build/Intermediates.noindex/SwiftExplicitPrecompiledModules` deleted first: killing the first
run left stale `.pcm` files that failed the next build with "module file ... is out of date".

Tests therefore ran on `platform=iOS Simulator,name=iPhone 17`, same recipe otherwise
(ipad/test-iphone.log):

    ✔ Suite TerminalMouseReportingTests passed after 28.942 seconds.
    ✔ Test run with 13 tests in 1 suite passed after 28.942 seconds.
    ** TEST SUCCEEDED **

iPad-simulator build (ipad/build.log), exact spec recipe, run last against the final tree:
`** BUILD SUCCEEDED **`.

Worth re-running `-only-testing:HeelerTests` on the iPad destination on a machine whose
simulator launches apps; the suites are all platform-independent logic, so no result should
differ.

## Review fixes (second pass)

- Fix 1: `HeelerTerminalView` now claims the whole right-button indirect-pointer touch sequence
  while `tracksMouse` (`rightButtonTouchToClaim`, `finishClaimedRightButtonTouch`, plus overrides
  of touchesBegan/Moved/Ended/Cancelled): it becomes first responder on began, reports press and
  release on end through the same grid mapper `tapAction` uses, and forwards none of those
  touches, so Ghostty's `pointIsInsidePointerSelection` early return can no longer swallow a
  right click landing inside a stale drag rect. The `selectionMenuPoint` /
  `contextMenuInteraction` overrides stay as a second line of defence.
- Fix 2: the two-finger `textSelectionGesture` begins only while `tracksMouse`; otherwise
  Ghostty's one-finger long press already presents the sheet and both could fire.
- No unit test added: both paths need a synthesized `UITouch`/`UIEvent` (`buttonMask`,
  `location(in:)`), which the suite cannot fabricate; the encoding they call
  (`remoteRightClickSequence`) is already covered.
- Re-verified after the fixes: iPad build `** BUILD SUCCEEDED **` (ipad/build.log). The iPad
  destination still cannot run tests on this machine (this time "Failed to establish
  communication with the test runner (Channel disconnected)", ipad/test.log), so the suite ran on
  a pre-booted iPhone 17: `✔ Test run with 13 tests in 1 suite passed` / `** TEST SUCCEEDED **`
  (ipad/test-iphone.log). Note the simulator host needed `xcrun simctl shutdown all` plus an
  explicit boot first — an unbooted device times out at 60s under xcodebuild.
