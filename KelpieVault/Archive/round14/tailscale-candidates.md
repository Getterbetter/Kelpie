# Open item 22: the round-13 candidates against the code at HEAD (8506f4c, post-cab2da6)

Line numbers are HEAD's, not my working tree's.

## (1) A socket inherited as reusable across a path change made while suspended — fixed by cab2da6

`networkPathDidChange` now sets `transportSuspect = true` *before* the `phase == .active`
guard (EventsSession.swift:458-459), so a move recorded while backgrounded survives into the
next activation and `ensureTransport` cannot take the `!transportSuspect &&
await transport.isConnected` branch (EventsSession.swift:709). The underlying hazard is
unchanged and still real: `isConnected` is the driver's `isReusable` flag, not a probe
(HeelerSSHTransport.swift:1774-1778 -> SSHConnection.swift:220-221). Two residual holes:
`windDown()` clears the suspicion again (EventsSession.swift:795), and `NWPathMonitor`
delivers nothing to a frozen process — so a path that moves *and moves back* while the app is
away leaves no change for `NetworkPathTracker.record` (NetworkPathObserver.swift:75-82) and the
flag is never set at all.

## (2) A host-key prompt with no presenter on the root screen — not present

Two presenters are mounted: ContentView.swift:151 applies `.hostKeyConfirmation()` above
`HerdrClientRootView`, and HerdrClientRootView.swift:180 applies a second on the Console
cover, so `presenters` never reaches 0 and `confirmFirstConnect` cannot decline for want of a
screen (HostKeyConfirmationBroker.swift:62). It could not produce this symptom anyway: a
declined first connect is `.hostKeyRejected`, non-retryable, so the session goes to `.failed`
(EventsSession.swift:584-588), not to an endless Reconnecting.

## (3) A deadline Preflight applies that EventsSession lacks — not present

Both dial through `SSHTransportConnector.connect` with the same
`SSHTransportSettings.defaultRequestTimeout` = 15 s (SSHTransportSettings.swift:43), applied
to TCP connect, host-key verify and auth (HeelerSSHTransport.swift:345-410, 453-476). Since
cab2da6 the session has *more* deadlines, not fewer (`terminalAcquisitionTimeout` = 30 s,
EventsSession.swift:237, now bounding `awaitTerminalTransport`, :994). The asymmetry runs the
other way: Preflight fails once and reports; the session retries forever at a 30 s cap.

## What Preflight does on connect that EventsSession does not

- Always a fresh dial, never reuse. `connector.connect` per run, closed immediately
  (HostOnboardingStore.swift:102, 116). The session reuses `currentTransport` on an unprobed
  flag (EventsSession.swift:708-711) and reuses that transport's cached `$HOME`
  (`homeDirectory`, `cachesSuccess: true`, HeelerSSHTransport.swift:310); Preflight re-resolves
  `$HOME` and the socket path on every run.
- Host key on its own screen, with a 60 s timeout it owns (HostOnboardingStore.swift:96-98,
  161-174); the session goes through the app-wide broker instead (ConsoleStore.swift:740-748).
- Extra probe, less exposure: Preflight also runs `listSessions()` (one exec channel) and then
  stops. It never opens `events.subscribe`, never holds a channel open, and never opens an
  attach PTY. So a green Preflight proves TCP + auth + stream-local forwarding + one ping, and
  nothing about anything long-lived.
- No per-run deadline in either; no timeout the session lacks.

## Most likely cause

Preflight proves exactly the short-lived path that is working, so the Host most likely fails on
what only the session does — a long-lived channel (`events.subscribe`, or the attach PTY) that
dies on the Tailscale path and re-marks the transport suspect (EventsSession.swift:418, 893) as
fast as each new dial installs one, keeping the session in a permanently retryable
`.reconnecting` cycle.

## Smallest fix I would make (not made)

Make the reuse path prove itself: in `ensureTransport` (EventsSession.swift:708-711) ping a
reused transport instead of trusting `isConnected`, and close it on failure — one extra round
trip on the reuse path, and no dead socket can be handed to a parked attach again. Choose it
only after the trace names the phase.
