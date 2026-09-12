# Robustness review — Transport, Client, connection-owning Console

Review only; no edits, no builds, no device. Read: `Sources/Heeler/Transport/*`,
`Sources/Heeler/Client/*`, `ConsoleStore.swift`, `HostConsoleProjection.swift`,
`AttachTerminalStore.swift`, `ContentView.swift`, `AppActivityCoordinator.swift`,
`ConsoleActivityDriver.swift`, `TerminalByteFeed.swift`, `TerminalStatusDialog.swift`,
`Packages/HeelerSSH/Sources/HeelerSSH/SSHConnection.swift` (API surface only),
`Tests/HeelerTests/` file listing. ADRs 0011/0016/0017 and CLAUDE.md's herdr facts
were read as the spec.

## Verdict

The transport layer itself is the strongest part of the app: `EventsSession`,
`SSHChannelAdmission`, `SharedAsyncOperation`, `AsyncDeadline` and the attach
output gate are unusually careful — generation-pinned reconnect, FIFO
cancellation-safe waiter queues, bounded buffers with drop markers, the
`dropSnapshotSubscriptions` rule honoured on every disconnect path, `id: ""`
handled in `HerdrWire.decodeResult`, subscription sets sorted so resync cannot
churn. It is not "quickly put together". The weak seam is the layer above it —
`HerdrClientStore` / `HerdrClientRootView`, ADR 0017's newest code, which has
**no test file at all** — plus two systemic gaps: no network path monitor, and
several unbounded awaits on the teardown path that feeds a UIKit background
assertion.

## Ranked findings

### Must-fix

**M1. `Sources/Heeler/Client/HerdrClientRootView.swift:512-515` — the Host's
session name is read once at view construction and never revalidated.**
`HerdrClientHostView` is keyed `.id(host.id)` (line 154) and `Host.id` is a `let`
that survives `HostStore.update` (`Hosts/HostStore.swift:87`), so editing a Host —
changing its session name, or its address to `100.65.54.52` — does not rebuild the
view, and `HerdrClientStore.sessionName` (`HerdrClientStore.swift:24`, a `let`) keeps
its construction-time value for the life of the process.
*How it fails:* the user edits the Host to a named session (or clears it); the Client
silently keeps exec-ing `herdr --session <old>` / bare `herdr` on every reattach,
against the wrong session, until the app is relaunched. This is the same shape as the
bug the owner found tonight.
*Confidence:* high (code-level certainty; not run on device).
*Fix:* key the view on the fields the store captures, not the id —
`.id(HerdrClientIdentity(hostID: host.id, sessionName: host.sessionName))` — or make
`sessionName` a `var` on the store, push it from an `.onChange(of: host.sessionName)`
and `replaceTerminal()`. Files: `HerdrClientRootView.swift`, `HerdrClientStore.swift`.

**M2. `Sources/Heeler/Transport/EventsSession.swift:682` — `windDown()` awaits
`waitForTerminalIdle()` with no bound, and that await gates a UIKit background
assertion.**
Chain: `AppActivityCoordinator.didEnterBackground` takes the assertion →
`ConsoleActivityDriver.run` (`Support/ConsoleActivityDriver.swift:28-29`)
`await console.suspend()` then `activity.didFinishSuspending()` →
`ConsoleStore.suspend` (`ConsoleStore.swift:166`) awaits every projection's
`session.suspend()` → `deactivate()` → `windDown()` → `waitForTerminalIdle()`.
Nothing in that chain has a deadline. The terminal permit is held by
`withTerminalTransport`, whose operation is the whole attach lifetime including
`TerminalAttachSession.end()` → `readerTask.cancel(); await readerTask.value`
(`HeelerSSHTransport.swift:2374-2378`).
*How it fails:* if any link stalls (a PTY close that does not return, a libssh2 call
that ignores cancellation), `didFinishSuspending()` never runs, the assertion is
never released, and iOS kills the app for failing to end a background task — the
worst possible failure mode, because the user just sees the app gone.
*Confidence:* medium-high on the missing bound (certain from the code); medium on
whether a real stall occurs — the normal path is bounded by the 1 s PTY read timeout
and the 2 s `channel.close`.
*Fix:* wrap `waitForTerminalIdle()` (and ideally the whole `windDown`) in
`AsyncDeadline.run(for:)` with a budget well under
`AppActivityCoordinator.defaultGracePeriod` (20 s), and give
`ConsoleStore.suspend` its own overall deadline so `didFinishSuspending()` always
runs. Files: `EventsSession.swift`, `ConsoleStore.swift`.

