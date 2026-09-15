# Review: rebase kelpie-upstream-20260915 (38c9f3d) onto Heeler v0.1.8

Read-only review. No builds, no tests run.

## Findings (running)

### M1 (must-fix, high) — `Sources/Heeler/Console/ConsoleView.swift:540`
`openInNewWindow` calls `openWindow(value: AgentRoute(agentID:))`, but `HeelerApp`
no longer declares `WindowGroup(for: AgentRoute.self)` (spec 2). With no scene
accepting that value SwiftUI logs "No WindowGroup ... accepts value of type
AgentRoute" and nothing happens. The row context-menu item at line 522-525 is
therefore dead on iPad.

### M2 (must-fix, medium-high) — `project.yml:66-76` + `Sources/Heeler/Console/ConsoleView.swift:528-532`
`NSUserActivityTypes: dev.bybee.heeler.agent` is now declared in the app's
Info.plist (new since the tag — the tag had no `Sources/Heeler/Info.plist`),
and `AgentWindowDrag` is still applied to every Console row when
`supportsMultipleWindows`. Dragging a row to the screen edge on iPad now asks
iPadOS for a second scene; each scene builds its own `ContentView` ->
`HerdrClientRootView`, so two herdr clients compete for the one Attach channel
— the exact failure spec 2 forbids.

### S1 (should-fix, high) — `Sources/Heeler/Console/ConsoleSplitPresentation.swift:32-39`
Kelpie commit `23c4a30` was skipped for upstream's `ConsoleSplitPresentation`,
but the two are not equivalent. Upstream picks `.detailOnly` only in *regular
+ portrait*; in *regular + landscape* it picks `.all`. `23c4a30` made the
terminal fill the window whenever an Agent was open at regular width, in either
orientation, because "the Agent list split the screen ... left herdr a column
wide". On a landscape 11-inch iPad the regression the commit fixed is back.
Nothing in upstream's policy reads the router path at all.

### S2 (should-fix, medium) — `Sources/Heeler/ContentView.swift:185`
`restoreRoute()` writes `notificationRouter.path = [restoration.route.agentID]`
from `@SceneStorage`, but Kelpie never presents the Console at launch
(`isShowingConsole` starts false). So after a kill while the Console cover was
on an Agent, the app relaunches on the herdr client with `path` non-empty.
Consequences: `AgentSceneDirectory.keyScenePresentedAgent` reports that Agent,
so `AgentNotificationCenterDelegate.willPresent` suppresses its pushes
(`AgentNotificationRouting.foregroundPresentation`) while the user cannot see
it; and `reconcileTerminalOwnership` claims that Host's terminal channel for a
window showing no terminal. At the tag `path` was non-empty only while the
Console was up.

### S3 (should-fix, medium) — `Sources/Heeler/Terminal/TerminalKeyboard.swift:241-271` / `Tests/HeelerTests/TerminalKeysKeyboardTests.swift:59-60`
`sendControlKey` was rewritten to route through `sendQuickKey`/Ghostty
(38c9f3d compile fix), so `TerminalControlKey.bytes(applicationCursor:)` has no
production caller left — only the test. `shiftTabEncodesBackTab` now asserts a
table nothing ships; the key bar's real encoding path is untested.

