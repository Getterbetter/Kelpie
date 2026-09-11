---
source: "delegate-20260910-191536/review/review.md — round 1 fresh-context review, 2026-09-10 22:02"
---

# Fresh-context review — Kelpie iPad pointer/scroll/layout (bb1aece, b1c0fe4, b81f3c8)

Reviewed: `git diff 98cb6b6..b81f3c8 -- Sources Tests docs CHANGELOG.md`, plus the vendored package
at `Packages/GhosttyTerminal/Sources/GhosttyTerminal/Platform/UIKit/` and the surrounding Heeler code.
No edits made. Nothing was run on a simulator; findings are code-traced.

## Findings

### 1. should-fix — a trackpad right click is still swallowed after a pointer drag
`Sources/Heeler/Terminal/TerminalScreenView.swift:1349` (the `selectionMenuPoint` override) only
controls one of the two ways Ghostty arms the menu. In
`Packages/.../UITerminalView+Interaction.swift:219` a right `.began` sets
`pendingSelectionMenuPoint = location` from `pointIsInsidePointerSelection(location)` **without**
consulting `selectionMenuPoint(at:)`. On `.ended` (line 241) a non-nil pending point takes the
early-return branch: `selectionMenuPoint(at:)` now returns nil, so no menu is shown, and line 247
`return true` exits before any `sendMouseButton`. Net effect while `tracksMouse`: a right click
inside the rect left by a previous pointer drag produces *neither* the herdr menu nor an SGR report.
`pointer.lastSelectionRect` is only cleared by a left click that moves < 2 pt
(`finishPointerSelection`, line ~313), so the state persists across the whole drag-then-right-click
sequence — a plausible user flow (drag to select in herdr, right-click the selection).
The builder documented this in notes.md as a known caveat and left it. Spec item 1 asks for the
right press+release to reach herdr, so this is a real remaining gap, not a nit.
Confidence: high (traced line by line; not observed at runtime).
Fixable from the subclass by intercepting `touchesEnded` for `event.buttonMask.contains(.secondary)`
— the fallback the spec itself sketches in 1c.

### 2. should-fix — the two-finger selection gesture is ungated
`Sources/Heeler/Terminal/TerminalScreenView.swift:1338` returns `true` for `textSelectionGesture`
unconditionally. Two consequences:
- It bypasses Ghostty's own gate (`UITerminalView+Interaction.swift:726-733`, which refuses any
  long press when `activeTextSelectionDelegate == nil`), so the sheet can be presented for a host
  that never opted into selection.
- When `!tracksMouse` **both** Ghostty's one-finger long press and this two-finger one are live. If
  the second finger lands more than a few ms after the first, the one-touch recognizer can reach
  `.began` at 0.5 s and the two-touch one 0.5 s after the second finger, giving two
  `TerminalTextSelectionPresenter.present` calls and a UIKit "already presenting" failure.
Spec 2d scopes the two-finger gesture to "while herdr owns the mouse"; `return modeTracker.tracksMouse`
would match it. Confidence: high on the gate bypass, medium on the double-present (depends on UIKit
long-press arbitration, which I could not exercise).

### 3. should-fix (unverified) — `.detailOnly` assumes a sidebar toggle the terminal screen may not show
`Sources/Heeler/Console/ConsoleView.swift:196` hides the sidebar whenever an agent is open on regular
width, on the premise that "the Agent list is one toolbar tap away (the standard sidebar toggle)".
But the agent terminal deliberately renders an empty, clear-backed navigation bar it draws *under*:
`Sources/Heeler/Console/AgentTerminalView.swift:837` `.ignoresSafeArea(.container, edges: .top)`,
`:845` `.navigationBarBackButtonHidden(true)`, `:846` `.navigationTitle("")`, `:851-853` clear
`toolbarBackground` — the comment at :820-822 says the bar exists "only as the owner of the status bar
appearance. Its content stays hidden." Nobody has seen this on an iPad (notes.md records that the iPad
simulator would not launch the app, and no screenshot exists). If SwiftUI suppresses or visually loses
the display-mode button here, the agent list is unreachable while a terminal is open; the escape hatch
is `AgentEdgeBackGesture` (:838), which dismisses and restores `.automatic`, so it is not a hard trap.
Confidence: medium — the mechanism is real, the outcome is untested.

