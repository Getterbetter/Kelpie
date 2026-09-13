# Background/foreground map (Open item 27)

## 1. scenePhase .inactive/.background today
- ContentView.swift:272-286: `.onChange(of: scenePhase)` handles only `.active` and `.background` (no `.inactive` case; falls to `default: break`).
- `.background` -> `activity.didEnterBackground()` only (ContentView.swift:283).
- AppActivityCoordinator.didEnterBackground() (AppActivityCoordinator.swift:178-198): calls `UIApplication.shared.beginBackgroundTask` (via `UIKitBackgroundExecutionGranter.begin`, AppActivityCoordinator.swift:61-81) — this IS the beginBackgroundTask/UIBackgroundTaskIdentifier assertion. If grant fails, tears down immediately (`suspend()`, line 185); else starts a 20s grace `graceTask` (`defaultGracePeriod`, line 97) that calls `suspend()` (private, line 208-214) after the sleep, yielding `.suspended` on `events` stream.
- ConsoleActivityDriver.run() (ConsoleActivityDriver.swift:19-32) consumes `.suspended` -> `await console.suspend()` (ConsoleStore.swift:182-201, 8s deadline `suspendTimeout`) then `activity.didFinishSuspending()` releases the background task (AppActivityCoordinator.swift:203-206). So: app does NOT close transport immediately on background — it holds it live for the grace period, then deliberately tears it down (not "leave to OS kill").
- HostConsoleProjection.suspend() -> `session.suspend()` -> EventsSession.suspend() (EventsSession.swift:317-322) deliberately ends channel + SSH connection.
- Client attach: HerdrClientRootView's `HerdrClientHostView.onChange(of: activity.phase)` (HerdrClientRootView.swift:715-718) fires only media staging cleanup (`media.didEnterBackground()`) on `.suspended`, not terminal teardown directly — the terminal's own teardown rides on the Console-level session suspend, since AttachTerminalStore parks on the same Transport.

## 2. Return to .active
- ContentView.swift:273-282: `.active` -> `activity.didBecomeActive()`, `pairingSync.reconcile()`, `pushRegistration.refresh()` (concurrent Tasks, not awaited serially in the handler).
- AppActivityCoordinator.didBecomeActive() (lines 160-176): cancels grace task, releases background token if still held, computes `lastAbsenceMayHaveSuspended`, increments `activationCount`, yields `.activated`.
- ConsoleActivityDriver -> `console.reactivate()` -> `ConsoleStore.activate(revalidating: true)` (ConsoleStore.swift:122-165): for every Host projection, awaits `projection.resume()` serially in a for-loop (HostConsoleProjection.swift:129-131, `session.resume()`), then — only if revalidating — runs `projection.revalidate()` for ALL hosts concurrently via `withTaskGroup` (ConsoleStore.swift ~157-165), each bounded by the Transport's request timeout (15s default, SSHTransportSettings.swift:43).
- "Reconnecting" presentation: `HerdrClientStore.statusPresentation` (HerdrClientStore.swift ~180-200) derives from `hostStatus` (`EventsSessionStatus`, fed by `console.hostStatuses[host.id]` via `.onChange` in HerdrClientRootView.swift:686-688) through `TerminalStatusPresentation(hostSessionStatus:)`.

