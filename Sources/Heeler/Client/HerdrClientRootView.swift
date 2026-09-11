import Observation
import PhotosUI
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
    /// Passed explicitly, like `hardwareKeyboard`: the sheet is transient but
    /// the three loaded products should outlive it.
    let tipJar: TipJarStore

    @State private var primaryHost = PrimaryHostStore()
    /// The live Client's handle, set by the screen that owns it — the same
    /// arrangement as `TerminalKeyboardControl`, and for the same reason: the
    /// menu outlives no store and must not hold one.
    @State private var commands = HerdrClientCommands()
    @State private var isShowingConsole = false
    /// True while the Client is handing its Attach channel back, before the
    /// cover is presented. See ``presentConsole()``.
    @State private var isPreparingConsole = false
    @State private var isShowingSettings = false
    @State private var isShowingSetupGuide = false
    @State private var isShowingTipJar = false
    /// The add-Host route the Setup Guide asked for, opened once that sheet
    /// is gone: two sheets must never overlap.
    @State private var pendingHostAction: HostListView.InitialAction?
    @State private var hostSheet: HostSheet?
    @State private var manualReconnectInFlightHostIDs: Set<Host.ID> = []
    @State private var isHovering = false
    /// True while the menu capsule is held down, from the button style below.
    @State private var isPressed = false
    @State private var isSelectingPhoto = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var isSelectingFile = false
    @State private var isPromptingForHostFile = false
    /// This window's width, read from the root itself rather than the screen
    /// so Split View, Slide Over and Stage Manager all report through one
    /// place. Drives the terminal's *default* font size and the menu's
    /// compact form; 0 until the first layout.
    @State private var windowWidth: CGFloat = 0

    private struct HostSheet: Identifiable {
        let id = UUID()
        let hostID: Host.ID?
        var initialAction: HostListView.InitialAction?
    }

    var body: some View {
        // A ZStack, not a Group: modifiers on a Group distribute to whichever
        // branch is live, and the Host sheet below must survive the swap from
        // Welcome to the client that a successful pairing causes mid-sheet.
        ZStack {
            if let host = primaryHost.host(in: hosts.hosts) {
                client(for: host)
            } else {
                // With no Host there is nothing to attach to, and the Mac is
                // where the work is: the Welcome screen says what to run there
                // and leads with pasting the Pairing Code.
                WelcomeView(hosts: hosts, presentation: .root) { action in
                    hostSheet = HostSheet(
                        hostID: nil, initialAction: Self.initialAction(for: action))
                }
            }
        }
        // On the Group, not inside `client(for:)`: the same sheet serves the
        // Welcome screen, and pairing a Host from it swaps the branch
        // underneath without tearing the sheet down mid-preflight.
        .sheet(item: $hostSheet) { destination in
            // HostListView brings its own NavigationStack.
            HostListView(
                store: hosts,
                initialHostID: destination.hostID,
                initialAction: destination.initialAction,
                connectionStatuses: console.hostStatuses,
                standingFailures: console.hostStandingFailures,
                latencies: console.hostLatencies,
                manualReconnectInFlightHostIDs: manualReconnectInFlightHostIDs,
                retryConnection: { await reconnectHost($0) })
        }
        // A background reader, not a GeometryReader wrapping the content: the
        // reader would take over the root's sizing, and all that is wanted
        // here is the number.
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onChange(of: proxy.size.width, initial: true) { _, width in
                        windowDidResize(to: width)
                    }
            }
        }
        .onChange(of: hosts.hosts) { _, hosts in
            primaryHost.hostsDidChange(hosts)
        }
    }

    /// The one place the window's width lands. The zoom settings keep the
    /// user's own offset and only move the default underneath it, so a
    /// resize can never wipe a chosen zoom.
    private func windowDidResize(to width: CGFloat) {
        guard width > 0 else { return }
        windowWidth = width
        terminal.zoom.windowWidthDidChange(width)
    }

    /// Under this width the menu drops its Host name and shows as an icon
    /// alone: a Slide Over panel has no room for a chip that wide, and the
    /// name is the part herdr's own tab strip can spare.
    private var isCompactWidth: Bool {
        windowWidth > 0 && windowWidth < TerminalZoomSettings.mediumWidthThreshold
    }

    private static func initialAction(
        for action: WelcomeView.Action
    ) -> HostListView.InitialAction {
        switch action {
        case .pasteCode: .paste
        case .scanCode: .scan
        case .addManually: .addManually
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
        // The foreground Blocked/Done banner (#77) is drawn wherever the app's
        // root is; ConsoleView keeps drawing its own for when the cover is up.
        .overlay(alignment: .top) { banner }
        .animation(.snappy, value: bannerStore.banner)
        .fullScreenCover(isPresented: $isShowingConsole) {
            consoleScreen(onClose: { isShowingConsole = false })
                // On the cover's own content, not inside `consoleScreen`:
                // the Console screen is the cover's role alone, and a
                // second use of it — as a root, as it once was — must not
                // clear the router's path by being torn down.
                .onDisappear { notificationRouter.path = [] }
        }
        .sheet(
            isPresented: $isShowingSetupGuide,
            onDismiss: {
                // The same two-sheet hand-off HostListView uses for its
                // manual fallback: open the second only once the first is
                // fully gone.
                guard let pending = pendingHostAction else { return }
                pendingHostAction = nil
                hostSheet = HostSheet(hostID: nil, initialAction: pending)
            }
        ) {
            WelcomeView(hosts: hosts, presentation: .sheet) { action in
                pendingHostAction = Self.initialAction(for: action)
                isShowingSetupGuide = false
            }
        }
        .photosPicker(
            isPresented: $isSelectingPhoto,
            selection: $selectedPhoto,
            matching: .images)
        .onChange(of: selectedPhoto) { _, item in
            guard let item else { return }
            selectedPhoto = nil
            commands.stage([.photo(PhotosPickerImageSelection(item: item))])
        }
        // `.item` rather than `.data`: an agent can be handed a folder-backed
        // document as readily as a file, and `FilePreparer` refuses what it
        // cannot read.
        .fileImporter(
            isPresented: $isSelectingFile,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            guard case .success(let urls) = result, !urls.isEmpty else { return }
            // The security scope is opened by `FilePreparer`, exactly as it is
            // for the Agent terminal's own importer.
            commands.stage(urls.map { .file($0) })
        }
        .hostFilePathPrompt(isPresented: $isPromptingForHostFile) { path in
            commands.openHostFile(path)
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
                inputMode: inputMode,
                tipJar: tipJar)
        }
        // Presented the same way the Setup Guide is: its own sheet, never
        // stacked on another one.
        .sheet(isPresented: $isShowingTipJar) {
            TipJarView(store: tipJar)
        }
        // A notification tap routes through the Console, so the Console has
        // to be on screen for it to land.
        .onChange(of: notificationRouter.path, initial: true) { _, path in
            guard !path.isEmpty else { return }
            hostSheet = nil
            isShowingSettings = false
            isShowingSetupGuide = false
            isShowingTipJar = false
            pendingHostAction = nil
            presentConsole()
        }
    }

    @ViewBuilder
    private var banner: some View {
        if let banner = bannerStore.banner {
            AgentNotificationBannerView(banner: banner) {
                bannerStore.dismiss()
                notificationRouter.open(banner.target)
            }
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    /// Presents the Agents cover only once the Client's Attach channel is
    /// actually closed. A Transport serves one channel at a time and an Agent
    /// Attach does not retry a refusal, so presenting first and closing after
    /// is a race — and the deep link is the flow that would lose it.
    private func presentConsole() {
        guard !isShowingConsole, !isPreparingConsole else { return }
        isPreparingConsole = true
        Task { @MainActor in
            await commands.prepareForConsole()
            isPreparingConsole = false
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
    }

    /// Still sized to sit over the empty right end of herdr's own tab strip,
    /// but labelled: this is the only way to Hosts, Agents and Settings, and
    /// it has to be findable without a pointer resting on it. Naming the
    /// current Host earns the width — it says which machine is on screen as
    /// well as where to go to change it.
    private var menuButton: some View {
        Menu {
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
            Button("Hosts", systemImage: "server.rack") {
                hostSheet = HostSheet(hostID: nil)
            }
            Divider()
            Button("Agents", systemImage: "rectangle.on.rectangle") {
                presentConsole()
            }
            Button("Settings", systemImage: "gearshape") {
                isShowingSettings = true
            }
            Button("Setup Guide", systemImage: "questionmark.circle") {
                isShowingSetupGuide = true
            }
            // Last of the about-the-app group, next to Settings and the Setup
            // Guide. Kelpie is free; this buys nothing.
            Button("Tip the Developer…", systemImage: "heart") {
                isShowingTipJar = true
            }
            Divider()
            // Uploaded to the Host, then typed into the focused pane as a
            // path — the way herdr's own remote client pastes an image.
            Button("Attach Photo…", systemImage: "photo") {
                isSelectingPhoto = true
            }
            Button("Attach File…", systemImage: "doc") {
                isSelectingFile = true
            }
            // The other direction: a file the agent wrote on the Host,
            // fetched and shown here. The terminal's own path taps land in
            // the same viewer; this is the way in when the path has scrolled
            // off, or was never printed.
            Button("Open File on Host…", systemImage: "doc.text.magnifyingglass") {
                isPromptingForHostFile = true
            }
            Button("Reconnect", systemImage: "arrow.clockwise") {
                commands.reconnect()
            }
        } label: {
            menuLabel
                .font(.caption.weight(.medium))
                .lineLimit(1)
                // The capsule hugs the name; the cap lives in `menuHostName`
                // because a `maxWidth` frame in this overlay would stretch
                // the capsule to that width, and a `fixedSize` would let a
                // long name spill past the material.
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
                .contentShape(Capsule())
        }
        .foregroundStyle(.primary)
        // Near-opaque at rest: the material capsule already separates it from
        // whatever herdr is drawing underneath, and a pointer is not the only
        // way this screen gets used.
        .opacity(isHovering || isPressed ? 1 : 0.92)
        // A press lifts the capsule the way a hovering pointer does. A `Menu`
        // only routes a `ButtonStyle` to its label under `.button` menu style;
        // the style itself only reports the press and draws the label as is.
        .menuStyle(.button)
        .buttonStyle(PressReportingButtonStyle { isPressed = $0 })
        .onHover { isHovering = $0 }
        .hoverEffect(.highlight)
        .padding(12)
        .accessibilityLabel("Kelpie Menu")
        .accessibilityHint("Hosts, agents and settings")
    }

    /// The same capsule either way: a narrow window keeps the icon and drops
    /// the Host name, because the accessibility label on the menu already
    /// says what this is and herdr's tab strip needs the columns back.
    @ViewBuilder
    private var menuLabel: some View {
        let label = Label(menuHostName, systemImage: "server.rack")
        if isCompactWidth {
            label.labelStyle(.iconOnly)
        } else {
            label
        }
    }

    /// The primary Host's name, capped so the capsule stays a chip over the
    /// right end of herdr's tab strip rather than a bar across it.
    private var menuHostName: String {
        let name = primaryHost.host(in: hosts.hosts)?.displayName ?? "Kelpie"
        let cap = 24
        guard name.count > cap else { return name }
        return String(name.prefix(cap - 1)) + "…"
    }

    private func reconnectHost(_ id: Host.ID) async {
        guard manualReconnectInFlightHostIDs.insert(id).inserted else { return }
        await console.retryHost(id)
        try? await Task.sleep(for: .milliseconds(1_200))
        manualReconnectInFlightHostIDs.remove(id)
    }
}

/// Reports its button's press state and draws nothing of its own. SwiftUI
/// gives a `Menu` label no `isPressed` to read, and `hoverEffect` answers a
/// pointer alone; this is the smallest thing that tells the label a finger is
/// on it.
private struct PressReportingButtonStyle: ButtonStyle {
    let isPressedDidChange: (Bool) -> Void

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, isPressed in
                isPressedDidChange(isPressed)
            }
    }
}

