# Composer text field — QA review of dabbc0f (read-only, no build)

## MUST-FIX

### 1. A control key from the pill desyncs the mirror from the remote line
`Sources/Heeler/Terminal/TerminalKeyBar.swift:558-562` (`keyBar(_:didPress:)`) sends
esc / ctrl-c chords / arrows straight to the PTY and never touches
`composerControl`. `TerminalComposerMirror.committed` keeps the field's text.

- Type `hello` in the field (remote line = `hello`, committed = `hello`).
- Press Ctrl-C or Esc: the remote line editor clears its line. The field still
  shows `hello`, committed is still `hello`.
- Type `x`: `update(to:)` diffs `hellox` vs `hello` and sends only `x`. The field
  shows `hellox`, the agent sees `x`.
- Or delete a character in the field: it sends a DEL into an already-empty
  prompt, which in Claude Code's TUI is a keypress the app interprets itself.

Arrows are the same class of break: they move the *remote* cursor off end-of-line,
which is the one precondition the DEL repair depends on (spec decision 3 accepts a
mis-repair only for a cursor the user moved inside the TUI, not for one the pill
moved out from under the mirror).

Fix: route `keyBar(_:didPress:)` through the control while the composer is
active — clear the field and `mirror.reset()` for `esc`/`ctrl-c`/`enter`, and at
minimum call `mirror.reset()` for every control key so the next edit retypes the
whole field rather than diffing against a line that no longer exists.
Confidence: high (pure code reading; the byte paths are unambiguous).

### 2. After a pipeline replacement the field keeps the *retired* terminal's key bar
`Sources/Heeler/Terminal/TerminalComposer.swift:106-111` — `terminal`'s `didSet`
only calls `mirror.reset()`.
`Sources/Heeler/Terminal/TerminalComposer.swift:285-288` — the field's
`inputAccessoryView` getter resolves `control?.terminal?.sharedKeyBar` lazily, but
UIKit caches the accessory view until someone calls `reloadInputViews()`, and
nothing does for the field.

While the composer is active `HeelerTerminalView.canBecomeFirstResponder`
(`TerminalScreenView.swift:1306-1308`) is false, so the *new* terminal never takes
first responder — the field holds the keyboard straight through the reconnect and
never re-queries its accessory. The bar on screen is then terminal A's bar, and
terminal A has been retired by `HerdrClientView.screen(for:)`:

- `screen.isLocalInputEnabled = false` (`HerdrClientView.swift:78`) — every
  `keyBar(_:didPress:)`, `didType`, and sticky action guards on
  `isLocalInputEnabled` and returns early. Esc, Tab, Ctrl, the arrows and the
  symbol keys are all dead.
- `screen.composerControl = nil` (`HerdrClientView.swift:81`) — the composer
  toggle becomes a no-op and `keyBarComposerState` returns nil.
- 150 ms later the retired surface is released; the bar's `handler` is weak, so it
  goes nil and the pill is inert with no visible sign.

Typing from the software keyboard still works (that goes through `control` →
`control.terminal`, which *is* updated), so the failure looks like "the pill
stopped working after a reconnect".

Fix: in `terminal`'s `didSet`, when the field is first responder,
`UIView.performWithoutAnimation { field?.reloadInputViews() }` alongside the
`mirror.reset()`.
Confidence: medium-high. It rests on UIKit caching `inputAccessoryView` — which is
exactly why `HeelerTerminalView` itself calls `reloadInputViews()` in five places
(`TerminalScreenView.swift:1242, 2291, 2361, 2390`) — but I could not run the
device to see it.

## SHOULD-FIX

