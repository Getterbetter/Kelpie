# Rebase review fixes — worker report (2026-09-15)

Worktree `/Users/anthonytopalides/Developer/Kelpie-rebase`, branch `kelpie-upstream-20260915`, from `38c9f3d`.

## 1. Multi-window off
`project.yml:73-85` — app target `info.properties` now declares
`UIApplicationSceneManifest.UIApplicationSupportsMultipleScenes: false`.
`INFOPLIST_KEY_UIApplicationSceneManifest_Generation` stays YES; a file value wins over
the generated one, and the regenerated `Sources/Heeler/Info.plist:25-29` carries the dict.
`supportsMultipleWindows` is therefore false, and both upstream call sites are already
gated on it — `ConsoleView.swift:522` (`if supportsMultipleWindows, ...` around the
"Open in New Window" button) and `ConsoleView.swift:531-534`
(`AgentWindowDrag(..., isEnabled: supportsMultipleWindows)`). No extra gating needed.

`NSUserActivityTypes` **kept**. Grep for `dev.bybee.heeler.agent`:
- `project.yml:84` (the declaration)
- `Sources/Heeler/Info.plist:23` (generated from it)
- `Sources/Heeler/Notifications/AgentRoute.swift:13` — `AgentRoute.activityType`
- `Sources/Heeler/ContentView.swift:26` (old) — the `@SceneStorage` key, now removed
- `.testloop/reports/2026-09-13-ipad-native.md:207` — a report, not code

`AgentRoute.makeUserActivity` and `ContentView`'s `.onContinueUserActivity(AgentRoute.activityType)`
still use the type, and an undeclared activity type is never delivered, so the entry stays with
a comment saying why.

## 2. Landscape detail-only
`Sources/Heeler/Console/ConsoleSplitPresentation.swift:11-14,22-25,30,36-44` — new
`hasOpenAgent` member and init parameter; at regular width `defaultVisibility` is
`.detailOnly` whenever an Agent is open, in either orientation (landscape with no Agent open
still seeds `.all`). Sidebar widths stay orientation-driven.
`Sources/Heeler/Console/ConsoleView.swift:73-77` passes `hasOpenAgent: !notificationRouter.path.isEmpty`.
Tests: `Tests/HeelerTests/ConsoleSplitPresentationTests.swift:19-43` adds
`regularWidthWithOpenAgentShowsDetailOnly(isLandscape:)` (both orientations assert `.detailOnly`)
and `openingAnAgentInLandscapeReseedsToDetailOnly`.

## 3. No route restoration at launch
`Sources/Heeler/ContentView.swift` — removed the `@SceneStorage("dev.bybee.heeler.agentRoute")`
property (was :26) and the write-back at :117. `restoreRoute()` (now :164-176) no longer calls
`SceneRouteRestoration.resolve` and never writes `notificationRouter.path`; it carries only a live
hand-off activity through and marks the scene not-restored. The call site in `.onAppear` is kept
because it also latches `hasRestoredRoute`, which `.onContinueUserActivity` reads. A doc comment
gives the reason (`keyScenePresentedAgent` suppression + `reconcileTerminalOwnership`).
Everything else in `ContentView` is unchanged; `AgentRoute.sceneStorageValue` and
`SceneRouteRestoration` are untouched and still covered by `AgentRouteTests`.

## 4. Key bar encoding
`Sources/Heeler/Terminal/TerminalKeyboard.swift:345-358` — `sendControlKey` writes
`TerminalControlKey.bytes(applicationCursor: usesApplicationCursorKeys)` to
`terminalSession.sendInput`, as the pre-rebase code did. Upstream's `AgentQuickKey`/`sendQuickKey`
is left in place for its own callers. `shiftTabEncodesBackTab` now asserts a shipping table again.

## 5. Stale CI comment
`scripts/run-ci-ios-tests.sh:919-920` — reworded to "Kelpie builds for iPad and iPhone; CI boots an
iPad simulator." No `Makefile` occurrence.

## Verification
- `xcodegen generate` — clean.
- Release, `generic/platform=iOS`, `CODE_SIGNING_ALLOWED=NO`: **BUILD SUCCEEDED** (`build-release.log`).
- Debug `build-for-testing`, same destination: **TEST BUILD SUCCEEDED**, 0 `error:` lines
  (`build-for-testing.log`).
- Tests were not executed (no simulator on this Mac); device/simulator test run is still owed.
