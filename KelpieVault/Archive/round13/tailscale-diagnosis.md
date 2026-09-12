# Root screen spins at "Connecting" off Wi-Fi (Tailscale) — diagnosis (in progress)

Commit 409eb1a, read-only.

## Established so far

1. Address is NOT stale. `ConsoleStore.setHosts` (Sources/Heeler/Console/ConsoleStore.swift:108-119)
   ends and rebuilds the projection whenever the incoming `Host` differs at all from
   `projection.host`, and it is driven from `ContentView.onChange(of: hostStore.hosts)`
   (Sources/Heeler/ContentView.swift:166-169). The session's `connect` closure captures the
   Host value handed to `startProjection`, so an edit (local or pairing-synced) produces a new
   session dialling the new address. `HerdrClientStore` re-resolves the runner per call
   (ConsoleStore.swift:308-316).
2. No interface/cellular gating anywhere in the SSH or transport layer — grep for
   `allowsCellular|requiredInterfaceType|usesInterfaceType|NWPathMonitor` hits only
   `Sources/Heeler/Transport/NetworkPathObserver.swift`. So "cellular is treated as unusable"
   is not the mechanism.
3. The indefinite spinner has a concrete mechanism (see below): the root client's attach parks
   on `EventsSession.awaitTerminalTransport()` with **no timeout and no user-visible status**
   for as long as the Host's session is in its retryable reconnect loop.

## The spinner mechanism (high confidence)

- `HerdrClientStore.terminalStatus` (Sources/Heeler/Client/HerdrClientStore.swift:102-106)
  reports `.connecting` while `isReplacing` or the pipeline is `.stopped`.
- The pipeline's run calls `runTerminal` → `ConsoleStore.terminalRunner` →
  `HostConsoleProjection.terminalRunner()` (Sources/Heeler/Console/HostConsoleProjection.swift:212)
  → `EventsSession.withTerminalTransport` (Sources/Heeler/Transport/EventsSession.swift:371-393)
  → `awaitTerminalTransport()` (EventsSession.swift:965-997).
- With no transport installed and no *recorded* failure, the caller is appended to
  `terminalTransportWaiters` and simply waits. `AttachTerminalStore.status` stays `.connecting`
  (Sources/Heeler/Console/AttachTerminalStore.swift:360-362) — spinner, no message, no Reconnect.
- Waiters are only resumed on a successful transport (EventsSession.swift:723) or failed when the
  failure is **non-retryable** (EventsSession.swift:579-584, 641-646). A retryable failure
  (`sshUnreachable`, `timedOut`) loops forever with backoff and never touches the waiters.
- So: Host unreachable-but-retryable ⇒ root screen spins forever with no diagnosis, while the
  Console cover would show `.reconnecting(attempt:…)` plus a reason. Getting back on Wi-Fi makes
  a retry succeed, the waiter resumes, and the client attaches. That matches the symptom exactly.

