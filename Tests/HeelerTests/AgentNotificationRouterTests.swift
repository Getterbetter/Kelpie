import Foundation
import Testing

@testable import Heeler

/// The navigation half of #74, as Open item 28 left it: a notification or
/// Live Activity tap lands on the root screen — herdr's own client for the
/// Host it named — and never navigates the Console, while taps made inside
/// the Console still open the right Agent detail through its navigation path,
/// wait for a pane that has not synced yet, and fall back to the Console with
/// no alarming copy when one never arrives.
///
/// Pane ids that stand in for a live herdr address use the observed
/// alphanumeric `w…:p…` family (uppercase included). `%gone` and `%other`
/// stay deliberately fake: those cases only need distinct opaque strings.
@MainActor
@Suite("Agent notification router")
struct AgentNotificationRouterTests {
    private func consoleAgent(hostID: UUID, paneID: String) -> ConsoleAgent {
        ConsoleAgent(
            hostID: hostID, hostName: "mac-studio",
            agent: Agent(.fixture(paneID: paneID)),
            workspaceLabel: nil, repositoryCheckout: nil, lastOutputSnippet: nil)
    }

    /// Polls until `condition` holds, yielding so the router's tasks progress.
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

    @Test func tapOnAKnownAgentOpensItsDetail() {
        let router = AgentNotificationRouter()
        let hostID = UUID()
        router.agentsDidChange([consoleAgent(hostID: hostID, paneID: "wV:p1")])

        router.open(AgentNotificationTarget(hostID: hostID, paneID: "wV:p1"))

        #expect(router.path == [ConsoleAgent.ID(hostID: hostID, paneID: "wV:p1")])
        #expect(router.pendingTarget == nil)
    }

    @Test func tapReplacesTheCurrentlyPresentedAgent() {
        let router = AgentNotificationRouter()
        let hostID = UUID()
        router.agentsDidChange([
            consoleAgent(hostID: hostID, paneID: "wV:p1"),
            consoleAgent(hostID: hostID, paneID: "w1C:p1"),
        ])
        router.path = [ConsoleAgent.ID(hostID: hostID, paneID: "w1C:p1")]

        router.open(AgentNotificationTarget(hostID: hostID, paneID: "wV:p1"))

        #expect(router.path == [ConsoleAgent.ID(hostID: hostID, paneID: "wV:p1")])
    }

    /// The killed-state launch path: the tap arrives before any Host has
    /// synced, so the router waits on the Console and routes the moment the
    /// pane appears.
    @Test func tapBeforeTheConsoleSyncsWaitsForThePaneThenOpens() {
        let router = AgentNotificationRouter()
        let hostID = UUID()

        router.open(AgentNotificationTarget(hostID: hostID, paneID: "wV:p1"))
        #expect(router.path.isEmpty)
        #expect(router.pendingTarget == AgentNotificationTarget(hostID: hostID, paneID: "wV:p1"))

        router.agentsDidChange([consoleAgent(hostID: hostID, paneID: "wV:p1")])

        #expect(router.path == [ConsoleAgent.ID(hostID: hostID, paneID: "wV:p1")])
        #expect(router.pendingTarget == nil)
    }

    /// A stale pane — closed since the push was sent — never shows up, so
    /// the tap quietly stays on the Console once the grace window elapses.
    @Test func stalePaneFallsBackToTheConsoleQuietly() async throws {
        let router = AgentNotificationRouter(pendingGrace: .milliseconds(25))
        let hostID = UUID()
        router.agentsDidChange([consoleAgent(hostID: hostID, paneID: "w1:pT")])
        // Viewing some other Agent when the tap lands: fall back means
        // popping to the Console, not staying wherever the user was.
        router.path = [ConsoleAgent.ID(hostID: hostID, paneID: "w1:pT")]

        router.open(AgentNotificationTarget(hostID: hostID, paneID: "%gone"))
        #expect(router.path.isEmpty)

        try await waitUntil("the pending target should expire") {
            router.pendingTarget == nil
        }
        #expect(router.path.isEmpty)
    }

    /// Unknown key id or an undecryptable envelope resolves to no target;
    /// the tap still brings the user to the Console.
    @Test func unresolvableTapFallsBackToTheConsole() {
        let router = AgentNotificationRouter()
        let hostID = UUID()
        router.agentsDidChange([consoleAgent(hostID: hostID, paneID: "wV:p1")])
        router.path = [ConsoleAgent.ID(hostID: hostID, paneID: "wV:p1")]

        router.open(nil)

        #expect(router.path.isEmpty)
        #expect(router.pendingTarget == nil)
    }

    /// If the user starts navigating while a tap is still waiting for its
    /// pane, the deep link must not yank them away later.
    @Test func manualNavigationDropsAPendingDeepLink() {
        let router = AgentNotificationRouter()
        let hostID = UUID()

        router.open(AgentNotificationTarget(hostID: hostID, paneID: "wV:p1"))
        router.path = [ConsoleAgent.ID(hostID: hostID, paneID: "%other")]

        router.agentsDidChange([
            consoleAgent(hostID: hostID, paneID: "wV:p1"),
            consoleAgent(hostID: hostID, paneID: "%other"),
        ])

        #expect(router.path == [ConsoleAgent.ID(hostID: hostID, paneID: "%other")])
        #expect(router.pendingTarget == nil)
    }

    /// Open item 28. A tapped notification or Live Activity is a landing on
    /// the root screen, not a Console navigation: `path` going non-empty is
    /// what used to present the Console cover, so leaving it alone is the
    /// whole of the change. The tap's pane is not consulted at all.
    @Test func aTapLandsOnTheClientWithoutNavigatingTheConsole() {
        let router = AgentNotificationRouter()
        let hostID = UUID()
        router.agentsDidChange([consoleAgent(hostID: hostID, paneID: "wV:p1")])

        router.land(onHostID: hostID)

        #expect(router.landing?.hostID == hostID)
        #expect(router.path.isEmpty)
        #expect(router.pendingTarget == nil)
    }

    /// Two pushes from the same Host are two landings: the root screen
    /// watches this value, and a repeat tap still has to lower the cover.
    @Test func repeatedTapsForOneHostEachLand() {
        let router = AgentNotificationRouter()
        let hostID = UUID()

        router.land(onHostID: hostID)
        let first = router.landing
        router.land(onHostID: hostID)

        #expect(first?.hostID == hostID)
        #expect(router.landing?.hostID == hostID)
        #expect(router.landing != first)
    }

    /// A tap arriving while the Console is still waiting for a pane drops
    /// that wait: the user is leaving the Console, not navigating it, and the
    /// pane must not yank them back when it finally syncs.
    @Test func aTapDropsAPendingConsoleTarget() {
        let router = AgentNotificationRouter()
        let hostID = UUID()
        router.open(AgentNotificationTarget(hostID: hostID, paneID: "wV:p1"))
        #expect(router.pendingTarget != nil)

        router.land(onHostID: hostID)
        router.agentsDidChange([consoleAgent(hostID: hostID, paneID: "wV:p1")])

        #expect(router.pendingTarget == nil)
        #expect(router.path.isEmpty)
    }
}
