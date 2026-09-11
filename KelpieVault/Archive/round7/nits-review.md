# Fresh-context review — round-2 nits (uncommitted `kelpie` diff)

Reviewed: `git diff` over 5 files, plus the surrounding call sites
(`TerminalSelectionOverlayView`, `TerminalZoomSettings`, `ContentView`).
Not run: no build, no device, no tests (read-only review).

## Per-item verdicts

### Item 1 — resolve once per press: MET, with two caveats
- Cache: `TerminalScreenView.swift:770` (`pressLinkMatch`), filled by
  `linkMatchForPress` at :2020-2024, cleared at :1591.
- Direct touch: `gestureRecognizerShouldBegin` :1753 and `handleTap` :2740 both
  go through `linkMatchForPress`. `touchesBegan` (:1575) runs before a
  UITapGestureRecognizer action (no `delaysTouchesBegan`), so the box is
  cleared, then filled once, then reused. One viewport copy. ✔
- Trackpad: `tapGesture.allowedTouchTypes = [directTouch]` (:2152) confirms the
  pointer path never reaches `shouldBegin`; its two reads were the claim
  (:1697) and the release. The release now opens `claimed.match` (:1721) with
  no second resolve. One copy. ✔
- No read-before-write: `linkMatchForPress` always falls back to a fresh
  `linkMatch` when the box is nil (:2021-2023). No "silently no link" path. ✔

**nit (confidence: high) — `TerminalScreenView.swift:2021` cache is keyed on
"a press is in progress", not on the point.** Safe in-app only because every
tap is preceded by `touchesBegan` on this view. I checked the one path that
could bypass it: a touch that hit-tests to a selection handle is swallowed by
`TerminalSelectionOverlayView.touchesBegan` (:142, :346 — empty, no `super`),
so `pressLinkMatch` would *not* be cleared; but `gestureRecognizer(_:shouldReceive:)`
at `TerminalScreenView.swift:1804` rejects handle touches for the tap
recognizer, so `handleTap` cannot fire from one. The hole is closed today by
that second guard alone. Worth a one-line comment, not a fix.

**nit (confidence: high) — `TerminalScreenView.swift:2737` `handleTap(at:)` is
internal and called directly by `Tests/HeelerTests/TerminalAttachTests.swift:1232`
with no `touchesBegan`.** Two direct `handleTap` calls at different points on
one instance now return the first point's match. Only reachable from tests, but
it makes the suite able to pass for the wrong reason.

**nit (confidence: high) — `TerminalScreenView.swift:1714-1722` dropped the
`linkMatch(at: ended) == claimed.match` re-check.** If the viewport scrolls
under a held trackpad press (agent output) within the 8 pt window, the release
now opens the link that was under the *press*, not the one under the cursor.
The spec asked for exactly this and the code documents it; recording it as a
deliberate behaviour change, not a defect.

**nit (confidence: high) — `TerminalScreenView.swift:1989 linkURL(at:)` has no
callers** anywhere in `Sources/` or `Tests/`, and is the one remaining
uncached entry into `linkMatch`. Pre-existing dead code (untouched by this
diff), but it is the symbol the spec named in item 1; leaving it is a trap for
the next reader. Delete or route it through `linkMatchForPress`.

### Item 2 — doc: MET
`TerminalLinkDetector.swift:15-23`. The "one piece of terminal-specific
knowledge" claim is gone and the grapheme-vs-cell limitation (wide glyphs,
tabs, one column of drift per glyph) is stated. Doc only, no code change. ✔

