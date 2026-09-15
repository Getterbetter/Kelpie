# Rebase review fixes 2 — hardware keys

## Fix 1: mapped chords intercepted before the scene-command route
`Sources/Heeler/Terminal/TerminalScreenView.swift`, `pressesBegan`. `interceptHardwareKey(press)`
now runs before the `hardwarePressRoute == .sceneCommand` test, guarded by
`zoomShortcutStep(for: press) == nil` so ⌘+/⌘− still step the font size. The call was removed from
its old place inside the zoom `guard`'s else branch; it still runs ahead of
`beginPhysicalKeyForArmedModifiers`. `interceptHardwareKey` only answers presses
`TerminalHardwareKeyMapping.bytes(for:)` has bytes for, so every other ⌘ chord keeps upstream's
scene-command routing. Restores ⌘←/→/↑/↓ (Home/End/PageUp/PageDown) and the ⌘. press-path backstop.

## Fix 2: one Escape key command
Kelpie's bare-Escape `UIKeyCommand` is dropped; the vendored package registers Escape itself
(`UITerminalView+KeyCommands.swift`), withholds it while text is marked, and dedupes it with
`claimKeyCommandDelivery`. The static `escapeKeyCommands` array became a single
`commandPeriodKeyCommand` (⌘. only — confirmed by grep that the package has no ⌘. entry; its
`controlKeyCommandInputs` includes "." but only under `.control`). The ⌘. action
`heelerEscapeKeyCommand` still goes through `sendHardwareKey` → `claimHardwareKeyDelivery`, whose
`claimKey` folds ⌘. onto Escape, so command path and press path share one claim.

Notes / residual:
- The package's Escape command logs through `TerminalDebugLog`, not `TerminalKeyTrace`, so bare
  Escape no longer appears in Kelpie's key trace. Accepted per brief.
- The two claim sets are not merged: `claimKeyCommandDelivery` is internal to the package. If a
  future iPadOS delivers Escape as both a package command and a press, Kelpie's press-path
  intercept runs before `super.pressesBegan`, so the package's own dedupe cannot see it. Not
  observed; noted only.
- `canPerformAction`'s `heelerEscapeKeyCommand` logging branch left in place (selector still exists).

## Navigation path writers (report only, no change)
- `Client/HerdrClientRootView.swift:198` — `notificationRouter.path = []` in the Console cover's
  `onDisappear`. Inside the Console cover's own lifecycle; allowed.
- `Console/ConsoleView.swift:186, 265, 274, 283, 329, 330, 388` — Console navigation; allowed.
- `Notifications/AgentNotificationRouter.swift:84, 88, 90` — inside `open(_:)`, reached from
  `AgentSceneDirectory.open` (`AgentSceneDirectory.swift:342`) and, in Kelpie, only from
  `ContentView.swift:91` (dragged-row activity) and `ContentView.swift:136`
  (`onContinueUserActivity`); allowed.
- `Notifications/AgentNotificationRouter.swift:105` — `agentsDidChange`, resolving a pending target
  from the Console feed and only when `path.isEmpty`; allowed.
No writer outside those.

## Tests
No test asserts the key-command list. `Tests/HeelerTests/TerminalKeysKeyboardTests.swift` has no
Escape/keyCommand assertions; `TerminalHardwareKeyMappingTests.swift:19 commandPeriodSendsEsc`
tests the mapping bytes only, unaffected. No test changes, no new files, no `xcodegen`.

## Builds
- Release, `generic/platform=iOS`: BUILD SUCCEEDED (`release-build.log`).
- Debug `build-for-testing`, same destination: TEST BUILD SUCCEEDED, 0 errors
  (`debug-build-for-testing.log`).