## 3. SSH dead-connection detection
- No BSD/libssh2 keepalive found anywhere in Packages/HeelerSSH (grep for `libssh2_keepalive`, `SO_KEEPALIVE`, `TCP_KEEPALIVE` returns nothing). Only `SO_NOSIGPIPE` is set (SSHByteTransport.swift:110-123) and one `SO_SNDBUF` test hook (SessionDriver.swift:2015-2023).
- Detection is entirely app-level: `EventsSession.KeepalivePolicy` (EventsSession.swift:37-45) pings herdr every 30s (`.default` interval) only when the connection has been idle that long (`connectionIsIdle`, EventsSession.swift:812). A failed ping -> `keepaliveDidFail` (EventsSession.swift:891) tears the connection down.
- Write path: `SocketConnector.writeBridge`/session write returns `.peerClosed` on `EPIPE` (SessionActivity.swift:2438-2441 area — actually SessionDriver.swift's write path maps writeErrno==EPIPE to `.peerClosed`).
- Reads/writes otherwise time out via `SSHError.timedOut` derived from explicit deadlines passed through the driver (SessionDriver.swift many sites, e.g. 2590, 2676, 2699, 2764, 2796, 2809, 2829, 3674, 3691, 3737, 3811-3815, 4122).
- A socket dead while suspended is NOT noticed immediately on resume: EventsSession.swift:453-463 comment explicitly states the failure mode — "resume `ensureTransport` handed the dead socket straight to a parked ... " reader; noticing happens only via the next failed keepalive ping or failed request (the EPIPE/timedOut path), up to keepalive interval + request timeout later (this is documented as bug #142, now mitigated by `reactivate()`'s revalidate step in §2, not by the transport layer itself).

## 4. Attach channel (root screen exec herdr with PTY)
- `HerdrClientStore` does not own its own Transport connection; it "parks" on the Host's `EventsSession` Transport (comment, HerdrClientStore.swift:38-46).
- On suspend: Console-level suspend tears the whole SSH connection down (§1), which necessarily ends the exec/PTY channel too; the store itself is only told via `setPresented`/`hostStatusDidChange`, not a phase observer for the terminal itself.
- On resume/reconnect: `hostStatusDidChange` (HerdrClientStore.swift:113-124) — when status transitions to `.connected` and the terminal was `.ended`/`.stopped`, calls `replaceTerminal()`, i.e. a full new exec of `herdr` (`herdr --session <name>` or bare `herdr`) via `runTerminal` — NOT a reattach to a live process/channel. herdr's own TUI state is not preserved app-side; comment at HerdrClientStore.swift:137-139 notes "herdr's scrollback lives on the Host, so nothing local is lost" — i.e. herdr server-side session survives, but the PTY channel is always freshly exec'd.
- `rejoin()`/`leave()` (HerdrClientStore.swift:318-360) handle Console-cover overlay transitions the same way — full stop/restart of the pipeline, not a suspend-in-place.

## 5. UIBackgroundModes / push / Live Activity wake
- `project.yml` declares no `UIBackgroundModes` key at all (grep for UIBackgroundModes/BackgroundModes/remote-notification/voip/processing returned nothing); only `INFOPLIST_KEY_NSSupportsLiveActivities: YES` (project.yml:119) and standard usage-description keys (project.yml:84-121).
- No `BGTaskScheduler` usage anywhere in Sources/Heeler or Packages (grep across Transport/ and app files found none).
- Push (APNs) exists via `PushRegistrationDelegate`/`PushRegistrationStore` (HeelerApp.swift:7-10) and a `HeelerNotificationService` extension (Sources/HeelerNotificationService/Info.plist exists) for rich notification content, plus Live Activities (`HostLiveActivityCoordinator`) — these can deliver/display data without a live SSH socket, but nothing in scope indicates a push payload re-establishes or feeds the SSH transport itself; they are presentation-only wake paths.

## 6. Existing tests
- `Tests/HeelerTests/AppActivityCoordinatorTests.swift` — grace period/background-token behavior.
- `Tests/HeelerTests/ContentViewActivityDriverTests.swift` — the `.task` wiring that would go red if `ConsoleActivityDriver` were removed.
- `Tests/HeelerTests/AppForegroundRecoveryTests.swift` — foreground revalidation (#142-style recovery).
- `Tests/HeelerTests/EventsSessionKeepaliveTests.swift` — keepalive ping/failure behavior.
- `Tests/HeelerTests/ConsoleStoreNetworkPathTests.swift`, `NetworkPathObserverTests.swift` — path-change recovery, not suspend/resume per se.
- No test file specifically drives a real UIKit background-task expiration or an actual suspended-process/frozen-socket scenario (those are simulated via injected clocks/doubles in AppActivityCoordinatorTests, not device-level suspension).

## 7. Exact hook points for "keep alive N seconds, then suspend cleanly; reconnect fast on return"
- `AppActivityCoordinator.defaultGracePeriod` (AppActivityCoordinator.swift:97) — the single constant controlling "how long before deliberate teardown."
- `AppActivityCoordinator.didEnterBackground()` (AppActivityCoordinator.swift:178-198) — where the background assertion is requested and the grace timer started.
- `AppActivityCoordinator.backgroundTimeDidExpire()` (AppActivityCoordinator.swift:216-223) — fallback path when iOS reclaims time early.
- `ConsoleStore.suspendTimeout` (ConsoleStore.swift, "static let suspendTimeout: Duration = .seconds(8)") and `ConsoleStore.suspend()` (ConsoleStore.swift:182-201) — the deliberate-teardown budget/logic.
- `EventsSession.suspend()`/`resume()` (EventsSession.swift:317-322, 262-267) and `KeepalivePolicy` (EventsSession.swift:37-45) — where a longer-lived keepalive or a different suspend policy would be threaded through.
- `ConsoleStore.activate(revalidating:)` (ConsoleStore.swift:136-165) — where "reconnect fast and silently" logic (serial resume + concurrent revalidate) already lives and would be tuned.
- `HerdrClientStore.hostStatusDidChange` (HerdrClientStore.swift:113-124) — where the Attach channel's reattach-vs-replace decision is made.
- `project.yml` INFOPLIST_KEY section (around line 119) — where a `UIBackgroundModes` entry would need to be added if a background mode (e.g. voip/processing) were adopted instead of the current beginBackgroundTask-only grace period.

## Contradictions with the vault
None found in scope — the code matches the vault's description (round 12c network path observer present in NetworkPathObserver.swift/ConsoleStore; round 13 reconnect surfacing present via HerdrClientStore.statusPresentation / hostStatusDidChange wired to console.hostStatuses in HerdrClientRootView.swift:686-688). No BGTaskScheduler or UIBackgroundModes exists despite the vault not claiming otherwise; worth flagging since Open item 27 talks about "keeping the session alive longer when backgrounded" — today's only lever is `AppActivityCoordinator.defaultGracePeriod` (20s) plus whatever the OS's beginBackgroundTask grant actually allows (documented as "on the order of 30 seconds", not guaranteed).

## Files covered
- Sources/Heeler/ContentView.swift (full)
- Sources/Heeler/HeelerApp.swift (full)
- Sources/Heeler/Client/HerdrClientRootView.swift (full, incl. HerdrClientHostView)
- Sources/Heeler/Client/HerdrClientStore.swift (relevant sections)
- Sources/Heeler/Support/AppActivityCoordinator.swift (full)
- Sources/Heeler/Support/ConsoleActivityDriver.swift (full)
- Sources/Heeler/Console/ConsoleStore.swift (relevant sections)
- Sources/Heeler/Console/HostConsoleProjection.swift (relevant sections)
- Sources/Heeler/Transport/EventsSession.swift (full grep + key sections)
- Sources/Heeler/Transport/NetworkPathObserver.swift (full)
- Sources/Heeler/Transport/HerdrHostPath.swift (grepped, no background/keepalive/scenePhase hits)
- Sources/Heeler/Transport/SSHTransportSettings.swift, SSHChannelAdmission.swift, SharedAsyncOperation.swift (grepped)
- Packages/HeelerSSH/Sources/HeelerSSH/SocketConnector.swift, SSHByteTransport.swift, SessionDriver.swift, SessionActivity.swift (relevant sections + full grep for keepalive/socket/timeout)
- project.yml (grepped for UIBackgroundModes/INFOPLIST keys)
- Sources/HeelerNotificationService/Info.plist, Sources/HeelerWidgets/Info.plist (existence confirmed, not fully read — out of literal scope which named only Transport/ files, ContentView, HeelerApp, HerdrClientRootView, and Packages/HeelerSSH)
- Tests/ directory listing scanned for suspend/background/scenePhase/resume/AppActivityCoordinator/networkPath test file names
