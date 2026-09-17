# Open item 19 — no in-app banner on the root screen

## Cause: candidate (b), the preference gate

`AgentNotificationBannerStore.present(_:status:)` drops every held transition at

- `Sources/Heeler/Notifications/AgentNotificationBannerStore.swift:190-192`
  `guard let notify = triggers(agent.hostID), status == .done ? notify.done : notify.blocked else { return }`

`triggers` is wired to `NotificationPreferencesStore.confirmedTriggers(for:)`:

- `Sources/Heeler/HeelerAppModel.swift:91-94`
- `Sources/Heeler/Notifications/NotificationPreferencesStore.swift:696-709`
  ```swift
  guard let settings = confirmedSettings(for: hostID), settings.isRegistered else { return nil }
  ```
  `confirmedSettings` is nil for `.loading`, `.unavailable`, `.updating` and for a Host never loaded.

`isRegistered` is computed in `load(_:)`:

- `NotificationPreferencesStore.swift:516-521` — no APNs device token at all ⇒ `.unavailable` ⇒ gate nil.
- `NotificationPreferencesStore.swift:527-533` — `isRegistered: preferences != nil`, where
  `preferences = file.preferences(token: token.hex)`, and
  `NotificationRegistrationFile.preferences(token:)` (`NotificationRegistrationFile.swift:278-285`)
  matches an entry **by this device's current APNs token string**.

So the purely local, foreground-only in-app banner is gated on *this device's current
APNs token having a live entry in the Host's remote `notifications.json`*. It needs
none of that: no token, no Notification Key, no Host-side entry, no network.

This matches Anthony's own field evidence in Open item 19: the mini's
`~/.config/herdr/plugins/config/heeler/notifications.json` held one entry written
2026-09-11 with `env: sandbox`, the iPad then moved to TestFlight build 2 (a
**different** APNs token, production), and the file never changed. From that moment
`preferences(token:)` returned nil ⇒ `isRegistered == false` ⇒ `confirmedTriggers`
nil ⇒ every Blocked/Done was swallowed at the gate, on the root screen and behind
the Console cover alike. The iPhone, which "has no entry", was silent for the same
reason from the start.

The fail-closed comment says it mirrors "the plugin's missing-flag semantics". It
does not. The plugin (`plugin/src/notify-hook.js:101`) iterates the entries the file
holds and checks `entry.notify?.[flag] !== true` — a *per-flag* check inside an
existing entry. A device with no entry gets no push because the plugin has no key to
encrypt to: an addressing limit, not a user preference. The app copied the addressing
limit onto a surface that has no addressing problem.

## Fix

`confirmedTriggers(for:)` exists solely for this gate (its only caller is
`HeelerAppModel.swift:91`). It now mirrors the plugin's real semantics:

- an entry for this device exists ⇒ honour its flags (unchanged; an off flag still
  silences, `aDisabledDoneFlagSkipsDoneButKeepsBlocked` still holds);
- no entry for this token, an unreadable file, a read in flight, or no push
  registration on this device ⇒ both triggers on, because the local banner needs
  none of that.

It therefore never returns nil in practice; the optional and the store's
fail-closed branch stay, so an injected nil (a future caller, the existing
`unknownPreferencesFailClosed` test) still behaves as before.

One `Self.log.info` line records the fallback, so a device log names the Host that
had no confirmed entry.

## Ruled out

- **(a) the Agent list not refreshing while the client owns the screen.** The client's
  Attach and the events session share one `EventsSession` per Host
  (`HostConsoleProjection.terminalRunner()` line 212-227 calls
  `session.withTerminalTransport`; RPC uses `session.withTransport` on the same
  session). `HeelerAppModel.start()` calls `console.resume()` unconditionally
  (`HeelerAppModel.swift:155-160`) and `observe({ console.agents })`
  (`HeelerAppModel.swift:238-241`) feeds the store regardless of which screen is up;
  nothing in `HerdrClientRootView` suspends the Console. `pane.agent_status_changed`
  still lands in `HostConsoleProjection.applyStatusChange` (line 750) → `publish()`.
- **(c) the hold cancelled by a cleared snapshot.** Real but not the cause here: it
  needs a reconnect inside the 3 s window, and it would be intermittent rather than
  total. See "left undone" below.
- **(d) presented-Agent suppression.** `AgentSceneDirectory.keyScenePresentedAgent`
  (`AgentSceneDirectory.swift:304-309`) reads `router.path.last ?? pendingTarget?.agentID`,
  and Kelpie restores no route at launch (`ContentView.swift:160-175`), so it is nil on
  the root screen; `shouldSuppressBanner` returns false for a nil presented Agent
  (`AgentNotificationRouting.swift:38-42`).

## Left undone (worth an Open item)

A status change that starts a 3 s hold and is followed, inside that window, by a
connection drop loses the banner permanently: `EventsSession` status ≠ `.connected`
calls `HostConsoleProjection.invalidateSnapshot()` (line 636-648) which empties
`agentsByPane`, the empty list reaches `agentsDidChange` and hits `cancelHold(for:)`
(`AgentNotificationBannerStore.swift:115-121`), and when the snapshot returns the
status equals the preserved baseline, so `guard status != previous` skips it
(line 125). Out of scope for this fix; it is not what made the banner *never* appear.
