# Notification pipeline robustness review — round 12b

Scope: app (`Sources/Heeler/Notifications`, `LiveActivities`, `Client/HerdrClientRootView`,
`ContentView`, `HeelerApp`/`PushRegistrationDelegate`), `Sources/HeelerNotificationService`,
`Sources/HeelerNotificationCore`, `plugin/src`, `relay/src`. Read-only; no builds, no device.
The working-tree fix (`NotificationPreferencesStore.reregisterChangedDevices`, `PairingSync`,
`ContentView` triggers) was read for context and deliberately **not** re-reviewed.

## Ranked findings

| # | Sev | Conf | Location | Gap | How it fails in practice | Fix (one line) |
|---|-----|------|----------|-----|--------------------------|----------------|
| 1 | must-fix | high | `Sources/Heeler/Notifications/AgentNotificationCenterDelegate.swift:42` | `willPresent` returns `[]` unconditionally, on the assumption the in-app banner will fire. The two pipelines are independent and neither knows about the other. | A real, delivered push — the one piece of *proof* the whole chain works — is discarded while foregrounded. If the banner path is blocked for any of its ~6 preconditions (findings 2, 3, 7, or simply an unregistered/unreachable Host), the user gets nothing at all, which is exactly what Anthony saw in Open item 19. | Feed the decrypted push into `AgentNotificationBannerStore` from `willPresent`, or return `[.banner, .sound]` unless that pane's transition was already announced within a few seconds. Files: `AgentNotificationCenterDelegate.swift`, `AgentNotificationBannerStore.swift`, `PushRegistrationStore.swift` (delegate wiring). |
| 2 | must-fix | high | `Sources/Heeler/Console/HostConsoleProjection.swift:646` (`invalidateSnapshot`) + `Sources/Heeler/Notifications/AgentNotificationBannerStore.swift:70-84` | Every reconnect/revalidate clears `agentsByPane`, so `console.agents` drops the Host's rows; the banner store then treats the post-reconnect snapshot as "first sight is baseline, never a transition". | An agent that goes Blocked/Done while the Host's SSH link is re-establishing (iPad sleep, Wi-Fi→cellular, keepalive miss — routine on iPad) **never** banners, and finding 1 means no push surfaces either. Silent both ways. | Keep the per-pane status baseline across a snapshot invalidation and baseline only genuinely new panes — e.g. key `statuses` on `hostConnectionGenerations` rather than clearing on pane disappearance. File: `AgentNotificationBannerStore.swift`. |
| 3 | must-fix | high | `Sources/Heeler/Notifications/PushRegistrationStore.swift:108` | `refresh()` early-returns `if case .registered = state`, so `authorizationStatus()` is never re-read once a token has landed. `Tests/HeelerTests/PushRegistrationStoreTests.swift:112` (`refreshKeepsAnAlreadyCapturedToken`) enshrines this. | The user turns Kelpie's notifications off in iOS Settings; `ContentView.swift:264` dutifully calls `refresh()` on every foreground and it does nothing. Settings keeps showing the green "Ready to configure Host notifications" row, the Host entry stays armed, every push is dropped by iOS. Written-once state with no revalidation — the same class as tonight's bug. | Always read `authorizationStatus()`; drop to `.denied` when it is no longer authorized, and re-register when it returns. Files: `PushRegistrationStore.swift`, its test. |
| 4 | should-fix | med-high | `Sources/Heeler/Notifications/PushRegistrationStore.swift:14-20` | `APNSEnvironment.current` is derived from `#if DEBUG`, i.e. from the build *configuration*, not from the `aps-environment` entitlement that actually decides which APNs host the token lives on. | A Release-configuration build installed from Xcode or an ad-hoc/development profile gets a **sandbox** token and writes `env: production` into the Host file. Pushes go to the production APNs host, which answers 400 BadDeviceToken — never 410, so nothing prunes and nothing re-registers. This is tonight's failure with the polarity reversed, and the in-flight fix does not catch it because the (token, env) pair looks self-consistent. | Read `aps-environment` from the embedded provisioning profile / entitlements at runtime, falling back to the compile-time value. File: `PushRegistrationStore.swift`. |
| 5 | should-fix | high | `Sources/Heeler/Client/HerdrClientRootView.swift:233-241` | The Console cover is presented only when `notificationRouter.path` becomes non-empty. `AgentNotificationRouter.open(nil)` (`AgentNotificationRouter.swift:38-41`) sets `path = []`. | A tap on a push whose envelope does not decrypt — unknown kid, or the Notification Key lost to a reinstall/restore while the stale Host entry still pushes — opens the app onto the herdr client and does *nothing*. The router's documented contract ("falling back always means the Console, quietly") is not honoured on Kelpie's root. Same for a killed-state tap whose pane does not appear inside the 15 s grace (`AgentNotificationRouter.swift:27`) on a cold cellular launch. | Present the Console on any resolved tap, including the nil-target one — e.g. have the delegate signal "a tap happened" separately from the path. Files: `HerdrClientRootView.swift`, `AgentNotificationRouter.swift`. |
| 6 | should-fix | high | `Sources/Heeler/Settings/NotificationSettingsView.swift:114-212`, `NotificationPreferencesStore.swift:350` | Nothing on the device ever proves the pipeline works end to end. `isRegistered` means only "my token hex appears in `notifications.json`". The relay URL, the plugin's health, the herdr hook's survival and APNs' verdict are never observed from the app, and there is no "notifications are not working" state anywhere. | Tonight the evidence existed the whole time — the hook was throwing on APNs' 400 and writing it to `herdr plugin log list --plugin heeler` (`plugin/README.md:75`, `notify-hook.js:342`) — but nothing on the iPad said anything, so the failure ran for a day. Every silent-failure finding below compounds into this one. | Add a "Send a test notification" path (a plugin action or relay echo) and, cheaply, show the entry's `env` vs this build's env and the last successful registration time per Host. Files: `NotificationSettingsView.swift`, `NotificationPreferencesStore.swift`, `plugin/` (test action). |
| 7 | should-fix | med | `Sources/Heeler/Notifications/NotificationPreferencesStore.swift:155-161`; triggers at `ContentView.swift:188,214` and `NotificationSettingsView.swift:45` | `refresh()` runs only on a host-status change, a device-token change, or a Settings visit. Nothing re-reads the file on foreground or on a cadence. | The plugin prunes this device's token on a 410 (`notify-hook.js:337`) and the app never notices: `confirmedTriggers` stays `true` for hours, so the in-app banner keeps firing for a Host whose pushes are dead — the app looks healthy while it is not. Symmetrically, a flag another device changed is stale. | Also refresh (and re-register) on `scenePhase == .active`. File: `ContentView.swift`. |
| 8 | should-fix | high | `Sources/Heeler/LiveActivities/HostLiveActivityCoordinator.swift:~497` (`perform`'s `catch { return false }`); `Sources/Heeler/Pairing/PairingSync.swift:586` (`logOnce("adopted-host-registration")`) and `:680` | Both registration side-paths swallow their errors. `logOnce` additionally dedupes by kind for the process lifetime, so a repeated failure logs once and never again. | A second device that adopts a Host over iCloud and whose ceremony keeps failing (plugin absent, Host briefly unreachable) shows no entry, no error, no retry signal — the user has no way to tell it apart from working. Same for a Live Activity token that never lands. | Surface a per-Host note the way `liveActivities.reconcileNotes` already does, and let the preferences store show it. Files: `PairingSync.swift`, `HostLiveActivityCoordinator.swift`, `NotificationSettingsView.swift`. |
| 9 | should-fix | med | `Sources/Heeler/Notifications/NotificationPreferencesStore.swift:292-295` | The launch sweep requires `settings.isRegistered || last != nil`. After a reinstall or a restore-to-new-device without pairing sync, both are false (UserDefaults wiped, new token absent from the file). | The install is left permanently unregistered until the user happens to open Settings and toggle. The old entry survives indefinitely, because a wrong-env or dead token draws 400 BadDeviceToken, not the 410 the prune path depends on. | When a Notification Key record exists for a Host but no entry carries this token, treat it as "re-register me". File: `NotificationPreferencesStore.swift`. |
| 10 | nit | high | `plugin/src/notify-hook.js:80-99`, `:108-121`, `:286-309` | Every "send nothing" path (`notifications.json` absent/corrupt/foreign `v`, missing `notify` flag, zero eligible devices, malformed entry) returns silently with no log line. | The owner reading `herdr plugin log list` sees nothing at all for the most common misconfigurations, which is indistinguishable from "the hook never ran". | One `console.error` per silent-skip reason. File: `plugin/src/notify-hook.js`. |
| 11 | nit | high | `plugin/src/notify-hook.js:326-338` | `delivered` goes true if *any* device's push succeeded, and the pane's dedupe marker is then written for all. | On a two-device Host where one token is failing, that device's notification for this transition is simply lost; the marker prevents a later event for the same status from retrying it. Small, but it is the multi-device interference the brief asked about. | Track delivery per token, or only write the marker when every eligible device succeeded. File: `plugin/src/notify-hook.js`. |
| 12 | nit | high | `relay/src/worker.js:259-270` | `/push` is unauthenticated: any caller who learns the Worker URL can post arbitrary envelopes to any device token, subject only to the rate limiter. | Nuisance pushes (the extension shows the relay's generic "Kelpie / Agent update" fallback since the envelope will not decrypt). Tokens are semi-secret, so exposure is low. | A shared secret header written into `notify.json` alongside `relay_url`. Files: `relay/src/worker.js`, `plugin/src/notification-config.js`, `NotificationConfigFile.swift`. |
| 13 | nit | med | `relay/src/rate-limit.js` via `worker.js:249-251` | The fixed-window limiters are per-isolate in-memory state; Cloudflare runs many isolates. | The limits are advisory, not enforced. Fine for this deployment; worth not trusting them as a control. | Durable Object or Workers Rate Limiting binding if it ever matters. |
| 14 | nit | med | `plugin/herdr-plugin.toml`; Open item 1c | The `[[events]]` hooks are declarative so they do survive a herdr restart, and `min_herdr_version = "0.7.5"` gates the floor — but the plugin installed on the mini is upstream's (`github:ZingerLittleBee/Heeler/plugin@main`), not this repo's, and nothing on the device checks which plugin or which version is present. A herdr upgrade that changes `agent get`'s shape makes `currentAgentStatus` throw and fails closed (logged only, `notify-hook.js:172-197`). | Version skew between this repo's plugin and the installed one is invisible until notifications stop. | Have the app read and display the plugin's version during the registration probe. Files: `plugin/`, `NotificationPreferencesStore.swift`. |

## Q3 — does a finished Claude Code turn banner on the root screen today?

Traced. Every one of these must hold:

1. The primary Host's `HostConsoleProjection` is `.connected` **and has not reconnected since the
   previous status was observed** (finding 2). `ContentView.swift:148-152` keeps `console.resume()`
   running while the herdr client owns the screen, and the client's `exec herdr` is a separate
   session channel from the events subscription, so the Console list *is* live behind the cover —
   that part is sound.
2. `console.agents` shows the pane moving to `.done` (herdr emits `done`, not `idle`, for claude),
   and the previous status was already observed — not first sight.
3. The status holds 3 s (`AgentNotificationBannerStore.swift:53`).
4. `presentedAgent` is nil — true on the root screen, since `notificationRouter.path` is `[]`.
5. `notificationPreferences.confirmedTriggers(for:)` is non-nil **and** `notify.done` is true —
   which requires this device's *current* token hex to be present in the Host's
   `notifications.json` (`NotificationPreferencesStore.swift:218-221, 350-354`).

**Verdict: no, not tonight.** Condition 5 was false: per Open item 19 the mini's file held one
entry from 2026-09-11 with the iPad's pre-TestFlight token, so `preferences(token:)` returned nil,
`isRegistered` was false, and the banner failed closed — the same root cause as the missing
background pushes. The in-flight round-12b fix should therefore repair the foreground banner as
well as the background push, which is worth stating in the vault so the two are not chased
separately. After that fix, conditions 1-4 still stand as live failure modes (finding 2 especially).
Note also that the in-app banner is gated on APNs registration succeeding at all
(`NotificationPreferencesStore.swift:209-212` → `.unavailable` when `deviceToken()` is nil): a user
who declines notification permission gets no in-app banner either, which may not be intended.

## Q4 — multi-device

Correct by construction in the parts I could check: entries are keyed per device token, each device
mints or adopts its own Notification Key, `ceremony.remove` removes only the calling device's entry,
and `pruneTokens` filters by token. Two real interference points: (a) `relay_url` in `notify.json`
is Host-global and last-writer-wins across devices (`NotificationRegistrationCeremony.swift:55-61`)
— a self-builder's custom relay on one device silently re-points the other's; (b) finding 11.
`PairingSync.registerIfNeeded` registers an adopted Host with both flags on regardless of what the
sibling chose — arguably correct, worth a decision note.

## Q7 — test coverage gaps

Coverage is genuinely good (2552 lines across 14 suites; the banner store alone has 16 cases
covering hold, flap, baseline, suppression and fail-closed). Gaps that map to the findings above:

- No test that a foreground push surfaces *anything* — `willPresent` returning `[]` is asserted
  nowhere, so finding 1 is untested in both directions.
- No test of the banner store across a connection generation change / agent-list clear (finding 2).
- `PushRegistrationStoreTests.swift:112` asserts the *wrong* behaviour for finding 3; there is no
  authorization-revoked case.
- No test that a nil-target tap presents the Console (finding 5).
- Plugin: `notify-hook.test.js` covers the 410 prune path but not a 400 BadDeviceToken / wrong-env
  response, which is the shape tonight's failure actually took.
- No test pins `APNSEnvironment.current` to the entitlement rather than the build config (finding 4).

## What I could not check

- Runtime behaviour: no device, no build, no simulator (per CLAUDE.md). Every claim is from source.
- What is actually installed on the mini — plugin identity/version, `notify.json` contents,
  `herdr plugin log` output. Finding 14 rests on Open item 1c's description.
- Whether iOS keeps a `willPresent: []` notification in Notification Center (I believe not, but did
  not verify) — it does not change finding 1's severity either way.
- The relay as deployed (secrets, env vars); only `relay/src` was read.
- `Sources/Heeler/Console/ConsoleStore.swift` and `HostConsoleProjection.swift` were read only
  around the agent-list lifecycle, enough for finding 2.