/// A handle on the live Client for chrome that sits outside it. Weak, and set
/// by the screen itself, so a Host switch rebuilding the store cannot leave
/// the menu driving a dead one.
@MainActor
@Observable
final class HerdrClientCommands {
    weak var store: HerdrClientStore?
    /// The live Client's media staging, for the menu's own pickers. Weak for
    /// the same reason `store` is: the menu outlives every Host switch.
    weak var media: HerdrMediaStagingStore?

    /// The Host file viewer for the Host on screen. Weak like the rest: the
    /// menu outlives every Host switch.
    weak var files: HostFileViewerStore?

    func reconnect() { store?.reconnect() }

    /// Fetches one Host file and previews it. The menu's "Open File on
    /// Host…" calls this; so should a tap on a path in the terminal, once
    /// the terminal view forwards one (`TerminalLinkDetector.Match.hostPath`).
    func openHostFile(_ path: String) { files?.open(path) }

    func stage(_ items: [MediaIntakeItem]) { media?.stage(items) }

    /// Ends the Client's attach and waits for the channel to close.
    func prepareForConsole() async {
        guard let store else { return }
        store.setPresented(false)
        await store.leave().value
    }
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
    @State private var keyboardControl: TerminalKeyboardControl
    @State private var media: HerdrMediaStagingStore
    @State private var files: HostFileViewerStore

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
        let store = HerdrClientStore(
            hostID: host.id,
            sessionName: sessionName.isEmpty ? nil : sessionName,
            transportGeneration: console.hostConnectionGenerations[host.id],
            runTerminal: console.terminalRunner(for: host.id))
        let keyboardControl = TerminalKeyboardControl()
        _store = State(initialValue: store)
        _keyboardControl = State(initialValue: keyboardControl)
        _files = State(
            initialValue: HostFileViewerStore(download: console.fileDownloader(for: host.id)))
        // The Client's draft is the pane itself: a staged path is typed in,
        // through the same route a text paste takes, with the bracketed-paste
        // mode the live surface reports.
        _media = State(
            initialValue: HerdrMediaStagingStore(
                stageImage: console.imageStager(for: host.id),
                stageFile: console.fileStager(for: host.id),
                insert: { text in
                    store.requestPaste(
                        text,
                        bracketedPaste: keyboardControl.usesBracketedPaste)
                }))
    }

    var body: some View {
        HerdrClientView(
            store: store,
            terminal: terminal,
            activity: activity,
            hardwareKeyboard: hardwareKeyboard,
            onHostPathTap: { path in commands.openHostFile(path) },
            keyboardControl: keyboardControl,
            media: media
        )
        .onChange(of: console.hostConnectionGenerations[host.id]) { _, generation in
            store.transportGenerationDidChange(generation)
        }
        .onChange(of: isShowingConsole, initial: true) { _, isShowing in
            store.setPresented(!isShowing)
        }
        // Paired: a Host switch replaces this view (`.id(host.id)`) and the
        // old store's channel has to close with it, or the Host it was
        // holding refuses the next attach. `rejoin()` is a no-op unless a
        // spurious disappear/appear pair actually left it.
        .hostFileViewer(files)
        .onAppear {
            commands.store = store
            commands.media = media
            commands.files = files
            store.rejoin()
        }
        .onDisappear { store.leave() }
        // A staging operation is exactly the work worth finishing while the
        // app is briefly out of sight; it is cancelled only on real suspension.
        .onChange(of: activity.phase) { _, phase in
            guard phase == .suspended else { return }
            media.didEnterBackground()
        }
    }
}
