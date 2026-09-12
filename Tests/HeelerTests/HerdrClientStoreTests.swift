import Foundation
import Testing

@testable import Heeler

/// The ADR 0017 root screen's store, which had no tests at all: the Host
/// fields it reads live, the states it can be parked in, and the bounded
/// hand-off that lets the Console open over it.
///
/// No SSH and no UI — the attach runner is a closure, so every test here
/// observes exactly what the store would have put on the wire.
@MainActor
@Suite("herdr client store", .timeLimit(.minutes(1)))
struct HerdrClientStoreTests {
    /// Records the target of every attach the store starts, in order.
    private final class AttachLog: @unchecked Sendable {
        private let lock = NSLock()
        private var targets: [TerminalAttachTarget] = []

        func record(_ target: TerminalAttachTarget) {
            lock.lock()
            defer { lock.unlock() }
            targets.append(target)
        }

        var recorded: [TerminalAttachTarget] {
            lock.lock()
            defer { lock.unlock() }
            return targets
        }
    }

    /// A store whose attaches are recorded and then refused. The refusal is
    /// what a Host that went away produces, and it keeps each test to the one
    /// question it is asking: which session the attach named.
    private func makeStore(
        sessionName: String?, log: AttachLog
    ) -> HerdrClientStore {
        HerdrClientStore(
            hostID: Host.fixture().id,
            sessionName: sessionName,
            transportGeneration: 0
        ) { request, _ in
            log.record(request.target)
            throw TransportError.sshUnreachable(detail: "not connected")
        }
    }

    /// Polls until `condition` holds, yielding so the store's queued lifecycle
    /// transitions can run.
    private func waitUntil(
        _ comment: Comment, timeout: Duration = .seconds(5),
        condition: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(condition(), comment)
    }

    // MARK: The Host's session name is read live (M1)

    @Test func editingTheHostSessionNameReachesTheNextAttach() async throws {
        // The bug this replaces: `Host.id` survives an edit, the root view is
        // identified by that id, and the store captured the session name at
        // init — so every later attach kept exec-ing the old session until the
        // app was relaunched.
        let log = AttachLog()
        let store = makeStore(sessionName: "work", log: log)
        store.viewDidResize(cols: 80, rows: 24)
        try await waitUntil("the first attach should name the Host's session") {
            log.recorded == [.client(session: "work")]
        }

        let firstSurface = store.terminalID
        store.hostDidChange(sessionName: "release")
        try await waitUntil("a new session name should rebuild the pipeline") {
            store.terminalID != firstSurface
        }
        store.viewDidResize(cols: 80, rows: 24)

        try await waitUntil("the next attach should name the edited session") {
            log.recorded == [.client(session: "work"), .client(session: "release")]
        }
        #expect(store.sessionName == "release")
    }

    @Test func aClearedSessionNameMeansTheDefaultSession() async throws {
        // What `HostFormView` leaves behind when the user empties the field:
        // whitespace, which must mean bare `herdr`, not `--session "  "`.
        let log = AttachLog()
        let store = makeStore(sessionName: "work", log: log)
        store.viewDidResize(cols: 80, rows: 24)
        try await waitUntil("the first attach should happen") { !log.recorded.isEmpty }

        let firstSurface = store.terminalID
        store.hostDidChange(sessionName: "   ")
        try await waitUntil("clearing the name should rebuild the pipeline") {
            store.terminalID != firstSurface
        }
        store.viewDidResize(cols: 80, rows: 24)

        try await waitUntil("the next attach should run the default session") {
            log.recorded.last == .client(session: nil)
        }
        #expect(store.sessionName == nil)
    }

    @Test func anUnchangedSessionNameDoesNotDisturbTheLivePipeline() async throws {
        let log = AttachLog()
        let store = makeStore(sessionName: "work", log: log)
        store.viewDidResize(cols: 80, rows: 24)
        try await waitUntil("the first attach should happen") { !log.recorded.isEmpty }
        let surface = store.terminalID

        // The same name arrives on every Host edit, including ones that
        // changed something else entirely.
        store.hostDidChange(sessionName: " work ")

        try await Task.sleep(for: .milliseconds(50))
        #expect(store.terminalID == surface)
        #expect(log.recorded == [.client(session: "work")])
    }

    // MARK: Every state has a visible representation (S3)

