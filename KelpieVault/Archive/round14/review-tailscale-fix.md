# Review — Open item 22 bounded events-channel teardown

Reviewed (read-only, no build): the six-file diff, the builder notes, SessionDriver/SSHConnection
internals, EventsSession run loop / ensureTransport / windDown, AsyncDeadline, ConsoleStore.suspend.

## (a) Diagnosis — confirmed

- `SessionDriver.closeStreamLocal` (SessionDriver.swift:1003) opens with `await acquireOperation()`
  (:1004); the 2 s only becomes a deadline inside `cleanChannel(..., cancellable: false)` (:1021-1025).
  `acquireOperation()` (:4275-4285) is a plain FIFO `withCheckedContinuation` — no deadline, no
  cancellation. `invalidateResources()` (:4250) does **not** resume `operationWaiters`, so the queue
  drains only as holders release; it does call `activity.releaseAllWaiters()`
  (SessionActivity.swift:101), which wakes parked socket waits, and `repeatUntilCompleteHolding`
  re-checks `try requireSession()` after every wait (:3831), so holders then error out and release.
  That is what makes abandon work.
- Holders on the primary Host's connection, confirmed: `exchangeStreamLocal` (SessionDriver.swift:742,
  acquire at :750) holds across the whole RPC round trip plus a failure-path `cleanChannel`;
  `writePTY` (:503, acquire at :505) holds per write chunk and on its error path runs
  `finishOwnedSendIfNeeded` (:537) before `releaseOperation()`; `driver.close` (:1845) acquires at
  :1846. The `SSHConnection` header comment (SSHConnection.swift:18-25) already states the same.

## Correctness findings

1. **should-fix (borderline must-fix)** — `Sources/Heeler/Transport/HeelerSSHTransport.swift:2247`
   (`Task { await self.abandonConnection() }`) vs `:2258` (`guard connected else { return }`).
   The abandon is an unstructured Task with no ordering against the run loop's next
   `ensureTransport` → `try? await transport.close()` (EventsSession.swift:876-877). If `close()`
   wins the actor turn it sets `connected = false` (HeelerSSHTransport.swift:1782-1783) and parks in
   `connection.close(timeout:)` → `driver.close` → `acquireOperation()` — the exact unbounded wait
   being fixed — and the later `abandonConnection()` then returns at its `connected` guard without
   ever invalidating the driver, so nothing frees it. The run loop is inside that close, so the Host
   is wedged again. In practice the backoff sleep in `emitReconnectingAndBackOff` (EventsSession.swift
   :941-947) almost always lets the abandon task run first, so this is a narrow race, not the common
   path — but the fix's guarantee rests on scheduling luck. Cheap fix: make `abandonConnection()`
   invalidate unconditionally (drop the `connected` guard; `SSHConnection.abandon()` /
   `driver.invalidate()` are idempotent), or gate `close()` on an `abandoned` flag. Confidence: high
   on the mechanism, medium on how often it bites.

2. **should-fix** — `Packages/HeelerSSH/Sources/HeelerSSH/SSHConnection.swift:372` (`abandon()`), no
   test. The whole fix rests on "abandon returns while another operation holds the operation mutex",
   and the three new app-level tests exercise `ScriptedTransport`, which never touches the driver, so
   that claim is verified nowhere. The package has `operationWaiterCountForTesting`
   (SSHConnection.swift:359) and DEBUG holds (`holdNextSessionWaitForTesting`) to drive it. Suites
   under `Packages/HeelerSSH` run via `scripts/run-heelerssh-package-tests.sh`, not
   `-only-testing:HeelerTests/...`. Confidence: high.

## Checked and sound

- **(b) abandon safety.** `driver.invalidate()` (SessionDriver.swift:1887) → `invalidateResources()`:
  clears channel/SFTP tables, `resumeAllChannelOpenWaiters`, `resumeAllPTYTeardownWaiters`,
  `wakeSFTPIdleWaiters`, `activity.releaseAllWaiters()`, `InvalidatedSessionTeardown.reclaim`,
  `closeDescriptor()` (fd guarded `>= 0`, so a concurrent `close()` cannot double-close). Parked
  holders wake, hit `requireSession()`/`resolveChannel` and throw `SSHError.connectionInvalidated`,
  mapped to `TransportError.sshUnreachable` (HeelerSSHTransport.swift:2021-2022), which is both
  retryable (Transport.swift:861) and `indicatesDeadConnection` (EventsSession.swift:472-474) — so
  the root screen's attach on the same connection fails into `terminalDidFail` and gets a rebuilt
  attach on the next transport generation, not a permanent failure. No use-after-free window:
  invalidation and the libssh2 call are in different actor turns and every loop re-checks
  `requireSession()` before the next native call. `abandon()` itself takes only the driver's actor
  turn, never the operation mutex; `byteTransport.abort()` is a sync non-blocking call
  (SSHByteTransport.swift:90).
