# Robustness review — identity and durable state (round 12)

Reviewed, read-only, no builds: `Sources/Heeler/Hosts/` (Host, HostStore, HostCredentialsProvider,
HostOnboardingStore, HostListView delete path), `Sources/Heeler/Pairing/` (PairingSync — read as
current per brief, PairingSyncRecord, PairingCode, PairingCeremony, PairingScanStore,
SSHPairingConnector), `Sources/Heeler/Transport/` (SecretStore, DeviceKeyStore, KnownHostsStore,
HostKeyPolicy, HeelerSSHHostKeyVerifier, HostKeyFingerprint),
`Sources/HeelerNotificationCore/` (NotificationKeyStore, NotificationKeyMirror),
`Sources/Heeler/Notifications/NotificationPreferencesStore.swift` (RegisteredDeviceTokenLog,
reregisterChangedDevices — tonight's code, read not re-reviewed),
`Sources/Heeler/ContentView.swift` wiring, `HeelerApp.swift`, `Heeler.entitlements`, `project.yml`,
ADR 0007/0008/0017/0018, and `Tests/HeelerTests/{PairingSync,HostStore,KnownHostsStore}Tests.swift`.

Not checked: no device, no build, no test run; the HeelerSSH package internals; the plugin/relay
side of `notifications.json` pruning; whether iCloud Keychain actually propagates on Anthony's
devices; the Console/terminal settings stores beyond an inventory of their defaults keys.

## Ranked findings

| # | Severity | Conf | Where | Gap | How it fails in practice |
|---|---|---|---|---|---|
| 1 | must-fix | high | `Sources/Heeler/Pairing/PairingSync.swift:370-390` (`adoptCoordinates`) | Adopting a sibling's newer address/port/username does **not** import that record's fingerprints into the known-hosts store; only the new-Host branch (`:322-325`) does. | The mini moves to its Tailscale address. The sibling takes the new address, then has no TOFU pin for `100.65.54.52:22`. The Console's policy is `{ _ in false }` (`Console/ConsoleStore.swift:635`), so every connect fails `hostKeyRejected` with no prompt — the exact "moved Host unreachable on the second device" symptom the ADR 0018 amendment set out to fix, one step later. Recovery needs Edit Host → preflight. Fix: in `adoptCoordinates`, run the same `record.fingerprints.compactMap(PairingSyncFingerprint.init(encoded:))` → `knownHosts.setFingerprint` loop the add path uses. Files: `PairingSync.swift`, test in `Tests/HeelerTests/PairingSyncTests.swift:363`. |
| 2 | must-fix | high | `Sources/Heeler/Pairing/PairingSync.swift:216-225` + `publish` `:445-501` | Deleting a Host removes only *this* device's record. The sibling still holds the Host, so its next reconcile republishes it, and this device then adopts it back. | Delete the mini on the iPhone; next time the iPad foregrounds, the record returns, and the iPhone's next reconcile re-adds the Host, its fingerprints and its Notification Key, and re-queues a notification registration. Deletion is not durable and there is no tombstone. Fix: publish a tombstone (a record with a `deletedAt`, or a synced `deleted-hosts` item) that suppresses re-adoption on both sides, or make deletion explicitly local-only in the UI copy. Files: `PairingSync.swift`, `PairingSyncRecord.swift`, `Hosts/HostListView.swift` (copy). |
| 3 | must-fix | high | `Sources/Heeler/Hosts/HostStore.swift:98-107`; `Notifications/NotificationRegistrationCeremony.swift:67-80` | Removing a Host deletes its password and its synced record, but never its Notification Key (Keychain + app-group mirror) and never unregisters this device from the Host's `notifications.json`. | The deleted Host keeps pushing to this device; the NSE still finds the key by `kid` and decrypts, so alerts keep arriving for a Host the app no longer shows, and the key stays in the shared Keychain and in `notification-keys.json` forever. Fix: on `remove`, best-effort `NotificationRegistrationCeremony.remove(hostID:deviceToken:over:)` when the Host is reachable, and unconditionally `NotificationKeyStore.removeRecord(forHost:)` + `registeredTokens.forget(_:)`. Files: `HostStore.swift` (or the caller in `HostListView.swift`), `ContentView.swift` wiring. |
| 4 | should-fix | high | `Sources/Heeler/Pairing/PairingScanStore.swift:158-163` | Pairing always `catalog.add`s a Host with a fresh UUID; nothing looks for an existing Host at the same address/username/fingerprint. | Re-pairing the mini (after a wipe, a new Pairing Code, or just a second scan) silently creates a duplicate Host row. Both publish records, the sibling adopts both, and the Host's `notifications.json` is keyed by device token, so the second registration overwrites the first entry's key — the first Host's Live Activity and push path go dead with no message. Fix: match on the pinned fingerprint (or address+username) and offer "update the existing Host" instead of adding. |
| 5 | should-fix | medium | `Sources/Heeler/Hosts/HostCredentialsProvider.swift:28-33`; `Console/ConsoleStore.swift:632-634` | A password Host adopted from a sibling arrives with `authMethod == .password` and no password (deliberately unsynced, ADR 0018), and the Console maps `passwordNotSet` to `TransportError.authenticationFailed`. | On the second device the adopted Host reads as "authentication failed" forever, with nothing saying a password is needed — the root screen has no prompt and the hint only exists in preflight (`HostOnboardingStore.swift:74`). Fix: surface `passwordNotSet` as its own transport/presentation case with "Enter this Host's password" and a route into the Host form. |
| 6 | should-fix | medium | `Sources/Heeler/Hosts/HostStore.swift:49-53` | `guard catalog.version == Self.catalogVersion` treats a **newer** catalog as unreadable, and `catalogLoadError` then blocks every add/update/remove (`:135-139`). | A TestFlight user moving back to an older build (or any future version bump) sees an empty Host list *and* cannot add a Host to recover — the app is bricked until the newer build is reinstalled. Fix: accept `catalog.version <= catalogVersion` (decode leniently and drop unknown fields), reserving the hard failure for genuinely corrupt bytes. No test covers forward compatibility (`Tests/HeelerTests/HostStoreTests.swift`). |
| 7 | should-fix | medium | `Sources/Heeler/Pairing/PairingSync.swift:377`, `421`, `476` | Conflict resolution is last-writer-wins on wall-clock `Date()` taken independently on each device, with no skew guard and no logical counter. | A device whose clock runs ahead (or a manual date change) wins every conflict; its stale address can overwrite a sibling's correct one, and the sibling then adopts the stale value because the record is "newer". Fix: at minimum ignore records whose `updatedAt` is implausibly in the future, or carry a monotonic revision counter alongside the timestamp. |
| 8 | should-fix | medium | `Sources/Heeler/Transport/KnownHostsStore.swift:117-119` | `storedValues()` is `defaults.dictionary(...) as? [String: String] ?? [:]`; a single non-string value makes the whole TOFU database read as empty, and the next `setFingerprint` writes that empty dictionary back. | One bad entry silently discards every trusted fingerprint; because the Console never prompts, every Host then fails `hostKeyRejected` and the user has to re-confirm each one through preflight. Fix: filter element-wise (`compactMapValues { $0 as? String }`) rather than casting the whole dictionary, and never overwrite on a failed read. |
| 9 | should-fix | low | `Sources/Heeler/Pairing/PairingSync.swift:525-536` (`withdraw`) | Withdrawal only deletes accounts listed in the local `kelpie.pairing-sync.published` default. | After a reinstall (UserDefaults gone, iCloud Keychain items intact) turning the sync setting off deletes nothing: the records stay in iCloud and keep feeding siblings. Fix: withdraw by enumerating `records.readAll()` for Hosts this device holds, not by the local ledger. |
| 10 | nit | high | `HostStore.swift:98-107`, reinstall path | On reinstall the Keychain keeps `host-password-<uuid>` and `dev.bybee.heeler.notifications/<uuid>` items whose Host UUIDs no longer exist anywhere; nothing ever sweeps them. | Dead secrets accumulate silently. Fix: a launch sweep that deletes secret accounts with no matching Host id (after the pairing-sync adopt, so it cannot race adoption). |
| 11 | nit | medium | `ContentView.swift:236-243` vs `:148-152` | The pairing-sync adopt `.task` and the `console.setHosts`/`console.resume()` `.task` start concurrently; the "Adopt before anything else needs the catalog" comment is not enforced by ordering. | Harmless today (the `onChange(of: hostStore.hosts)` re-feeds the Console after adoption), but it is a load-bearing comment with nothing holding it up. |
| 12 | nit | medium | `Sources/Heeler/Hosts/HostOnboardingStore.swift:131-137` | `trustPresentedHostKey` writes the presented algorithm's entry but leaves any entry stored under the *old* algorithm for the same endpoint. | A stale pin lingers; if the server ever negotiates the old algorithm again the connection fails `hostKeyMismatch` against a key the user already replaced. |
| 13 | nit | low | `Sources/Heeler/Hosts/Host.swift:93-97` | `Host.init(from:)` throws on an invalid `sessionName`, and `HostStore`'s decode is all-or-nothing. | One bad Host takes the whole catalog to `catalogUnreadable` (which then blocks writes). Decoding per-element and skipping the bad one would be safer. |

## Lens notes (coverage, nothing further to flag)

- **Secrets hygiene:** clean. The Bootstrap seed stays in memory (`PairingCode.Bootstrap`, never
  written); `PairingSync.logOnce` logs only a failure kind and the error description; only two
  `privacy: .public` interpolations exist in the app and neither carries key material; the
  app-group mirror is `completeFileProtectionUntilFirstUserAuthentication` + excluded from backup,
  matching the Keychain class of the items it mirrors.
- **Keychain split:** device-only items are `AfterFirstUnlockThisDeviceOnly`, synced ones
  `AfterFirstUnlock`; `baseQuery` carries the `synchronizable` flag on every read, write **and**
  delete, so the two halves cannot cross. Entitlements need no `keychain-access-groups` —
  `group.TME.Kelpie.shared` is implicitly a Keychain access group on iOS. Correct as written.
- **Concurrency:** `UserDefaultsKnownHostsStore` is an actor with a shared instance, so concurrent
  first-connects cannot lose each other's writes; `HostStore` and `PairingSync` are `@MainActor`
  and the re-entrancy guard + per-pass stamp re-read (`reconcile()` / `runReconcile()`) closes the
  interleaving hole. No lost-write path found beyond finding 8.
- **Migration:** `Host` decodes absent fields with defaults and drops `socatPath`;
  `PairingSyncRecord` versions its schema and skips unknown ones; `NotificationKeyStore`/
  `NotificationKeyMirror` both gate on `v == 1`. Only `HostStore`'s equality check on
  `catalogVersion` is a forward-compat trap (finding 6).
- **Test gaps:** no test for (a) a sibling resurrecting a deleted Host, (b) fingerprints arriving
  with adopted coordinates, (c) an adopted password Host, (d) a newer-than-current catalog version,
  (e) a corrupt `knownHostFingerprints` dictionary, (f) clock skew between devices.