### Should-fix

**S1. No network path monitor anywhere in the app.** `grep -r NWPathMonitor Sources
Packages` returns nothing, and `Packages/HeelerSSH` sets no TCP keepalive or socket
timeouts (`SSHConnection.isConnected` is `driver.isReusable`, a local flag, not a probe).
*How it fails:* Wi-Fi→cellular, a LAN→Tailscale address change, or a VPN toggle leaves
a socket that is dead but still "reusable". `EventsSession.ensureTransport`
(`EventsSession.swift:596-599`) reuses it; detection waits for the 30 s keepalive plus
the 15 s request timeout (`SSHTransportSettings.defaultRequestTimeout`), so the user
stares at a live-looking but frozen terminal for up to ~45 s before `.reconnecting`
even appears. The owner is about to make exactly this change (`100.65.54.52`).
*Confidence:* high on the absence; high on the latency arithmetic (it is the same
figure `AppForegroundRecoveryTests`' header derives).
*Fix:* an `NWPathMonitor` observer that, on a path change, calls
`ConsoleStore.reactivate()` (already the right entry point — it maps to
`projection.revalidate()` → `session.revalidate()`) and marks the transport suspect.
Files: a new `Support/NetworkPathObserver.swift`, wired in `ContentView.swift`
beside the `ConsoleActivityDriver` `.task`; `EventsSession.swift` for a
`markTransportSuspect()` entry point.

**S2. `Sources/Heeler/Transport/EventsSession.swift:365-368` — an Attach channel
death does not tell the session its connection is suspect.**
`withTerminalTransport`'s catch only calls `releaseTerminal()`. Nothing calls
`revalidate()`, sets `transportSuspect`, or nudges the run loop.
*How it fails:* the link drops. The attach read fails first (1 s poll) and
`AttachTerminalStore` goes `.ended("The session failed: …")` with a Reconnect button.
The events session is parked on a stream a dead socket never ends, so it stays
`.connected`; the Host still reads green in the Console. Auto-reattach only happens
when `transportGeneration` advances (`HerdrClientStore.transportGenerationDidChange`),
which needs the keepalive to notice — the 45 s of S1. Tapping Reconnect in the
meantime re-attaches over the same dead transport and fails again.
*Confidence:* high.
*Fix:* on a `.channelFailed`/`.timedOut` escape from `withTerminalTransport`, run the
`revalidate()` path (ping; on failure go down `keepaliveDidFail`).
Files: `EventsSession.swift`.

**S3. `Sources/Heeler/Client/HerdrClientStore.swift:273-279` +
`Console/TerminalStatusDialog.swift:57` — `.rejoinRequired` is a dead-end UI state.**
`abortReplacementOffStage` parks the store in `.rejoinRequired` with
`terminal.status == .stopped`. `terminalStatus` (line 74) then returns `.stopped`
verbatim, and `TerminalStatusPresentation(status:)` maps `.stopped` to `nil` — **no
overlay**. `reconnect()` (line 109) and `viewDidResize` (line 84) both guard on
`lifecycleState == .active` and silently no-op.
*How it fails:* the user sees a frozen last frame of the terminal with no spinner, no
error and no Reconnect; the menu's Reconnect does nothing. Recovery needs a
background→foreground round trip or a Console-cover cycle. Nothing proves SwiftUI
will deliver the balancing appear the comment assumes.
*Confidence:* medium (the state is reachable by construction; how often SwiftUI
produces the unbalanced disappear is unmeasured).
*Fix:* have `terminalStatus` report `.connecting` while `.rejoinRequired`, and let
`reconnect()` call `rejoin()` in that state. Files: `HerdrClientStore.swift`.

**S4. `Sources/Heeler/Client/HerdrClientRootView.swift:259-267` — presenting the
Console waits on an unbounded await with no user-visible state.**
`presentConsole()` sets `isPreparingConsole`, then
`await commands.prepareForConsole()` → `store.leave().value` →
`AttachTerminalStore.stop()` (`AttachTerminalStore.swift:347-358`), which awaits
`session.end()` and then `runTask.value`, neither bounded. `isPreparingConsole` drives
nothing in the UI.
*How it fails:* tapping "Agents", or a notification deep link, appears to do nothing
until the channel closes; if it never closes, the Console is unreachable for the
session, with no error. Same unbounded shape on `acquireTerminal()`
(`EventsSession.swift:822`) when a Host switch's new attach queues behind an old
permit that never releases — the new Client sits on "Connecting…" forever.
*Confidence:* high on the missing bound; medium on frequency.
*Fix:* deadline `prepareForConsole()` (a few seconds) and present the cover anyway on
expiry — the Agent attach already surfaces `terminalChannelAlreadyOpen` properly —
and show a progress state while `isPreparingConsole`. Files: `HerdrClientRootView.swift`,
`HerdrClientStore.swift`.

**S5. No tests exist for `HerdrClientStore` / `HerdrClientCommands` / the ADR 0017
root screen.** `grep -rl "HerdrClientStore\|prepareForConsole" Tests/` → empty, in a
136-file suite. Untested: leave/rejoin across the Console cover, Host switch while
attached, double-Reconnect, `TerminalRecoveryGenerationLatch` reconciliation,
`.rejoinRequired`, the `replacementID` races.
*How it fails:* every finding above in the Client layer is invisible to CI, and the
one-Attach-channel-per-Transport invariant has no regression guard at the layer that
actually opens and closes it.
*Confidence:* high.
*Fix:* a `HerdrClientStoreTests` driving a fake `TerminalSessionRunner`, in the shape
of the existing `AttachTerminalStoreTests` / `AgentSurfaceReplacementTests`.

### Nits / optional

- `Transport/TerminalAttach.swift:209-210, 257-275` — `.resize` entries are appended
  to `state.reliable` with no coalescing, and the reliable queue is unbounded. A
  keyboard or Split View animation enqueues one SSH window-change per frame, and a
  stalled write (up to the 15 s request timeout) lets keystrokes pile up and then
  replay in a burst. Cheap fix: replace a trailing `.resize` instead of appending,
  and cap `reliable`. Confidence high, impact low.
- `Terminal/TerminalByteFeed.swift:52-53` — `buffered` is unbounded before the first
  `attach()`. Bounded in practice because a run only starts after the view reports a
  size, but a busy herdr could buffer megabytes in the mount window. Confidence medium.
- `Console/AttachTerminalStore.swift:412-458` — `consume` iterates PTY output on the
  MainActor, so every chunk of a build log hops through the main thread. Performance,
  not correctness; would be worth an Instruments pass, not a rewrite.
- `Transport/EventsSession.swift:946-950` — `releaseTerminal`'s `while … { … return }`
  is an `if` written as a loop. Cosmetic.
- `Client/PrimaryHostStore.swift:25-30` — `host(in:)` falls back to `hosts.first`
  without persisting, so a catalog reorder can silently change which Host the root
  shows. Low impact.
- `Transport/HeelerSSHTransport.swift:1871-1893` — `withColdStartWake` retries the
  whole operation after a wake, so a worst-case RPC is 3 × `requestTimeout` (≈45 s)
  rather than the 15 s the constant advertises. Worth documenting on the constant.

## What I checked, and what I could not

Checked by reading: the reconnect/backoff loop and its generation pinning; the
`dropSnapshotSubscriptions` rule on every disconnect path (honoured in `run`'s both
failure arms and in `windDown`); subscription-set determinism
(`HostConsoleProjection.swift:848` sorts pane ids, so resync cannot churn the channel);
`id: ""` and subscribe-probe-id fallback (`HerdrWire.swift:55-79`); channel admission
budgets and lease release including the `deinit` path; cancellation safety of all four
waiter queues; every RPC's deadline coverage; the app-activity → suspend/resume →
revalidate chain; `try?`/empty-catch sweep across Client and Console (only
`Task.sleep` and one deliberate best-effort snippet read).

Could not check: anything requiring a run — no build, no device, no simulator, so
every timing claim is read off the tree rather than measured; whether libssh2 actually
returns promptly from `close`/`cancel` under a severed link (the `WeakNetworkE2ETests`
fixture covers RPCs, not the Attach teardown path); real iOS suspension behaviour
(`AppForegroundRecoveryTests`' own header says the same); `Packages/HeelerSSH`
internals below the public API, per scope.