### 4. nit — the trigger is "an agent is selected", not "a terminal is open"
`Sources/Heeler/Console/ConsoleView.swift:197` keys on `notificationRouter.path.isEmpty`. A non-empty
path also covers `removedWorktreeSurface` and `missingAgentSurface` (ConsoleView.swift:230, 264),
which are `ContentUnavailableView`s, not terminals — the sidebar hides behind those too. Spec 4 says
"while a terminal is open". Harmless in practice; both surfaces carry their own way back.

### 5. nit — sidebar can stay revealed over the terminal when switching agents
`Sources/Heeler/Console/ConsoleView.swift:171`: `onChange(of: preferredColumnVisibility)` fires only
when the *preferred* value changes. Reveal the sidebar by hand inside agent A (`columnVisibility = .all`),
tap agent B: the path changes but the preferred value stays `.detailOnly`, so the sidebar stays up and
the new terminal is not full-bleed. Deliberate per the comment at :47-49 ("left alone afterwards so the
sidebar toggle keeps working"), and self-corrects on the next navigation to the list. Not a stuck-hidden
bug — the reverse case (back to the list) does restore `.automatic`.

### 6. nit — the two-finger sheet is not quite "the same sheet as before"
`Sources/Heeler/Terminal/TerminalScreenView.swift:1775` passes `anchorRange: nil`. Ghostty's own path
(`UITerminalView+Interaction.swift:545-600`) computes an anchor from `surface.quicklookWord()` so the
sheet opens with the touched word selected and scrolled to. Same view controller, same presentation —
only the anchor is lost. The spec explicitly asked for `anchorRange nil`, so this is per spec, noted
only so nobody is surprised by the difference in feel.

### 7. nit / scope — a fourth commit touches a forbidden file and is not in the notes
`aab7149 build: point the unit-test host at Kelpie.app` sits on top of b81f3c8 and edits `project.yml`
(+`Heeler.xcodeproj/project.pbxproj`). The spec's "Do NOT touch" list names `project.yml` outright,
and notes.md line 74-81 states the fix "belongs in project.yml ... out of scope here" and lists only
three commits. The change itself is correct and one line (`TEST_HOST: $(BUILT_PRODUCTS_DIR)/Kelpie.app/Kelpie`),
but it is undisclosed in the notes and its trailer says `Claude Fable 5.1` while the other three say
`Claude Opus 5 (1M context)`. Worth a sentence in the notes either way.

## Checked and clean

- **Right click, `tracksMouse == false`**: both overrides (`TerminalScreenView.swift:1349`, `:1357`)
  fall through to `super`, so Ghostty's copy-menu behaviour and the `UIContextMenuInteraction` path are
  byte-for-byte what they were in a plain shell.
- **Right click, `tracksMouse == true`, clean path**: at `UITerminalView+Interaction.swift:192` the
  `suppressSurfacePositionForSelectionMenu` guard is false, so `sendMousePos` lands first and
  `.ended` (:250-259) sends PRESS then RELEASE for the right button — SGR press+release at the right
  cell, out through the surface write callback Heeler already bridges. (Both press and release arrive
  on touch-up rather than on touch-down; herdr's menu opens on the press, so this is only a latency
  difference.)
- **Long-press gating**: `gestureRecognizerShouldBegin` (:1335-1345) tests `rightClickGesture` and
  `textSelectionGesture` by identity *before* the generic `is UILongPressGestureRecognizer` branch, so
  ours are never caught by the "refuse Ghostty's" rule. Ghostty's own long press is refused exactly
  while `tracksMouse` and otherwise defers to `super` — spec 2b/2c satisfied.
- **Cell mapping**: `rightClickTouch(at:)` (:1563) is a line-for-line mirror of `clickTouch(at:)`
  (:1550) — same `gridPointMapper.cell(at:)`, same `isLocalInputEnabled` guard, same
  `terminalSession.sendInput`. It does not use `tapAction`, which is correct: `tapAction` decides
  keyboard-raising, which a right click must not do.
- **No stray left click on release**: `didReportRightClickForTouch` is set at :1765 and consumed by
  `handleHerdrTap` at :1352; it is reset in `touchesBegan` (:1296) only while the recognizer is
  `.possible`, which is the right window (a second finger arriving mid-press does not clear it).
  Ghostty's own tap-to-toggle-keyboard cannot fire either: its `tapCandidateMaxDuration` is 0.35 s
  (`UITerminalView+Interaction.swift:36`), below the 0.5 s press.
- **Scroll coexistence**: `pointerScrollGesture` (:1680-1694) is `indirectPointer` + scroll-types;
  Ghostty's drag-select pan (`setupIndirectPointerSelectionGesture`, package :452-462) has no delegate,
  so simultaneity depends on ours — and the new
  `gestureRecognizer(_:shouldRecognizeSimultaneouslyWith:)` (:1367) returns true for it. I verified by
  compiling a reduced case (`swiftc -emit-objc-header`, subclass of a class whose *superclass* declares
  the `UIGestureRecognizerDelegate` conformance) that the selector is still inferred `@objc` and
  exported, so UIKit will call it — the plausible silent failure here does not occur.
  The `numberOfTouches == 0` guard (:1782) hands any pointer *drag* back to Ghostty.
- **Sign convention**: `handleHerdrPointerScrollGesture` (:1786-1787) and the finger pan
  `handleHerdrTouchScrollGesture` (:1846-1847) call `scrollTouch(translationY:)` with the identical
  sign and both zero the translation, so local scrollback vs. remote wheel reports stay one decision.
- **No double scroll on direct touch**: `installTouchScrolling` disables every pre-existing direct pan
  (:1651-1654, which kills Ghostty's `setupTouchScrollInput` pan), and `pointerScrollGesture` only
  accepts `indirectPointer`.
- **Swift 6 strict concurrency**: nothing new escapes. All new members live on `HeelerTerminalView`
  (a `UIView`, so `@MainActor`) or on the `@MainActor` `TerminalTextSelectionPresenter`; the new
  `ConsoleView` state is a plain `@State` enum read in a computed property. No closures capture
  non-`Sendable` state, no `@preconcurrency` was added, no `nonisolated`/`@unchecked` anywhere in
  the diff.
- **Tests**: `Tests/HeelerTests/TerminalMouseReportingTests.swift:51-77` asserts real encoder output —
  SGR `ESC[<2;20;10M`, legacy `1B 5B 4D 34 33 33` (button 2 +32, release 3 +32 checked in the second
  test), the full press+release pair in both encodings, and `nil` both before DECSET 1000 and after
  `1000l`. That is exactly spec item 6. The encoder itself (`TerminalMouseReporting.swift:26-42`) is
  correct: legacy release collapses to button 3, SGR keeps button identity and flips the terminator.
- **CHANGELOG / ADR**: one "Kelpie" section above `[Unreleased]`, house style; ADR 0016 is accurate
  about the override points (I re-derived each claim from the package source).

## Could not check

- Anything requiring a running iPad: gesture arbitration, whether the split-view toggle is visible over
  the terminal, whether herdr actually opens its menu. notes.md records that the iPad simulator would
  not launch the app on this machine (tests were run on iPhone 17 instead); I did not re-run the build
  or the suite.
- libghostty's internal mouse-report encoding — I confirmed the Swift-side call sites
  (`surface?.sendMouseButton` / `sendMousePos`) but the binary is opaque, so 1c rests on the builder's
  reading plus the fact that the same callback already carries every other byte.
- `TerminalGridPointMapper`'s accuracy: unchanged by this work, and its existing tests cover it.