### Item 3 — strict cell for links only: MET
`TerminalMouseReporting.swift:116-125`. Guards `point.x >= origin.x` **and**
`point.y >= origin.y` (top/left padding → nil) as well as
`< origin + columns*cellWidth` / `+ rows*cellHeight` (right/bottom leftover →
nil). Both padding edges covered. ✔
Non-link callers all still on the clamping `cell(at:)`:
`TerminalScreenView.swift:2040, :2055, :2528, :2557, :2576, :2650` and
`TerminalSelectionOverlayView.swift:265`. `strictCell` has exactly one caller,
`linkMatch(at:)` (`TerminalScreenView.swift:2000`). ✔
No test covers `strictCell`; `TerminalMouseReportingTests.swift:178-183` still
only exercises the clamping mapper. **nit (confidence: high)** — the new
boundary behaviour is untested.

### Item 4 — dead environment injection removed: MET
`ContentView.swift:117` gone. Repo-wide grep for `HardwareKeyboardObserver`
returns only the `@State` at `ContentView.swift:26` and explicit `let`
parameters (`HerdrClientRootView.swift:27, :438, :452`,
`HerdrClientView.swift:17`). No `@Environment(HardwareKeyboardObserver.self)`
reader exists. ✔

### Item 5 — font default: builder's proof is CORRECT
- `HerdrClientRootView.swift:98-105` — the background `GeometryReader` sits on
  the root `ZStack`'s modifier chain (outside the Host/Welcome branch), with
  `.onChange(of: proxy.size.width, initial: true)`, so it fires on first layout
  in either branch.
- `:118` → `TerminalZoomSettings.windowWidthDidChange(width)`.
- `TerminalZoomSettings.swift:94-101` recomputes `baseFontSize` from
  `defaultFontSize(forWindowWidth:idiom:)` and re-resolves `fontSize` with the
  user offset preserved.
- `:80-89` + `:24-33, :41-42` — ladder is ≥700 → 12, ≥500 → 11, else 10, iPad
  only. A Slide Over launch settles at 10.
Leaving the idiom-keyed `defaultFontSize(for:)` as the pre-layout seed and
migration base is right: `:58` and `:64` both need it.

**nit (confidence: medium)** — "before a Slide Over launch can be *seen* at
12 pt" is asserted, not proved. The ghostty surface is created in the terminal
view's `makeUIView`, which can run in the same layout pass as the
GeometryReader's first `onChange`; ordering between the two is not guaranteed,
so a single frame at 12 pt is possible. Cosmetic at worst.

### Item 6 — weak claim touch: MET
`TerminalScreenView.swift:755-764` (`ClaimedLinkTouch.touch` is `weak`, matching
`claimedRightButtonTouch` at :742). All three consumers unwrap:
- `:1602-1605` (`touchesBegan`) — takes the touch straight out of the incoming
  `touches` set via `linkTouchToClaim`, so no `contains` guard is needed. ✔
- `:1613-1614` (`touchesMoved`) — `let touch = claimed.touch, touches.contains(touch)`. ✔
- `:1711-1713` (`finishClaimedLinkTouch`) — same guard. ✔
Loss mid-gesture: UIKit owns the `UITouch` for the life of the sequence and
this is the identical pattern already shipping for the right-button claim, so
the risk is the pre-existing one. If it *did* nil out, the failure mode is
benign-ish: `claimedLinkTouch` is never cleared (the guard at :1711 returns
early), the link simply does not open, and Ghostty receives `touchesMoved`/
`touchesEnded` for a touch whose `touchesBegan` it never saw. Same shape as the
right-button path. **nit (confidence: medium)** — no `claimedLinkTouch = nil`
in `didMoveToWindow` (:1560-1572), which does reset every other piece of touch
state (`releaseHeldPointerDrag`, `responderGate.invalidateTouches`).
Pre-existing.

### Item 7 — router reset scoped to the cover: MET
`HerdrClientRootView.swift:155-162`. `consoleScreen(onClose:)` has exactly one
caller in the repo (grep: `:157` only; the definition is `:254`), and the
`.onDisappear` was previously the outermost modifier inside `consoleScreen`
(`:268-270`, removed) — applying it at the call site puts it at the identical
position in the view tree, so it fires at the same moment on cover dismissal. ✔
Absent from the no-Host root: that branch is `WelcomeView` (`:74-79`), which
never touches `notificationRouter`. ✔ No other presentation of the Console
exists; `presentConsole()` just sets `isShowingConsole`. ✔

