# Builder A report — round 33, SSH group (Open item 55)

Branch `round33-A`, worktree `$SP/wt-A`.

## Picks

1. `295644c4` feat(ssh): record failing phase and libssh2 code — picked as `a0498226`. Conflict only in `scripts/run-ci-ios-tests.sh` (package e2e count): upstream 53→56 tests, 3→4 suites; applied the delta to Kelpie's 49 → **52 tests in 4 suites**.
2. `2b340f47` fix(ssh): scope failure diagnostics to each operation — picked as `1726ebc1`. Two conflicts in `SessionDriver.swift`: (a) `readSFTPFileIfPresent` — took upstream's rescoped body (withDiagnosticPhase/withSFTPUse) and re-added Kelpie's `maximumByteCount` per-chunk cap (8a3cd63c host files); (b) a hunk whose upstream side carried `listSFTPDirectories`/`isSFTPDirectory` from upstream `a6d56523` (browse remote directories, not in Kelpie, not assigned to any builder) — dropped. `invalidate()` and the rest of the abandon path untouched. Adaptation line appended to the message.
3. `f3fafc42` fix(ssh): capture timeout diagnostics before cleanup — picked clean as `0f3de540`. After picks 1–3: HeelerSSH package `build-for-testing` (generic iOS) **TEST BUILD SUCCEEDED** (abandon test compiles).
4. `66e7b64a` feat(ssh): add RSA-SHA2 key authentication (#347) — picked as `6d0250fb`. Conflicts:
   - `HostStore.swift`: Kelpie already had a lenient catalog loader (newer version read with a notice; an undecodable Host hidden with a notice; versioned file never rewritten on read). Upstream adds per-entry decoding that keeps an unknown-authMethod Host and writes it back unchanged. Merged: every entry decodes to `.known(Host)` or `.unknown(JSONValue)`; hidden entries of **any** kind are preserved on add/update/remove (upstream's fix, widened); Kelpie's notices and never-refuse behaviour kept; legacy (v0) catalogs now always migrate in place since nothing is lost.
   - Upstream test `malformedKnownAuthHostStillMakesTheCatalogUnreadable` contradicts Kelpie's `oneUnreadableHostDoesNotTakeTheCatalogWithIt`; adapted and renamed `malformedKnownAuthHostIsHiddenAndPreserved` (no error, notice, bytes unchanged, entry survives an add).
   - `CHANGELOG.md`: only the two #347 entries taken (upstream's side also carried #305/#314 entries Kelpie does not have).
   - `run-ci-ios-tests.sh`: package e2e 56→60 upstream, so Kelpie 52 → **56 tests in 4 suites**, message "fifty-six"; SharedFixtureE2ETests 95→97 auto-merged (Kelpie was 95, delta +2).
   - `project.pbxproj`: Kelpie's side + `xcodegen generate` (adds RSAKey.swift, RSAKeyStore.swift).
   - ADR: upstream's `docs/adr/0017-rsa-sha2-key-authentication.md` collides in number with Kelpie's `0017-herdr-client-is-the-screen.md`; kept upstream's filename (Kelpie already has a 0016 collision the same way) so later picks referencing it apply. Orchestrator may want to renumber.
   - After this pick: app + HeelerTests `build-for-testing` (generic iOS) **TEST BUILD SUCCEEDED**.
5. `95b4db57` feat(ssh): report forwarding pump failures — picked as `ed0e412f`. Only the package e2e count conflicted: upstream 60→61, Kelpie 56 → **57** (failure message updated to fifty-seven too).
6. `2c9066b5` fix(ssh): redial once when a handshake fails in key exchange — picked as `47317e9f`. CHANGELOG entry added under Unreleased/Fixed beside Kelpie's; package e2e count upstream 61→63 tests, 4→5 suites, so Kelpie 57 → **59 tests in 5 suites** (message fifty-nine); the new named-test assertion kept.
7. `d0bfd156` test(ssh): give fixture connection setup a 30s deadline — picked clean.
8. `85b0cfd2` test(ssh): write to a never-valid descriptor in the errno bridge test — picked clean.
9. `ec24d140` feat(ssh): expose the server identification string — picked clean.
10. `3b7ddf64` fix(pairing): refuse Tailscale SSH before authenticating — picked as `6f2b3b56`. Only `CHANGELOG.md` conflicted (upstream's side carried its 0.1.9/0.1.10 release sections); took Kelpie's file and added only the #358 entry under Unreleased/Fixed. Code picked clean. Note: the new message and plugin README text name `ssh_port` in `pair.json`, which arrives with builder C's plugin picks (#355 lineage), not in Kelpie yet on this branch.
11. `93377c59` ci: count the new pairing and identification e2e tests — picked as `e02f7438`. All three hunks conflicted (upstream's absolute numbers include tests from commits Kelpie lacks). Applied deltas: SharedFixtureE2ETests 97 → **99**, package e2e 59 → **60 tests in 5 suites** (message "sixty"). Adaptation line appended.

After all 11 picks: HeelerSSH package build-for-testing and app build-for-testing both **TEST BUILD SUCCEEDED** at the tip; `bash -n` on the CI script clean. Device tests running next.

## Device tests (iPad 09D7738D, at the tip `e02f7438`)

18 suites: PairingCeremonyE2ETests, PairingReachFailureTests, EnrollmentResponseTests, PairingCeremonyErrorTests, PairingScanStoreTests, HostTests, HostStoreTests, HostCredentialsProviderTests, DeviceKeyStoreTests, RSAKeyStoreTests, KeychainSecretStoreTests, DeviceKeyTests, RSAKeyTests, EventsSessionSubscriptionsTests, HostOnboardingStoreTests, HostKeyConfirmationBrokerTests, PreflightReportTests, TransportErrorPresentationTests.
Result: **Test run with 162 tests in 18 suites passed**, TEST SUCCEEDED, zero recorded issues. Skips: the whole "Pairing ceremony e2e" suite (incl. the two new tests `tailscaleSSHIsRefusedBeforePinOrAuthentication`, `silentEntrypointExitIsReportedAsUnanswered`) skips with its reason "requires localhost sshd, an authorized Ed25519 test key, node, and the plugin checkout" — CI covers it. HeelerSSH package suites (incl. new KeyExchangeRetryTests, SSHDiagnosticsTests, identification test) compile only; CI runs them.

## What is left / unsure / for the orchestrator

- Nothing left: all 11 picks landed, none skipped.
- ADR number collision: upstream's `docs/adr/0017-rsa-sha2-key-authentication.md` beside Kelpie's `0017-herdr-client-is-the-screen.md` (CLAUDE.md cites ADR 0017 for the latter). Consider renumbering at integration.
- HostStore merge is a real design merge, not mechanical (see pick 4). Upstream's "malformed known-auth Host makes the catalog unreadable" was replaced by Kelpie's hole-with-notice semantics; confirm that is wanted.
- CI counts are deltas on Kelpie's numbers and unverified until CI runs: package e2e **60 tests in 5 suites**, SharedFixtureE2ETests **99**. Also `HeelerSSHTransportBehaviorE2ETests` RSA assertions added by pick 4 need the CI fixture.
- The #358 pairing message names `ssh_port`/`pair.json`, which Kelpie's plugin gains only with builder C's picks.
- Orchestrator should run the full suite on both devices; watch HostStoreTests, RSAKey*/DeviceKey*, TransportErrorPresentationTests, PreflightReportTests.