## Still to check
- Whether `ensureTransport` reuses a stale `isReusable` transport built on the old path.
- Whether `HeelerSSHTransport.connect` bounds the TCP/handshake, and what Preflight does
  differently (its own deadline? its own confirmation? does it pin the new address's key?).

## (1) Can `ensureTransport` reuse a transport from the old address / old path?

- Old **address**: no. A Host edit ends the whole projection and its session
  (ConsoleStore.swift:111-115), so the next `connect()` closure carries the new address.
- Old **path**: yes, structurally. `EventsSession.ensureTransport` (EventsSession.swift:688-698)
  reuses `currentTransport` whenever `!transportSuspect && await transport.isConnected`, and
  `isConnected` is not a probe — it is the driver's local `isReusable` flag
  (Packages/HeelerSSH/Sources/HeelerSSH/SSHConnection.swift:220-222), which a path change does
  not clear. The only thing that clears it is `networkPathDidChange` setting `transportSuspect`
  (EventsSession.swift:452-461), and that **returns early unless `phase == .active`**
  (EventsSession.swift:453). So a path move that happens while the app is backgrounded/suspended
  is never recorded: on resume, `activate()` (EventsSession.swift:468-479) clears
  `terminalTransportFailure`, `run` calls `ensureTransport`, the dead socket answers
  `isReusable == true`, it is handed straight to the parked attach waiter
  (EventsSession.swift:723-727), and `openPTY` then sits on a dead connection
  (HeelerSSHTransport.swift:2347-2351).
- Most likely failure the loop is retrying, in order:
  1. `TransportError.timedOut` from the attach/keepalive on a **reused dead socket** — 
     HeelerSSHTransport.swift:2351 (`openPTY(timeout: requestTimeout)`) / the keepalive ping.
     This is the single most likely one: it is retryable, so it never reaches the waiters
     (EventsSession.swift:579-584, 641-646), and the root screen keeps showing `.connecting`.
  2. `sshUnreachable` while the Tailscale tunnel is re-establishing over cellular — retryable,
     backoff caps at 30 s (EventsSession.swift:13-14), so this alone should clear within a
     minute; it does not explain an indefinite spin on its own.
  3. A host-key confirmation that never surfaces: `HostKeyConfirmationBroker.confirmFirstConnect`
     (HostKeyConfirmationBroker.swift:61-72) returns **false immediately** when
     `presenters == 0` or another decision is pending, and the root's presenter is registered by
     an `onAppear`/`onDisappear` pair (HostKeyConfirmationBroker.swift:105-106) that the
     Console cover's presentation can take down. A declined first connect fails the connect —
     but as a *non-retryable* error it would surface as `.clientEnded`, so this is the least
     likely of the three for this symptom. It is still a real second bug for the
     new-address-from-a-sibling case.

## (2) What Preflight does that the events session does not

`HostOnboardingStore.check` (Sources/Heeler/Hosts/HostOnboardingStore.swift:96-120):
- Dials a **brand-new** transport through `connector.connect` for every test, pings, and closes
  it (`try? await transport.close()`, :115-116). Nothing is reused, so no stale socket, no
  suspect flag, no generation, no Attach permit, no waiter.
- Asks the host-key question **on its own screen**, through
  `awaitFingerprintDecision(for:)` (:96-98) — always answerable, never silently declined —
  and pins on confirm through the same `HostKeyPolicy(knownHosts:)`.
- Reports every failure as a `PreflightReport` with a hint. There is no state in which it
  shows an unbounded spinner.
- The root client, by contrast, borrows the Console's long-lived session and has exactly one
  wait with no deadline (`awaitTerminalTransport`, EventsSession.swift:965-997) and one status
  that swallows everything (`terminalStatus`, HerdrClientStore.swift:102-106).

## Most likely cause

**The root screen has no failure surface for a Host whose session is stuck in a retryable
reconnect loop, and the loop off Wi-Fi is most likely retrying a `timedOut` against an SSH
socket that `ensureTransport` reused because the path change that killed it was never recorded
(`networkPathDidChange` no-ops while suspended, EventsSession.swift:453, and
`isConnected`/`isReusable` is a flag, not a probe).** Confidence: **high** that this is the
mechanism of the indefinite information-free "Connecting" (code-proven);
**medium** that the reused-dead-socket path is the specific failure being retried, since the
30 s backoff cap means a genuinely unreachable address should recover on its own.

## Fix (one paragraph)

Give the root screen the session's own state instead of an unbounded wait. `EventsSession`
already publishes `.reconnecting(attempt:delay:failure:)`, and `ConsoleStore.hostStatuses`
already carries it; `HerdrClientStore` should take the Host status as an input and map
`.reconnecting`/`.failed` into `statusPresentation` — spinner *plus* the failure's presentation
text and a Reconnect button — rather than collapsing `isReplacing`/`.stopped` to a bare
`.connecting` (HerdrClientStore.swift:102-106). Second, bound the wait: give
`awaitTerminalTransport` the same treatment `acquireTerminal` already has
(`terminalAcquisitionTimeout`, EventsSession.swift:237/919-963) so a parked attach fails with
`timedOut` instead of waiting forever, and resume waiters with a *retryable* failure too
(EventsSession.swift:579-584, 641-646) so the Client can show it and offer a retry. Third, and
independently, make `EventsSession.networkPathDidChange` record the suspicion while suspended
(set `transportSuspect` before the `phase == .active` guard, EventsSession.swift:452-456) so a
path move during a backgrounded stretch cannot be inherited as a "reusable" socket.

## Device diagnostic

Off Wi-Fi, while the root screen is spinning, open the floating menu → the Console cover and
read the Host's row. If it says **Reconnecting (attempt n)** with a reason, the session is the
one failing and the root screen is simply not reporting it (primary cause). If it says
**Connected**, the session is fine and the Client's own lifecycle is latched (`isReplacing`
never cleared) — then force-quit and relaunch while still off Wi-Fi: a fresh launch that
connects proves the latch. If a **"Trust this Host?"** alert appears at any point, the host-key
path is involved as well.
