# Review A — round 33, SSH cherry-picks (e7eb9b57..86e8a126)

Fresh-context reviewer, read-only. No builds or tests run (another build held the lock); everything below is from reading the diffs and the tree at `86e8a126`.

## Checked and sound

1. **Kelpie's package behaviour survived.**
   - `Packages/HeelerSSH/Sources/HeelerSSH/SessionDriver.swift` at the tip equals upstream's file at `4b7778d0` plus Kelpie's `maximumByteCount` per-chunk cap (lines 1307, 1331-1333) and minus upstream-only `readSFTPFileRange`, `seekSFTPFileToStart`, `listSFTPDirectories`, `openSFTPDirIfPresent`, `readSFTPDirEntry` and `isSFTPDirectory`. None of these existed in Kelpie before the round (`git show e7eb9b57^:…SessionDriver.swift` has none of them), so the round drops nothing of Kelpie's.
   - The cap sits inside the new `withDiagnosticPhase`/`withSFTPUse` body. `responseTooLarge` still reaches the caller unchanged, because `normalize` passes an `SSHError` straight through. `SSHSFTPClient.swift:59-65` still passes the cap in.
   - The abandon path works. `SSHConnection.abandon()` (`SSHConnection.swift:427-431`) calls `driver.invalidate()`. That runs `invalidateResources()` (`SessionDriver.swift:2026`, `4634`), which never takes `acquireOperation()`. Upstream's diagnostics rewrite added only `sftpUses`/`oneShotChannels` clearing there, plus a `recordWait` in `acquireOperation`, and neither blocks. The test `abandonReturnsWhileTheOperationMutexIsHeld` (`SessionDriverE2ETests.swift:1695`) is unchanged, and its hooks `holdNextExecChannelAllocationForTesting` and `operationWaiterCountForTesting` still exist.
   - TCP keepalive: `SocketConnector.swift:166` is the only Kelpie diff against upstream in that file.
2. **The redial (`3c4b2722`) cannot leak or double-dial.**
   - Direct `connect`: each failed attempt's `handshake` runs `invalidateResources()` in its catch (`SessionDriver.swift:237-239`), so the first socket is closed before the second dial.
   - Each attempt goes through `SocketConnector.connect`, so keepalive is applied to every socket.
   - Both attempts share one deadline, and there are at most 2 attempts.
   - The retry only fires when the failure is `LIBSSH2_ERROR_KEY_EXCHANGE_FAILURE`, so a cancellation or timeout does not redial.
   - Abandon cannot race it, because no `SSHConnection` exists until the handshake returns.
   - Through a Jump Host, the target driver is invalidated and the forwarding transport aborted before the redial.
4. **The dropped `listSFTPDirectories` hunk leaves nothing behind.** `git grep` finds no `listSFTPDirectories`, `isSFTPDirectory`, `readSFTPFileRange` or `listDirectories` anywhere in the tree.

3. **The `HostStore` merge (`f40b80f3`) is correct.**
   - `Sources/Heeler/Hosts/HostStore.swift` changes the Host list in only three places: `add`, `update` and `remove`. Each keeps `catalogEntries` in step. `persist()` writes `catalogEntries`, including the hidden `.unknown` entries in their original order and as their original JSON.
   - No readable Host is lost or duplicated on save. Before this round, Kelpie dropped a hidden Host at the first save, so this is strictly better.
   - Legacy (v0) migration now always rewrites the file, but it carries every hidden entry, so nothing is lost.
   - `malformedKnownAuthHostIsHiddenAndPreserved` (`Tests/HeelerTests/HostStoreTests.swift:185`) tests the right thing for Kelpie's rules:
     - no `catalogUnreadable`, a notice, and the stored bytes untouched on read;
     - after an `add`, the malformed entry (`"port":"twenty-two"`) is still first and there are two entries.
   - `unknownAuthMethodSkipsOnlyThatHost` and `legacyCatalogMigrationPreservesAnUnknownAuthHost` cover order and field preservation across add, update and remove.
5. **The shared-fixture CI count (`SharedFixtureE2ETests 99 6 0`) is right.** A per-struct `@Test` count gives HeelerSSHPTY 3 + JumpHostGate 8 + TransportBehavior 59 + ImageStaging 8 + WeakNetwork 8 + PairingCeremony 13 = 99. `HeelerSSHDirectStreamLocalE2ETests 9` also matches. The package count is wrong: see M1.
6. **The Tailscale refusal and server identification are sound.**
   - The code picked clean onto Kelpie's `SSHPairingConnector`. The refusal happens before the Host Key is compared and before authentication, and only on the Bootstrap path (`refusingTailscaleSSH: true`). The config-only path does not refuse, which is upstream's choice.
   - `serverIdentification` is read after a successful handshake, and the redial path carries it for both direct and Jump connections.
   - `PairingScanStore` covers both new cases, `.tailscaleSSH` and `.enrollmentUnanswered`. No other `switch` over `PairingCeremonyError` exists in `Sources`.
   - The failure message names `ssh_port` in `pair.json`. That key exists at HEAD (`plugin/src/pairing-config.js`, `plugin/README.md:118`), since builder C's picks.