- **(c) reconnect.** `transportSuspect` is set on all three callers before the end, so
  `ensureTransport` (EventsSession.swift:867) skips reuse, drops `currentTransport` and connects
  fresh; after abandon `transport.close()` returns at its `connected` guard (except in finding 1).
- **(d) cancellation safety.** `AsyncDeadline` is deliberately unstructured (AsyncDeadline.swift:57-62)
  so the timeout really returns while the loser is still parked; `AsyncDeadlineResolution.resolve`
  guards `result == nil`, so no double-resume of the checked continuation. Double-finish is not a
  hazard here: `AsyncThrowingStream.Continuation.finish` is idempotent, so the reader's later
  `finish(throwing:)` (HeelerSSHTransport.swift:2333-2337) is a no-op. The losing `end()` task stays
  parked until the mutex drains; it holds only the abandoned transport's own admission lease
  (`admissionLease.release()`, :2329), and a fresh transport has its own limiter — no cross-transport
  starvation.
- **(e) tests.** Both stall tests inject `streamEndTimeout: .milliseconds(100)` and gate the ender on
  a gate never opened — no real 2 s sleep; they assert the graceful end was attempted
  (`wedged.entryCount == 1`), that abandon happened once, that a second transport was built and
  re-subscribed. The healthy-path test uses a 30 s timeout and asserts `abandonedStreamCount == 0`
  plus a sub-second path change, so a regression to always-abandon fails. Helpers (`failPing`,
  `SequencedTransportConnector`, `ScriptedTransportCallGate.entryCount`) all pre-exist.
- **(g) isolation.** `abandoner` is `@Sendable` non-async over a Sendable continuation and the actor;
  `HerdrEventStream` stays a Sendable final class; `EventsSession.endStreamPromptly` is actor-isolated
  and only awaits. Nothing new crosses an isolation boundary unsafely.

## (f) windDown — real but bounded

`EventsSession.windDown` keeps `await stream.end()` (EventsSession.swift:978) on the same unbounded
mutex wait, and it is what the background assertion waits on. It cannot hang the suspend past the
deadline: `ConsoleStore.suspend` wraps the projection suspends in
`AsyncDeadline.run(for: ConsoleStore.suspendTimeout)` (ConsoleStore.swift:180, 182-199), and
`AsyncDeadline` is unstructured, so it returns at 8 s regardless and
`AppActivityCoordinator` releases the UIKit assertion on time. The consequence is a leaked teardown
task plus an SSH connection never closed before iOS freezes its sockets (and the transport reference
kept alive by that task), which `resume()`'s re-prove makes harmless. Worth noting that windDown
closes the transport immediately after the end anyway, so the graceful end buys little there —
switching it to the bounded path later would be a small, safe follow-up, not a blocker.

## Optional / style

- `HeelerSSHTransport.swift:2258-2266` — `abandonConnection` drops the SFTP clients without closing;
  the comment explains it, but the same reasoning applies to `close()`'s ordering and is not
  cross-referenced.
- `EventsSession.swift:533-535` — the bare `catch` comment says "Cancellation only"; true today only
  because `stream.end()` cannot throw. A one-word note of that dependency would age better.
- `HerdrEvents.swift:166-173` — `abandon()` is documented "Idempotent"; it is in effect (the second
  call re-cancels and spawns a second no-op abandon task) but not literally.
- No test covers the trace line on the give-up path, nor the finding-1 ordering.

## Not checked

Did not build or run anything (per brief): no compile check, no device run, no execution of the three
new tests. Did not re-derive the trace log's timings; took the builder's Host-vs-Host comparison at
face value after confirming the mutex mechanism it rests on.
