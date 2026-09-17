# Open item 19 — report

Cause, fix, ruled-out candidates and the one residual bug: see `diagnosis.md` in this folder.

Files changed (all in /Users/anthonytopalides/Developer/Kelpie):
- Sources/Heeler/Notifications/NotificationPreferencesStore.swift — `confirmedTriggers(for:)` falls back to both triggers on, plus a `Self.log.info` naming the Host.
- Sources/Heeler/Notifications/AgentNotificationBannerStore.swift — header comment only.
- Tests/HeelerTests/NotificationPreferencesStoreTests.swift — 3 tests updated, 3 added.

Build: `xcodebuild build-for-testing` against the iPad — TEST BUILD SUCCEEDED, no errors. Derived data and SPM clone deleted.

Not done: the mid-hold snapshot-clear bug (diagnosis.md, "Left undone"); no device test run.

## Review delta (must-fix + should-fix)

Must-fix: the fallback was silencing nothing on a Host whose Notifications toggle the
user turned off (`setNotificationsEnabled(false, …)` leaves `.idle(isRegistered: false)`).
`confirmedTriggers(for:)` now requires the discriminator `flagsToCarry` already uses — a
surviving Notification Key (`ceremony.keys.record(forHost:)`), which `ceremony.remove`
deletes on an explicit off. So: registered → its flags; unregistered but key present
(stale/rotated token) → both on; no key (explicit off, or a Host never set up here) → nil,
fail closed. Stale doc comment above `lastRegistrationDate` removed.

Should-fix: the fallback `log.info` is now once per Host per state change, via
`bannerFallbacksLogged: Set<Host.ID>` cleared at the top of `load(_:)`.

Tests: `confirmedTriggersOfANeverRegisteredHostAreNil` (was …AreBothTriggersOn),
`notificationsTurnedOffOnThisHostSilencesTheBanner` (new),
`triggersAreBothOnWhileARegisteredHostsTruthIsUnknown` and
`triggersAreBothOnWithNoDeviceToken` now seed a key, as does
`aStaleEntryForAnotherTokenStillBanners`; shared `seedNotificationKey()` helper.
