# Round 2 reviewer nits — implementation summary

Branch `kelpie`, tree modified, NOT committed, NOT installed. Files touched:

- /Users/anthonytopalides/Developer/Kelpie/Sources/Heeler/Terminal/TerminalScreenView.swift
- /Users/anthonytopalides/Developer/Kelpie/Sources/Heeler/Terminal/TerminalMouseReporting.swift
- /Users/anthonytopalides/Developer/Kelpie/Sources/Heeler/Terminal/TerminalLinkDetector.swift
- /Users/anthonytopalides/Developer/Kelpie/Sources/Heeler/ContentView.swift
- /Users/anthonytopalides/Developer/Kelpie/Sources/Heeler/Client/HerdrClientRootView.swift

No new Swift files. `make generate` was run (the Ghostty artifact was already
fetched); it rewrote Heeler.xcodeproj identically — git status shows it clean.

## 1. Viewport read twice per tap — done
Link resolution is now once per touch sequence.
- New boxed cache `pressLinkMatch: ResolvedLinkMatch?` (a `Match?` in a struct,
  because "resolved to nothing" and "not resolved yet" differ) plus
  `linkMatchForPress(at:)`: answers from the box when filled, else calls
  `linkMatch(at:)` and fills it.
- Cleared at the top of `touchesBegan`, so each new press resolves afresh.
  No damage counter, no timer.
- Direct tap: `gestureRecognizerShouldBegin` (tapGesture branch) and
  `handleTap(at:)` both go through `linkMatchForPress` — one viewport copy.
- Trackpad click: `linkTouchToClaim` resolves through `linkMatchForPress`;
  `finishClaimedLinkTouch` opens `claimed.match` instead of re-resolving at the
  release point and comparing. The <= 8 pt movement guard is unchanged.
  Note `tapGesture.allowedTouchTypes = [directTouch]`, so the pointer path never
  went through shouldBegin — its two reads were the claim and the release.
- Behaviour note: if the viewport scrolls under a held pointer within those
  8 pt, the link under the *press* is what opens. That is the press the user
  made, and what the spec asked for.

## 2. Wide characters and tabs — doc only, done
`TerminalLinkDetector`'s type doc no longer claims wrapping is "the one piece of
terminal-specific knowledge"; it says wrapping is the knowledge it does carry,
and adds a paragraph: rows are indexed by grapheme while the grid mapper counts
cells, so a wide glyph (CJK, two-cell emoji) or a tab earlier in the row shifts
every link right of it by a column per glyph. No cell-width mapping built.

## 3. Grid mapper clamps — done, links only
`TerminalGridPointMapper.strictCell(at:)` added next to `cell(at:)`: maps via
`cell(at:)` then returns nil when the point is above/left of `gridOrigin` or past
`columns * cellWidth` / `rows * cellHeight` — the padding and the leftover strip.
`linkMatch(at:)` is its only caller. `cell(at:)` and every other caller (mouse
reporting, hold drag, touch selection, selection overlay) still clamp, unchanged.

## 4. `.environment(hardwareKeyboard)` — removed
Removed from `ContentView.body` (was line 117). Confirmed before the edit with
`grep -rn "Environment(HardwareKeyboardObserver" Sources/ Tests/` (no hits) and
after with `grep -rn "environment(hardwareKeyboard"` (no hits). Consumers
(`HerdrClientRootView`, `HerdrClientHostView`, `HerdrClientView`) take it as an
explicit `let`; ContentView keeps the @State and the inputMode wiring.

## 5. Font default keys off idiom — SUPERSEDED by round 5, no change
The idiom default is only the store's birth value; the first layout replaces it
with the width-derived one before a Slide Over launch can be seen at 12 pt.
Proof:
- Sources/Heeler/Client/HerdrClientRootView.swift:102 —
  `.onChange(of: proxy.size.width, initial: true)` on the root's background
  GeometryReader, so it fires on the first layout.
- Sources/Heeler/Client/HerdrClientRootView.swift:118 —
  `terminal.zoom.windowWidthDidChange(width)`.
- Sources/Heeler/Settings/TerminalZoomSettings.swift:94-101 — recomputes
  `baseFontSize` from `defaultFontSize(forWindowWidth:idiom:)`, user offset on top.
- Sources/Heeler/Settings/TerminalZoomSettings.swift:77-88 — the ladder:
  >= 700 pt -> 12, >= 500 pt -> 11, below -> 10.
So a first launch in Slide Over settles at 10 pt. The idiom-keyed
`defaultFontSize(for:)` is left alone: it is the pre-layout seed and the
migration base for installs that stored an absolute size.

## 6. Strongly retained UITouch — done
The claim moved from a tuple to a private `ClaimedLinkTouch` struct with
`weak var touch: UITouch?`, matching `claimedRightButtonTouch`. `touchesBegan`,
`touchesMoved`, `linkTouchToClaim` and `finishClaimedLinkTouch` unwrap it and
keep the `touches.contains(touch)` guard, so a claim whose touch has gone reads
as a claim that does not match and the sequence falls through to Ghostty.

## 7. onDisappear path reset — moved to the cover
Moved off `consoleScreen(onClose:)` onto the `.fullScreenCover` content
(HerdrClientRootView.swift:155-162). Cover behaviour identical.
Context: the second call site the nit describes (`consoleScreen(onClose: nil)`
as the no-Host root, added in 7dba133) was already replaced by WelcomeView in
a2d66a2, so there is no live side-effect today — the fix is against its return.

## 8. Menu button press state — done
`PressReportingButtonStyle` (private, file-local in HerdrClientRootView.swift)
renders `configuration.label` unchanged and only reports `configuration.isPressed`
through a closure; the menu button applies it and its opacity is now
`isHovering || isPressed ? 1 : 0.92`. Deliberately a reporter rather than a style
that draws the opacity: if SwiftUI declines to route a ButtonStyle to a Menu
label on some OS version, the rest state is exactly as today and only the press
lift is missing. `hoverEffect(.highlight)` untouched.

## Build
Release, physical iPad id 09D7738D-2173-55EF-8966-A9C3EA1D0514. Log:
/private/tmp/claude-501/-Users-anthonytopalides-Developer-Kelpie/6918c0d2-ef95-4c15-9608-4b7a2925730c/scratchpad/build/nits-build.log
RESULT: ** BUILD SUCCEEDED ** (Release, device destination, exit 0).
No warnings or errors in any of the five touched files; the only app-target
warnings in the log are pre-existing (SettingsView.swift:25 and :95,
TerminalAgentSwitcher.swift:590, TerminalFontSettings.swift:67).

Not done: no commit, no device install, no CHANGELOG entry, no unit-test run
(the test target cannot compile for a device destination and the simulator is
off-limits on this Mac).