### 3. `refreshComposerKey()` has no call site for a late `composerControl`
`Sources/Heeler/Terminal/TerminalKeyBar.swift:219-232`, called only from `init`
(`:161`) and from the toggle's own `UIAction` (`:437`). The state it reads is
`composerControl?.isEnabled` (`:592-594`), and the bar is created lazily inside
`HeelerTerminalView.inputAccessoryView`. Today the ordering happens to work —
`makeUIView` sets `view.composerControl` at `TerminalScreenView.swift:253` before
anything can touch the accessory — but nothing enforces it, and if the bar is ever
built first the toggle key is hidden permanently, with no other route to turn the
composer on. `refreshStickyKeys` has the equivalent hook
(`setStickyModifierChangeHandler`, `TerminalScreenView.swift:1270`); this has none.
Fix: make `HeelerTerminalView.composerControl` a `didSet` that calls
`keyBar?.refreshComposerKey()`.
Confidence: medium (latent, not currently reachable).

### 4. The retired screen still forwards `onKeyboardHandoffEnded` to the composer
`Sources/Heeler/Client/HerdrClientView.swift:127` sets it;
`HerdrClientView.swift:77-88` clears `keyboardControl`, `composerControl`,
`claimsKeyboard`, `onSend`, … but not `onKeyboardHandoffEnded`. The wrapper in
`TerminalScreenView.swift:254-258` / `314-318` guards with
`if let keyboardControl, keyboardControl.terminal !== view { return }` — on a
retired screen `keyboardControl` is nil, so the guard falls through and the
retired view forwards. `setLocalInputEnabled(false)` →
`cancelKeyboardTransitionLayoutDeferral()` → `onKeyboardHandoffEnded?(id,
.cancelled)` (`TerminalScreenView.swift:2436`) therefore reaches
`composer.endKeyboardHandoff(id)`. `endResponderHandoff` guards on id equality
(`TerminalKeyboardInset.swift:311`), so it only misfires when the retired view's
active handoff id is the live freeze — i.e. a reconnect landing during a composer
handoff, which releases the freeze early and lets the terminal reflow twice.
Fix: add `screen.onKeyboardHandoffEnded = nil` to the retired branch.
Confidence: medium-high.

### 5. `keyboardClaimIsConsumedOnce` does not test what it is named
`Tests/HeelerTests/TerminalComposerTests.swift:109-115`. With no terminal,
`toggle()` sets `pendingKeyboardClaim = false`, so both `#expect(!…)` pass
trivially and the "consumed once" behaviour (`defer { pendingKeyboardClaim =
false }`, `TerminalComposer.swift:152-155`) is never exercised.
`pendingKeyboardClaim` is `private(set)` so a test cannot arm it directly.
Fix: expose a seam (an injectable "terminal holds the keyboard" probe) or rename
the test to what it checks. Confidence: high.

## NITS

6. `TerminalComposer.swift:159-162` — `beginKeyboardHandoff()` returns a fresh
   `UUID()` when `keyboardInset` is nil. The caller stores it as a live freeze
   token and the later `cancel`/`end` are silent no-ops. Prefer an optional.
7. `TerminalScreenView.swift:1579-1583` — the composer early-return in
   `requestKeyboard()` skips `finishKeyboardTransitionLayout(handoffOutcome:
   .cancelled)`, so an in-flight terminal handoff is left deferred until its own
   fallback (500 ms, `TerminalKeyboardInset.swift:70`).
8. `TerminalKeyBar.swift:568-573` — an armed sticky Ctrl/Alt only makes *pill*
   keys a chord. With the composer on, a letter from the software keyboard goes
   into the field, so "arm Ctrl, press c on the keyboard" silently types `c`.
   Worth a line in the design note / device check list.
9. `TerminalComposer.swift:43-55` — DELs are counted in grapheme clusters. The
   doc comment covers flag emoji; a *decomposed* mark (e + U+0301, which some
   third-party keyboards and pasted text produce) is also one grapheme and two
   scalars, and one DEL removes only the mark in most line editors.
10. `TerminalComposer.swift:262-268` — the placeholder is a subview of the
    `UITextView`, pinned to `topAnchor`/`leadingAnchor`, i.e. to the scroll
    content, not the frame. Harmless while the field is empty; would drift if it
    were ever shown with a non-zero content offset.
