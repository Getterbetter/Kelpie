# Round 33 review — groups B and D (fresh context)

Reviewer: Opus, read-only. Scope and priorities from the orchestrator brief.
Status: complete. Counts: must-fix 0, should-fix 4, nit 3.

## 1. EventsSession after the B series

### should-fix — S1. A link-failure retry during the subscribe window wedges every RPC while the Host shows Connected
`Sources/Heeler/Transport/EventsSession.swift:417-439` with `:813-816`, `:866-869` and `startKeepalive` `:1112`.

Scenario: the run loop has installed (or reused) `currentTransport` and is inside
`transport.subscribeToEvents(...)` (`:816`), so `liveStream` is nil. That window
opens on every reconnect and on every `updateSubscriptions` re-subscribe (which
follows every `.connected` re-snapshot). A `withTransport` call on that same
transport fails with `.timedOut` (a slow herdr answer, not a dead link) or
`.sshUnreachable`. The retry path sets `transportSuspect = true` and
`currentTransport = nil`, but with no live stream it cannot wake the loop. The
subscribe then succeeds on the old transport; the loop sets `liveStream`, yields
`.connected`, and `startKeepalive` returns without starting a keepalive because
`currentTransport` is nil (`:1112`). The loop parks on a stream that has no reason
to end. The retrying caller, and every later `withTransport` caller, parks in
`transportWaiters` (`awaitUsableTransport` has no deadline) until something
external ends the stream (path change, backgrounding). `revalidate()` is also a
no-op (`:333` needs `currentTransport`). The Host reads Connected while every
Console RPC hangs.

Inherited from upstream (upstream's plain `liveStream?.end()` is equally a no-op
with no stream), so not a Kelpie regression, but it is exactly the "waiter that
can pend forever" class, and Kelpie's keepalive does not rescue it.

