# Open item 22 — the primary Host's `stream.end()` never returns

## The chain, from the trace to the await

`EventsSession.networkPathDidChange()` (EventsSession.swift:479) →
`await stream.end()` (:490) → `HerdrEventStream.end()` (HerdrEvents.swift:154) →
the `ender` closure supplied by `HeelerSSHTransport.openEventsChannel`
(HeelerSSHTransport.swift:2221-2224):

```
readerTask.cancel()
await readerTask.value          // <- the unbounded await
```

`readerTask` runs `runEventsChannel` (HeelerSSHTransport.swift:2228). Cancelling it
gets out of the read loop promptly — `channel.read(timeout: .seconds(1))`, and
`SocketReadiness.wait(cancellable: true)` resolves on cancellation. What it cannot
get out of promptly is the tail:

```
2289:  try await channel.close(timeout: .seconds(2))
2297:  await admissionLease.release()
2300-2305:  ackContinuation.finish(...); eventContinuation.finish(...)
```

Two independent problems in that tail:

1. **The hang.** `channel.close` → `SSHStreamLocalChannel.close` →
   `SessionDriver.closeStreamLocal` (SessionDriver.swift:1003), whose first line is
   **`await acquireOperation()` (SessionDriver.swift:1004; impl :4275)** — the
   driver's FIFO operation mutex. It has **no deadline and no cancellation**: the
   2 s the caller passes is only turned into a deadline *after* the mutex is held
   (`cleanChannel(..., cancellable: false)` on the far side). `SSHConnection`'s own
   doc comment already states this for the sibling path: *"the deadline is computed
   after `acquireOperation()` returns, so the wait for the driver's operation mutex
   ahead of it is unbounded"* (SSHConnection.swift:18-25).
   Every other driver operation holds that mutex, and `exchangeStreamLocal`
   (SessionDriver.swift:742-751) — the one-shot channel behind *every* herdr RPC —
   holds it across the whole round trip (`requestTimeout`), plus a further
   non-cancellable 2 s `cleanChannel` on its failure path. On a path that died
   silently (no RST/FIN) each queued RPC burns its full timeout before releasing,
   so the close's turn is pushed out indefinitely while the app keeps issuing work.
2. **Even without a hang, the stream cannot finish early.** `eventContinuation`
   is finished only at :2301-2305, i.e. *after* the close. So the session's
   `for try await event in stream.events` (EventsSession.swift:717) stays parked for
   exactly as long as the teardown does. That is why 27C2B977 logged nothing more:
   no "the events stream ended", no attempt, no keepalive — the run loop was parked
   inside `stream.end()`'s caller and on the stream itself.

## Why the two Hosts differed

E14E42A1 finished 1.6 s after the path change (t=872.172 → 873.770): ~1 s for the
cancelled read to unwind plus the bounded close. Its SSH session carried the events
channel and nothing else, so `acquireOperation()` was uncontended.

27C2B977 is the primary Host — the root screen's herdr Attach (`exec herdr`, PTY)
lives on the *same* SSH connection, and the Console/Client layer drives RPCs against
it. Two ways that starves the close, both on the same mutex:
- an in-flight `exchangeStreamLocal` RPC holding the mutex for its full
  `requestTimeout` on a socket that will never answer, with more queued behind it;
- an attach `writePTY` (SessionDriver.swift:503) whose write went `EAGAIN` and
  therefore became `transportSendOwner`: every other operation's
  `waitForTransportSendAdmission` then stalls, and its own error path runs
  `finishOwnedSendIfNeeded` — a further non-cancellable 2 s drain — before
  releasing.
Nothing here is per-Host code; it is per-Host *traffic*, which is exactly the
"timing or state differs" the evidence predicted.

## The fix

1. `HerdrEventStream` gains `abandon()` (sync, non-awaiting): finishes `events` at
   once and hands the channel's teardown away. `HeelerSSHTransport` supplies it as:
   cancel the reader, finish the event continuation, and abandon the SSH session —
   `SSHConnection.abandon()` → `SessionDriver.invalidate()`, which takes **no**
   operation mutex and no deadline, so every parked driver call fails against an
   invalidated session instead of waiting on a socket that will never answer. The
   transport is already marked suspect on these paths, so `ensureTransport` builds a
   fresh one (and its own `try? await transport.close()` — the same unbounded mutex
   wait — now returns immediately, since `close()` guards on `connected`).
2. `EventsSession.endStreamPromptly(_:)` bounds the graceful end at
   `streamEndTimeout` (2 s, injectable). On expiry it traces
   `stream end timed out; abandoning the transport` and calls `abandon()`.
   Used by the three paths that already distrust the transport:
   `networkPathDidChange`, `keepaliveDidFail`, `terminalDidFail`.

Left alone, per the brief: `updateSubscriptions` and `windDown`/`suspend()` keep the
graceful end. Note `windDown`'s `await stream.end()` (EventsSession.swift:932) sits
on the *same* unbounded mutex wait, and it is what the app's background assertion
waits on — reported, not changed.

## What changed

- `Sources/Heeler/Transport/HerdrEvents.swift` — `HerdrEventStream` gains an
  `abandoner` (defaulted, so the Demo and scripted call sites are untouched) and
  `abandon()`; `end()`'s doc now states that it is unbounded on a dead link.
- `Sources/Heeler/Transport/HeelerSSHTransport.swift` — `openEventsChannel` supplies
  the abandoner (cancel reader, finish the event continuation, abandon the
  connection); new private `abandonConnection()`.
- `Packages/HeelerSSH/Sources/HeelerSSH/SSHConnection.swift` — new public
  `abandon()`: `driver.invalidate()` + `byteTransport?.abort()` + parent, no mutex,
  no deadline.
- `Sources/Heeler/Transport/EventsSession.swift` — `streamEndTimeout` (2 s,
  injectable) and `endStreamPromptly(_:)`; used by `networkPathDidChange`,
  `keepaliveDidFail` and `terminalDidFail`. New trace line on the give-up path:
  `phase=suspect ... note="stream end timed out; abandoning the transport"`.
- `Tests/HeelerTests/Support/ScriptedTransport.swift` — `gateNextStreamEnd(using:)`
  and `abandonedStreamCount`.
- `Tests/HeelerTests/EventsSessionTerminalChannelTests.swift` — three tests.

Not built here (another worker compiles on the device). `swiftc -parse` clean on
every edited file.
