# Fresh-context review — 2026-09-17

## Must-fix

1. **`Sources/Heeler/Notifications/NotificationPreferencesStore.swift:717`** — the fallback also fires for a Host whose
   "Notifications" toggle the user turned **off**. `setNotificationsEnabled(false, …)` (same file, 470–492) removes the
   entry and stores `HostSettings(isRegistered: false, notify: …)`; the state is `.idle`, so the new `guard … else`
   branch returns `NotificationTriggerPreferences()` (both on) and the banner announces Blocked/Done on a Host the user
   explicitly silenced. `Sources/Heeler/Settings/NotificationSettingsView.swift:164-173` is the toggle, bound to
   `settings.isRegistered`. The store already has the discriminator it needs: `flagsToCarry` (≈655-672) treats a
   surviving Notification Key as "the user last chose on", because `ceremony.remove` deletes that key on an explicit
   off. Same signal would separate "user said no" from "token changed / never registered". Confidence: high (read the
   toggle, the writer and the gate; not device-confirmed).

## Should-fix

2. **`NotificationPreferencesStore.swift:717`** — the log line fires on *every* banner evaluation for an unregistered
   Host (the gate is per status transition per Agent), not once per state change. `Logger.info` is cheap, but a device
   trace on a multi-Agent Host will be mostly this line. Confidence: high.

## Nits

3. `Packages/HeelerSSH/Sources/HeelerSSH/SocketConnector.swift:161-167` — every other syscall in `connect(to:…)` goes
   through the injected `Operations` seam; `applyKeepaliveIgnoringFailure` calls `setsockopt` directly on the raw fd, so
   a fake `Operations` in a unit test has a real `setsockopt` run against whatever integer it returned from
   `makeSocket`. Harmless (failures are swallowed) but it is the one unmockable call in that function.
4. `Sources/Heeler/Terminal/TerminalKeyBar.swift:236-247` — there are no `TerminalKeyBar` tests in the repo at all, so
   the "hidden in Console / hidden while the composer is off" rule is untested. Pre-existing gap, not a regression.
5. `Sources/Heeler/Terminal/TerminalComposer.swift:262` — after a soft newline the remote buffer holds earlier prompt
   lines while `mirror.committed` is `""`; `deleteBackwardOnEmptyField` will then take a character off the *previous*
   line. That matches the documented intent ("a character typed before the composer was on"), so noting only.

## Checked and sound

- **Piece 1 diagnosis**: confirmed. `confirmedSettings` (730-737) yields nil for `.loading/.unavailable/.updating`, and
  `load` sets `isRegistered: preferences != nil` from `NotificationRegistrationFile.preferences(token:)` (≈529), so a
  token change drops the entry match and the old `guard … settings.isRegistered` returned nil, which the banner gate
  (`AgentNotificationBannerStore.swift:194-196`) fails closed on. The sole caller is `HeelerAppModel.swift:90-94`.
- Another *device's* entry cannot silence this device: `preferences(token:)` is keyed on this device's token only.
- Concurrency: store and banner store are both `@MainActor @Observable`; the `triggers` closure captures the store
  weakly; `Logger` is `Sendable`. No new isolation crossing.
- Piece 1 tests assert real behaviour; the reinstall test now asserts `states[host.id]`, which is still a true claim.
- **Piece 2 constraints**: `leadingDividerAfterSoftNewline` / `leadingDividerAfterComposer` are both created deactivated
  and neither is in the `NSLayoutConstraint.activate` block; `refreshComposerKey()` runs from `init` (line 173) and from
  the toggle action (468), and always deactivates both before activating exactly one. No double-active, no dangling.
- `softNewlineKey?.isHidden = state != true` hides it for `nil` (Console) and `false` (composer off) alike.
- `softNewlineFromKeyBar` mirrors `submit`: `isActive` + field guard, `mirror.update(to:)` before the escape, field
  cleared, placeholder and intrinsic size refreshed. `keyBarDidPressSoftNewline` gates on `isLocalInputEnabled`, like
  `keyBar(_:didType:)`; no sticky-modifier path. Composer tests assert observable state, and the new field suite is
  `@MainActor`.
- **Piece 3**: Darwin levels/names are right (`SOL_SOCKET`/`SO_KEEPALIVE`, `IPPROTO_TCP` + `TCP_KEEPALIVE` idle seconds,
  `TCP_KEEPINTVL` seconds, `TCP_KEEPCNT` probes); `socklen_t(MemoryLayout<Int32>.size)` matches the `Int32` value;
  `errno` is read with no intervening libc call. Applied while `ownsDescriptor` is still true, before the `return`, and
  guarded to `SOCK_STREAM` + `AF_INET`/`AF_INET6` (`SocketAddress` fields are `Int32`). The wrapper catches
  `KeepaliveFailure` and a bare `error`, so nothing escapes into `connect`. The test closes its fd via `defer`
  registered after the `#require`, and a negative fd never reaches it. `PrimaryHostStore.defaultsKey` change is a
  literal-to-reference swap with the same string; `PairingSync` reads it at the same access level.

## Could not check

- No build and no device run: compilation of the new Darwin constants against the package's Swift 6 settings, and the
  actual on-device banner behaviour, are unverified.
- Whether the plugin's own prune/registration flow relies on `confirmedTriggers` anywhere outside the app (it does not
  in this repo's Swift).

## Verdict

- Piece 1 — fix first (finding 1).
- Piece 2 — ship.
- Piece 3 — ship.
