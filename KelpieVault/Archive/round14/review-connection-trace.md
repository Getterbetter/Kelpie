# Review: the connection trace (Open item 22)

Reviewed: `Sources/Heeler/Transport/ConnectionTrace.swift` (new),
`Tests/HeelerTests/ConnectionTraceTests.swift` (new), and the diffs to
`EventsSession.swift`, `ConsoleStore.swift`, `NetworkPathObserver.swift`.
Not checked: I did not build, run the suite, or run it on device (another
worker holds the device). Swift 6 conformance is read, not compiler-proven.

The facility is sound and does what the spec asked. Findings below are all
about the sink's threading and two blind spots in coverage.

## Correctness

### 1. should-fix — the sink does synchronous disk I/O on the MainActor
`Sources/Heeler/Transport/NetworkPathObserver.swift:234` →
`ConnectionTrace.swift:206` → `ConnectionTrace.swift:239-252`

`NetworkPathObserver` is `@MainActor` (`NetworkPathObserver.swift:186-188`) and
its feed task is `Task { @MainActor … }` (`:227`). `notePath` therefore runs on
the main thread, and `ConnectionTraceFile.append` rewrites the **entire** file
synchronously (`try? data.write(to: url, options: .atomic)`), up to the 4000-line
cap — roughly half a megabyte per line once the buffer fills.

Why it matters: the spec's check (b) explicitly forbids blocking the MainActor
on disk I/O. On a flapping Tailscale path — exactly the scenario this exists to
capture — path changes arrive in bursts and each one hitches the UI.
Confidence: high (isolation and write call are both plainly in the source).

### 2. should-fix — the same synchronous rewrite blocks the `EventsSession` actor
`Sources/Heeler/Transport/EventsSession.swift:499-517` → `ConnectionTrace.swift:200-207`

`trace(...)` is actor-isolated and calls `sink` inline, so every one of the ~30
call sites performs a full-file rewrite while holding the session actor. During
a reconnect storm that is the hot path the trace is measuring; the trace can
perturb the timing of the hang it is meant to explain, and the cost is O(n²) in
lines written.

Why it matters: a diagnostic that changes the behaviour under diagnosis is a
weaker instrument. A serial background queue / detached actor behind the sink
fixes both 1 and 2 without changing any call site.
Confidence: high on the mechanism, medium on whether it is bad enough in
practice to matter at the observed event rate.

### 3. should-fix — a hang in the transport-reuse window leaves no line
`Sources/Heeler/Transport/EventsSession.swift:815-825`

The first thing the loop does on each attempt is `await transport.isConnected`
and then possibly `try? await transport.close()`. Both are awaits into the SSH
driver, and the first trace line of the attempt (`reused…` / `closing…`) is only
written **after** `isConnected` returns. If either await never returns — a
plausible shape for the reported symptom, since `isConnected` is the driver's
`isReusable` flag and `close()` talks to a dead socket — the log ends on the
previous `phase=status … reconnecting`, with nothing to distinguish it from a
hang in the backoff sleep.

Fix shape: one `trace(.connect, .started …)`-style line at the top of
`ensureTransport`, before the reuse probe. Confidence: high.

### 4. should-fix (small) — `windDown` is untraced, so a stall there is invisible
`Sources/Heeler/Transport/EventsSession.swift:788-801` (called from `retry()`
`:556`, `deactivate()` `:565`, `finish()` `:573`)

`windDown` closes the transport and then `await waitForTerminalIdle(timeout:)`.
A `retry` whose `windDown` stalls produces `phase=lifecycle note="retry"` and
then silence — indistinguishable from finding 3. It is also the place that
clears `transportSuspect` (`:795`), which the builder names as a residual
hazard; a line there would show the suspicion being dropped.
Confidence: high that it is untraced; medium that it matters.

### 5. nit — `notePath`'s arguments are formatted even when the trace is off
`Sources/Heeler/Transport/NetworkPathObserver.swift:234-235`

`notePath(_ summary: String, change: String)` takes plain parameters, so
`snapshot.summary` (an array join plus two interpolations) and
`String(describing: change)` are both evaluated before the `guard isEnabled`
inside. Every other call site in the change is autoclosure-clean; this is the
one place the "zero cost when disabled, no formatting" claim is not literally
true. Rare path, tiny cost, but it is the stated bar.
Fix shape: `@autoclosure` both parameters, or hoist `guard
ConnectionTraceLog.shared.isEnabled`. Confidence: high.

### 6. nit (inherited) — the file write happens outside the lock
`Sources/Heeler/Transport/ConnectionTrace.swift:240-251`

The snapshot is built under `Mutex`, but `data.write` is outside it. Two
concurrent appenders (the MainActor path observer and the session actor are
genuinely concurrent) can have the stale snapshot land last, leaving the file
one or more lines short until the next append. Atomic writes mean no torn file,
only lost tail lines — and if the app is killed at that instant, the lost line
is the most interesting one. `TerminalKeyTrace.write` has exactly the same
shape, so this matches precedent rather than departing from it.
Confidence: high on the race, low on how often it bites.

## What checked out

- **(a) autoclosure discipline**: every one of the ~30 `trace(` call sites in
  `EventsSession.swift` passes its outcome and detail as autoclosure arguments;
  `Self.traceOutcome(...)` (which is where `String(describing:)` lives,
  `:522-524`) is always in the outcome position, never eagerly evaluated. Only
  `attempt:`/`backoff:` are eager and they are an `Int?`/`Duration?` with no
  formatting. `traceStatus` (`:605`) guards `isEnabled` before it switches. The
  one exception is finding 5, outside this file.
