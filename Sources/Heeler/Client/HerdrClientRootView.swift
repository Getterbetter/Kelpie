import Observation
import SwiftUI

/// The app's root: herdr's own client for the primary Host, full screen.
///
/// Heeler's native Console is not gone — it still owns push registration,
/// Live Activities and every Agent operation — but it is no longer the screen.
/// It lives one tap away behind the floating menu, in a full-screen cover, and
/// a notification deep link presents it by itself so routing lands on the
/// Agent exactly as before. The stores it needs (`ConsoleStore`, the activity
/// driver) are created and driven in `ContentView`, above this view, so they
/// stay alive while the cover is down.
struct HerdrClientRootView: View {
    let hosts: HostStore
    let console: ConsoleStore
    let terminal: TerminalSettings
    let inputMode: AgentInputModeSettings
    let appearance: AppAppearanceSettings
    let pushRegistration: PushRegistrationStore
    let notificationPreferences: NotificationPreferencesStore
    let relaySettings: NotificationRelaySettings
    @Bindable var notificationRouter: AgentNotificationRouter
    let bannerStore: AgentNotificationBannerStore
    let liveActivities: HostLiveActivityCoordinator
    let activity: AppActivityCoordinator
    let hardwareKeyboard: HardwareKeyboardObserver

    @State private var primaryHost = PrimaryHostStore()
    /// The live Client's handle, set by the screen that owns it — the same
    /// arrangement as `TerminalKeyboardControl`, and for the same reason: the
    /// menu outlives no store and must not hold one.
    @State private var commands = HerdrClientCommands()
    @State private var isShowingConsole = false
    @State private var isShowingSettings = false
    @State private var hostSheet: HostSheet?
    @State private var manualReconnectInFlightHostIDs: Set<Host.ID> = []
    @State private var isHovering = false

    private struct HostSheet: Identifiable {
        let id = UUID()
        let hostID: Host.ID?
    }

    var body: some View {
        Group {
            if let host = primaryHost.host(in: hosts.hosts) {
                client(for: host)
            } else {
                // Onboarding is the Console's own empty state, unchanged:
                // "No Hosts", with Add Host opening the same sheet.
                consoleScreen(onClose: nil)
            }
        }
        .onChange(of: hosts.hosts) { _, hosts in
            primaryHost.hostsDidChange(hosts)
        }
    }

    private func client(for host: Host) -> some View {
        HerdrClientHostView(
            host: host,
            console: console,
            terminal: terminal,
            activity: activity,
            hardwareKeyboard: hardwareKeyboard,
            isShowingConsole: isShowingConsole,
            commands: commands
        )
        // A different Host is a different attach: rebuild rather than
        // repoint the pipeline.
        .id(host.id)
        .overlay(alignment: .topTrailing) { menuButton }
        .fullScreenCover(isPresented: $isShowingConsole) {
            consoleScreen(onClose: { isShowingConsole = false })
        }
        .sheet(item: $hostSheet) { destination in
            // HostListView brings its own NavigationStack.
            HostListView(
                store: hosts,
                initialHostID: destination.hostID,
                connectionStatuses: console.hostStatuses,
                standingFailures: console.hostStandingFailures,
                latencies: console.hostLatencies,
                manualReconnectInFlightHostIDs: manualReconnectInFlightHostIDs,
                retryConnection: { await reconnectHost($0) })
        }
        .sheet(isPresented: $isShowingSettings) {
            SettingsView(
                terminal: terminal,
                appearance: appearance,
                pushRegistration: pushRegistration,
                notificationPreferences: notificationPreferences,
                relaySettings: relaySettings,
                liveActivities: liveActivities,
                console: console,
                hosts: hosts.hosts,
                inputMode: inputMode)
        }
        // A notification tap routes through the Console, so the Console has
        // to be on screen for it to land.
        .onChange(of: notificationRouter.path, initial: true) { _, path in
            guard !path.isEmpty else { return }
            hostSheet = nil
            isShowingSettings = false
            isShowingConsole = true
        }
    }

