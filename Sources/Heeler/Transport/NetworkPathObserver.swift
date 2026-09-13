import Foundation
import Network
import Observation
import OSLog

/// One observation of the device's network path.
///
/// Deliberately smaller than `NWPath`: the two facts that decide whether a
/// live SSH socket is still worth anything are whether the path is satisfied
/// at all and which interfaces are actually carrying it. A Wi-Fi→cellular
/// hand-off, a VPN toggle and a Tailscale address change all show up as the
/// second one while the first never stops being true.
struct NetworkPathSnapshot: Sendable, Equatable {
    var isSatisfied: Bool
    /// The interfaces the path is using, by name, in the order the system
    /// reports them.
    var interfaces: [String]

    init(isSatisfied: Bool, interfaces: [String] = []) {
        self.isSatisfied = isSatisfied
        self.interfaces = interfaces
    }

    /// One-line spelling for the connection trace: whether there is a path at
    /// all, and what is carrying it.
    var summary: String {
        let carried = interfaces.isEmpty ? "none" : interfaces.joined(separator: ",")
        return "\(isSatisfied ? "satisfied" : "unsatisfied") via \(carried)"
    }
}

/// Where path observations come from. A protocol so the observer can be
/// driven by a test double: `NWPathMonitor` reports real hardware, which no
/// test can move.
protocol NetworkPathSource: Sendable {
    /// A stream of observations, beginning with the current path. Finishing
    /// the stream stops the observer.
    func paths() -> AsyncStream<NetworkPathSnapshot>
}

/// The real thing: `NWPathMonitor`, converted to snapshots on its own queue
/// so nothing but a value ever crosses into the observer.
struct SystemNetworkPathSource: NetworkPathSource {
    func paths() -> AsyncStream<NetworkPathSnapshot> {
        AsyncStream { continuation in
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { path in
                continuation.yield(
                    NetworkPathSnapshot(
                        isSatisfied: path.status == .satisfied,
                        interfaces: path.availableInterfaces
                            .filter { path.usesInterfaceType($0.type) }
                            .map(\.name)))
            }
            continuation.onTermination = { _ in monitor.cancel() }
            monitor.start(queue: DispatchQueue(label: "dev.bybee.heeler.network-path"))
        }
    }
}

/// Turns a stream of path observations into the changes worth acting on.
/// Pure and synchronous, so the interesting rules are testable without a
/// network, a clock or a task.
struct NetworkPathTracker {
    enum Change: Equatable {
        /// The device has no usable path at all. Nothing to reconnect to yet.
        case lost
        /// A usable path came back after there was none.
        case restored
        /// Still satisfied, but over different interfaces: the sockets on the
        /// old ones are dead however reusable they still look.
        case interfacesChanged
    }

    private var last: NetworkPathSnapshot?

    init() {}

    /// Records an observation and reports what changed, or nil when nothing
    /// did. The first observation establishes the baseline and reports
    /// nothing: the connection was built on that path.
    mutating func record(_ snapshot: NetworkPathSnapshot) -> Change? {
        defer { last = snapshot }
        guard let last else { return nil }
        guard last != snapshot else { return nil }
        if !snapshot.isSatisfied { return last.isSatisfied ? .lost : nil }
        if !last.isSatisfied { return .restored }
        return last.interfaces == snapshot.interfaces ? nil : .interfacesChanged
    }
}

/// How hard a path change tries to repair the Hosts before giving up until
/// the next one. Capped, unlike `ReconnectPolicy`: this is a nudge on top of
/// the session's own unlimited reconnect loop, and repeating it forever would
/// only re-dial something already re-dialling.
struct NetworkPathRecoveryPolicy: Sendable, Equatable {
    var attempts: Int
    /// How many repairs a single flap storm may trigger beyond the first.
    /// Changes that arrive while a repair is running collapse into one
    /// follow-up: a VPN or Wi-Fi flap can emit a dozen path updates in a
    /// second, and replaying a full repair for each of them would keep
    /// re-dialling Hosts that are already re-dialling.
    var followUps: Int
    var backoff: ReconnectPolicy

    static let `default` = NetworkPathRecoveryPolicy(
        attempts: 4,
        followUps: 1,
        backoff: ReconnectPolicy(
            initialDelay: .milliseconds(500), multiplier: 2, maxDelay: .seconds(8)))
}

/// Collapses path changes that arrive while a repair is running down to one
/// follow-up, and reports which deliveries were collapsed.
///
/// The observer cannot do this in its own `for await`: that loop is suspended
/// for the whole repair, so every snapshot a flap produced is still sitting in
/// the stream's buffer afterwards and replays as a fresh repair. A separate
/// consumer posts here instead, and only the newest change survives.
@MainActor
private final class PathChangeInbox {
    struct Delivery {
        let change: NetworkPathTracker.Change
        /// The change arrived while a repair was already running.
        let wasCoalesced: Bool
    }

