# Review 2 — rebase onto Heeler v0.1.8 (worktree Kelpie-rebase, head 38c9f3d)

Read-only. Files read at `git show 38c9f3d:<path>`. Comparisons: tag `kelpie-pre-rebase-20260915`, `upstream/main`.

## Area A — notification / Live Activity taps

Verdict: **Kelpie's landing rule survives the port to upstream's multi-scene directory.** One real
regression, and it is in the code the concurrent builder is already touching.

Mechanism at head, confirmed:
- `PushRegistrationStore.swift:244` builds the UN delegate with the app-wide `AgentSceneDirectory`,
  constructed in `PushRegistrationDelegate.init` — so it exists before any window.
- `AgentNotificationCenterDelegate.swift:97-101` (didReceive) → `directory.land(onHostID:)`; no
  target → `HerdrClientNoticeStore.shared.post(.unreadableNotification)`. `directory.open(...)` is
  no longer reachable from a notification tap, so the Console is never presented by one.
- `AgentSceneDirectory.swift:316-328` `land` picks the key scene (else most recent), calls
  `entry.router.land(onHostID:)` + `entry.activate()`; with no scene it parks `pendingLanding`
  (`:167`), drained in `register` at `:192-195` — after `entries[sceneID]` is assigned (`:186`) and
  before `pendingOpen`, so a cold launch cannot be overtaken by a Console open.
- `AgentNotificationRouter.swift:34-46,63-72` — `landing`/`Landing(hostID,sequence)`/`land`/
  `landingWasHandled` are byte-identical in intent to the tag; `path` is untouched by `land`.
- `HerdrClientRootView.swift` is **unchanged from the tag** (empty diff for `Sources/Heeler/Client`);
  `:264-267` `.onChange(of: notificationRouter.landing, initial: true)` → `:278-288` `landOnClient`
  lowers the cover, clears every sheet, `primaryHost.land(...)`, `landingWasHandled()`.
- Live Activity: `ContentView.swift:131-134` `.onOpenURL` → `notificationRouter.land(onHostID:)`;
  widget URLs unchanged (`AgentLiveActivityWidget.swift:161,255,342`); no diff under
  `Sources/HeelerWidgets`.

Per-scenario answers:
- **Killed / cold launch**: lands. `pendingLanding` → `register` → router → root view's
  `initial: true` observer (installed during the first body pass, before `onAppear`) sees nil→value.
  Console not presented.
- **Background**: lands. Directory has a live entry; `entry.activate()` foregrounds it.
- **Foreground, Console cover up**: lands. The root view stays in the hierarchy behind the cover, so
  its `.onChange` fires and `landOnClient` sets `isShowingConsole = false`.
- **Foreground, root screen**: lands; `landOnClient` is idempotent for an already-lowered cover.

### A1 — must-fix (high) — `Sources/Heeler/ContentView.swift:185`
`restoreRoute()` seeds `notificationRouter.path = [restoration.route.agentID]` on a cold launch.
On Kelpie the Console cover is **down** at that point, so `AgentSceneDirectory.scenes` reports
`presentedAgent` = that agent (`AgentSceneDirectory.swift:299`) and `keyScenePresentedAgent`
(`:305-309`) is non-nil while the user is looking at the root screen. `willPresent`
(`AgentNotificationCenterDelegate.swift:64-66` → `AgentNotificationRouting.foregroundPresentation`
`:60-62`) then returns `.suppressed`, so a **Blocked/Done push for that Agent is silently dropped**
— neither the in-app banner nor iOS shows anything. Answer to the brief's `willPresent` question:
yes in the steady state (the cover's `onDisappear` clears `path`,
`HerdrClientRootView.swift:197-200`), **no** after a cold launch that restored a route.
The builder's removal of `restoreRoute()` fixes this; if any other path seeds `path` while the
cover is down, the same suppression returns. Whoever lands that change should confirm nothing else
writes `notificationRouter.path` outside the cover.

### A2 — nit (medium) — `Sources/Heeler/ContentView.swift:133`
The Live Activity tap calls this window's `notificationRouter.land(...)` directly instead of
`app.sceneDirectory.land(...)`, so it skips the key-scene choice and `entry.activate()`. Identical
to the tag on a single-window device; on iPad multi-window the URL lands in whichever scene SwiftUI
routes it to rather than the key one. Same shape as the tag, so not a rebase regression.

### A3 — nit (low) — `Sources/Heeler/ContentView.swift:138`
`onContinueUserActivity` → `sceneDirectory.open(...)` sets `router.path` but Kelpie's root view
never presents the cover in response, so a dragged-row route is invisible until the user opens the
Console by hand. Upstream-feature × Kelpie-root mismatch, not a tap-landing regression.

## Area B — hardware key paths, `Sources/Heeler/Terminal/TerminalScreenView.swift`

Verdict: **upstream's structure is preserved and the Kelpie intercepts are correctly re-inserted,
but two combos now reach the wrong path — one of them a dead feature.**

Structure check: head `pressesBegan` (`:2837-2904`) is upstream's `:1852-1888` with Kelpie's ⌘C,
`clearTouchSelection`, ⌘V and `interceptHardwareKey` spliced in; `pressesEnded` (`:2906-2921`) and
`pressesCancelled` (`:3039-3059`) keep upstream's sceneCommand/armed-modifier bookkeeping and
delegate zoom-press dropping to Kelpie's `forwardablePresses` (`:2953`) instead of upstream's inline
`zoomShortcutStep` filter — equivalent.