### Item 8 — press state on the floating control: LIKELY A NO-OP
The control is a **`Menu`** with a custom label (`HerdrClientRootView.swift:~270-337`,
`} label: { menuLabel … }`), and `.buttonStyle(PressReportingButtonStyle { … })`
is applied to the `Menu` itself at `:347`.

**should-fix / must-fix (confidence: medium-high) — `HerdrClientRootView.swift:347`.**
A `Menu` with the default (`.automatic`) menu style renders its label through
`MenuStyle`, whose `Configuration` has no `isPressed`, and does not route the
label through an ambient `ButtonStyle` on iOS. On that reading
`configuration.isPressed` is never observed, `isPressed` stays `false`, and the
opacity change at `:343` never fires — i.e. item 8 is not delivered, only
made to look delivered. The builder's own comment concedes the possibility and
no device check was run, so this is currently unverified either way.
Why it matters: the spec item is a behaviour, and the code as written cannot be
told apart from the old behaviour without running it.
SwiftUI-correct routes, in order of preference:
1. Add `.menuStyle(.button)` next to the existing `.buttonStyle(…)` (iOS 16+
   `ButtonMenuStyle` is the documented way to make a `Menu` adopt a
   `ButtonStyle`). Because `PressReportingButtonStyle.makeBody` draws only
   `configuration.label`, the rest appearance stays exactly as authored.
2. Failing that, drive the state from the label with
   `.onLongPressGesture(minimumDuration: 0, pressing: { isPressed = $0 },
   perform: {})` — but verify it does not swallow the tap that opens the menu.
Either way this needs a device check, which is cheap: press and hold the
capsule and watch for the opacity lift.

**nit (confidence: medium) — `HerdrClientRootView.swift:347` scope.**
`.buttonStyle` propagates through the environment to descendants, and a `Menu`'s
content is a stack of `Button`s (`:293-322`). On any OS version where the style
*is* honoured, each menu item would also report through
`isPressedDidChange`, flashing the capsule's opacity while an item is pressed,
and would render as a bare `configuration.label`. If item 8 is fixed via route
1, reset the content with `.buttonStyle(.automatic)` inside the menu closure or
scope the reporter more tightly.

**nit (confidence: high)** — a `Menu` presents on touch-down, so even when the
press state does arrive, the "lift" lasts only until the menu appears. Worth
confirming it reads as intended rather than as a flicker.

## Cross-cutting checks

- **Swift 6 strict concurrency**: no new `nonisolated`, `@unchecked Sendable`,
  or actor-hop. `PressReportingButtonStyle` (`HerdrClientRootView.swift:390-399`)
  stores a non-`Sendable` `(Bool) -> Void`; `ButtonStyle` imposes no `Sendable`
  requirement, and the closure mutates a `@State` through its non-mutating
  setter, which is the ordinary pattern. `onChange` fires outside the update
  pass, so no "modifying state during view update". Clean.
- **Force unwraps / `try!`**: none introduced. The new code is all `guard let`
  / `if let`.
- **`Packages/` untouched**: `git diff --stat -- Packages` is empty. ✔
- **No new Swift files**, so no `xcodegen generate` obligation; `git status`
  shows `Heeler.xcodeproj` clean. ✔
- **CHANGELOG**: none of the eight items is user-visible except item 8 (a press
  highlight) and item 3 (a tap in the padding no longer opens a link). Both are
  arguably below the line; flagging only so the call is made deliberately.

## What I could not check
- Any runtime behaviour: no build, no simulator (off-limits on this Mac), no
  device. Every timing claim above (UIKit touch-delivery order, whether
  `ButtonStyle` reaches a `Menu` label, the first-frame font size) is reasoned
  from the source and the platform contract, not observed.
- Whether the touched tests still pass — the builder reports none were run.
