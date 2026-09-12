# Robustness review — root screen, terminal, client chrome (round 12)

Reviewer: Opus reviewer (delegate). Read-only; no edits, no builds, no device.
Excluded by brief: the uncommitted `replace(_:withText:)` rewrite path and the
one-finger scroll-to-dismiss rule (another reviewer owns both). They are treated
as current code below only where something *else* feeds them.

## Ranked findings

| # | Sev | Conf | Location | Gap | How it fails in practice |
|---|-----|------|----------|-----|--------------------------|
| 1 | must-fix | high | `Sources/Heeler/Client/HerdrClientRootView.swift:154` (`.id(host.id)`) with `:512-535` (`HerdrClientHostView.init`) | The Client store captures `host.sessionName` once at init, and the view identity is the Host **id** alone, so editing the Host never rebuilds the store. | Anthony edits the primary Host's herdr session name in `HostFormView`. `hosts.hosts` changes, the view keeps its identity, `HerdrClientStore.sessionName` stays `let`-bound to the old value, and every subsequent attach — including `reconnect()` and every transport-generation replacement, which both go through `makeTerminal(sessionName:)` — still runs `exec herdr --session "<old name>"`. Only an app relaunch fixes it. Same applies to any other Host field the store snapshots. |
| 2 | should-fix | medium | `Sources/Heeler/Terminal/TerminalScreenView.swift:1020-1051` (`showsKeyBar` didSet / `dropKeyBar()`) | Dropping the key bar clears the bar and its change handler but never clears an **armed sticky Ctrl/Alt** in the terminal. | Tap `ctrl` on the key bar, then dock a Magic Keyboard (or the observer flips for any reason). `showsKeyBar` goes false, the bar is destroyed, and the armed modifier survives in the vendored view with nothing on screen showing it. The next character typed on the hardware keyboard goes out as a control chord — e.g. `c` becomes `^C` and kills the agent. Fix: clear sticky modifiers in `dropKeyBar()` (and on `setLocalInputEnabled(false)`), alongside `setStickyModifierChangeHandler(nil)`. |
| 3 | should-fix | medium | `Sources/Heeler/Client/HardwareKeyboardObserver.swift:20-33` | `isConnected` is seeded once at init and thereafter only moved by `GCKeyboardDidConnect/Disconnect`; nothing re-reads `GCKeyboard.coalesced` on foreground. | Dock or undock the Magic Keyboard while Kelpie is suspended. GameController notifications posted to a suspended process are not a reliable delivery guarantee, so the app can return with a stale answer. Everything downstream is then wrong at once: `screen.showsKeyBar`, `screen.claimsKeyboard`, `screen.isHardwareKeyboardConnected` (so scroll-to-dismiss misbehaves), `keyboardPresentation`, and `inputMode.hardwareKeyboardDidChange` in `ContentView.swift:141`. Fix: re-read `GCKeyboard.coalesced` from `activity.activationCount` / scene activation, where `ContentView` already has a hook. |
| 4 | should-fix | medium | `Sources/Heeler/Terminal/TerminalScreenView.swift:1306-1322` (`inheritKeyboard`) + `:1974-1990` (`beginKeyboardTransitionLayoutDeferral`) + `Sources/Heeler/Terminal/TerminalKeyboard.swift:473-484` (`notificationSettlesOwnKeyboard`) | The freeze started by an inherited keyboard ends only on a `keyboardDidChangeFrame` whose end frame matches `window.keyboardLayoutGuide.layoutFrame`; with a hardware keyboard attached no software keyboard frame is published, so the only exit is the 0.5 s wall-clock leash. | The root screen's normal case: `claimsKeyboard = { hardwareKeyboard.isConnected }` is true with a Magic Keyboard, so every fresh surface (first attach, Host switch, transport-generation replacement, Console cover coming down) enters the freeze, becomes first responder, and then sits with `layoutSubviews` suppressed and every grid report deferred for the full 500 ms before `.timedOut` thaws it. Observable as a half-second of stale/unsized grid and a late first resize report on each reattach. `inheritKeyboard` already handles the `!isFirstResponder` case; the `isFirstResponder && no software keyboard` case has no early exit. |
| 5 | should-fix | medium | `Sources/Heeler/Terminal/TerminalScreenView.swift:2866-2883` (`handleTap`) and `:1872-1884` (`gestureRecognizerShouldBegin` for `tapGesture`) | A tap on any cell the link detector claims is swallowed whole — it never becomes a click for herdr — and path matching is loose enough to fire on ordinary agent output. | `TerminalLinkDetector.hostPath` accepts any whitespace-delimited token starting `/` or `~/` whose last component has a short alphanumeric extension. Agent output is full of those (`/Users/x/proj/main.swift`, `~/notes.md`). Tapping such a cell to place a cursor, dismiss a herdr menu, or pick a row starts a Host download HUD instead and sends nothing to herdr — a click the TUI simply never receives, with no way to say "no, I meant the click". Suggest gating `.hostPath` behind a deliberate gesture (long-press item, or only when `!modeTracker.tracksMouse`) and leaving `.url` on the plain tap. |
| 6 | should-fix | medium | `Sources/Heeler/Terminal/TerminalScreenView.swift:1515-1521` (`recordTerminalInput`) | The shadow `textInputStorage` silently stops tracking the real line whenever a write contains ESC or DEL — every arrow key, Esc, and app-owned hardware chord is dropped on the floor rather than reconciled. | Cross-reference for the reviewer who owns `replace(_:withText:)`: that rewrite path trusts `textInputStorage` to be a faithful suffix of the remote line (`replacedRangeEnd == documentLength`). Type `hello wrold`, press ←←← to fix it, then let autocorrect rewrite the word: the DEL count is computed against a storage that never saw the cursor move, so the DELs land on the wrong characters. Also affects `deleteBackward`'s delegate bookkeeping and `keyboardActivationRegion` (which derives from `caretRect(for: endOfDocument)`). Either reset the storage on any unmodelled write or refuse the rewrite after one. |
| 7 | should-fix | high | `Sources/Heeler/Client/HerdrClientRootView.swift:364-377` (`menuButton` label) | The floating capsule is roughly 28 pt tall (`.caption` line height + 6 pt padding top and bottom) against the 44 pt HIG minimum, and it is the **only** route to Hosts, Agents, Settings, Setup Guide, Reconnect and all attach commands. | On a phone it sits in the bottom corner over herdr's mobile header; at compact width it is icon-only, so the target shrinks further. A missed tap lands on herdr's surface and is forwarded to the PTY as a click. Fix: keep the visual capsule but give the `Menu` a ≥44 pt `contentShape`/frame, or pad the label to 44 pt. |
| 8 | should-fix | high | `Sources/Heeler/Terminal/TerminalKeyBar.swift:33` (`keyHeight = 38`), `:39` (`titleSize = 16`), `:32` (`barHeight = 46`), `:248-256` and `:283` | Keys are 38 pt tall (below the 44 pt minimum) and every label is a fixed 16 pt `systemFont`/`monospacedSystemFont` with a fixed 46 pt bar — no Dynamic Type anywhere in the bar. | At large accessibility text sizes the bar does not grow and the captions do not; at the default size the keys are already under the minimum target, on the one row of chrome an iPhone user has for Esc/Tab/Ctrl/arrows. `minimumKeyWidth` is 44 but the height is not. Use `UIFontMetrics`/`preferredFont(forTextStyle:)` (as `TerminalControlPadView.makeButton` already does at `TerminalKeyboard.swift:281-286`) and derive `barHeight` from the scaled key height. |
| 9 | nit | medium | `Sources/Heeler/Client/HerdrMediaStagingStore.swift:165-173` (`nextStateChange`) | `withCheckedContinuation` inside a `withObservationTracking` one-shot is not cancellation-aware: a cancelled `queueTask` suspended here never resumes. | `leave()` cancels and then nils `queueTask`, so the queue recovers — but the orphaned task and its continuation are retained for the life of the process, holding the store and its intake copies. Add a `withTaskCancellationHandler` or poll with a timeout. |
| 10 | nit | medium | `Sources/Heeler/Files/HostFileViewer.swift:70-88` | The download task writes through `self?`; if the store is gone when the transfer lands, the downloaded file's directory is never removed. | A Host switch or app teardown mid-download leaves a temp directory until the next launch's `cleanupRemnants()`. The `Task.isCancelled` branch does clean up; the `self == nil` path does not. |
| 11 | nit | high | `Sources/Heeler/Terminal/TerminalKeyTrace.swift:80-89` | `write` joins up to 4000 lines and does a synchronous atomic `Data.write` on the calling (main) thread, once **per logged line**. | Only with `kelpie.key-trace` on — but that is exactly when it matters. `handleHerdrRightClickGesture` logs `drag motion` per cell crossed and `pressesBegan` logs per key, so the trace performs a ~200 KB main-thread file write per input event and perturbs the very timing it exists to measure (this is the tool that found the round-3 Escape bug). Append to a file handle, or buffer and flush off-main. |
| 12 | nit | medium | `Sources/Heeler/Terminal/TerminalScreenView.swift:1573-1585` (`paste(itemProviders:)`) | The `isLocalInputEnabled` guard is checked at call time but the text insertion happens a turn later inside `Task { @MainActor }` with no recheck. | A paste that lands while the pane is being paused (Console cover coming up) types into a surface the app has just disabled. Same shape as the `hasClaimedPasteThisTurn` reset. |
| 13 | nit | low | `Sources/Heeler/Terminal/TerminalScreenView.swift:1673-1683` (`layoutSubviews`) + `Sources/Heeler/Terminal/TerminalHoldCueView.swift:68` | `layoutSubviews` returns before `super` while the keyboard freeze is on, and `holdCue.frame` is only assigned in `show(at:in:)`. | A rotation, Split View divider drag or Stage Manager resize during a hold (or during the 500 ms freeze of finding 4) leaves the cue container on the old bounds, so the disc is drawn at a stale offset or clipped. Decorative only. |
| 14 | nit | low | `Sources/Heeler/Terminal/TerminalScreenView.swift:1759-1779`, `:1685-1699` | `didMoveToWindow(nil)` clears momentum, selection, hold and the responder-gate touch count, but not `claimedLinkTouch` / `claimedRightButtonTouch`. | A pointer press claimed when the view leaves its window leaves a stale claim; both hold their `UITouch` weakly so the next sequence's `touches.contains` guard fails harmlessly, but `claimedLinkTouch` can then block a subsequent link claim in the `else if` chain at `:1727`. |
| 15 | nit | low | `Sources/Heeler/Terminal/TerminalScreenView.swift:2756-2766` | `tapGesture` deliberately does not `require(toFail: doubleTapGesture)`. | Documented trade: a double tap to select a word also sends a left click to herdr first, which under mouse tracking can activate whatever was under the finger (a tab, a pane close box) before the word is selected. Accepted by design; noted only because the lens asked what fires twice. |

