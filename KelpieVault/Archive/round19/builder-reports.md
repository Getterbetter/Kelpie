# Round 19 builder reports (2026-09-15)

Spec: `spec-36-foreground-lease.md`. Items 37 and 38 were built in the main session (see Decisions, round 19).

## Plugin builder (opus-builder)

`plugin/src/notify-hook.js` `readEligibleDevices`: `leased` = tokens whose `Date.parse(entry.foreground_until) > Date.now()` (a lease only counts on an entry with a valid non-empty token, so a token-less junk entry cannot silence everyone — a deliberate narrowing of "every entry"); after the existing filters, `leased.size === 0 ? devices : devices.filter(leased.has)`. Five tests in a new `notify-hook: foreground lease` suite (live lease silences the other device; expired sends to both; malformed and null send to both; leased-but-ineligible sends nothing and leaves no state; a 410 prune preserves `foreground_until`). README: table row and an "Anti-noise" step 3. `npm test`: 318 passed, 0 failed.

## App builder (opus-builder)

`NotificationRegistrationFile.settingForegroundUntil(_:forDeviceToken:)` / `foregroundUntil(token:)` (lenient parse, fractional seconds accepted); `NotificationRegistrationCeremony.setForegroundLease(until:deviceToken:over:)` (absent file, unregistered device, unchanged value: no write); `NotificationPreferencesStore`: `backgroundNotification`, `appDidEnterBackground()`, `foregroundLease`/`foregroundRefreshInterval` init parameters, the refresh loop, a `Duration.timeInterval` helper. Tests: 5 file, 3 ceremony, 3 store. Release build succeeded. The device test run never left preflight ("Unlock iPad Pro to Continue").

Main-session change after review: `writeForegroundLease` writes to every Host rather than the ones whose last read said registered, because on a cold launch the Console connects after `didBecomeActive` and the read says unreachable; the ceremony's no-op for an unregistered device makes that safe.
