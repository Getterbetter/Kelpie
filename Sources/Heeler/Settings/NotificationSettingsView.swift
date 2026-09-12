import SwiftUI
import UIKit

/// Notification settings: push registration, per-Host delivery preferences,
/// the privacy disclosure, and the self-builder relay override. Pushed from
/// the settings root, which owns the NavigationStack.
struct NotificationSettingsView: View {
    let pushRegistration: PushRegistrationStore
    let notificationPreferences: NotificationPreferencesStore
    @Bindable var relaySettings: NotificationRelaySettings
    let liveActivities: HostLiveActivityCoordinator
    @Environment(\.openURL) private var openURL
    @State private var isShowingExplainer = false

    var body: some View {
        Form {
            Section {
                notificationRow
            } header: {
                Text("Agent Notifications")
            } footer: {
                Text("Get notified when an Agent is waiting for your input or finishes.")
            }

            // Per-Host preferences (#75): registration on/off plus the
            // separate Done flag, once this device holds a push token.
            if pushRegistration.deviceToken != nil {
                ForEach(notificationPreferences.hosts) { host in
                    hostNotificationSection(host)
                }
            }

            // The persistent privacy disclosure (#76): the same story as
            // the pre-permission explainer, reachable any time, linking to
            // PRIVACY.md.
            privacySection

            // Custom Push Relay base URL (#76): only meaningful to a
            // self-builder; empty leaves every Host's plugin config alone.
            // Last on purpose — it is the one section most users never touch.
            customRelaySection
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .task { await notificationPreferences.refresh() }
        // The user can finish push bootstrap on this very screen; the
        // per-Host rows appear the moment the token lands.
        .onChange(of: pushRegistration.deviceToken) { _, token in
            guard token != nil else { return }
            Task { await notificationPreferences.refresh() }
        }
        // The disclosure gate (#76): the iOS permission prompt only fires
        // after the user reads the explainer and taps Continue.
        .sheet(isPresented: $isShowingExplainer) {
            NotificationExplainerSheet {
                Task { await pushRegistration.enable() }
            }
        }
    }

    @ViewBuilder
    private var notificationRow: some View {
        switch pushRegistration.state {
        case .unknown:
            HStack {
                Text("Checking notification status")
                    .foregroundStyle(.secondary)
                Spacer()
                ProgressView()
            }
        case .needsPermission:
            Button("Enable Notifications") {
                isShowingExplainer = true
            }
        case .waitingForToken:
            HStack {
                Text("Registering with Apple")
                Spacer()
                ProgressView()
            }
        case .registered(let token):
            HStack {
                Text("Ready to configure Host notifications")
                Spacer()
                if token.environment == .sandbox {
                    Text("Sandbox")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)
            }
        case .denied, .revoked:
            VStack(alignment: .leading, spacing: 6) {
                Text("Notifications are turned off for Kelpie.")
                // The Hosts keep their entries and keep sending; iOS drops
                // every push. Nothing else on the device says so, so this
                // row does (#3, #6).
                if hasAnyRegisteredHost {
                    Text(
                        "This device is still registered with a Host, "
                            + "but iOS will not deliver anything until you turn "
                            + "notifications back on."
                    )
                    .font(.caption)
                    .foregroundStyle(.red)
                }
                Button("Open Kelpie Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        openURL(url)
                    }
                }
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Text("Could not register for push notifications. \(message)")
                    .foregroundStyle(.secondary)
                Button("Try Again") {
                    Task { await pushRegistration.enable() }
                }
            }
        }
    }

    private func hostNotificationSection(_ host: Host) -> some View {
        Section {
            switch notificationPreferences.states[host.id] {
            case nil, .loading:
                HStack {
                    Text("Checking this Host")
                        .foregroundStyle(.secondary)
                    Spacer()
                    ProgressView()
                }
            case .unavailable(let message):
                VStack(alignment: .leading, spacing: 6) {
                    Text(message)
                        .foregroundStyle(.secondary)
                    Button("Check Again") {
                        Task { await notificationPreferences.refresh() }
                    }
                }
            case .idle(let settings):
                hostToggles(host: host, settings: settings, isUpdating: false)
            case .updating(let settings):
                hostToggles(host: host, settings: settings, isUpdating: true)
            case .failed(_, let settings):
                hostToggles(host: host, settings: settings, isUpdating: false)
            }
        } header: {
            Text(host.displayName)
        } footer: {
            hostSectionFooter(host)
        }
    }

