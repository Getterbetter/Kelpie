import Foundation
import Testing

@testable import Heeler

/// The in-app foreground banner (#77): Blocked/Done transitions observed on
/// the Console's live Agent list must hold before announcing (anti-flap),
/// never repeat for an unchanged status (dedupe), stay silent for the
/// presented Agent and for Hosts whose notification preferences are unknown
/// or off (fail closed), and auto-dismiss after a few seconds.
///
/// Pane ids here stand in for live herdr addresses, so they use the observed
/// alphanumeric `w…:p…` family (uppercase included). The store only compares
/// them as opaque strings.
@MainActor
@Suite("Agent notification banner store")
struct AgentNotificationBannerStoreTests {
    private let hostID = UUID()

    /// Mutable fixtures the store's injected closures read at fire time.
    @MainActor
    private final class World {
        var presentedAgent: ConsoleAgent.ID?
        var triggers: [UUID: NotificationTriggerPreferences] = [:]
        var soundCount = 0
    }

    private let world = World()

    private func makeStore(
        holdDuration: Duration = .milliseconds(20),
        dismissDelay: Duration = .seconds(5)
    ) -> AgentNotificationBannerStore {
        let world = world
        return AgentNotificationBannerStore(
            holdDuration: holdDuration,
            dismissDelay: dismissDelay,
            adoptsPresenter: false,
            presentedAgent: { world.presentedAgent },
            triggers: { world.triggers[$0] },
            playSound: { world.soundCount += 1 })
    }

    private func agent(
        _ paneID: String, _ status: AgentStatus,
        hostID: UUID? = nil, kind: String = "claude", workspaceLabel: String? = nil
    ) -> ConsoleAgent {
        ConsoleAgent(
            hostID: hostID ?? self.hostID, hostName: "mac-studio",
            agent: Agent(.fixture(paneID: paneID, status: status, kind: kind)),
            workspaceLabel: workspaceLabel,
            repositoryCheckout: nil,
            lastOutputSnippet: nil)
    }

    /// Polls until `condition` holds, yielding so the store's tasks progress.
    private func waitUntil(
        _ comment: Comment, timeout: Duration = .seconds(2),
        condition: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(condition(), comment)
    }

    /// Lets any (wrongly) scheduled hold elapse so silence is meaningful.
    private func waitPastHold() async throws {
        try await Task.sleep(for: .milliseconds(100))
    }

    // MARK: Transition detection and copy

