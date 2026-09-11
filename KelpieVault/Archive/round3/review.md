# Reviewer findings — Kelpie round 3

Reviewed: `git diff` (TerminalScreenView.swift, HerdrClientRootView.swift, CHANGELOG.md,
project.pbxproj) plus the two new files, against spec.md, the vendored
`UITerminalView+Keyboard.swift` / `+UITextInput.swift`, and ADR 0016.
Not run: no build, no device, no tests (per brief).

## Must-fix

None. Nothing in the diff is outright wrong on the paths I could trace.

## Should-fix

### S1 — alt-echo suppression expires a turn too early
`Sources/Heeler/Terminal/TerminalScreenView.swift:2029-2038` (reset),
consumed at `:1193` and `:1179`.
`claimedAltCombos` is cleared by `DispatchQueue.main.async`, i.e. at the end of the
runloop turn in which `pressesBegan` intercepted the combo. The vendored package's
equivalent flag for exactly this problem, `hardwareKeyboard.keyHandled`, is set in
`pressesBegan` and cleared only in `pressesEnded`/`pressesCancelled`
(`UITerminalView+Keyboard.swift`, and consumed in `+UITextInput.swift:150-158`) — a
deliberately longer window, because the package documents that the text-input system's
responses "arrive asynchronously (they round-trip the keyboard daemon)".
If UIKit delivers `deleteBackward()` for Option+Backspace in a later turn than
`pressesBegan`, the suppression has already lapsed and the word delete is followed by a
stray character delete — the exact double-fire this code exists to stop.
The press-scoped cleanup in `forwardablePresses` (`:1983-1987`) already exists, so the
async `claimedAltCombos.removeAll()` at `:2036` can simply be dropped from the turn reset
and left to `pressesEnded`/`pressesCancelled` (keep the turn reset for
`claimedHardwareKeys`, which is genuinely a per-turn dedupe).
Note the spec (A2 step 5) asked for both resets, so this is a spec-derived risk rather
than a builder deviation.
Confidence: medium. Depends on iPadOS delivery ordering I cannot observe here.

### S2 — `insertText` suppression is both too broad and (for the mapped table) inert
`Sources/Heeler/Terminal/TerminalScreenView.swift:1179`
```swift
if !claimedAltCombos.isEmpty, text.count == 1 { return }
```
Three separate problems:
1. It is keyed on "any alt combo is in flight", not on the press that produced this text.
2. Every combo that can enter `claimedAltCombos` is Backspace, Left, Right or
   ForwardDelete (`interceptHardwareKey` at `:1962-1975` only inserts when
   `bytes(for:) != nil`, and the table has no printable keys). None of those produce
   `insertText`. So the guard never fires for the case it was written for.
3. What it *can* catch is a genuine single character typed in the same runloop turn as an
   Option+arrow — plausible during fast editing or auto-repeat — which is silently
   swallowed.
Secondary: the early `return` happens before `super.insertText`, so the package's
`claimPendingInputMethodKeys()` never runs for that call; a key loaned to the input
method in the same turn goes unclaimed and is replayed raw by
`replayUnclaimedInputMethodKeys()`. Narrow (needs an IME active), but it is a
double-type.
Software-keyboard typing is unaffected as the spec required — `claimedAltCombos` is empty
when no press is in flight — so the requirement is met; the guard is just doing more harm
than good. Simplest fix: delete it, or scope it to a specific press identity.
Confidence: high on points 1-2, medium on the real-world impact of point 3.

### S3 — the host capsule probably overflows instead of truncating
`Sources/Heeler/Client/HerdrClientRootView.swift:203-204`
```swift
.frame(maxWidth: 180)
.fixedSize(horizontal: true, vertical: false)
```
`fixedSize` proposes `nil` width to the flexible frame; with no `idealWidth` the frame
proposes `nil` onward, so the `Label` reports its full untruncated ideal width, and the
frame then clamps *its own* size to 180 while the child stays at its ideal width. The
child is placed centred in the 180pt frame, so a long `displayName` spills past the
`.background(.regularMaterial, in: Capsule())` and the stroke rather than tail-truncating
inside them. `.lineLimit(1)`/`.truncationMode(.tail)` never get a narrow proposal to act
on. The comment at `:201-202` asserts the opposite behaviour.
The overlay is `alignment: .topTrailing` (`:75`), so without `fixedSize` the frame would
instead be a constant 180pt wide — which is why `fixedSize` was added; a form that gets
both hug-and-truncate is needed (e.g. give the frame an `idealWidth`, or measure the text
and clamp the string itself).
Only bites for names wider than ~180pt at `.caption` (roughly 30+ characters), so it may
never be seen in practice.
Confidence: medium. SwiftUI flexible-frame semantics under a nil proposal; I could not
run it.

