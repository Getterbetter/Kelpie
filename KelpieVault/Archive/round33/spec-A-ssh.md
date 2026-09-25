# Builder A — the SSH group (Open item 55)

Letter: **A**. Read `spec-common.md` first; it governs worktree, build lock, paths and reporting.

Pick these from `upstream/main`, in this order:

1. `295644c4` feat(ssh): record failing phase and libssh2 code for diagnostics refs #343
2. `2b340f47` fix(ssh): scope failure diagnostics to each operation refs #343 (large: SessionDriver)
3. `f3fafc42` fix(ssh): capture timeout diagnostics before cleanup refs #343
4. `66e7b64a` feat(ssh): add RSA-SHA2 key authentication (#347) (touches `Sources/Heeler/Hosts/HostStore.swift` and the project)
5. `95b4db57` feat(ssh): report forwarding pump failures and the Jump target refs #351
6. `2c9066b5` fix(ssh): redial once when a handshake fails in key exchange
7. `6b2e8e52` test(ssh): give fixture connection setup a 30s deadline
8. `08d8a7b6` test(ssh): write to a never-valid descriptor in the errno bridge test
9. `4b7778d0` feat(ssh): expose the server identification string
10. `3b7ddf64` fix(pairing): refuse Tailscale SSH before authenticating (app pairing code + tests + plugin README)
11. `93377c59` ci: count the new pairing and identification e2e tests

Kelpie's own changes in this area, which must survive every resolution:

- `90fc39a3` TCP keepalive on the SSH socket (SSH package) and the one `kelpie.primary-host` constant.
- `19277ce8` the Tailscale hang fix: a dead transport is **abandoned** instead of awaiting its close (`SessionDriver.acquireOperation()` / abandon path in the package; `abandonReturnsWhileTheOperationMutexIsHeld` test). Upstream's diagnostics rewrite of `SessionDriver` (2b340f47) is the biggest risk here: keep the abandon path working and its test compiling.
- `8a3cd63c` Mac-vs-iPad gaps (host files etc.) touched the package too.

Checks: the app and test target compile (`build-for-testing`, generic iOS), the HeelerSSH package test target compiles (it cannot run here; CI runs it), and on the iPad run the app suites the picks touch or add: at least `PairingCeremonyTests`, `PairingScanStoreTests`, and any `HostStore`/key-related suite 66e7b64a changes (find them with `git show --stat`). `PairingCeremonyE2ETests` needs a real sshd and will skip or be gated on the device; say which.

If you reach about 70 tool calls with picks left, stop cleanly after the current pick, write the report with the exact next sha, and end; the orchestrator will continue you.