    private func consoleScreen(
        onClose: (@MainActor () -> Void)?
    ) -> some View {
        ConsoleView(
            hosts: hosts, console: console, terminal: terminal,
            inputMode: inputMode,
            appearance: appearance,
            pushRegistration: pushRegistration,
            notificationPreferences: notificationPreferences,
            relaySettings: relaySettings,
            notificationRouter: notificationRouter,
            bannerStore: bannerStore,
            liveActivities: liveActivities,
            activity: activity,
            onClose: onClose
        )
        // The cover owns the deep link while it is up; dropping the path on
        // dismiss keeps the next notification a change the Console sees.
        .onDisappear { notificationRouter.path = [] }
    }

    /// Small on purpose: it sits over the empty right end of herdr's own tab
    /// strip, and herdr needs those columns more than this does.
    private var menuButton: some View {
        Menu {
            Button("Agents", systemImage: "rectangle.on.rectangle") {
                isShowingConsole = true
            }
            Button("Hosts", systemImage: "server.rack") {
                hostSheet = HostSheet(hostID: nil)
            }
            if hosts.hosts.count > 1 {
                Menu("Switch Host", systemImage: "arrow.left.arrow.right") {
                    Picker(
                        "Host",
                        selection: Binding(
                            get: { primaryHost.host(in: hosts.hosts)?.id },
                            set: { if let id = $0 { primaryHost.select(id) } })
                    ) {
                        ForEach(hosts.hosts) { host in
                            Text(host.displayName).tag(Host.ID?.some(host.id))
                        }
                    }
                }
            }
            Button("Settings", systemImage: "gearshape") {
                isShowingSettings = true
            }
            Button("Reconnect", systemImage: "arrow.clockwise") {
                commands.reconnect()
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 24))
                .frame(width: 36, height: 36)
                .contentShape(.circle)
        }
        .foregroundStyle(.primary)
        // Resting at just over half opacity so it reads as chrome over
        // herdr's own tab strip; a pointer brings it fully up, and a press
        // opens the menu over a dimmed screen anyway.
        .opacity(isHovering ? 1 : 0.55)
        .onHover { isHovering = $0 }
        .hoverEffect(.highlight)
        .padding(12)
        .accessibilityLabel("Kelpie Menu")
    }

    private func reconnectHost(_ id: Host.ID) async {
        guard manualReconnectInFlightHostIDs.insert(id).inserted else { return }
        await console.retryHost(id)
        try? await Task.sleep(for: .milliseconds(1_200))
        manualReconnectInFlightHostIDs.remove(id)
    }
}

/// A handle on the live Client for chrome that sits outside it. Weak, and set
/// by the screen itself, so a Host switch rebuilding the store cannot leave
/// the menu driving a dead one.
@MainActor
@Observable
final class HerdrClientCommands {
    weak var store: HerdrClientStore?

    func reconnect() { store?.reconnect() }
}

/// Owns one Host's Client store for as long as that Host is the primary one.
private struct HerdrClientHostView: View {
    let host: Host
    let console: ConsoleStore
    let terminal: TerminalSettings
    let activity: AppActivityCoordinator
    let hardwareKeyboard: HardwareKeyboardObserver
    let isShowingConsole: Bool
    let commands: HerdrClientCommands

    @State private var store: HerdrClientStore

    init(
        host: Host,
        console: ConsoleStore,
        terminal: TerminalSettings,
        activity: AppActivityCoordinator,
        hardwareKeyboard: HardwareKeyboardObserver,
        isShowingConsole: Bool,
        commands: HerdrClientCommands
    ) {
        self.host = host
        self.console = console
        self.terminal = terminal
        self.activity = activity
        self.hardwareKeyboard = hardwareKeyboard
        self.isShowingConsole = isShowingConsole
        self.commands = commands
        let sessionName = host.sessionName.trimmingCharacters(in: .whitespacesAndNewlines)
        _store = State(
            initialValue: HerdrClientStore(
                hostID: host.id,
                sessionName: sessionName.isEmpty ? nil : sessionName,
                transportGeneration: console.hostConnectionGenerations[host.id],
                runTerminal: console.terminalRunner(for: host.id)))
    }

    var body: some View {
        HerdrClientView(
            store: store,
            terminal: terminal,
            activity: activity,
            hardwareKeyboard: hardwareKeyboard
        )
        .onChange(of: console.hostConnectionGenerations[host.id]) { _, generation in
            store.transportGenerationDidChange(generation)
        }
        .onChange(of: isShowingConsole, initial: true) { _, isShowing in
            store.setPresented(!isShowing)
        }
        .onAppear { commands.store = store }
    }
}
