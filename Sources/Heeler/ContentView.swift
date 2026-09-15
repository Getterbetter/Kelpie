import SwiftUI
import UIKit

/// One window's root: the Console (#8), with Host management (#14) behind it.
///
/// The stores behind it are app-wide (`HeelerAppModel`); what a window owns
/// is its navigation. On iPad every window is a scene with its own router,
/// so two windows can show two Agents, and each restores its own Agent after
/// the app is terminated: first from its scene storage, else from the value
/// the window was opened with, else from a dragged row's user activity.
struct ContentView: View {
    let app: HeelerAppModel
    /// The `WindowGroup` value: the Agent this window was opened on, kept in
    /// step with the window's navigation so opening that Agent again finds
    /// this window.
    @Binding var windowRoute: AgentRoute?
    @State private var notificationRouter = AgentNotificationRouter()
    @State private var sceneID = UUID()
    @State private var window = WindowReference()
    /// A dragged row's Agent that reached this scene before it restored.
    @State private var incomingActivityRoute: AgentRoute?
    @State private var hasRestoredRoute = false
    /// Replaced once restoration knows whether this window is new.
    @State private var activation = SceneActivationTracker(isRestored: false)
    @State private var hardwareKeyboard = HardwareKeyboardObserver()
    /// Owned here with the other client stores so the three products stay
    /// loaded across every presentation of the tip jar sheet.
    @State private var tipJar = TipJarStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        // herdr's own client is the screen (ADR 0017). The stores it and
        // the Console need are owned by `HeelerAppModel` and driven here, at
        // the root, so push, Live Activities and the activity driver keep
        // running while the Console itself is only a cover away.
        HerdrClientRootView(
            hosts: app.hostStore, console: app.console, terminal: app.terminal,
            inputMode: app.inputMode,
            appearance: app.appearance,
            pushRegistration: app.pushRegistration,
            notificationPreferences: app.notificationPreferences,
            relaySettings: app.relaySettings,
            notificationRouter: notificationRouter,
            bannerStore: app.bannerStore,
            liveActivities: app.liveActivities,
            activity: app.activity,
            hardwareKeyboard: hardwareKeyboard,
            tipJar: tipJar
        )
        // The Settings toggle lives behind the cover, so it reaches the
        // reconcile through the environment rather than another parameter.
        .environment(app.pairingSyncSettings)
        // The Console connects Hosts in the background and has no screen of
        // its own to ask on, so the first-connect question lands here — and
        // on the Console cover's own root, for when that is what is up.
        .hostKeyConfirmation()
        .environment(\.sceneWindow, window)
        .environment(
            \.agentSceneRouting,
            AgentSceneRouting(directory: app.sceneDirectory, sceneID: sceneID))
        // Automatic input mode is a function of this one fact, so it is
        // pushed from the single observer rather than read in three places.
        .onChange(of: hardwareKeyboard.isConnected, initial: true) { _, isConnected in
            app.inputMode.hardwareKeyboardDidChange(isConnected)
        }
        // The one place the app's light/dark override is applied: it lands on
        // the window, so sheets, pushed screens, and the UIKit terminal
        // surfaces all resolve against the chosen appearance.
        .preferredColorScheme(app.appearance.preferredColorScheme)
        .background {
            WindowReader { window.attach($0) }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .onAppear {
            // Restored first, so a notification tap that launched the app
            // and is waiting for a window lands on top of it when the window
            // registers. A dragged row's Agent needs the registration to
            // route through the single-window rule, so it goes last.
            let draggedRoute = restoreRoute()
            app.sceneDirectory.register(
                sceneID: sceneID, router: notificationRouter, window: window,
                activate: { activateWindow() })
            window.observeInteraction { [directory = app.sceneDirectory, sceneID] in
                directory.sceneDidReceiveInteraction(sceneID: sceneID)
            }
            if scenePhase == .active {
                sceneDidBecomeActive()
            }
            if let draggedRoute {
                app.sceneDirectory.open(draggedRoute.target, preferredSceneID: sceneID)
            }
            app.start()
        }
        .onDisappear {
            app.sceneDirectory.unregister(sceneID: sceneID)
        }
        // A foreground return is not the user choosing this window; see
        // `SceneActivationTracker`. Moving between windows arrives through
        // `observeInteraction` instead.
        .onChange(of: scenePhase) {
            if scenePhase == .active {
                sceneDidBecomeActive()
            }
        }
        // Feeds the Console's Agent list to this window's router, so a
        // notification tap that arrived before the Hosts synced (killed-state
        // launch) routes the moment its pane appears.
        .onChange(of: app.console.agents, initial: true) {
            notificationRouter.agentsDidChange(app.console.agents)
            app.sceneDirectory.sceneRouteDidChange(sceneID: sceneID)
        }
        // Every navigation is written back to the window value. Nothing is
        // written to scene storage: Kelpie restores no route at launch (see
        // `restoreRoute`), so a stored one would only go stale.
        .onChange(of: notificationRouter.path) { _, path in
            let route = path.last.map(AgentRoute.init(agentID:))
            if windowRoute != route {
                windowRoute = route
            }
            app.sceneDirectory.sceneRouteDidChange(sceneID: sceneID)
        }
        // Every Live Activity link — a row, the surrounding chrome, the
        // compact and minimal presentations — names a Host, and that is all a
        // tap needs: it lands on the root screen, herdr's own client for that
        // Host (Open item 28). A row link's pane id is kept in the link and
        // ignored here, because herdr's client focuses its own pane and takes
        // no target from outside.
        .onOpenURL { url in
            guard let link = AgentActivityLink.target(from: url) else { return }
            notificationRouter.land(onHostID: link.hostID)
        }
        .onContinueUserActivity(AgentRoute.activityType) { activity in
            guard let route = AgentRoute(userActivity: activity) else { return }
            if hasRestoredRoute {
                app.sceneDirectory.open(route.target, preferredSceneID: sceneID)
            } else {
                incomingActivityRoute = route
            }
        }
        // Kelpie: herdr's own desktop notifications (OSC 9 / OSC 777) share
        // the Agent Notification banner while the app is foregrounded, so the
        // relay is handed the same store the overlay draws from. Every other
        // start-up task lives in `HeelerAppModel.start()`.
        .task { TerminalDesktopNotificationRelay.shared.connect(bannerStore: app.bannerStore) }
        // An existing window prefers Heeler's own links, so a Live Activity
        // tap lands in a window that is already open instead of spawning
        // one. A dragged row's activity is not a `heeler://` link, so it
        // still gets the new window it was dropped to create.
        .handlesExternalEvents(
            preferring: [Self.linkEventPrefix], allowing: ["*"])
    }