    @Test func aDetachedClientStillOnScreenOffersAReconnectThatWorks() async throws {
        // An `onDisappear` without its balancing `onAppear` leaves the
        // pipeline stopped under a visible view. That used to render as no
        // overlay at all: a frozen last frame with no way back.
        let log = AttachLog()
        let store = makeStore(sessionName: "work", log: log)
        store.viewDidResize(cols: 80, rows: 24)
        try await waitUntil("the first attach should happen") { !log.recorded.isEmpty }

        await store.leave().value
        #expect(store.needsRejoin)
        #expect(store.statusPresentation == .rejoinRequired)

        store.reconnect()
        try await waitUntil("Reconnect should rejoin rather than no-op") {
            !store.needsRejoin
        }
        #expect(store.statusPresentation?.kind == .connecting)
        store.viewDidResize(cols: 80, rows: 24)
        try await waitUntil("the rejoin should attach again") {
            log.recorded.count == 2
        }
    }

    @Test func aClientBehindTheConsoleCoverDrawsNoOverlay() async throws {
        // The other way to be detached: the cover is up on purpose, the
        // Console is drawing its own screen, and the Client is off stage.
        let log = AttachLog()
        let store = makeStore(sessionName: "work", log: log)
        store.viewDidResize(cols: 80, rows: 24)
        try await waitUntil("the first attach should happen") { !log.recorded.isEmpty }

        store.setPresented(false)
        try await waitUntil("the Client should let the channel go") {
            store.terminal.status == .stopped
        }
        #expect(!store.needsRejoin)
        #expect(store.statusPresentation == nil)
    }

    @Test func aRemoteExitNamesTheSessionAndWaitsForTheUser() async throws {
        // herdr refusing a session name that no longer exists is the common
        // case now that the name is editable. It ends the attach; it must not
        // start another one by itself, and the overlay has to say which
        // session was asked for.
        let log = AttachLog()
        let store = HerdrClientStore(
            hostID: Host.fixture().id,
            sessionName: "gone",
            transportGeneration: 0
        ) { request, _ in
            log.record(request.target)
            throw HeelerSSHTransport.attachChannelFailure(
                exitStatus: 1, attachCommand: "herdr --session \"gone\"")
        }
        store.viewDidResize(cols: 80, rows: 24)

        try await waitUntil("the attach should end on the remote exit") {
            store.statusPresentation?.kind == .ended
        }
        let message = try #require(store.statusPresentation?.message)
        #expect(message.contains("gone"))
        #expect(message.contains("1"))

        // No auto-rejoin: one attach, and it stays ended until the user acts.
        try await Task.sleep(for: .milliseconds(100))
        #expect(log.recorded.count == 1)
        #expect(store.statusPresentation?.kind == .ended)
    }

    // MARK: The Console hand-off is bounded (S4)

    @Test func theConsoleHandoffGivesUpRatherThanHangingForever() async throws {
        // A teardown that ignores cancellation, as a wedged SSH close does.
        // Before the deadline this made the Console unreachable for the rest
        // of the session, with nothing on screen to say so.
        let store = HerdrClientStore(
            hostID: Host.fixture().id,
            sessionName: nil,
            transportGeneration: 0
        ) { _, _ in
            await Task.detached { try? await Task.sleep(for: .seconds(30)) }.value
        }
        store.viewDidResize(cols: 80, rows: 24)
        let commands = HerdrClientCommands()
        commands.store = store

        let started = ContinuousClock.now
        let handedOver = await commands.prepareForConsole(timeout: .milliseconds(150))

        #expect(!handedOver)
        #expect(started.duration(to: .now) < .seconds(2))
    }

    @Test func aPromptHandoffReportsSuccess() async throws {
        let log = AttachLog()
        let store = makeStore(sessionName: nil, log: log)
        store.viewDidResize(cols: 80, rows: 24)
        try await waitUntil("the first attach should happen") { !log.recorded.isEmpty }
        let commands = HerdrClientCommands()
        commands.store = store

        #expect(await commands.prepareForConsole(timeout: .seconds(5)))
    }

    @Test func aHandoffWithNoLiveClientSucceedsImmediately() async {
        // The Welcome screen's case: no Host, so no store, and the Console
        // must still open.
        let commands = HerdrClientCommands()
        #expect(await commands.prepareForConsole(timeout: .milliseconds(50)))
    }
}