Fix (either): after a successful subscribe, have the run loop check
`transportSuspect || currentTransport == nil` and, if so, `await stream.end()`
and `continue` so `ensureTransport` redials; or, in `withTransport`, only nil
`currentTransport` when `liveStream != nil` (otherwise leave it installed and
suspect, and let the run loop's own `ensureTransport` replace it). Confidence:
high on the trace, medium on how often the window is hit.

### should-fix (low) — S2. The retry drops the old transport without closing it
`Sources/Heeler/Transport/EventsSession.swift:417-419` vs `ensureTransport` `:979-991`, `windDown` `:1095-1098`.

Builder's open question. Not a hang and not a permanent leak: the socket closes
when the last reference to the old `HeelerSSHTransport` drops, via
`SSHConnection.deinit` (`Packages/HeelerSSH/.../SSHConnection.swift:460`), which
invalidates the driver without the operation mutex (the round-14-safe path). But
until then the connection stays open whenever the graceful end succeeded within
2 s (no abandon): the old root-screen Attach PTY channel and cached SFTP clients
keep it alive until the Attach is replaced on the generation bump, and
`windDown` cannot close it because it is no longer `currentTransport`. On Kelpie
that briefly means two SSH connections to the primary Host, one still carrying
the previous herdr client. Previously Kelpie's suspect paths left the transport
installed and `ensureTransport` closed it (which, after an abandon, returns at
once). Fix: keep the dropped transport in a `retiredTransport` slot and close it
from `ensureTransport` (or call `abandon`-equivalent on it) — or, as in S1's
second option, leave it installed and suspect so the existing close path runs.
Confidence: medium.

### should-fix — S3. The one-shot retry re-sends non-idempotent RPCs after a `.timedOut`
`Sources/Heeler/Transport/EventsSession.swift:406-448` (`isTransportLinkFailure`, `:455-460`).

`withTransport` retries *every* operation once on `.timedOut`, and the composer's
`agent.prompt` goes through it (`Sources/Heeler/Console/ConsoleStore.swift:431-434`).
A `.timedOut` is a request that was written and not answered in time; on the
degraded link this retry targets, herdr may well have received it. `agent.prompt`
types the text and Enter, so the retry submits the same prompt a second time on
the replacement transport (herdr queues it in the agent TUI unconditionally).
Same for `pane.send_text`/`send_input`, `agent.start`, `tab.create`,
`workspace.create`. `.sshUnreachable` from a channel that never opened is safe;
`.timedOut` is not. Inherited from upstream (`83d6986b`/`92fe8601`), not a Kelpie
regression; the Kelpie root-screen composer sends over the Attach PTY and is not
affected, only the Console composer and Console actions. Fix: retry `.timedOut`
only for operations the caller marks idempotent (a `retryOnTimeout:` flag on
`withTransport`, false for writes), or for writes only wait out the replacement
before the first attempt and never re-send after one. Confidence: high on the
mechanism, medium on frequency.

### nit — N1. `awaitUsableTransport` hands out a suspect transport
`Sources/Heeler/Transport/EventsSession.swift:475`. Unlike `awaitTerminalTransport`
(`:1325`, `!transportSuspect`), an RPC arriving after `keepaliveDidFail` /
`terminalDidFail` / `networkPathDidChange` (transport suspect but still installed
until `ensureTransport` runs) is sent on the distrusted transport. If it was
abandoned the call fails fast and the retry rides the replacement (fine); if the
graceful end succeeded the first attempt can burn its full request timeout before
the retry. Not a correctness bug. Fix: `if let t = currentTransport, !transportSuspect`.

### Checked and sound
- Every `TransportWaiter` is removed from the array before its single resume
  (`resumeTerminalTransportWaiters` tail, `failTransportWaiters`,
  `cancelTransportWaiter`); no double resume.
- Cancellation: pre-cancelled tasks resume at once; the `onCancel` hop finds the
  waiter or nothing.
- Every run-loop exit releases waiters: both retryable branches, both
  non-retryable branches (`:844-849`, `:916-921`), `windDown` (`:1079`). After a
  non-retryable `return`, `runTask` stays non-nil but `terminalTransportFailure`
  is recorded first, so `awaitUsableTransport` throws it (`:483`) rather than
  parking. A waiter that arrives during backoff is bounded by the backoff delay
  plus the next attempt.
- `windDown` concurrent with a retry caller inside `endStreamPromptly`: after it
  returns, `isWindingDown`/`phase` make `awaitUsableTransport` throw.
- The Kelpie adaptation of `9470cf55` (`endStreamPromptly`, `resubscribeRequested`
  only with a live stream) is correct and keeps the round-14 bound: no new
  unbounded `stream.end()` or `transport.close()` on a distrusted link was added.
  Side effect worth knowing: a retry that lands while a keepalive/terminal
  failure is being ended turns that `.reconnecting` into a silent resubscribe;
  harmless.

## 2. Never-autocorrect (`db0db7e4`)
Sound. The terminal's six correction traits now fall through to the vendored
setter-proof `.no` implementations in both styles; `TerminalComposerTextView`
still sets `.default` autocorrect/spell check in its init
(`Sources/Heeler/Terminal/TerminalComposer.swift:301-302`) and
`kelpieComposerFieldKeepsAutocorrectionOn` pins it
(`Tests/HeelerTests/TerminalInputTraitsTests.swift:98-104`).

## 3. Item 49 (`7b6eb485`)
Sound. Traced `Sources/Heeler/Notifications/AgentNotificationBannerStore.swift:140-165, 202-221`:
- Cleared snapshot (Host has no rows): the hold keeps running, the id goes into
  `awaitingSnapshot`.
- Pane back at the same status before the hold elapses: the hold fires normally,
  once. After it elapsed: `elapsedWhileAway.removeValue` fires `present` once and
  consumes the entry, so a second snapshot cannot fire it again.
- Pane back at another status: `cancelHold` clears the hold, the elapsed entry and
  the awaiting mark. Pane absent once its Host lists Agents again: same.
- No double banner from the held path; the hold task is removed from `holds`
  before presenting; `cancelHold` cancels it.

### nit — N2. Entries for a Host that never lists Agents again linger
`awaitingSnapshot` / `elapsedWhileAway` (`:62-66`) keep an id for a removed or
permanently offline Host, alongside the existing kept baseline. Bytes, not a
behaviour bug; if the Host is re-added with the same id and pane id at the same
status, a stale elapsed hold would banner then. Optional fix: clear both when a
Host is removed.

### nit — N3. Cross-pipeline dedupe window vs a long gap
If a push for the same Blocked/Done was presented during the gap and the pane
returns after `duplicateWindow`, the held banner shows again (`announce`,
`:260-272`). Before the fix it was lost instead, so this is the better failure.

## 4. Item 53 (`08cabe95`)
Sound. `AgentLaunchPendingRetry.run` (`Sources/Heeler/Console/HostConsoleProjection.swift:864-882`)
matches only `HerdrAPIError` with code `agent_launch_pending` (the real transport
throws `HerdrAPIError` for API rejections, e.g. `HeelerSSHTransport.swift:815`, so
the match works outside the scripted tests); every other error propagates on the
first attempt; the budget is 10 s of sleeps (plus each call's own time);
`Task.sleep` makes it cancellable. `RenameStore.swift:142-143` maps only that code
to the friendly message, before the generic `HerdrAPIError` case. Rename is
idempotent, so composing with `withTransport`'s retry is harmless.

## 5. Item 52 (`95417700`)
Shell and path safety: sound.
- The directory goes through `RemoteShellPath.quotedAbsolute` (must start with
  `/`, no `'`, no `\`, no control characters) and arrives as `$1`; the file name
  must match `[A-Za-z0-9._-]+` not starting with `-` and arrives as `$2`. Both
  scripts contain no `'` or `\`, so the outer single quotes hold under sh, bash,
  zsh and fish login shells.
- Deletion is gated three times: `staleNames` keeps only lines whose name is
  exactly `<fileName>.tmp-` plus ASCII letters/digits/hyphens, older than 3600 s by
  the Host's own `date +%s` and mtime, and not `justWritten`;
  `removalCommand` re-validates every name; `rm -f --` runs after `cd "$1"` with
  slash-free names. A hostile file name containing a newline can forge listing
  lines, but only for names that pass the same `.tmp-` gate, so nothing but that
  file's temporary siblings in that directory can ever be removed.
- Runs only when `withNotificationFileRequestDeadline` returned (a throwing
  replace never reaches the `Task`); every failure is `try?`/`guard` silent; the
  just-written temp was renamed away and is excluded by name anyway.

### should-fix — S4. The detached sweep races the e2e test's channel counts
`Sources/Heeler/Transport/HeelerSSHTransport.swift:997-1001` vs
`Tests/HeelerTests/HeelerSSHTransportBehaviorE2ETests.swift:1325-1343` (and `:1354-1357`).

`exerciseNotificationFiles` (direct and Jump Host variants, mandatory real-SSH
suites in CI) replaces `previousLive`, which now spawns an unawaited sweep whose
`runExec` holds an `.ordinarySession` admission and a connection channel
(`notificationFileStateForTesting` reads `channelAdmission.snapshot()`). The test
then asserts `ordinarySessionCount == 1` and `connectionChannelCount == 1` during
the delayed write, and `== 0` after its cancellation. If the listing exec is still
in flight (slow CI runner, Jump Host hop), those expectations fail. Likely rare
because the intervening SFTP read queues on the same driver, but it is a timing
dependency the test cannot control. Fix: keep the sweep task in a property and
expose an `awaitNotificationSweepForTesting()` the test awaits after each replace
(or poll `ordinarySessionCount == 0` before arming the delayed write). The
builder flagged this; the e2e suite was not run in the round (it needs the local
sshd fixture). Confidence: medium.

## 6. Swift 6 and force unwraps
No force unwraps, `try!` or `as!` in any added source line of B or D. The
continuation closures run actor-isolated (same pattern as the existing terminal
waiters); `Task { [weak self] }` in the `@MainActor` banner store and the
actor-isolated sweep `Task` capture only Sendable values.

## What I checked and what I did not
Checked by reading: the full B diff of `EventsSession.swift`, the run loop,
`ensureTransport`, `windDown`, keepalive, terminal-transport waiters,
`endStreamPromptly`, `SSHConnection.deinit`; the `db0db7e4` trait diff and tests;
the three D commits' sources and the relevant tests. Not checked: nothing was
built or run (per brief); the upstream-only focus tests dropped in `9470cf55`; the
new `EventsSessionSubscriptionsTests` beyond their existence; the round-30 item-19
diagnosis note in detail.

## Fix verification (`f7cbc098`)

Read only; nothing built or run. The commit reports 230 tests green on the iPad,
including the new `aTimedOutSendIsNotRetriedButTheTransportIsReplaced` and
`aLinkFailureDuringTheSubscribeRedialsInsteadOfParkingForever`.

**S1 and S2: pass.**
- `withTransport` no longer clears `currentTransport`. It sets `transportSuspect`
  and ends a live stream as before (`EventsSession.swift:431`, `:449`). The
  suspect transport stays installed, so `ensureTransport` (`:1018-1027`) or
  `windDown` closes it: S2 is closed.
- `awaitUsableTransport` and the continuation branch both read `usableTransport`
  (`transportSuspect ? nil : currentTransport`), so a suspect transport is never
  handed out.
- The run loop checks `transportSuspect` right after `liveStream = stream`
  (`:893-903`). If it is set, the loop ends the stream (bounded) and continues
  into `ensureTransport`, which closes the old transport, redials and resumes the
  waiters. That closes the S1 wedge. It also covers a `networkPathDidChange` or
  `terminalDidFail` that lands mid-subscribe, which returned early with no stream
  before this commit.
- I found no new way for a caller to park forever. I checked every
  `transportSuspect = true` site:
  - `withTransport` (`:431`) ends a live stream. With no live stream, the loop is
    either mid-subscribe (the new check catches it) or backing off (the next
    `ensureTransport` replaces the transport).
  - `terminalDidFail` (`:586`), `networkPathDidChange` (`:626`) and
    `keepaliveDidFail` (`:1238`) either end the live stream or return when there
    is none, and the same two cases then apply.
  - The subscribe-timeout catch (`:855`) backs off, then calls `ensureTransport`.
  - After a non-retryable `.failed` return, the suspect transport can now stay
    installed, but `terminalTransportFailure` is always recorded first, so
    `awaitUsableTransport` throws it instead of parking. When the session is not
    active, it throws at the phase guard.
- The terminal channel is unchanged. `awaitTerminalTransport` and
  `terminalTransportIsCurrent` already refused a suspect transport. They behave
  as they did when the transport was cleared.

**S3: pass.** Only `.sshUnreachable` is retried (`isRetryableLinkFailure`,
`:475-479`). `.timedOut` still marks the transport suspect and ends the stream,
then rethrows the original error at `guard retries else { throw error }`
(`:453`).

**S4: pass.** `sweepStaleTemporaryFiles` is awaited after the replace, outside the
replace's deadline (`HeelerSSHTransport.swift:1007`). Failures stay silent, and
the sweep still runs only after a successful replace.

### New nits from the fix
- **N4. A stale `resubscribeRequested`.** `liveStream` is now set before the new
  suspect check, so a `withTransport` failure that lands while that stream is
  being ended sets `resubscribeRequested = true` (`:449`). The new branch then
  continues without clearing the flag. Its only reset is in the stream-ended
  branch (`:938-944`), so it survives until the next stream ends. The next real
  failure then goes through that branch as a silent resubscribe: no
  `.reconnecting`, no backoff, and `pendingKeepaliveFailure` is left unread. This
  happens once and recovers (`ensureTransport` still redials a suspect transport).
  Fix: add `resubscribeRequested = false` before that branch's `continue`.
- **N5. The awaited sweep lengthens the write.** On a slow link, the sweep adds up
  to two exec round trips (each bounded by `requestTimeout`) to a successful
  `replaceNotification*` call. It can never fail the write.
- **Note, not a defect of this commit.** Since the B series, a single `.timedOut`
  RPC (a busy herdr, not a dead link) marks the primary Host's transport suspect.
  That replaces the transport and makes the root-screen herdr client re-attach.
  This is by design upstream, and worth knowing if re-attaches show up after slow
  `agent.read` calls.
