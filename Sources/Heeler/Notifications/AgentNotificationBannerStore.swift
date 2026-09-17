import AudioToolbox
import Foundation
import Observation

/// One in-app Agent Notification banner ready to display (#77): where a tap
/// lands and the exact push-renderer copy, so in-app and APNs wording cannot
/// drift.
struct AgentNotificationBanner: Equatable, Sendable {
    /// Where a tap lands. Nil for a banner with nowhere to go — a desktop
    /// notification the remote terminal asked for names no pane, and the tap
    /// only dismisses it.
    let target: AgentNotificationTarget?
    let alert: AgentNotificationAlert
}

/// The banner store the view hierarchy actually kept, for the code that
/// cannot be handed one: `AgentNotificationCenterDelegate` is built by the
/// UIKit app delegate, before any view exists, and must reach the live store
/// when a foreground push arrives.
///
/// Adopted from `agentsDidChange`, not from `init`: SwiftUI builds a
/// `ContentView` (and its `@State` initial values) more than once and keeps
/// only one, so a store that registered itself at construction could publish
/// an instance nothing draws. The Console feed reaches the retained store
/// alone.
@MainActor
enum AgentNotificationBannerPresenter {
    private(set) static weak var store: AgentNotificationBannerStore?

    static func adopt(_ store: AgentNotificationBannerStore) {
        self.store = store
    }
}

/// Announces foreground Blocked/Done Agent transitions from the Console's
/// live Agent list (#77), and presents pushes that arrive while the app is
/// foregrounded (`AgentNotificationCenterDelegate.willPresent`).
///
/// The gates mirror the plugin's pipeline, app-side: a transition must hold
/// `holdDuration` before announcing (herdr's status detection flaps), an
/// unchanged status never repeats, the presented Agent stays silent (spec
/// #68, story 8, decided at fire time like the push path), and a Host whose
/// notify flags say so stays quiet.
///
/// The flag gate below still fails closed on a nil, but its production
/// source — `NotificationPreferencesStore.confirmedTriggers(for:)` — no
/// longer returns one: this banner is local and needs no push registration,
/// and gating it on one is what made it silent (Open item 19). See that
/// method for the reasoning.
@MainActor
@Observable
final class AgentNotificationBannerStore {
    private(set) var banner: AgentNotificationBanner?

    /// Last observed status per pane; a banner candidate is a change of it.
    @ObservationIgnored private var statuses: [ConsoleAgent.ID: AgentStatus] = [:]
    /// In-flight anti-flap holds, cancelled when the status moves on.
    @ObservationIgnored private var holds: [ConsoleAgent.ID: Task<Void, Never>] = [:]
    @ObservationIgnored private var dismissal: Task<Void, Never>?
    /// What was last announced for a pane, when, and by which pipeline. One
    /// key, checked in both directions: whichever of the live event stream
    /// and the push arrives second recognises the other's announcement and
    /// stays quiet. Checking it one way only meant a push that won the race
    /// was followed by the Console's own banner a hold later.
    @ObservationIgnored private var announced: [ConsoleAgent.ID: Announcement] = [:]
    @ObservationIgnored private let holdDuration: Duration
    @ObservationIgnored private let adoptsPresenter: Bool
    @ObservationIgnored private let dismissDelay: Duration
    @ObservationIgnored private let duplicateWindow: Duration
    @ObservationIgnored private let presentedAgent: @MainActor () -> ConsoleAgent.ID?
    @ObservationIgnored private let triggers:
        @MainActor (Host.ID) -> NotificationTriggerPreferences?
    @ObservationIgnored private let playSound: @MainActor () -> Void

    /// - Parameters:
    ///   - holdDuration: how long a transition must hold before announcing.
    ///   - dismissDelay: how long a shown banner stays before auto-dismissing.
    ///   - presentedAgent: the Agent currently on screen (the router's
    ///     `path.last`), read at fire time.
    ///   - triggers: the Host's *confirmed* notify flags; nil (unregistered,
    ///     unreachable, still loading) means no banner.
    ///   - playSound: the banner's sound; 1007 is the system SMS-alert tone,
    ///     played through the alert route so the ringer switch is honored.
    ///   - duplicateWindow: how long an announced transition suppresses the
    ///     matching push, which travels the plugin → relay → APNs path for
    ///     the same status change and lands within seconds of it.
    ///   - adoptsPresenter: whether the Console feed makes this store the
    ///     one `AgentNotificationBannerPresenter` hands foreground pushes
    ///     to. The app's store adopts; a test's must not, or a real push
    ///     arriving on the device mid-run lands in it (seen on the iPad,
    ///     round 30).
    init(
        holdDuration: Duration = .seconds(3),
        dismissDelay: Duration = .seconds(5),
        duplicateWindow: Duration = .seconds(30),
        adoptsPresenter: Bool = true,
        presentedAgent: @escaping @MainActor () -> ConsoleAgent.ID?,
        triggers: @escaping @MainActor (Host.ID) -> NotificationTriggerPreferences?,
        playSound: @escaping @MainActor () -> Void = { AudioServicesPlayAlertSound(1007) }
    ) {
        self.holdDuration = holdDuration
        self.dismissDelay = dismissDelay
        self.duplicateWindow = duplicateWindow
        self.adoptsPresenter = adoptsPresenter
        self.presentedAgent = presentedAgent
        self.triggers = triggers
        self.playSound = playSound
    }

