import SwiftUI

/// App entry point. M0 ships only the buildable skeleton; the Console UI
/// arrives in M1 once the Transport underneath it exists.
@main
struct HeelerApp: App {
    /// APNs delivers device tokens through UIApplicationDelegate callbacks
    /// only, so push bootstrap (#71) needs this adaptor.
    @UIApplicationDelegateAdaptor(PushRegistrationDelegate.self)
    private var pushDelegate
    /// The aggregate phase across every window: active while any one is.
    @Environment(\.scenePhase) private var scenePhase
    /// The Agent the root window is on. Kelpie shows herdr's own client full
    /// screen (ADR 0017) and a Transport serves one Attach channel at a time,
    /// so there is one window and no `WindowGroup` value to carry the route;
    /// it is held here and restored from the scene's own storage.
    @State private var windowRoute: AgentRoute?

    init() {
        try? ImagePreparer.cleanupRemnants()
        try? FilePreparer.cleanupRemnants()
        // Files downloaded from a Host for Quick Look are deleted when their
        // sheet closes; a kill mid-preview is the one case that leaves one.
        HostFileViewerStore.cleanupRemnants()
    }

    var body: some Scene {
        // One window, not upstream's value-typed multi-window group: herdr's
        // client is the screen and a Transport serves one Attach channel at a
        // time, so two windows would compete for it (ADR 0017).
        WindowGroup {
            #if DEBUG && targetEnvironment(simulator)
                if DemoScreenshotMode.isEnabled {
                    DemoScreenshotRootView()
                } else {
                    productionContent(route: $windowRoute)
                }
            #else
                productionContent(route: $windowRoute)
            #endif
        }
        .commands { ConsoleCommands() }
        .onChange(of: scenePhase) {
            #if DEBUG && targetEnvironment(simulator)
                guard !DemoScreenshotMode.isEnabled else { return }
            #endif
            pushDelegate.appModel.scenePhaseDidChange(scenePhase)
        }
    }

    private func productionContent(route: Binding<AgentRoute?>) -> some View {
        ContentView(app: pushDelegate.appModel, windowRoute: route)
    }
}