## Optional / nits

- `HerdrClientRootView.swift:219` — `.accessibilityLabel("Kelpie Menu")` now masks the
  host name the capsule displays; VoiceOver loses the one piece of information the new
  label added. Consider `"Kelpie Menu, \(menuHostName)"`. (Spec said keep the label, so
  this is a judgement call.)
- `HerdrClientRootView.swift:223-225` — the `"Kelpie"` fallback in `menuHostName` is
  unreachable: `menuButton` is only rendered from `client(for:)` (`:75`), which the body
  (`:47-52`) only reaches when `primaryHost.host(in:)` is non-nil.
- `TerminalScreenView.swift:1882`, `:1966` — `interceptedPresses` holds `UIPress` strongly
  and is drained only by `pressesEnded`/`pressesCancelled`; a press that receives neither
  (view torn down mid-press) is retained for the view's life. The package does the same
  with `pressesLoanedToInputMethod`, so this is house-consistent.
- `TerminalScreenView.swift:1892-1901` — registering `UIKeyCommand.inputEscape` with
  `wantsPriorityOverSystemBehavior` means Escape no longer dismisses anything while the
  terminal is first responder. Intended on this screen; worth knowing.
- `TerminalScreenView.swift:2004-2016` — the Escape dedupe window is one runloop turn,
  matching the package's `claimControlKeyDelivery`. If the key command and `pressesBegan`
  ever land in different turns a double ESC is possible; inherited from the package's
  design, not introduced here.
- A held Escape will not auto-repeat: `UIKeyCommand` does not repeat and the press is
  swallowed before the package's repeat path. Not a regression — it did not work at all
  before.
- `TerminalScreenView.swift:1961` — `interceptHardwareKey` runs before the package's
  `shouldDeferKeyToInputMethod`, so Option+arrow during an active IME composition is taken
  from the input method. Very narrow.
- `TerminalScreenView.swift:1945-1949`, `:1953-1957` — when every press in a set is
  intercepted or a zoom shortcut, `super.pressesEnded`/`pressesCancelled` is skipped, so
  the package's `hardwareKeyboard.keyHandled = false` reset does not run for that event.
  I could not construct a case where the flag stays stale past the *next* ordinary key's
  release, and the same early return pre-existed for zoom shortcuts.
- `TerminalHardwareKeyMapping.swift` — the doc comment is unusually good; the
  Kitty-protocol caveat the spec asked for is there and accurate.

## What I checked and cleared

- **(1) began/ended symmetry.** `interceptedPresses` (`:1966`, `:1983`) drops intercepted
  presses from both `pressesEnded` and the newly added `pressesCancelled`; the restructured
  `pressesBegan` (`:1928-1943`) is behaviourally identical to the old zoom-only version for
  non-intercepted presses. No press reaches `super` in one phase but not the other.
  `pressesCancelled` previously fell through to the package wholesale, so zoom presses now
  get dropped there too — that is a fix, not a regression.
- **(2) the per-turn claim set.** Both orderings are safe. Key-command-first:
  `handleEscapeKeyCommand` (`:1911-1918`) claims, then `interceptHardwareKey` finds the
  claim taken and stays silent while still swallowing the press.
  `pressesBegan`-first: the claim is taken, the later key command is denied. Cmd+`.` folds
  onto Escape's claim via `claimKey(for:)` (`:2020-2026`), so the two spellings of the same
  physical press cannot both send. No double ESC on either path.