    @ViewBuilder
    private func hostToggles(
        host: Host,
        settings: NotificationPreferencesStore.HostSettings,
        isUpdating: Bool
    ) -> some View {
        Toggle(
            "Notifications",
            isOn: Binding(
                get: { settings.isRegistered },
                set: { enabled in
                    Task {
                        await notificationPreferences.setNotificationsEnabled(
                            enabled, for: host)
                    }
                }))
            .disabled(isUpdating)
        if settings.isRegistered {
            Toggle(
                "Done Notifications",
                isOn: Binding(
                    get: { settings.notify.done },
                    set: { enabled in
                        Task {
                            await notificationPreferences.setDoneEnabled(enabled, for: host)
                        }
                    }))
                .disabled(isUpdating)
            Toggle(
                "Live Activity",
                isOn: Binding(
                    get: { liveActivities.isEnabled(for: host.id) },
                    set: { liveActivities.setEnabled($0, for: host.id) }))
                .disabled(isUpdating)
        }
    }

    /// Whether any Host still holds an entry for this device — the thing
    /// that makes withdrawn permission a silent failure rather than a
    /// setting nobody used.
    private var hasAnyRegisteredHost: Bool {
        notificationPreferences.hosts.contains { registeredSettings(for: $0.id) != nil }
    }

    private func registeredSettings(
        for hostID: Host.ID
    ) -> NotificationPreferencesStore.HostSettings? {
        switch notificationPreferences.states[hostID] {
        case .idle(let settings), .updating(let settings), .failed(_, let settings):
            settings.isRegistered ? settings : nil
        case .loading, .unavailable, nil:
            nil
        }
    }

    /// The end-to-end health of one Host's registration (#6). Nothing here
    /// proves a push arrives — only a delivered push does that — but these
    /// are the two disagreements the app *can* see, and both of them
    /// previously failed in total silence: a `400 BadDeviceToken` from a
    /// wrong-environment entry prunes nothing and retries nothing.
    @ViewBuilder
    private func hostHealth(_ host: Host) -> some View {
        if let settings = registeredSettings(for: host.id) {
            let buildEnvironment =
                pushRegistration.deviceToken?.environment ?? APNSEnvironment.current
            if let entryEnvironment = settings.environment, entryEnvironment != buildEnvironment {
                Text(
                    "This Host's entry is for the \(entryEnvironment.rawValue) APNs "
                        + "environment; this build registers in \(buildEnvironment.rawValue). "
                        + "Pushes are being sent to the wrong Apple server. "
                        + "Turn Notifications off and on again to rewrite it."
                )
                .foregroundStyle(.red)
            } else if let entryEnvironment = settings.environment {
                Text("APNs environment: \(entryEnvironment.rawValue).")
            }
            if let registeredAt = notificationPreferences.lastRegistrationDate(for: host.id) {
                Text(
                    "This device registered \(registeredAt.formatted(date: .abbreviated, time: .shortened))."
                )
            } else {
                Text("This device's registration date is not recorded on this install.")
            }
            // Failures from the registration side-paths, which used to log
            // once per process and never speak again (#8).
            if let note = notificationPreferences.registrationNotes[host.id] {
                Text(note)
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private func hostSectionFooter(_ host: Host) -> some View {
        let registered = registeredSettings(for: host.id) != nil
        VStack(alignment: .leading, spacing: 6) {
            hostHealth(host)
            if registered {
                Text(NotificationPrivacyCopy.liveActivityFooter)
                if !liveActivities.areActivitiesEnabled {
                    Text(NotificationPrivacyCopy.liveActivityDisabledHint)
                }
                if liveActivities.isEnabled(for: host.id),
                    let note = liveActivities.reconcileNotes[host.id]
                {
                    Text("Live Activity: \(note)")
                }
            }
            // Fail loudly (#75): a toggle that could not reach the Host
            // says so and stays on the Host's confirmed value.
            if case .failed(let message, _) = notificationPreferences.states[host.id] {
                Text(message)
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private var privacySection: some View {
        Section {
            NavigationLink {
                NotificationPrivacyDetailView()
            } label: {
                Label("How notifications stay private", systemImage: "lock.shield")
            }
        } header: {
            Text("Privacy")
        } footer: {
            Text(NotificationPrivacyCopy.summary)
        }
    }

    @ViewBuilder
    private var customRelaySection: some View {
        Section {
            TextField(
                NotificationRelayEndpoint.productionBaseURLString,
                text: $relaySettings.rawValue)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .textContentType(.URL)
            if relaySettings.hasInvalidEntry {
                Text("Enter a valid HTTP or HTTPS URL.")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if relaySettings.hasInsecureHTTPEntry {
                Text(
                    "HTTP exposes the device token and notification metadata. "
                        + "Use HTTPS except for local development."
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
        } header: {
            Text("Custom Push Relay")
        } footer: {
            Text(
                "Leave blank to use \(NotificationRelayEndpoint.productionBaseURLString). "
                    + NotificationPrivacyCopy.customRelayCaveat)
        }
    }
}