11. `TerminalComposer.swift:398` — Return with marked text present returns false
    and neither submits nor commits the composition. Rarely reachable (IMEs
    normally consume Return before `shouldChangeTextIn`), but it is a silent
    swallow rather than a fallthrough.

## Checked and clean

- `TerminalComposerMirror.update/submit/sanitized` against spec decision 1: common
  prefix in Characters, `old.count - prefix` DELs, new tail as UTF-8, Return sends
  `0x0D` and clears. Verified the empty diff, the mid-line edit, the shorter
  target, the longer target, and post-submit retype. Correct under the spec's
  stated assumption (remote cursor at end of line) — the only way that assumption
  breaks from inside the app is finding 1.
- `TerminalKeyBar.swift:249-253, 331-347` — `scrollLeadingWithComposer` /
  `scrollLeadingWithoutComposer` are both created inactive and are never both
  active: `refreshComposerKey` deactivates both before activating one. No conflict.
- `TerminalKeyBar.swift:177-179` — the second divider is in
  `dividerHeightConstraints` and `applyTextSizeMetrics` updates both. Dynamic Type
  correct.
- `TerminalKeyBar.swift:230` — `composerKey.configuration?.baseForegroundColor = …`
  does mutate: the button is built with `UIButton(configuration:primaryAction:)`
  (`:487`) so `configuration` is non-nil, and Swift's optional-chained assignment
  to a settable property goes through the setter.
  `setNeedsUpdateConfiguration()` after it is redundant but harmless.
- `hasActiveStickyModifiers` is `public` on the vendored view
  (`Packages/GhosttyTerminal/…/UITerminalView+PublicSticky.swift:69`) and reachable
  from the extension. The vendored package is untouched by this commit.
- `TerminalComposer.swift:312-324` — the settle logic is a faithful copy of
  `AgentComposerView.swift:755-770`, including the `guard let
  activeKeyboardHandoffID` shadow: `self.activeKeyboardHandoffID = nil` clears the
  stored property while the callback still receives the shadowed non-optional. Not
  a nil pass.
- Swift 6 strict concurrency: `TerminalComposerTextView` is implicitly `@MainActor`
  (UITextView), the `@objc` selector observer and the non-`@Sendable`
  `onKeyboardHandoffSettled` closure both inherit that isolation, and
  `DispatchQueue.main.async` with main-actor calls is the established pattern here
  (six other sites, including `AgentComposerView.swift:639`). No new isolation
  problem found. `control ↔ field ↔ terminal` is weak on the control's side with
  no cycle: the field's closure retains the control, the control holds the field
  weakly.
- Tests: `Data + Data` is valid (RangeReplaceableCollection), and `#require` in a
  `throws` helper called from `throws` tests is fine. No force unwraps, no `try!`.
- `canBecomeFirstResponder` going false while the composer is active does *not*
  cost the terminal its copy menu: selection uses an explicitly presented
  `UIEditMenuInteraction` (`TerminalScreenView.swift:1054, 3541`), not
  responder-chain `canPerformAction`.
- `xcodegen` output committed (`Heeler.xcodeproj/project.pbxproj` in the commit),
  CHANGELOG entry present, vault notes updated.

## Not checked

- No build, no test run, no device (per the brief). Nothing here is compile- or
  device-confirmed.
- Whether UIKit posts a keyboard frame notification at all on a same-height
  responder swap between two views sharing one accessory. If it does not, the
  inset freeze always exits on the 500 ms `responderHandoffFallbackDelay` rather
  than on the settle — correct but slow, and only visible on the device.
- Whether one `TerminalKeyBar` instance serving as `inputAccessoryView` for two
  responders behaves on iPadOS (spec decision 4 asserts it; upstream does the same
  for the Console).
- The responder flows (a)–(h) were traced through the code only; none of
  `focusField`, `typeIntoField`, `toggle`'s handoff, or the hardware-keyboard
  transition has a test.