- **(3) software keyboard / plain backspace.** Software-keyboard and dictation text arrives
  with no press in flight, so `claimedAltCombos` is empty and both overrides fall straight
  through to `super`. A plain hardware Backspace has no `.option`, so
  `isSuppressingAltEcho` is false and the package's own `shouldSuppressUIKeyInput` →
  `keyHandled` path handles it unchanged. Neither is swallowed. (See S2 for the residual
  breadth problem.)
- **(4) Swift 6 / isolation.** `HeelerTerminalView` inherits `UIView`'s `@MainActor`; the
  new `static let escapeKeyCommands`, the `@objc` handler and the
  `DispatchQueue.main.async { [weak self] }` reset all match four pre-existing uses of the
  same pattern in this file (`:243`, `:1529`, `:1589`, `:2032`) and the package's own.
  `TerminalHardwareKeyMapping` is a UIKit-free `Sendable` value type as specified. Builds
  clean at `SWIFT_VERSION: "6.0"`.
- **(5) send route.** `sendHardwareKey` (`:1998-2003`) uses
  `guard isLocalInputEnabled … terminalSession.sendInput(bytes)` — byte-for-byte the shape
  of `clickTouch(at:)` / `rightClickTouch(at:)` (`:1706`, `:1721`). Correct raw route,
  correct gate. (When local input is disabled the press is swallowed rather than passed to
  `super`; that is the safer direction.)
- **(6) the capsule and the menu.** `hosts.hosts` and
  `primaryHost.host(in: hosts.hosts)?.displayName` are read the same way the rest of the
  file reads them (`:47`, `:174`). The `Switch Host` `Picker` and its
  get/set `Binding` moved verbatim — no binding change, and it is still gated on
  `hosts.hosts.count > 1`. Divider and item order match the spec exactly
  (Switch Host / Hosts / Divider / Agents / Settings / Reconnect). Padding, hover,
  `.hoverEffect(.highlight)`, `.padding(12)` and the `topTrailing` alignment are unchanged,
  so compact-width layout is the same 12pt-inset top-right anchor as before; only the
  intrinsic width grew. Comments were rewritten as asked. See S3 for the one layout doubt.
- **(7) CHANGELOG.** `### Changed` then `### Fixed` under `[Unreleased]` is Keep a
  Changelog order; all three entries carry `(Kelpie)` where upstream puts the PR link, as
  the spec directed; wording matches what the code actually does.
- **(8) project.pbxproj.** Exactly 8 added lines, and they are the right 8:
  `TerminalHardwareKeyMapping.swift` gets a `PBXFileReference`, a `PBXBuildFile`, a place
  in the `Terminal` group and an entry in the app target's Sources phase;
  `TerminalHardwareKeyMappingTests.swift` gets the same four in the test group and the test
  target's Sources phase. Both files land in the right target.
- **Vendored package untouched.** `git status` shows no change under `Packages/`; the
  overrides all live in `HeelerTerminalView`, per ADR 0016's house rule.
- **Tests.** `TerminalHardwareKeyMappingTests.swift` covers all six table rows plus the
  shift-allowed variant, and every negative the spec named (Escape+Cmd, bare Backspace,
  Backspace+Option+Control, Period without Command) plus Option+Command, Control+Option
  arrows, and unmapped keys. Swift Testing, matching neighbouring suites. Complete against
  A3.

## What I could not check

- Runtime behaviour of any kind: no build run, no device, no simulator. The builder's log
  reports `** BUILD SUCCEEDED **`; I took that as given.
- The actual iPadOS delivery order and latency of `pressesBegan` vs `deleteBackward` /
  `insertText` — S1 turns entirely on this.
- SwiftUI's resolved layout for the capsule at any width — S3 turns entirely on this.
- Whether `UIKeyCommand.inputEscape` with priority actually wins over the text-input system
  on this iPadOS version (the premise of Piece A); only the device can say.
- The tests were never executed.
- `KelpieVault/` changes in the working tree (`Feedback log.md`, `Kelpie.md`,
  `Onboarding proposal.md`) are outside the reviewed scope and are the orchestrator's, not
  the builder's — the builder's spec forbade them and the builder's report confirms it did
  not touch them.