    /// The Console feed, same as the router's: diff each pane's status
    /// against the last observed one. First sight is baseline, never a
    /// transition — a killed-state launch must not banner every Agent that
    /// was already Blocked when it synced.
    func agentsDidChange(_ agents: [ConsoleAgent]) {
        if adoptsPresenter { AgentNotificationBannerPresenter.adopt(self) }
        let current = Dictionary(agents.map { ($0.id, $0) }) { _, last in last }
        // A Host still listing agents is a Host whose snapshot is live, so a
        // pane missing from it really exited and its baseline goes.
        //
        // A Host listing none of them is almost always a cleared snapshot,
        // not every Agent quitting at once: `HostConsoleProjection`
        // invalidates `agentsByPane` on every reconnect and revalidation,
        // which on an iPad happens on sleep, a network change, or a missed
        // keepalive. Baselines are kept across that, so a Blocked or Done
        // that happened while the link was down banners once on the first
        // snapshot back instead of being swallowed as "first sight".
        let hostsWithLiveRows = Set(agents.map(\.hostID))
        for id in Array(statuses.keys) where current[id] == nil {
            cancelHold(for: id)
            if hostsWithLiveRows.contains(id.hostID) {
                statuses[id] = nil
                announced[id] = nil
            }
        }
        for (id, agent) in current {
            let previous = statuses[id]
            let status = agent.agent.status
            guard status != previous else { continue }
            statuses[id] = status
            cancelHold(for: id)
            guard previous != nil, status == .blocked || status == .done else { continue }
            scheduleHold(for: agent, status: status)
        }
    }

    /// A notification the terminal itself asked for (OSC 9 / OSC 777, via
    /// `TerminalDesktopNotificationRelay`). None of the Agent-transition
    /// gates apply: herdr already decided this was worth saying, there is no
    /// status to de-flap, and there is no pane to suppress it for. It shares
    /// the banner slot, so the newest message wins.
    func present(_ notification: TerminalDesktopNotification) {
        announce(
            AgentNotificationBanner(
                target: nil,
                alert: AgentNotificationAlert(
                    title: notification.title, body: notification.body)),
            from: .liveStream)
    }

    /// A push that arrived while the app is foregrounded. None of the
    /// transition gates apply: the plugin already decided this was worth
    /// sending, and the app's own list may not even have seen the change
    /// (a reconnecting Console, an unregistered-looking Host). The copy is
    /// the service extension's, so the two paths still read identically.
    ///
    /// The one gate that stays is de-duplication: this store announces the
    /// same transition from the live event stream, typically a second or two
    /// before the push completes its trip through the relay and APNs, and
    /// two alerts for one event is worse than either alone.
    func presentPush(target: AgentNotificationTarget, alert: AgentNotificationAlert) {
        announce(AgentNotificationBanner(target: target, alert: alert), from: .push)
    }

    func dismiss() {
        dismissal?.cancel()
        dismissal = nil
        banner = nil
    }

    private func scheduleHold(for agent: ConsoleAgent, status: AgentStatus) {
        let hold = holdDuration
        holds[agent.id] = Task { [weak self] in
            try? await Task.sleep(for: hold)
            guard !Task.isCancelled else { return }
            self?.holds[agent.id] = nil
            self?.present(agent, status: status)
        }
    }

    private func cancelHold(for id: ConsoleAgent.ID) {
        holds[id]?.cancel()
        holds[id] = nil
    }

    /// The held transition fires: apply the presentation-time gates, then
    /// show the banner with the push renderer's exact copy.
    private func present(_ agent: ConsoleAgent, status: AgentStatus) {
        let target = AgentNotificationTarget(hostID: agent.hostID, paneID: agent.agent.paneID)
        guard
            !AgentNotificationRouting.shouldSuppressBanner(
                target: target, presentedAgent: presentedAgent())
        else { return }
        guard let notify = triggers(agent.hostID),
            status == .done ? notify.done : notify.blocked
        else { return }
        announce(
            AgentNotificationBanner(
                target: target,
                alert: AgentNotificationRenderer.alert(
                    workspace: agent.workspaceLabel, agentKind: agent.agent.kind,
                    status: status)),
            from: .liveStream)
    }

    /// Which pipeline announced a transition. Only a *cross*-pipeline repeat
    /// is a duplicate: the same pipeline saying the same thing again is a
    /// genuine second transition (Blocked, answered, Blocked again), and
    /// swallowing that would be the original silence bug in miniature.
    private enum AnnouncementSource: Equatable {
        case liveStream
        case push
    }

    private struct Announcement {
        let alert: AgentNotificationAlert
        let at: ContinuousClock.Instant
        let source: AnnouncementSource
    }

    /// Shows a banner and records it, unless the other pipeline already
    /// announced this exact transition within `duplicateWindow`.
    private func announce(_ banner: AgentNotificationBanner, from source: AnnouncementSource) {
        if let agentID = banner.target?.agentID {
            if let previous = announced[agentID], previous.source != source,
                previous.alert == banner.alert,
                previous.at.duration(to: .now) < duplicateWindow
            {
                return
            }
            announced[agentID] = Announcement(alert: banner.alert, at: .now, source: source)
        }
        self.banner = banner
        playSound()
        armDismissal()
    }

    private func armDismissal() {
        dismissal?.cancel()
        let delay = dismissDelay
        dismissal = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.dismissal = nil
            self?.banner = nil
        }
    }
}
