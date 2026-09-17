# Review — Open item 42 (token-change entry replace + BadDeviceToken prune)

Reviewed: `git diff` over `Sources/Heeler/Notifications`, `Tests/HeelerTests`, `plugin/`, `docs/adr/0008`, `CHANGELOG.md`, plus surrounding code in `NotificationPreferencesStore.swift`, `NotificationRegistrationCeremony.swift`, `Sources/Heeler/Pairing/PairingSync.swift` and read-only `relay/src/worker.js`.

## Verdict

The mechanism is right on both sides. No must-fix. Four findings, ranked.

## Findings

### 1. should — `docs/adr/0008-...md:13` (behaviour, not only prose)
The env paragraph still states that a `400 BadDeviceToken` means "nothing is pruned … and the (token, env) pair looks self-consistent to the re-registration sweep". That is now false in a way that matters: with the plugin change, an entry whose `env` disagrees with its token (or any other APNs-side false BadDeviceToken) is deleted from `notifications.json`, while the app's `RegisteredDeviceTokenLog` still records the same pair — and `reregisterIfPairChanged` is gated on `guard last != token` (`NotificationPreferencesStore.swift:617`). So the entry is not rewritten by the launch sweep and the device goes silently unregistered until the user toggles it. Before this change the mismatch was at least visible through the env read-back the same paragraph describes. Either the ADR should record the trade-off explicitly, or the sweep should also re-register when the confirmed file has no entry for this token. Confidence: medium-high on the mechanism, medium on how often a false BadDeviceToken occurs in practice.

### 2. should — `Sources/Heeler/Notifications/NotificationPreferencesStore.swift:658-660`, `:613`
Load-bearing rationale comments now contradict the code this round shipped: ":658 that dead entry is left for the plugin to prune on the first APNs `410`" (it is now dropped by `replacing:` in the same write) and ":613 a dead entry sits on the Host drawing `400`s that prune nothing" (400 BadDeviceToken now prunes). Both are exactly the comments a future reader would trust. Confidence: high.

### 3. should — `NotificationPreferencesStore.swift:486` (disable branch of `setNotificationsEnabled`)
The disable path calls `ceremony.remove(deviceToken: token)`, which matches only the **current** token, and then `registeredTokens.forget(host.id)` (`:571`) clears `last`. If an install's token changed and the sweep never reached that Host, disabling notifications removes the live entry, forgets the previous token, and the dead entry becomes unreachable by any later enable — the same leak Open item 42 is closing, through the other door. Passing `last` into `remove` (or removing both tokens) closes it. Confidence: medium-high.

### 4. nit — `Sources/Heeler/Pairing/PairingSync.swift:787`
`registerIfNeeded` is the one `ceremony.register` call site that does not pass `replacing:`. Safe today — `hostWasRemoved`/`forget` call `registeredTokens.forget` (`:400`), so an adopted Host has no recorded pair — but it is a divergence worth a comment or the parameter.

### 5. nit — `NotificationPreferencesStore.swift:380`
"A `400` would then keep coming back, never the `410` that prunes" now reads oddly next to a 400 path that does prune.

### 6. nit — `CHANGELOG.md:72-77`
Under `Unreleased` correctly, reads well, and is accurate about the plugin half. The app half (a token change no longer leaves a dead entry on the Host) is user-visible too and is not mentioned.

## Checked and clean

- **Sibling-device deletion (brief item 1): no risk.** `RegisteredDeviceTokenLog` is plain `UserDefaults` keyed by Host UUID (`NotificationPreferencesStore.swift:26-70`) and is written only with this install's own `deviceToken()` — the two write sites are `NotificationPreferencesStore.swift:569/645` and `PairingSync.swift:800`. Pairing sync publishes Host records, tombstones and the Device Key through its own synced slots; it never publishes the `kelpie.notifications.last-registered-device` defaults key. `last` can therefore never be another device's token.
- **Env-only change (brief item 2):** hex stays equal, and `upserting(_:replacing:)`'s `previousToken != entry.token.hex` guard makes it a plain upsert — the current entry is never removed. After a Host removal or a disable, `forget` clears the record, so `last` cannot be stale in a way that deletes a live entry.
- **`remove(...)` (item 3):** unchanged, still keys off the current token's hex; `containsDevice` guard intact.
- **Swift 6 / style (item 4):** no new concurrency surface (`String?` / `APNSDeviceToken?` parameters, `Sendable` struct unchanged), no force unwraps, tests use the existing raw-string fixture style and assert the additive-field preservation the file contract promises. Old `upserting(_:)` retained as a delegating overload, so existing call sites are unaffected.
- **Plugin (item 5): correct, including the activity scope.** Both hooks parse the body inside `try/catch` and require `reason === "BadDeviceToken"`. The relay's own validation refusals are `json(400, { error })` (`relay/src/worker.js:286, 305, 318`) with no `reason`, and its APNs passthrough sets `reason: null` when the APNs body is not JSON (`:379-386`) — neither prunes, and `notify-hook.test.js` covers the relay-origin 400 explicitly. The activity push sends `live.token` (`plugin/src/activity-hook.js:91`), i.e. the Live Activity push token, so an APNs BadDeviceToken there rejects the *activity* token, not the device token: deleting only `live_activity` is the right scope, and treating it as a dead device token would be wrong.
- `node --test plugin/test/notify-hook.test.js plugin/test/activity-hook.test.js` — 49 pass, 0 fail.

## Not checked

- No Swift compile or test run (device-only suite; not run from this review).
- No live APNs/relay verification of the 400 body shape; reasoned from `relay/src/worker.js` only.
