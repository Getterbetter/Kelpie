import Foundation
import Testing

@testable import Heeler

/// The network path monitor (S1): which path movements are worth acting on,
/// and how hard recovery tries before leaving the session's own reconnect
/// loop to it. `NWPathMonitor` reports real hardware, so the observer is
/// driven by a stubbed source here.
@Suite("Network path observer", .timeLimit(.minutes(1)))
struct NetworkPathObserverTests {
    private struct StubPathSource: NetworkPathSource {
        let stream: AsyncStream<NetworkPathSnapshot>

        func paths() -> AsyncStream<NetworkPathSnapshot> { stream }
    }

    private static let wifi = NetworkPathSnapshot(
        isSatisfied: true, interfaces: ["en0"])
    private static let cellular = NetworkPathSnapshot(
        isSatisfied: true, interfaces: ["pdp_ip0"])
    private static let offline = NetworkPathSnapshot(isSatisfied: false)

    // MARK: The rules

    @Test func theFirstObservationIsTheBaselineAndReportsNothing() {
        var tracker = NetworkPathTracker()
        #expect(tracker.record(Self.wifi) == nil)
    }

    @Test func repeatingThePathReportsNothing() {
        var tracker = NetworkPathTracker()
        _ = tracker.record(Self.wifi)
        #expect(tracker.record(Self.wifi) == nil)
    }

    @Test func aHandoffBetweenInterfacesIsAChange() {
        // The case the whole thing exists for: still online, but every socket
        // on the old interface is dead while still reporting itself reusable.
        var tracker = NetworkPathTracker()
        _ = tracker.record(Self.wifi)
        #expect(tracker.record(Self.cellular) == .interfacesChanged)
    }

    @Test func losingAndRegainingThePathAreBothReported() {
        var tracker = NetworkPathTracker()
        _ = tracker.record(Self.wifi)
        #expect(tracker.record(Self.offline) == .lost)
        #expect(tracker.record(Self.offline) == nil)
        #expect(tracker.record(Self.cellular) == .restored)
    }

    // MARK: The observer

    @MainActor
    private final class RecoveryLog {
        var attempts = 0
        var recovered = false
    }

    @MainActor
    private func runObserver(
        _ snapshots: [NetworkPathSnapshot],
        policy: NetworkPathRecoveryPolicy,
        isRecovered: @escaping @MainActor (RecoveryLog) -> Bool
    ) async -> (observer: NetworkPathObserver, log: RecoveryLog) {
        let (stream, continuation) = AsyncStream.makeStream(of: NetworkPathSnapshot.self)
        let observer = NetworkPathObserver(
            source: StubPathSource(stream: stream), policy: policy)
        let log = RecoveryLog()
        let task = Task { @MainActor in
            await observer.run(
                recover: { log.attempts += 1 },
                isRecovered: { isRecovered(log) })
        }
        for snapshot in snapshots { continuation.yield(snapshot) }
        continuation.finish()
        await task.value
        return (observer, log)
    }

    @Test @MainActor func aPathChangeRepairsOnceWhenTheHostsComeBack() async {
        let (observer, log) = await runObserver(
            [Self.wifi, Self.cellular],
            policy: NetworkPathRecoveryPolicy(
                attempts: 4,
                followUps: 1,
                backoff: ReconnectPolicy(
                    initialDelay: .milliseconds(1), multiplier: 2, maxDelay: .milliseconds(4))),
            isRecovered: { _ in true })

        #expect(log.attempts == 1)
        #expect(observer.state == .idle)
    }

    @Test @MainActor func recoveryIsCappedAndSaysSo() async {
        // The session's own reconnect loop is unlimited; this nudge on top of
        // it must not be, or a Host that is simply down would be re-dialled
        // forever by two loops at once.
        let (observer, log) = await runObserver(
            [Self.wifi, Self.cellular],
            policy: NetworkPathRecoveryPolicy(
                attempts: 3,
                followUps: 1,
                backoff: ReconnectPolicy(
                    initialDelay: .milliseconds(1), multiplier: 2, maxDelay: .milliseconds(4))),
            isRecovered: { _ in false })

        #expect(log.attempts == 3)
        #expect(observer.state == .gaveUp)
    }

    @Test @MainActor func aFlapStormCostsOneRepairAndOneFollowUp() async {
        // A VPN or Wi-Fi flap emits a burst of path updates. The repair used
        // to be awaited inline inside the `for await`, so every snapshot the
        // burst queued replayed a full repair once the first one finished.
        let (stream, continuation) = AsyncStream.makeStream(of: NetworkPathSnapshot.self)
        let observer = NetworkPathObserver(
            source: StubPathSource(stream: stream),
            policy: NetworkPathRecoveryPolicy(
                attempts: 1,
                followUps: 1,
                backoff: ReconnectPolicy(
                    initialDelay: .milliseconds(1), multiplier: 2, maxDelay: .milliseconds(2))))
        let log = RecoveryLog()
        let flap = [Self.cellular, Self.wifi, Self.cellular, Self.wifi]
        let task = Task { @MainActor in
            await observer.run(
                recover: {
                    log.attempts += 1
                    // The rest of the storm lands while this repair runs.
                    for snapshot in flap { continuation.yield(snapshot) }
                    try? await Task.sleep(for: .milliseconds(20))
                },
                isRecovered: { true })
        }
        continuation.yield(Self.wifi)
        continuation.yield(Self.cellular)
        try? await Task.sleep(for: .milliseconds(200))
        continuation.finish()
        await task.value

        #expect(log.attempts == 2)
    }

    @Test @MainActor func losingThePathWaitsRatherThanRetrying() async {
        // Nothing to reconnect to yet: dialling an unsatisfied path only
        // burns the attempt cap before the path comes back.
        let (observer, log) = await runObserver(
            [Self.wifi, Self.offline],
            policy: .default,
            isRecovered: { _ in true })

        #expect(log.attempts == 0)
        #expect(observer.state == .offline)
    }
}