    @Test func blockedTransitionBannersAfterTheHoldWithThePushCopy() async throws {
        world.triggers[hostID] = NotificationTriggerPreferences()
        let store = makeStore()
        store.agentsDidChange([agent("wV:p1", .working)])

        store.agentsDidChange([agent("wV:p1", .blocked)])
        #expect(store.banner == nil, "the transition must hold before announcing")

        try await waitUntil("the banner should show once the hold elapses") {
            store.banner != nil
        }
        #expect(
            store.banner
                == AgentNotificationBanner(
                    target: AgentNotificationTarget(hostID: hostID, paneID: "wV:p1"),
                    alert: AgentNotificationAlert(
                        title: "Claude", body: "Blocked — waiting for input")))
        #expect(world.soundCount == 1)
    }

    /// The banner shares the push renderer, so a known workspace leads the
    /// same way it does on a push.
    @Test func aKnownWorkspaceLeadsTheBanner() async throws {
        world.triggers[hostID] = NotificationTriggerPreferences()
        let store = makeStore()
        store.agentsDidChange([agent("wV:p1", .working, workspaceLabel: "Caterm")])

        store.agentsDidChange([agent("wV:p1", .blocked, workspaceLabel: "Caterm")])

        try await waitUntil("the banner should show") { store.banner != nil }
        #expect(
            store.banner?.alert
                == AgentNotificationAlert(
                    title: "Caterm · Claude", body: "Blocked — waiting for input"))
    }

    @Test func doneTransitionBannersWithTheDoneCopy() async throws {
        world.triggers[hostID] = NotificationTriggerPreferences()
        let store = makeStore()
        store.agentsDidChange([agent("wV:p1", .working, kind: "codex")])

        store.agentsDidChange([agent("wV:p1", .done, kind: "codex")])

        try await waitUntil("the Done banner should show") { store.banner != nil }
        #expect(
            store.banner?.alert
                == AgentNotificationAlert(title: "Codex", body: "Done"))
    }

    /// The first sight of a pane is baseline, not a transition: a killed-state
    /// launch must not banner every already-Blocked Agent it syncs.
    @Test func firstSightOfABlockedAgentIsBaselineNotATransition() async throws {
        world.triggers[hostID] = NotificationTriggerPreferences()
        let store = makeStore()

        store.agentsDidChange([agent("wV:p1", .blocked)])

        try await waitPastHold()
        #expect(store.banner == nil)
        #expect(world.soundCount == 0)
    }

    @Test func workingAndIdleTransitionsNeverBanner() async throws {
        world.triggers[hostID] = NotificationTriggerPreferences()
        let store = makeStore()
        store.agentsDidChange([agent("wV:p1", .idle)])

        store.agentsDidChange([agent("wV:p1", .working)])
        store.agentsDidChange([agent("wV:p1", .idle)])

        try await waitPastHold()
        #expect(store.banner == nil)
    }

    // MARK: Anti-flap

    @Test func aTransitionThatDoesNotHoldNeverBanners() async throws {
        world.triggers[hostID] = NotificationTriggerPreferences()
        let store = makeStore()
        store.agentsDidChange([agent("wV:p1", .working)])

        store.agentsDidChange([agent("wV:p1", .blocked)])
        store.agentsDidChange([agent("wV:p1", .working)])

        try await waitPastHold()
        #expect(store.banner == nil)
    }

    /// A flap that settles back into Blocked banners exactly once, from the
    /// re-entry that finally held.
    @Test func aFlapThatSettlesBannersOnce() async throws {
        world.triggers[hostID] = NotificationTriggerPreferences()
        let store = makeStore()
        store.agentsDidChange([agent("wV:p1", .working)])

        store.agentsDidChange([agent("wV:p1", .blocked)])
        store.agentsDidChange([agent("wV:p1", .working)])
        store.agentsDidChange([agent("wV:p1", .blocked)])

        try await waitUntil("the settled transition should banner") { store.banner != nil }
        #expect(world.soundCount == 1)
    }

    /// Open item 49: a connection drop inside the hold clears the Host's
    /// rows, and the pane comes back at the status the hold was for. The
    /// hold keeps running across the gap and banners once.
    @Test func aDropInsideTheHoldStillBannersWhenThePaneReturnsUnchanged() async throws {
        world.triggers[hostID] = NotificationTriggerPreferences()
        let store = makeStore()
        store.agentsDidChange([agent("wV:p1", .working)])

        store.agentsDidChange([agent("wV:p1", .blocked)])
        store.agentsDidChange([])
        store.agentsDidChange([agent("wV:p1", .blocked)])

        try await waitUntil("the held transition should survive the reconnect") {
            store.banner != nil
        }
        #expect(store.banner?.alert.body == "Blocked — waiting for input")
        try await waitPastHold()
        #expect(world.soundCount == 1, "one transition, one banner")
    }

    /// A hold that elapses while the snapshot is still cleared waits for the
    /// pane, then banners when it returns at the same status.
    @Test func aHoldThatElapsesWhileAwayBannersWhenThePaneReturns() async throws {
        world.triggers[hostID] = NotificationTriggerPreferences()
        let store = makeStore()
        store.agentsDidChange([agent("wV:p1", .working)])

        store.agentsDidChange([agent("wV:p1", .blocked)])
        store.agentsDidChange([])
        try await waitPastHold()
        #expect(store.banner == nil, "nothing is announced for a pane that is not listed")

        store.agentsDidChange([agent("wV:p1", .blocked)])
        #expect(store.banner?.alert.body == "Blocked — waiting for input")
        #expect(world.soundCount == 1)
    }

    /// A pane that returns at another status is a new status, handled as
    /// before: Working cancels the Blocked hold.
    @Test func aPaneReturningAtAnotherStatusCancelsTheHold() async throws {
        world.triggers[hostID] = NotificationTriggerPreferences()
        let store = makeStore()
        store.agentsDidChange([agent("wV:p1", .working)])

        store.agentsDidChange([agent("wV:p1", .blocked)])
        store.agentsDidChange([])
        try await waitPastHold()
        store.agentsDidChange([agent("wV:p1", .working)])

        try await waitPastHold()
        #expect(store.banner == nil)
    }

    /// A pane that does not come back — its Host lists other Agents again —
    /// exited, and its held transition goes with it.
    @Test func aPaneGoneAfterTheReconnectCancelsItsPendingBanner() async throws {
        world.triggers[hostID] = NotificationTriggerPreferences()
        let store = makeStore()
        store.agentsDidChange([agent("w1:pT", .working), agent("wV:p1", .working)])

        store.agentsDidChange([agent("w1:pT", .working), agent("wV:p1", .blocked)])
        store.agentsDidChange([])
        store.agentsDidChange([agent("w1:pT", .working)])

        try await waitPastHold()
        #expect(store.banner == nil)
    }

    /// A pane that exits while its Host stays live cancels its hold at once.
    @Test func aVanishedPaneCancelsItsPendingBanner() async throws {
        world.triggers[hostID] = NotificationTriggerPreferences()
        let store = makeStore()
        store.agentsDidChange([agent("w1:pT", .working), agent("wV:p1", .working)])

        store.agentsDidChange([agent("w1:pT", .working), agent("wV:p1", .blocked)])
        store.agentsDidChange([agent("w1:pT", .working)])

        try await waitPastHold()
        #expect(store.banner == nil)
    }

    // MARK: Same-status dedupe

    @Test func anUnchangedStatusNeverRepeatsTheBanner() async throws {
        world.triggers[hostID] = NotificationTriggerPreferences()
        let store = makeStore()
        store.agentsDidChange([agent("wV:p1", .working)])
        store.agentsDidChange([agent("wV:p1", .blocked)])
        try await waitUntil("the first banner should show") { store.banner != nil }

        store.dismiss()
        store.agentsDidChange([agent("wV:p1", .blocked)])
        store.agentsDidChange([agent("wV:p1", .blocked)])

        try await waitPastHold()
        #expect(store.banner == nil)
        #expect(world.soundCount == 1)
    }

    // MARK: Suppression and preferences

    /// Suppression is decided at fire time: navigating into the Agent while
    /// its transition is still holding silences the banner.
    @Test func thePresentedAgentsOwnTransitionNeverBanners() async throws {
        world.triggers[hostID] = NotificationTriggerPreferences()
        let store = makeStore()
        store.agentsDidChange([agent("wV:p1", .working)])

        store.agentsDidChange([agent("wV:p1", .blocked)])
        world.presentedAgent = ConsoleAgent.ID(hostID: hostID, paneID: "wV:p1")

        try await waitPastHold()
        #expect(store.banner == nil)
        #expect(world.soundCount == 0)
    }

    @Test func anotherAgentsTransitionBannersWhileOneIsPresented() async throws {
        world.triggers[hostID] = NotificationTriggerPreferences()
        world.presentedAgent = ConsoleAgent.ID(hostID: hostID, paneID: "w1:pT")
        let store = makeStore()
        store.agentsDidChange([agent("w1:pT", .working), agent("wV:p1", .working)])

        store.agentsDidChange([agent("w1:pT", .working), agent("wV:p1", .blocked)])

        try await waitUntil("the other pane's banner should show") { store.banner != nil }
        #expect(store.banner?.target == AgentNotificationTarget(hostID: hostID, paneID: "wV:p1"))
    }

    /// Unknown preferences (Host unreachable, never registered, still loading)
    /// fail closed, matching the plugin's missing-flag semantics.
    @Test func unknownPreferencesFailClosed() async throws {
        let store = makeStore()
        store.agentsDidChange([agent("wV:p1", .working)])

        store.agentsDidChange([agent("wV:p1", .blocked)])

        try await waitPastHold()
        #expect(store.banner == nil)
    }

    @Test func aDisabledDoneFlagSkipsDoneButKeepsBlocked() async throws {
        world.triggers[hostID] = NotificationTriggerPreferences(blocked: true, done: false)
        let store = makeStore()
        store.agentsDidChange([agent("wV:p1", .working)])

        store.agentsDidChange([agent("wV:p1", .done)])
        try await waitPastHold()
        #expect(store.banner == nil)

        store.agentsDidChange([agent("wV:p1", .blocked)])
        try await waitUntil("the Blocked banner should still show") { store.banner != nil }
    }

    // MARK: Presentation lifecycle

    @Test func theBannerAutoDismissesAfterItsDelay() async throws {
        world.triggers[hostID] = NotificationTriggerPreferences()
        let store = makeStore(dismissDelay: .milliseconds(40))
        store.agentsDidChange([agent("wV:p1", .working)])

        store.agentsDidChange([agent("wV:p1", .blocked)])

        try await waitUntil("the banner should show") { store.banner != nil }
        try await waitUntil("the banner should auto-dismiss") { store.banner == nil }
    }

    @Test func aNewerBannerReplacesTheCurrentOne() async throws {
        world.triggers[hostID] = NotificationTriggerPreferences()
        let store = makeStore()
        store.agentsDidChange([agent("w1:pT", .working), agent("wR:pC", .working)])

        store.agentsDidChange([agent("w1:pT", .blocked), agent("wR:pC", .working)])
        try await waitUntil("the first banner should show") {
            store.banner?.target?.paneID == "w1:pT"
        }

        store.agentsDidChange([agent("w1:pT", .blocked), agent("wR:pC", .done)])
        try await waitUntil("the newer banner should replace it") {
            store.banner?.target?.paneID == "wR:pC"
        }
    }

    // MARK: Reconnects and vanished panes

    /// `HostConsoleProjection.invalidateSnapshot` clears `agentsByPane` on
    /// every reconnect and revalidation — iPad sleep, a network change, a
    /// missed keepalive — so the Host's rows disappear and come back. The
    /// baseline must survive that, or a Blocked that happened while the link
    /// was down reads as "first sight" and is swallowed.
    @Test func aTransitionAcrossAReconnectStillBanners() async throws {
        world.triggers[hostID] = NotificationTriggerPreferences()
        let store = makeStore()
        store.agentsDidChange([agent("wV:p1", .working)])

        // The connection drops: every row for this Host goes at once.
        store.agentsDidChange([])
        // It comes back, and the Agent finished while it was away.
        store.agentsDidChange([agent("wV:p1", .done)])

        try await waitUntil("the post-reconnect transition should banner") {
            store.banner != nil
        }
        #expect(store.banner?.alert.body == "Done")
    }

    /// A pane that really exited — its Host is still listing other Agents —
    /// is forgotten, so a later pane reusing that address baselines afresh.
    @Test func aPaneThatExitedWhileItsHostStayedLiveIsForgotten() async throws {
        world.triggers[hostID] = NotificationTriggerPreferences()
        let store = makeStore()
        store.agentsDidChange([agent("w1:pT", .working), agent("wV:p1", .working)])

        store.agentsDidChange([agent("w1:pT", .working)])
        store.agentsDidChange([agent("w1:pT", .working), agent("wV:p1", .blocked)])

        try await waitPastHold()
        #expect(store.banner == nil, "first sight of a new pane is baseline")
    }

    // MARK: Foreground pushes

    /// A delivered push is presented as it is: the plugin already applied
    /// every gate, and the app's own list may not have seen the change at
    /// all (#1).
    @Test func aForegroundPushBannersWithTheExtensionsCopy() async throws {
        let store = makeStore()
        let target = AgentNotificationTarget(hostID: hostID, paneID: "wV:p1")
        let alert = AgentNotificationAlert(title: "Caterm · Claude", body: "Done")

        store.presentPush(target: target, alert: alert)

        #expect(store.banner == AgentNotificationBanner(target: target, alert: alert))
        #expect(world.soundCount == 1)
    }

    /// Both pipelines carry the same transition; the push usually arrives a
    /// second or two after the live event stream announced it.
    @Test func aPushRepeatingAJustAnnouncedTransitionDoesNotAlertTwice() async throws {
        world.triggers[hostID] = NotificationTriggerPreferences()
        let store = makeStore()
        store.agentsDidChange([agent("wV:p1", .working)])
        store.agentsDidChange([agent("wV:p1", .done)])
        try await waitUntil("the in-app banner should show") { store.banner != nil }
        let announced = try #require(store.banner)
        store.dismiss()

        store.presentPush(target: try #require(announced.target), alert: announced.alert)

        #expect(store.banner == nil)
        #expect(world.soundCount == 1)
    }

    /// The race the other way round: the push arrives first, and the
    /// Console's own hold fires a few seconds later. The de-duplication is
    /// one key checked in both directions, so this is silent too.
    @Test func aTransitionAPushAlreadyShowedDoesNotBannerAgain() async throws {
        world.triggers[hostID] = NotificationTriggerPreferences()
        let store = makeStore()
        store.agentsDidChange([agent("wV:p1", .working)])
        store.presentPush(
            target: AgentNotificationTarget(hostID: hostID, paneID: "wV:p1"),
            alert: AgentNotificationAlert(title: "Claude", body: "Done"))
        store.dismiss()

        store.agentsDidChange([agent("wV:p1", .done)])

        try await waitPastHold()
        #expect(store.banner == nil)
        #expect(world.soundCount == 1)
    }

    /// A genuine second transition is not a duplicate: only a repeat from
    /// the *other* pipeline is.
    @Test func aRepeatedTransitionFromTheSamePipelineStillBanners() async throws {
        world.triggers[hostID] = NotificationTriggerPreferences()
        let store = makeStore()
        store.agentsDidChange([agent("wV:p1", .working)])
        store.agentsDidChange([agent("wV:p1", .blocked)])
        try await waitUntil("the first banner should show") { store.banner != nil }
        store.dismiss()

        store.agentsDidChange([agent("wV:p1", .working)])
        store.agentsDidChange([agent("wV:p1", .blocked)])

        try await waitUntil("the second Blocked should banner too") { store.banner != nil }
        #expect(world.soundCount == 2)
    }

    /// A *different* transition for the same pane is not a duplicate.
    @Test func aPushForALaterTransitionStillBanners() async throws {
        world.triggers[hostID] = NotificationTriggerPreferences()
        let store = makeStore()
        store.agentsDidChange([agent("wV:p1", .working)])
        store.agentsDidChange([agent("wV:p1", .blocked)])
        try await waitUntil("the in-app banner should show") { store.banner != nil }
        store.dismiss()

        store.presentPush(
            target: AgentNotificationTarget(hostID: hostID, paneID: "wV:p1"),
            alert: AgentNotificationAlert(title: "Claude", body: "Done"))

        #expect(store.banner?.alert.body == "Done")
        #expect(world.soundCount == 2)
    }

    @Test func dismissClearsTheBanner() async throws {
        world.triggers[hostID] = NotificationTriggerPreferences()
        let store = makeStore()
        store.agentsDidChange([agent("wV:p1", .working)])
        store.agentsDidChange([agent("wV:p1", .blocked)])
        try await waitUntil("the banner should show") { store.banner != nil }

        store.dismiss()

        #expect(store.banner == nil)
    }
}