    private static let linkEventPrefix = "\(AgentActivityLink.scheme)://"

    /// Counts only a newly opened window's first activation as the user
    /// working in it.
    private func sceneDidBecomeActive() {
        guard activation.sceneDidBecomeActive() else { return }
        app.sceneDirectory.sceneDidBecomeActive(sceneID: sceneID)
    }

    /// Kelpie restores no route at launch. The window opens on herdr's own
    /// client with the Console cover down, so a path written from scene
    /// storage would mark an Agent as presented that nothing shows — which
    /// suppresses that Agent's notification banners and claims the Host's
    /// single terminal channel for a window holding no terminal. Only a live
    /// hand-off activity is carried through, for the caller to open once this
    /// window is registered.
    private func restoreRoute() -> AgentRoute? {
        guard !hasRestoredRoute else { return nil }
        hasRestoredRoute = true
        let incoming = incomingActivityRoute
        incomingActivityRoute = nil
        activation = SceneActivationTracker(isRestored: false)
        return incoming
    }

    /// Brings this window forward when a deep link picks it. A no-op for the
    /// window the user is already in.
    private func activateWindow() {
        guard let scene = window.window?.windowScene,
            scene.activationState != .foregroundActive
        else { return }
        UIApplication.shared.activateSceneSession(
            for: UISceneSessionActivationRequest(session: scene.session),
            errorHandler: nil)
    }
}

#Preview {
    ContentView(
        app: HeelerAppModel(
            pushRegistration: PushRegistrationStore(), sceneDirectory: AgentSceneDirectory()),
        windowRoute: .constant(nil))
}
