import Foundation
import Observation

/// Where a tap lands: the root screen for a notification or Live Activity
/// (Open item 28), the right Agent detail for a tap inside the Console
/// (#74, #179).
///
/// The root of the app is herdr's own client (ADR 0017), which is what a
/// notification tap now shows — `landing` is that signal, and the root screen
/// is the only thing that reads it. `path`, `open(_:)` and the pending
/// machinery below are the Console's own: they serve the Console's
/// NavigationStack and taps made inside it. A tap can arrive there before the
/// tapped pane is known — a killed-state launch routes only once the Host's
/// first sync delivers the pane — so an unresolved target waits as pending
/// until the pane appears, the user navigates somewhere themselves, or a
/// grace window elapses. Falling back always means the Console, quietly:
/// never an alert.
@MainActor
@Observable
final class AgentNotificationRouter {
    /// The Console's NavigationStack path; ConsoleView binds to it, so user
    /// navigation and deep links share one source of truth.
    var path: [ConsoleAgent.ID] = []

    /// A tap still waiting for its pane to appear in the Console.
    private(set) var pendingTarget: AgentNotificationTarget?

    /// Whether the Console's latest Agent list has this row, as last fed
    /// through `agentsDidChange`.
    func isKnownAgent(_ id: ConsoleAgent.ID) -> Bool {
        knownAgentIDs.contains(id)
    }

    /// The most recent notification or Live Activity tap, for the root
    /// screen to land on. Nil until one arrives.
    private(set) var landing: Landing?

    /// One tap, resolved to the Host whose herdr the root screen should show.
    struct Landing: Equatable, Sendable {
        let hostID: UUID
        /// Two taps naming the same Host are two landings: the root screen
        /// watches this value, and a repeat tap must still lower the Console
        /// cover. Counted rather than time-stamped so it is exactly testable.
        let sequence: Int
    }

    @ObservationIgnored private var landingSequence = 0
    @ObservationIgnored private var knownAgentIDs: Set<ConsoleAgent.ID> = []
    @ObservationIgnored private var pendingExpiry: Task<Void, Never>?
    @ObservationIgnored private let pendingGrace: Duration

    /// `pendingGrace` bounds how long a tap may wait for its pane: long
    /// enough for a cold launch to connect and sync its Hosts, short enough
    /// that a stale pane cannot yank the user around minutes later.
    init(pendingGrace: Duration = .seconds(15)) {
        self.pendingGrace = pendingGrace
    }

    /// A tapped notification or Live Activity. It names a Host and usually a
    /// pane; only the Host is acted on, because the screen a tap lands on is
    /// herdr's own client and herdr's client cannot be told which pane to
    /// focus from outside (Open item 28). The Console is not presented and
    /// `path` is not touched — a tap that arrives while the Console cover is
    /// up lowers it instead.
    func land(onHostID hostID: UUID) {
        cancelPending()
        landingSequence += 1
        landing = Landing(hostID: hostID, sequence: landingSequence)
    }

    /// The root screen has landed the tap. Cleared rather than retained, so a
    /// screen that is rebuilt later — every Host deleted, then one added back
    /// — does not re-land a tap the user dealt with long ago.
    func landingWasHandled() { landing = nil }

    /// Routes a tap made inside the Console — its own Agent Notification
    /// banner. A known pane opens its detail at once; an unknown one parks
    /// the user on the Console and follows up if the pane arrives within the
    /// grace window; no target at all (a herdr desktop notification, an
    /// undecryptable envelope) is the Console itself, with no alarming copy.
    func open(_ target: AgentNotificationTarget?) {
        cancelPending()
        guard let target else {
            path = []
            return
        }
        if knownAgentIDs.contains(target.agentID) {
            path = [target.agentID]
        } else {
            path = []
            pendingTarget = target
            armPendingExpiry()
        }
    }

    /// The Console feed: resolves a pending tap the moment its pane appears.
    /// If the user has navigated somewhere else in the meantime, the deep
    /// link is dropped instead of yanking them away.
    func agentsDidChange(_ agents: [ConsoleAgent]) {
        knownAgentIDs = Set(agents.map(\.id))
        guard let pending = pendingTarget, knownAgentIDs.contains(pending.agentID)
        else { return }
        cancelPending()
        if path.isEmpty {
            path = [pending.agentID]
        }
    }

    private func armPendingExpiry() {
        let grace = pendingGrace
        pendingExpiry = Task { [weak self] in
            try? await Task.sleep(for: grace)
            guard !Task.isCancelled else { return }
            // Stale pane: it never showed up. Stay on the Console quietly.
            self?.pendingTarget = nil
            self?.pendingExpiry = nil
        }
    }

    private func cancelPending() {
        pendingExpiry?.cancel()
        pendingExpiry = nil
        pendingTarget = nil
    }
}