    private var pending: NetworkPathTracker.Change?
    private var arrivedDuringRepair = false
    private var isRepairing = false
    private var isFinished = false
    private var waiter: CheckedContinuation<Void, Never>?

    func post(_ change: NetworkPathTracker.Change) {
        if isRepairing || pending != nil { arrivedDuringRepair = true }
        pending = change
        resumeWaiter()
    }

    func finish() {
        isFinished = true
        resumeWaiter()
    }

    func beginRepair() { isRepairing = true }
    func endRepair() { isRepairing = false }

    func next() async -> Delivery? {
        while true {
            if let change = pending {
                pending = nil
                let coalesced = arrivedDuringRepair
                arrivedDuringRepair = false
                return Delivery(change: change, wasCoalesced: coalesced)
            }
            if isFinished || Task.isCancelled { return nil }
            await withTaskCancellationHandler {
                await withCheckedContinuation { waiter = $0 }
            } onCancel: {
                Task { @MainActor in self.finish() }
            }
        }
    }

    private func resumeWaiter() {
        let waiter = self.waiter
        self.waiter = nil
        waiter?.resume()
    }
}

/// Watches the device's network path and repairs the Host connections when it
/// moves (S1).
///
/// Without this, a Wi-Fi→cellular hand-off or a LAN→Tailscale address change
/// leaves an SSH socket that is dead but still reports `isReusable`, so
/// `EventsSession.ensureTransport` reuses it and the user stares at a
/// live-looking but frozen terminal for the keepalive interval plus a request
/// timeout — about 45 s — before `.reconnecting` even appears.
///
/// The observer owns no connection itself. It hands each change to the
/// `recover` closure (the Console's own revalidate path, which marks every
/// Transport suspect so in-flight requests fail against a closed connection
/// instead of waiting out their deadline) and retries on a capped backoff
/// while `isRecovered` still says no.
@MainActor
@Observable
final class NetworkPathObserver {
    enum State: Equatable {
        case idle
        /// No usable path. Nothing to do but wait for one.
        case offline
        case recovering(attempt: Int)
        /// The cap was reached with the Hosts still down; the session's own
        /// reconnect loop carries on, and the next path change re-arms this.
        case gaveUp
    }

    private(set) var state: State = .idle

    @ObservationIgnored private let source: any NetworkPathSource
    @ObservationIgnored private let policy: NetworkPathRecoveryPolicy
    @ObservationIgnored fileprivate var tracker = NetworkPathTracker()
    private static let log = Logger(
        subsystem: "dev.bybee.heeler", category: "network-path")

    init(
        source: any NetworkPathSource = SystemNetworkPathSource(),
        policy: NetworkPathRecoveryPolicy = .default
    ) {
        self.source = source
        self.policy = policy
    }

    /// Consumes path observations until the stream finishes or the calling
    /// task is cancelled. Drive it from a `.task` that lives as long as the
    /// app's root does.
    func run(
        recover: @escaping @MainActor () async -> Void,
        isRecovered: @escaping @MainActor () -> Bool
    ) async {
        let inbox = PathChangeInbox()
        let source = self.source
        // A separate consumer, so a repair never blocks the stream: whatever a
        // flap queues up while one is running collapses into a single
        // follow-up instead of replaying.
        let feed = Task { @MainActor [weak self] in
            defer { inbox.finish() }
            for await snapshot in source.paths() {
                guard let self, !Task.isCancelled else { return }
                guard let change = self.tracker.record(snapshot) else { continue }
                Self.log.notice(
                    "network path \(String(describing: change), privacy: .public)")
                // The connection trace's only view of the path: the session
                // sees no `NWPath`, and this is the fact that decides whether
                // a live-looking socket is worth anything. Free when off.
                ConnectionTraceLog.shared.notePath(
                    snapshot.summary, change: String(describing: change))
                inbox.post(change)
            }
        }
        defer { feed.cancel() }

        var followUps = 0
        while let delivery = await inbox.next() {
            switch delivery.change {
            case .lost:
                state = .offline
                followUps = 0
            case .restored, .interfacesChanged:
                if delivery.wasCoalesced {
                    guard followUps < policy.followUps else { continue }
                    followUps += 1
                } else {
                    followUps = 0
                }
                inbox.beginRepair()
                await repair(recover: recover, isRecovered: isRecovered)
                inbox.endRepair()
            }
        }
    }

    private func repair(
        recover: @MainActor () async -> Void,
        isRecovered: @MainActor () -> Bool
    ) async {
        for attempt in 1...max(policy.attempts, 1) {
            state = .recovering(attempt: attempt)
            await recover()
            if isRecovered() {
                state = .idle
                return
            }
            guard attempt < policy.attempts else { break }
            do {
                try await Task.sleep(for: policy.backoff.delay(beforeAttempt: attempt))
            } catch {
                state = .idle
                return
            }
        }
        Self.log.error("network path recovery gave up after \(self.policy.attempts) attempts")
        state = .gaveUp
    }
}
