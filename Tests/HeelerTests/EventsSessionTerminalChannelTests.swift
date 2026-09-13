import Foundation
import Testing

@testable import Heeler

/// The events session's terminal-channel seam under failure: a dead Attach
/// channel is evidence about the connection (S2), a moved network path is
/// evidence about every connection (S1), and teardown is bounded whatever the
/// permit holder does (M2).
///
/// Bounded on purpose: a regression here is a session that never emits again,
/// which must fail these tests rather than hang the run.
@Suite("EventsSession terminal channel", .timeLimit(.minutes(1)))
struct EventsSessionTerminalChannelTests {
    private let subscriptions: [EventSubscription] = [.global(.paneAgentDetected)]

    private func makeSession(
        connect: @escaping @Sendable () async throws -> any Transport,
        keepalive: KeepalivePolicy? = nil,
        terminalIdleTimeout: Duration = .seconds(5),
        terminalAcquisitionTimeout: Duration = .seconds(30),
        streamEndTimeout: Duration = .seconds(2),
        terminalWaiterDidRegister: (@Sendable () -> Void)? = nil
    ) -> EventsSession {
        EventsSession(
            subscriptions: subscriptions,
            connect: connect,
            reconnectPolicy: ReconnectPolicy(
                initialDelay: .milliseconds(10), multiplier: 2, maxDelay: .milliseconds(50)),
            keepalive: keepalive,
            terminalIdleTimeout: terminalIdleTimeout,
            terminalAcquisitionTimeout: terminalAcquisitionTimeout,
            streamEndTimeout: streamEndTimeout,
            terminalWaiterDidRegister: terminalWaiterDidRegister)
    }

    // MARK: A dead Attach channel distrusts the connection (S2)

    @Test func anAttachChannelFailureTakesTheHostOffConnected() async throws {
        // Before this, the attach surface went `.ended` with a Reconnect
        // button while the session stayed parked on a stream a dead socket
        // never ends — the Host still read green, and Reconnect re-attached
        // over the same dead transport.
        let first = ScriptedTransport()
        let second = ScriptedTransport()
        let connector = SequencedTransportConnector([first, second])
        let session = makeSession(connect: { try await connector.connect() })
        var updates = session.updates.makeAsyncIterator()

        await session.resume()
        #expect(await updates.next() == .status(.connecting))
        #expect(await updates.next() == .status(.connected))

        let failure = TransportError.sshUnreachable(detail: "the link went away")
        await #expect(throws: failure) {
            try await session.withTerminalTransport { _, _ in throw failure }
        }

        guard case .status(.reconnecting(_, _, let reported)) = await updates.next() else {
            Issue.record("expected .reconnecting after the attach channel died")
            await session.end()
            return
        }
        #expect(reported == failure)
        #expect(await updates.next() == .status(.connected))
        // Rebuilt, not reused: the dead connection was closed and a fresh one
        // dialled and pinged.
        #expect(await connector.connectCount == 2)
        #expect(await first.isClosed)