### B1 — must-fix (high) — `TerminalScreenView.swift:2872` vs `:2881`
The `.sceneCommand` route is tested **before** `interceptHardwareKey`. `hardwarePressRoute`
(`:3275-3285`) returns `.sceneCommand` for every ⌘ chord except `+ = - _`. So
**Cmd+←/→/↑/↓ never reach `interceptHardwareKey`**: they are pushed up the responder chain at
`:2900` and Kelpie's Home / End / Page Up / Page Down mapping
(`TerminalHardwareKeyMapping.swift:110,115,118-123`, `isCommandNavigationChord`) is dead. Nothing
else claims them — `escapeKeyCommands` (`:2797-2813`) covers only Escape and ⌘. — so the keys now do
nothing on the terminal. At the tag these were intercepted (the tag had no sceneCommand route).
Fix: run `interceptHardwareKey` before the sceneCommand test, or exempt the mapped ⌘ chords from it.

### B2 — must-fix (medium-high) — `TerminalScreenView.swift:2791-2795, 2797-2813`
The re-vendored package now registers **its own** Escape `UIKeyCommand`s
(`Packages/GhosttyTerminal/.../UITerminalView+KeyCommands.swift:55-70,83-90,120-133`); the tag's
package had none (`grep escapeKeyCommands` on the tag's copy is empty). Kelpie's `keyCommands`
override takes `super.keyCommands` — which now already contains the package's bare-Escape command —
and appends its own on top. Two consequences:
- The two paths have **independent** dedupe sets (`claimKeyCommandDelivery` inside the package vs
  `claimHardwareKeyDelivery` at `:2979-2985`). If the package's command is the one UIKit fires,
  Ghostty sends `.escape` **and** Kelpie's `pressesBegan`/`interceptHardwareKey` still sends raw
  `0x1B` on the iPadOS versions that deliver both a command and a press — the exact double-send
  `claimHardwareKeyDelivery` exists to prevent. Escape then arrives twice.
- The package deliberately **withholds** its Escape commands while text is marked (`:86-88`, so the
  key stays the input method's and cancels the composition). Kelpie appends its own
  unconditionally, so during an IME composition Escape is stolen from the input method and sent to
  the PTY.
Fix: drop Kelpie's bare-Escape command now the package owns it (keeping only the ⌘. entry), or
gate it on `!hasMarkedText` and share one claim.

### B3 — should-fix (medium) — `TerminalScreenView.swift:2872`
⌘. is also a ⌘ chord, so the `pressesBegan` backstop for it is gone for the same reason as B1. In
practice iPadOS respells ⌘. as an Escape press with the Command bit dropped
(`hardwareKey(for:)` `:3020-3029`), which routes `.terminal` and still works; but the traced
non-respelled spelling now has only the key-command path. Lower severity than B1 only because the
respelling is the observed behaviour.

### B4 — nit (medium) — `TerminalScreenView.swift:2881` before `:2888`
`interceptHardwareKey` runs ahead of `beginPhysicalKeyForArmedModifiers`, so a key-bar-armed ⌃/⌥/⇧
is neither consumed nor applied when the physical key is one the mapping owns (Escape, Option+⌫,
Option+←/→). The armed modifier survives and lands on the *next* keystroke instead. Deliberate per
the comment at `:2878-2880`; flagged only because it is new behaviour (the armed path is upstream's).

Checks that passed:
- Plain Backspace and Return: `bytes(for:)` returns nil for both unmodified (`:103-107,128-130`), so
  they fall through `interceptHardwareKey` → armed-modifier seam → `super.pressesBegan` → Ghostty
  `sendKey`. Exactly one path each.
- Escape (bare, press path) and Option+⌫ / Option+←/→: `.terminal` route → intercepted → raw bytes,
  press never forwarded, so Ghostty never encodes them. One path each (modulo B2).
- Begin/End/Cancel pairing: every `continue` in `pressesBegan` is matched. ⌘C-with-selection and
  `interceptHardwareKey` both insert into `interceptedPresses` (`:2858`, `:2930`) and both releases
  are removed in `forwardablePresses` (`:2947-2952`); ⌘V is dropped in `pressesBegan` (`:2868`) and
  its release by the `isPasteShortcut` guard (`:2954`); zoom presses by `:2953`. Presses filtered
  out of `remaining` as consumed-by-armed-modifiers can never be intercepted ones, because
  `interceptHardwareKey` `continue`s first. `claimedAltCombos` is cleared per press in
  `forwardablePresses` (`:2948-2950`), matching the `scheduleHardwareKeyClaimReset` comment
  (`:2996-3001`). No leak or orphan found.
- Armed-modifier cleanup: `endPhysicalKeyForArmedModifiers` / `cancelPhysicalKeyForArmedModifiers`
  are called for every non-sceneCommand press in Ended (`:2913`) and Cancelled (`:3049`), and the
  stale-token reset at the top of `pressesBegan` (`:2838-2841`) is upstream's verbatim. Same events
  as upstream.
- No key goes through both `insertText` and `sendKey`: `insertText` (`:1647-1661`) checks
  `consumeMatchingInsertEcho` then `applyArmedModifiers`; `deleteBackward` (`:1722-1734`) checks
  `consumeMatchingBackspaceEcho` then `isSuppressingAltEcho`; intercepted presses are never
  forwarded to `super`, so Ghostty's `sendKey` cannot also fire for them.
