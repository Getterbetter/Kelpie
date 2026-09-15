# Spec: Open item 36 — no alert push to a device while another device has Kelpie in the foreground

Round 19, 2026-09-15. Anthony (round 18): "notifications shouldnt appear on devices if one device is foregrounded, i.e. no iphone notifications if ipad is foregrounded".

## The mechanism: a foreground lease in `notifications.json`

The app already writes its own entry in each Host's `notifications.json` over SFTP (read-merge-write, one entry per device token; see `plugin/README.md` "Notification Registration file (v1)"). The plugin's notify hook already filters that file per push (`readEligibleDevices` in `plugin/src/notify-hook.js`). The relay stays stateless and untouched.

Additive v1 field on a device entry:

```json
{ "token": "…", "key": "…", "env": "production", "notify": {…},
  "foreground_until": "2026-09-15T08:12:30Z" }
```

- `foreground_until` (string, optional): ISO 8601 UTC instant, written by the device while Kelpie is in the foreground. While the Host's clock is before it, the device holds a **foreground lease**. Missing, null, empty, or unparseable means no lease. The plugin never writes it; it preserves it on rewrite (pruning already preserves unknown fields).
- Lease length: **180 s**. The app refreshes it every **60 s** while active, so one missed refresh still holds. Clocks are assumed NTP-synced on both ends; a skew of seconds is harmless at this length. A stale lease after a crash or a lost connection expires on its own within 3 minutes; that bounded delay is the accepted cost, recorded in Decisions.
- Cleared (the field removed from the entry) on `didEnterBackground`. Not on `willResignActive`: Control Centre, the app switcher and Split View stay in the foreground for this purpose.

## Plugin rule (`readEligibleDevices`, alert pushes only)

After the existing env/flag/key filters produce `eligible`, and reading the *whole* device list:

1. `leased = every entry (eligible or not) whose foreground_until parses (Date.parse) to > Date.now()`.
2. If `leased` is empty: send to `eligible` (today's behaviour).
3. Otherwise: send only to `eligible ∩ leased`. The foregrounded device still gets its push (the app turns it into an in-app banner via `willPresent`); the others get nothing. If the intersection is empty, nothing is sent and the hook exits quietly (the user is looking at a screen that shows the Agent).

The Live Activity path (`activity-hook.js`) is **not** changed: lock-screen updates are wanted on every device.

`readEligibleDevices` is called twice (the cheap pre-debounce exit and the real read after the sleep); both go through the same function, so both apply the rule.

## App side

- `NotificationRegistrationFile`: `settingForegroundUntil(_ date: Date?, forDeviceToken:)` — sets the field (ISO 8601 with fractional seconds off, `Z`) or removes it when `nil`; no-op returning `self` when the device has no entry; preserves every other field of the entry and every other entry. A `foregroundUntil(token:) -> Date?` reader for tests.
- `NotificationRegistrationCeremony`: `setForegroundLease(until: Date?, deviceToken:, over:)` mirroring `setLiveActivityPinnedPaneIDs`: read, apply, write only if changed; absent file or unregistered device is a no-op.
- `NotificationPreferencesStore`:
  - constants `foregroundLease: Duration = .seconds(180)`, `foregroundRefreshInterval: Duration = .seconds(60)`; both injectable through `init` for tests (default values above).
  - observe `UIApplication.didEnterBackgroundNotification` beside the existing `didBecomeActiveNotification` observer, through the same injected `NotificationCenter` (`foregroundCenter`), so tests post both names.
  - on `appDidBecomeActive()` (after the existing refresh + re-register): write the lease (`now + foregroundLease`) to every Host whose state is `.idle` with `isRegistered == true`, in a task group, each in its own `withNotificationTransport`; failures are logged at info and otherwise ignored (no registration note; this is best effort). Then start a refresh loop (`Task` with `Task.sleep(for: foregroundRefreshInterval)`) that rewrites the lease the same way until cancelled.
  - on `appDidEnterBackground()`: cancel the loop, then clear the lease (`nil`) on the same set of Hosts. Wrap the clear in a `UIApplication.shared.beginBackgroundTask` / `endBackgroundTask` pair so iOS gives the SFTP write its seconds (guard with `#if !targetEnvironment(macCatalyst)` only if the compiler needs it; there is no Catalyst build).
  - A Host that is registered *after* the app became active (the Settings toggle) gets its lease on the next refresh tick; no special case.
  - `deinit` removes both observers and cancels the loop.
- No UI. No change to `willPresent` or the banner store.
- `CHANGELOG.md` Unreleased: one line under the right heading: "Agent Notifications stay off a device while another device has Kelpie in the foreground."
- `plugin/README.md`: a row for `foreground_until` in the v1 table and one paragraph on the rule under the notify hook section.

## Tests

Plugin (`cd plugin && npm test`; `plugin/test/notify-hook.test.js` has the process-boundary harness with a fake relay and two devices A/B):
1. A holds a live lease (now + 120 s), both eligible: exactly one push, to A.
2. A's lease expired (now − 5 s): pushes to A and B.
3. A's lease malformed (`"soon"`) or null: pushes to both.
4. A holds a live lease but A's `notify.done` is false, B's true, event `done`: no push at all, hook exits 0, state file untouched (nothing "delivered").
5. Pruning on a 410 preserves B's `foreground_until` (extend an existing prune test or add one).

App (`Tests/HeelerTests`, Swift Testing, `@testable import Heeler`; the unit target runs on the iPad via `xcodebuild test -destination 'platform=iOS,id=09D7738D-2173-55EF-8966-A9C3EA1D0514' -only-testing:HeelerTests/<Suite>`):
1. `NotificationRegistrationFileTests`: set writes the ISO string on the right entry only; nil removes it; unknown sibling fields and other entries survive; unregistered token is a no-op.
2. `NotificationRegistrationCeremonyTests`: set/clear round trip through the scripted transport; no write when nothing changed; absent file is a no-op.
3. `NotificationPreferencesStoreTests`: with a registered Host A and an unregistered Host B, posting `didBecomeActive` writes a lease to A only, within `foregroundLease` of now; posting `didEnterBackground` removes it; with a short injected refresh interval (e.g. 50 ms) the lease is rewritten at least twice; a Host whose transport throws leaves the others written.

## Builders

- **Plugin builder**: `plugin/src/notify-hook.js`, `plugin/test/notify-hook.test.js`, `plugin/README.md`. Run `npm test` in `plugin/`. Do not touch the app or the relay.
- **App builder**: the three Swift files above, their three test files, `CHANGELOG.md`. No new Swift files (so no `xcodegen`). Build with the fixed path only (`S=~/Library/Caches/kelpie-build`, `-clonedSourcePackagesDirPath "$S/kelpie-spm" -derivedDataPath "$S/kelpie-dd"`, device id above, log to `$S/build-36.log`, read only the tail); run the three suites on the iPad with `-only-testing:HeelerTests/<Suite>` and `-resultBundlePath "$S/test-36.xcresult"` after `rm -rf` of that path. Never build in the scratchpad. Do not commit; report the files touched and the test counts.