## Test gaps

No unit tests exist for, in rough order of risk:

- `HerdrClientStore` — the entire cover-up/cover-down and transport-generation
  lifecycle (`setPresented`, `rejoin`, `leave`, `abortReplacementOffStage`,
  `enqueueLifecycleTransition` ordering). The most intricate state machine in
  scope, and the one the Attach-channel exclusivity depends on.
- `HardwareKeyboardObserver` — injectable `isConnected` exists precisely so it
  can be tested; nothing does.
- `TerminalKeyBar` — sticky-modifier refresh, and the `showsKeyBar`
  create/drop cycle (finding 2).
- `HerdrMediaStagingStore` — the ordered queue, failure-stops-the-batch rule,
  and intake-copy discard.
- `HostFileViewerStore` — replace-in-flight, cancel, and cleanup paths.
- The hold-then-drag state machine (`HeldPointerDrag`) — pure enough to test
  through `TerminalModeTracker` + `TerminalGridPointMapper`, both of which
  already have suites.

Covered well: `TerminalModeTracker`, `TerminalGridPointMapper`,
`TerminalTouchSelection`, `TerminalLinkDetector`, `MediaIntake`,
`TerminalSessionCallbackBridge` grid-report phases,
`TerminalKeyboardResponderGate`, `TerminalHardwareKeyMapping`,
`PrimaryHostStore`.

## What I could not check

- Anything requiring a device or a build: no run, no Instruments, no VoiceOver
  pass. Hit-target sizes above are computed from the constants in source.
- The vendored `Packages/GhosttyTerminal` internals: whether
  `UITerminalView.caretRect(for:)` copes with the custom
  `TerminalInputTextPosition` returned by the `endOfDocument` override
  (`TerminalScreenView.swift:903-908`) is load-bearing for
  `keyboardActivationRegion`, and I could not verify it without running.
  If it ever answers `.zero`, tap-to-raise-keyboard silently stops working.
- Whether iPadOS publishes a keyboard frame change for the shortcuts bar with a
  hardware keyboard attached — that is the one fact that decides whether
  finding 4 is a 500 ms freeze on every reattach or a non-issue. It is
  measurable on device in one attach with `kelpie.key-trace` on.
- Real IME behaviour (marked text, CJK, dictation, emoji keyboard) and real
  autocorrect/smart-punctuation behaviour in each `UITextInputTraits` style.
  The overrides at `:860-894` are consistent; only a device confirms them.
- Whether `console.terminalRunner(for:)` / `fileDownloader(for:)` are
  late-bound against the live Host record (finding 1 assumes they are, which is
  why only `sessionName` is called out).