7. **Concurrency, force unwraps and secrets are clean.**
   - The round's added lines contain no `try!`, `as!`, force unwrap, `nonisolated(unsafe)` or `@unchecked` in `Sources` or in the package `Sources`. `RSAKey` and `RSAKeyStore` are `Sendable`.
   - Diagnostics phases name the operation, host:port, socket path and channel/file ids. They never name exec commands, SFTP paths, usernames, passwords or key blobs. libssh2's `last_error` text carries no key material.
   - The one command-bearing note, `HeelerSSHTransport.swift:2046` ("Host command budget … expired: \(command)"), is reached only by `runHostCommand`. Its callers pass session list, agent discovery and skill probe commands, none of which carry a secret.
   - `SSHDiagnostics.note` is a no-op unless a sink is registered, and only `Tests/HeelerTests/Support/RealSSHFixture.swift:56` registers one. The app registers none.
   - `RSAKeyStore` uses the same Keychain service as `DeviceKeyStore` (`dev.bybee.heeler.ssh`).

## Findings

### Must-fix

**M1. `scripts/run-ci-ios-tests.sh:1954` (and the message at `:2051`): the package e2e lane asserts `60 tests in 5 suites`, but the tree has 61.** Confidence: high.

- Why the base was wrong: upstream's number always equals its raw `@Test` count in `Packages/HeelerSSH/Tests` (49 = 49 at `b384847`; 65 = 65 at `93377c59`). Kelpie's `19277ce8` added `abandonReturnsWhileTheOperationMutexIsHeld` (+1, raw 50) but left the assertion at 49. The builder applied upstream's deltas (+3, +4, +1, +2, +1) to that stale 49 and got 60. The tip's raw count is 61: 2+1+4+2+2+6+1+2+3+3+35 across the 11 test files, 5 `@Suite`s.
- Failure: the first CI run of the package lane prints `Test run with 61 tests in 5 suites passed`. The exact `grep -q` then fails the job, reporting that the suites "did not execute all sixty tests". This was already latent (49 against 50) because the lane had not run since `19277ce8` (Decisions.md: "unexecuted until a push").
- Fix: `Test run with 61 tests in 5 suites passed` and "sixty-one" in the message.
- Not run: counted from source, not from a run. The suite-level `.enabled(if:)` gates are fixture-driven and all satisfied in CI.

### Should-fix

None.

### Nit / optional

- **N1. `HostStore.swift:168-170`: the newer-catalog notice now overstates the loss.** It still says "Anything that version added is not shown here, and saving a Host drops it." Since the merge, a hidden Host is written back and survives. Only new fields on Hosts this build *can* read, and unknown top-level keys, are dropped on save. Suggested wording: "…saving a Host here drops the details it added."
- **N2. `HostStore.swift` (design): a hidden entry can never be cleared from the app.** It is not in `hosts`, so it cannot be removed, and the "One saved Host could not be read" notice now shows on every launch for good. Before this round the first save dropped it. This is fine for a newer build's Host, but a truly corrupt entry (the malformed-port case the test uses) has no way out short of reinstalling. Consider a "Discard unreadable Hosts" action on the notice, if that ever matters in practice.
- **N3. `HostStore.swift:209-214`: `update` changes `hosts[index]` before the `catalogEntries` lookup that can throw.** On that throw, memory and disk disagree. It cannot happen while the two lists stay in step, but reordering (look up the entry first) makes it airtight.
- **N4. `SSHConnection.swift:120-124` (upstream behaviour, not Kelpie's): if the second `openDirectTCPIP` fails during a Jump redial, the throw leaves the loop without the `close()` that the handshake-failure branch does.** The first attempt behaved the same before the round. The Jump connection belongs to the caller, so this is not a leak unless a caller relies on `connect(via:)` closing it on every failure. I did not trace the callers.

## Not checked

- Nothing was built or run. The builder's report says both package and app `build-for-testing` succeeded, and 162 tests passed on the iPad.
- `HostFormView`, `HostOnboardingView` and `Preflight` UI changes for RSA were not read line by line. They picked with only the conflicts listed in report-A.
- The `KeyExchangeRetryTests`/`SSHDiagnosticsTests` bodies were not read. CI runs them.