- **(b) bounded / truncated**: `limit = 4000` lines, oldest dropped
  (`ConnectionTrace.swift:242-244`); `lines` starts empty each launch and the
  first append rewrites the file, so it truncates per launch like the key trace.
  No data race on a file handle (there is none — atomic whole-file writes).
- **(c) gating**: `UserDefaults.standard.bool(forKey:)` read once in the `shared`
  static initialiser (`:178-181`), same launch-argument mechanism as
  `TerminalKeyTrace.isEnabled`, and `kelpie.key-trace` also enables it as
  specified. The pull command is documented in the file header (`:9-18`).
- **(d) decisive points**: connect (started/ok/failed, with reuse and close
  distinguished), ping, subscribe, the events-stream death, every status
  transition with attempt + backoff + failure + retryable, all three
  suspect-marking sites (`:437` attach channel, `:674` request timeout, `:1022`
  keepalive), the path change, and all five `awaitTerminalTransport` exits
  including both deadline expiries (`:1113`, `:1250`) and the parked-waiter
  resume/fail paths. Host-key confirmation is inside the injected `connect()`
  closure and shows as `connect started` with no terminator, which is
  diagnosable. The gaps I found are 3 and 4 above.
- **(e) ConsoleStore / NetworkPathObserver**: minimal. `ConsoleStore.swift:728-732`
  only adds `traceHost:`; `host.id.uuidString.prefix(8)` leaks no address, as the
  doc comment claims. `NetworkPathObserver` adds a computed `summary` and one
  call. No behavioural change with the trace off (modulo finding 5).
- **(f) project file**: `ConnectionTrace.swift` is in the `Heeler` target's
  Sources phase (`6280AC2C70A5BDB1571078D6`, referenced at pbxproj:1541) and
  `ConnectionTraceTests.swift` in `HeelerTests`' (`E444292D962D3F9441577CA7`,
  pbxproj:1583). Both correct, neither duplicated.
- **(g) tests**: Swift Testing (`@Suite`/`@Test`/`#expect`) with a `.timeLimit`
  trait, matching the neighbours. Every case injects its own sink through
  `ConnectionTraceLog(isEnabled:sink:now:)`, so nothing touches
  `ConnectionTraceFile` or the real Documents directory. The disabled case
  counts entry constructions (`Recorder.countedEntry`), which makes "no
  formatting when off" a measured fact rather than a claim — good. Retryable and
  non-retryable are both asserted end-to-end through a real `EventsSession`.
  Injected `now` keeps the timestamp assertion deterministic.

## The builder's three verdicts, spot-checked at HEAD (8506f4c)

All three hold.

1. **Reusable socket across a path change — fixed by cab2da6.** Confirmed:
   `transportSuspect = true` precedes the `phase == .active` guard
   (EventsSession.swift:458-459 @HEAD). The residual hazards are real too —
   `isConnected` is `driver.isReusable` (HeelerSSHTransport.swift:1774-1778 →
   HeelerSSH/SSHConnection.swift:219-221), and `windDown` clears the suspicion
   (EventsSession.swift:795).
2. **Host-key prompt with no presenter — not present.** Confirmed: both
   `.hostKeyConfirmation()` presenters exist (ContentView.swift:151,
   HerdrClientRootView.swift:180), `confirmFirstConnect` guards `presenters > 0`
   (HostKeyConfirmationBroker.swift:61), and `.hostKeyRejected` is non-retryable
   (Transport.swift:864-870), so it lands in `.failed`, not endless Reconnecting.
3. **A deadline Preflight has and the session lacks — not present.** Confirmed:
   `defaultRequestTimeout = .seconds(15)` (SSHTransportSettings.swift:43),
   `terminalAcquisitionTimeout = .seconds(30)` (EventsSession.swift:237),
   Preflight's own 60 s fingerprint timeout (HostOnboardingStore.swift:51), and
   Preflight's fresh-dial-then-close plus `listSessions()` (HostOnboardingStore
   .swift:102, 108, 116). `homeDirectory` is `cachesSuccess: true`
   (HeelerSSHTransport.swift:312).

**Most likely cause**: supported by the code as far as static reading can take
it. Preflight demonstrably exercises only the short-lived path (connect, ping,
one exec channel, close) and never opens `events.subscribe` or an attach PTY, so
"the Host fails on what only the session does" is the right shape of hypothesis.
It is not yet evidence — the trace is what turns it into evidence, and findings
3 and 4 are the two places the trace could still come back silent on precisely
the hypothesis being tested.

## Style notes (optional)

- `ConnectionTrace.swift:28-30`: the type-level doc comment for
  `ConnectionTracePhase` is glued to the end of the file-level prose with only a
  `///` line between, so the enum's own doc reads as the tail of the file
  overview. A blank line and a `// MARK:` would separate them.
- No launch marker. `TerminalKeyTrace` writes `trace start pid=…` first;
  this file has no equivalent, so a pulled log has no explicit launch or pid
  boundary (timestamps imply it, but only if you know when the run started).
- `ConnectionTrace.swift:709` (`trace(.subscribe, .succeeded)`) omits `attempt:`
  where every neighbouring subscribe line carries it; harmless, slightly
  irregular to grep.
- `ConnectionTraceEntry.field(_:)` builds `[String]` per scalar to collapse
  whitespace; `String(value.map { … })` or a single `replacingOccurrences` pass
  would be plainer. Cold path either way.