        await session.end()
    }

    @Test func aRemoteExitIsNotTransportDeath() async throws {
        // The loop this closes: a bad `--session` name — user-editable since
        // round 12 — makes herdr exit nonzero, which arrives as
        // `.channelFailed(detail: "attach channel: remote exit status N")`.
        // Treating that as a dead link marked a healthy transport suspect,
        // bumped the generation, replaced the terminal, and herdr exited
        // again, forever.
        let transport = ScriptedTransport()
        let connector = SequencedTransportConnector([transport])
        let session = makeSession(connect: { try await connector.connect() })
        var updates = session.updates.makeAsyncIterator()

        await session.resume()
        #expect(await updates.next() == .status(.connecting))
        #expect(await updates.next() == .status(.connected))

        let exit = HeelerSSHTransport.attachChannelFailure(
            exitStatus: 1, attachCommand: "herdr --session \"gone\"")
        await #expect(throws: exit) {
            try await session.withTerminalTransport { _, _ in throw exit }
        }

        #expect(await session.transportIsSuspect == false)
        #expect(await connector.connectCount == 1)
        #expect(await transport.isClosed == false)

        await session.end()
    }

    @Test func aCancelledAttachLeavesTheConnectionAlone() async throws {
        // Leaving the Client for the Console cover cancels its attach several
        // times a session; that is not evidence of anything.
        let transport = ScriptedTransport()
        let connector = SequencedTransportConnector([transport])
        let session = makeSession(connect: { try await connector.connect() })
        var updates = session.updates.makeAsyncIterator()

        await session.resume()
        #expect(await updates.next() == .status(.connecting))
        #expect(await updates.next() == .status(.connected))

        await #expect(throws: TransportError.cancelled) {
            try await session.withTerminalTransport { _, _ in
                throw TransportError.cancelled
            }
        }

        #expect(await session.transportIsSuspect == false)
        #expect(await connector.connectCount == 1)
        #expect(await transport.isClosed == false)

        await session.end()
    }

    // MARK: A moved network path distrusts every connection (S1)

    @Test func aNetworkPathChangeRebuildsTheTransport() async throws {
        // Wi-Fi→cellular, a VPN toggle, a LAN→Tailscale address change: the
        // socket is dead but still reports itself reusable, and without this
        // the user waits out the keepalive interval plus a request timeout.
        let first = ScriptedTransport()
        let second = ScriptedTransport()
        let connector = SequencedTransportConnector([first, second])
        let session = makeSession(connect: { try await connector.connect() })
        var updates = session.updates.makeAsyncIterator()

        await session.resume()
        #expect(await updates.next() == .status(.connecting))
        #expect(await updates.next() == .status(.connected))

        await session.networkPathDidChange()

        guard case .status(.reconnecting(_, _, let reported)) = await updates.next() else {
            Issue.record("expected .reconnecting after the network path moved")
            await session.end()
            return
        }
        #expect(reported == .sshUnreachable(detail: "The network connection changed."))
        #expect(await updates.next() == .status(.connected))
        #expect(await connector.connectCount == 2)
        #expect(await first.isClosed)

        await session.end()
    }

    @Test func aNetworkPathChangeWhileSuspendedIsStillRecorded() async throws {
        // A suspended session does no repair work — that is `resume()`'s
        // business — but the suspicion has to survive until it does. iOS
        // freezes sockets while the process is suspended and `isConnected` is
        // the driver's own reusable flag rather than a probe, so a path move
        // that went unrecorded came back as a "reusable" dead socket, handed
        // straight to whichever Attach was waiting for it.
        let transport = ScriptedTransport()
        let connector = SequencedTransportConnector([transport])
        let session = makeSession(connect: { try await connector.connect() })

        await session.networkPathDidChange()

        #expect(await session.transportIsSuspect)
        #expect(await connector.connectCount == 0)
        await session.end()
    }

    // MARK: A parked Attach is bounded and told why

    @Test func aParkedAttachFailsAtItsDeadlineRatherThanWaitingForever() async throws {
        // The root screen's indefinite "Connecting…" off Wi-Fi: the Client's
        // attach parks on a Transport the session has not installed, and a
        // retryable reconnect loop resumed waiters only on success — so the
        // spinner outlived the process with nothing on screen to act on.
        let (registrations, registrationContinuation) = AsyncStream.makeStream(of: Void.self)
        var registrationIterator = registrations.makeAsyncIterator()
        let transport = ScriptedTransport()
        let session = makeSession(
            connect: { transport },
            terminalAcquisitionTimeout: .milliseconds(100),
            terminalWaiterDidRegister: { registrationContinuation.yield() })

        // Never resumed: no Transport exists and no run loop is working on one.
        let parked = Task {
            try await session.withTerminalTransport { _, _ in
                Issue.record("a parked attach was handed a Transport")
            }
        }
        _ = await registrationIterator.next()

        await #expect(throws: TransportError.timedOut) { try await parked.value }

        await session.end()
        registrationContinuation.finish()
    }

    @Test func aRetryableFailureFailsTheParkedAttachToo() async throws {
        // The loop keeps retrying — that is right — but the surface waiting on
        // it needs the reason in the meantime, and the backoff caps at
        // `maxDelay` per attempt with no attempt limit.
        let failure = TransportError.sshUnreachable(detail: "the tunnel is down")
        let (registrations, registrationContinuation) = AsyncStream.makeStream(of: Void.self)
        var registrationIterator = registrations.makeAsyncIterator()
        let session = makeSession(
            connect: { throw failure },
            terminalWaiterDidRegister: { registrationContinuation.yield() })
        var updates = session.updates.makeAsyncIterator()

        let parked = Task {
            try await session.withTerminalTransport { _, _ in
                Issue.record("a failing session handed out a Transport")
            }
        }
        _ = await registrationIterator.next()

        await session.resume()
        #expect(await updates.next() == .status(.connecting))

        await #expect(throws: failure) { try await parked.value }
        // The session itself is unchanged: still retrying, not failed.
        guard case .status(.reconnecting(_, _, let reported)) = await updates.next() else {
            Issue.record("expected the session to keep retrying")
            await session.end()
            return
        }
        #expect(reported == failure)

        await session.end()
        registrationContinuation.finish()
    }

    // MARK: Teardown is bounded (M2)

    @Test func teardownStopsWaitingForAWedgedAttachPermit() async throws {
        // This await is the last link in the chain the app's UIKit background
        // assertion hangs on: unbounded, a stalled SSH close means
        // `didFinishSuspending()` never runs and iOS kills the app.
        let transport = ScriptedTransport()
        let session = makeSession(
            connect: { transport }, terminalIdleTimeout: .milliseconds(100))
        var updates = session.updates.makeAsyncIterator()

        await session.resume()
        #expect(await updates.next() == .status(.connecting))
        #expect(await updates.next() == .status(.connected))

        let acquired = AsyncStream.makeStream(of: Void.self)
        var acquiredIterator = acquired.stream.makeAsyncIterator()
        let stalled = Task {
            try await session.withTerminalTransport { _, _ in
                acquired.continuation.yield()
                // A teardown that ignores cancellation, as a wedged libssh2
                // close does.
                await Task.detached { try? await Task.sleep(for: .seconds(30)) }.value
            }
        }
        _ = await acquiredIterator.next()

        let started = ContinuousClock.now
        await session.suspend()
        let elapsed = started.duration(to: .now)

        #expect(elapsed < .seconds(2))
        #expect(await updates.next() == .status(.suspended))
        stalled.cancel()
        await session.end()
    }

    @Test func aPathChangeRecoversEvenWhenTheChannelCloseNeverReturns() async throws {
        // Open item 22, off Wi-Fi over Tailscale: the path moved, the session
        // ended its channel — and the ender never came back, because the SSH
        // driver's operation mutex has no deadline and the socket was gone
        // without an RST. Parked inside `end()`, the run loop could not retry,
        // reconnect or even keep the keepalive going, so the root screen read
        // "Reconnecting" for the life of the process. A gate the test never
        // opens is that close.
        let first = ScriptedTransport()
        let second = ScriptedTransport()
        let wedged = ScriptedTransportCallGate()
        await first.gateNextStreamEnd(using: wedged)
        let connector = SequencedTransportConnector([first, second])
        let session = makeSession(
            connect: { try await connector.connect() },
            streamEndTimeout: .milliseconds(100))
        var updates = session.updates.makeAsyncIterator()

        await session.resume()
        #expect(await updates.next() == .status(.connecting))
        #expect(await updates.next() == .status(.connected))

        await session.networkPathDidChange()

        guard case .status(.reconnecting(_, _, let reported)) = await updates.next() else {
            Issue.record("expected .reconnecting despite the stalled channel close")
            await session.end()
            return
        }
        #expect(reported == .sshUnreachable(detail: "The network connection changed."))
        #expect(await updates.next() == .status(.connected))
        // The graceful close really was attempted, and really never returned:
        // the session got past it by abandoning the transport instead.
        #expect(await wedged.entryCount == 1)
        #expect(await first.abandonedStreamCount == 1)
        #expect(await connector.connectCount == 2)
        #expect(await second.capturedSubscriptions == [subscriptions])

        await session.end()
    }

    @Test func aKeepaliveFailureRecoversEvenWhenTheChannelCloseNeverReturns() async throws {
        // The same stall on the other path that writes the connection off: an
        // unanswered keepalive ping. Ping 1 is the connect path's; ping 2 is
        // the one the dead link swallows.
        let first = ScriptedTransport()
        let second = ScriptedTransport()
        let wedged = ScriptedTransportCallGate()
        await first.failPing(atCall: 2, with: .timedOut)
        await first.gateNextStreamEnd(using: wedged)
        let connector = SequencedTransportConnector([first, second])
        let session = makeSession(
            connect: { try await connector.connect() },
            keepalive: KeepalivePolicy(interval: .milliseconds(20)),
            streamEndTimeout: .milliseconds(100))
        var updates = session.updates.makeAsyncIterator()

        await session.resume()
        #expect(await updates.next() == .status(.connecting))
        #expect(await updates.next() == .status(.connected))

        guard case .status(.reconnecting(_, _, let reported)) = await updates.next() else {
            Issue.record("expected .reconnecting despite the stalled channel close")
            await session.end()
            return
        }
        #expect(reported == .timedOut)
        #expect(await updates.next() == .status(.connected))
        #expect(await wedged.entryCount == 1)
        #expect(await first.abandonedStreamCount == 1)
        #expect(await connector.connectCount == 2)

        await session.end()
    }

    @Test func aHealthyChannelStillEndsGracefully() async throws {
        // The bound is a fallback, not the mechanism: a channel that can close
        // does, well inside the deadline, and nothing is abandoned — a
        // connection the session could have kept is never thrown away.
        let first = ScriptedTransport()
        let second = ScriptedTransport()
        let connector = SequencedTransportConnector([first, second])
        let session = makeSession(
            connect: { try await connector.connect() },
            streamEndTimeout: .seconds(30))
        var updates = session.updates.makeAsyncIterator()

        await session.resume()
        #expect(await updates.next() == .status(.connecting))
        #expect(await updates.next() == .status(.connected))

        let started = ContinuousClock.now
        await session.networkPathDidChange()
        #expect(started.duration(to: .now) < .seconds(1))

        guard case .status(.reconnecting(_, _, let reported)) = await updates.next() else {
            Issue.record("expected .reconnecting after the network path moved")
            await session.end()
            return
        }
        #expect(reported == .sshUnreachable(detail: "The network connection changed."))
        #expect(await updates.next() == .status(.connected))
        #expect(await first.abandonedStreamCount == 0)

        await session.end()
    }
}
