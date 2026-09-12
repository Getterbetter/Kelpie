import Foundation
import Observation
import UIKit
import os

/// Scoped borrow of a Host's live connection for Notification Registration
/// work (#75). The Console already keeps one SSH connection per Host;
/// preference reads and writes ride it instead of dialing a second one. An
/// unreachable Host throws `TransportError` — never a silent no-op.
protocol NotificationTransportProvider: Sendable {
    func withNotificationTransport<Value: Sendable>(
        for hostID: Host.ID,
        _ operation: @escaping @Sendable (any Transport) async throws -> Value
    ) async throws -> Value
}

/// The (token, environment) pair this device last successfully wrote into
/// one Host's Notification Registration file.
///
/// Both halves move without the user touching anything: APNs may hand out a
/// new token on any launch, and the same install switched from a development
/// build to TestFlight changes `env` from sandbox to production. A Host still
/// holding the old pair gets its pushes posted to the wrong APNs host, where
/// they are dropped in silence — so the pair is persisted and compared on
/// every launch, and a difference re-runs the registration ceremony.
struct RegisteredDeviceTokenLog {
    /// `UserDefaults` key: Host id → `"<env>:<unix seconds>:<token hex>"`. A
    /// plain string dictionary so the value stays a plist type and an
    /// unreadable blob reads as "nothing was ever registered", which only
    /// costs one extra idempotent upsert. Records written before the
    /// timestamp existed are two-part and still read.
    static let defaultsKey = "kelpie.notifications.last-registered-device"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The pair last written for `hostID`, nil when this device has never
    /// registered there (or the record predates this bookkeeping).
    func lastRegistered(for hostID: Host.ID) -> APNSDeviceToken? {
        lastRegistration(for: hostID)?.token
    }

    /// The pair and when it was written; the date is nil for records written
    /// by a build that did not keep one.
    func lastRegistration(for hostID: Host.ID) -> (token: APNSDeviceToken, date: Date?)? {
        guard let encoded = stored[hostID.uuidString] else { return nil }
        let parts = encoded.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard let environment = APNSEnvironment(rawValue: String(parts.first ?? "")) else {
            return nil
        }
        // Token hex never contains a colon, so the shape is unambiguous.
        switch parts.count {
        case 2 where !parts[1].isEmpty:
            return (APNSDeviceToken(hex: String(parts[1]), environment: environment), nil)
        case 3 where !parts[2].isEmpty:
            let date = Double(parts[1]).map(Date.init(timeIntervalSince1970:))
            return (APNSDeviceToken(hex: String(parts[2]), environment: environment), date)
        default:
            return nil
        }
    }

    func record(_ token: APNSDeviceToken, at date: Date = Date(), for hostID: Host.ID) {
        var values = stored
        values[hostID.uuidString] =
            "\(token.environment.rawValue):\(date.timeIntervalSince1970):\(token.hex)"
        write(values)
    }

    /// Drops the record for a Host this device just revoked itself from, so a
    /// later re-registration writes the pair afresh.
    func forget(_ hostID: Host.ID) {
        var values = stored
        guard values.removeValue(forKey: hostID.uuidString) != nil else { return }
        write(values)
    }

    private var stored: [String: String] {
        (defaults.dictionary(forKey: Self.defaultsKey) as? [String: String]) ?? [:]
    }

    private func write(_ values: [String: String]) {
        if values.isEmpty {
            defaults.removeObject(forKey: Self.defaultsKey)
        } else {
            defaults.set(values, forKey: Self.defaultsKey)
        }
    }
}

/// The one thing registration work outside this store needs from it: a way to
/// say that it failed, so the Host's row shows the failure instead of a log
/// line nobody reads (#8). Deliberately narrow — the Live Activity
/// coordinator and pairing sync take it as an optional dependency that
/// defaults to nil, so every test double of theirs keeps working untouched.
@MainActor
protocol RegistrationFailureRecording: AnyObject {
    func recordRegistrationFailure(
        _ error: any Error,
        source: NotificationPreferencesStore.RegistrationSource,
        for hostID: Host.ID)
    func clearRegistrationNote(for hostID: Host.ID)
}

/// Per-Host Agent Notification preferences (#75): the on/off registration
/// toggle and the separate Done flag, persisted in the Host's registration
/// file and filtered at the source by the plugin (the service extension
/// cannot silently drop a push).
///
/// The displayed value is always the last state the Host confirmed: a toggle
/// never flips optimistically, a failed write surfaces its error and snaps
/// back, and `refresh` re-reads the file so the screen shows the Host's
/// truth, not a local mirror.
@MainActor
@Observable
final class NotificationPreferencesStore {
    /// One Host's confirmed registration state, as its file last reported it.
    struct HostSettings: Equatable, Sendable {
        /// Whether this device has an entry in the Host's registration file.
        var isRegistered: Bool
        /// The entry's notify flags; meaningful only while registered.
        var notify: NotificationTriggerPreferences
        /// The APNs environment the Host's entry names for this device. It
        /// can disagree with the environment this install registers in — a
        /// development build's entry left behind by a TestFlight one — which
        /// sends every push to the wrong APNs host, so it is displayed
        /// rather than merely used.
        var environment: APNSEnvironment?
    }

    enum HostState: Equatable, Sendable {
        /// The registration file read is in flight.
        case loading
        /// The Host's truth is unknown: unreachable, plugin missing, or push
        /// bootstrap incomplete. No toggle can act until a refresh succeeds.
        case unavailable(message: String)
        /// The Host answered; the toggles reflect `settings`.
        case idle(HostSettings)
        /// A preference write is in flight; `settings` stays the last
        /// confirmed truth until the Host acknowledges.
        case updating(HostSettings)
        /// A write failed; `settings` is still the Host's truth (the replace
        /// is atomic), and the message says why the toggle did not move.
        case failed(message: String, settings: HostSettings)
    }

    /// Where a registration attempt that happens outside this store came
    /// from, so its note says which part of the pipeline is not armed.
    enum RegistrationSource: Sendable {
        case liveActivity
        case pairingSync

        var label: String {
            switch self {
            case .liveActivity: "Live Activity registration"
            case .pairingSync: "Paired-device registration"
            }
        }
    }

    private(set) var hosts: [Host] = []
    private(set) var states: [Host.ID: HostState] = [:]
    /// Per-Host notes from registration work this store did not drive
    /// (#8): the Live Activity token write and the pairing-sync adoption
    /// ceremony both used to swallow their failures into a once-per-process
    /// log line, so a second device that never armed looked identical to one
    /// that did.
    private(set) var registrationNotes: [Host.ID: String] = [:]

    private let transports: any NotificationTransportProvider
    private let deviceToken: @MainActor () -> APNSDeviceToken?
    /// The app-side custom Push Relay base URL, read at write time so a change
    /// in Settings lands on the next Host the user registers. `nil` — the
    /// empty/default setting — leaves each Host's `notify.json` untouched (#76).
    private let relayBaseURL: @MainActor () -> URL?
    private let ceremony: NotificationRegistrationCeremony
    /// What was last registered where, so a changed token or APNs
    /// environment can be noticed without reading every Host's file for it.
    private let registeredTokens: RegisteredDeviceTokenLog
    /// Hosts with a re-registration in flight: one ceremony per Host at a
    /// time, however many triggers fire while it runs.
    private var reregistering: Set<Host.ID> = []
    /// Hosts whose local notification state is being torn down, so the two
    /// removal triggers (the deletion hook and the catalog diff) cannot run
    /// the ceremony twice.
    private var forgetting: Set<Host.ID> = []
    /// Hosts whose entry could not be withdrawn before they left the
    /// catalog; their note outlives the Host row that would have shown it.
    private(set) var withdrawalFailures: Set<Host.ID> = []
    /// Short and bounded: the deletion is already done locally, and the user
    /// is not waiting on this.
    private static let withdrawalAttempts = 3
    private static let withdrawalRetryDelay: Duration = .milliseconds(400)
    /// Removed in `deinit`; the app's store lives for the process, but a
    /// test's must not keep answering after it goes.
    @ObservationIgnored private nonisolated(unsafe) var foregroundObserver: (any NSObjectProtocol)?
    @ObservationIgnored private nonisolated let foregroundCenter: NotificationCenter

    private static let log = Logger(
        subsystem: "dev.bybee.heeler", category: "notification-registration")

    /// The app foregrounding: the one moment worth re-reading every Host's
    /// file on, because everything that invalidates it happens while the app
    /// is away — the plugin pruning this device's token on an APNs `410`,
    /// another device rewriting a flag, a Host restored from a backup.
    static let foregroundNotification = UIApplication.didBecomeActiveNotification

    init(
        transports: any NotificationTransportProvider,
        deviceToken: @escaping @MainActor () -> APNSDeviceToken?,
        relayBaseURL: @escaping @MainActor () -> URL? = { nil },
        defaults: UserDefaults = .standard,
        ceremony: NotificationRegistrationCeremony = NotificationRegistrationCeremony(),
        foregroundCenter: NotificationCenter = .default
    ) {
        self.transports = transports
        self.deviceToken = deviceToken
        self.relayBaseURL = relayBaseURL
        self.ceremony = ceremony
        self.registeredTokens = RegisteredDeviceTokenLog(defaults: defaults)
        self.foregroundCenter = foregroundCenter
        // Observed here rather than through a scene-phase trigger in the
        // view: the file is this store's business, and a store that only
        // refreshes when something else remembers to ask is how a pruned
        // registration stayed invisible for a day.
        foregroundObserver = foregroundCenter.addObserver(
            forName: Self.foregroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // Weak in the *outer* closure: the notification center retains
            // the block, so a strong capture would keep the store alive for
            // the process and never run `deinit`.
            Task { @MainActor in await self?.appDidBecomeActive() }
        }
    }

    deinit {
        if let foregroundObserver {
            foregroundCenter.removeObserver(foregroundObserver)
        }
    }

    /// Re-read, then re-register anything the read proved stale.
    func appDidBecomeActive() async {
        await refresh()
        await reregisterChangedDevices()
    }

    /// Aligns with the Host catalog; a removed Host drops its state, its
    /// Notification Key, and its entry on the Host itself.
    func setHosts(_ hosts: [Host]) {
        let known = Set(hosts.map(\.id))
        // Named before the catalog moves: a withdrawal that fails has to say
        // which Host it could not reach, and by then the Host is gone.
        let removed = self.hosts.filter { !known.contains($0.id) }
        self.hosts = hosts
        states = states.filter { known.contains($0.key) }
        // A removed Host's note is kept: it is the record of an entry still
        // armed on a machine this device can no longer reach.
        registrationNotes = registrationNotes.filter {
            known.contains($0.key) || withdrawalFailures.contains($0.key)
        }
        for host in removed {
            hostWasRemoved(host.id, named: host.displayName)
        }
    }

    /// A Host left the catalog. Its Notification Key is this device's half of
    /// a credential the Host still holds, and its entry still names this
    /// device's token, so both go: leaving them behind means a deleted Host
    /// can keep pushing to a device that has no way to show where the push
    /// came from.
    ///
    /// The withdrawal races the Console: `ContentView` hands the new catalog
    /// to `ConsoleStore` too, and that drops the Host's projection — after
    /// which `withNotificationTransport` throws forever and the Host is left
    /// holding an armed entry with a still-valid token. A `400` would then
    /// keep coming back, never the `410` that prunes.
    ///
    /// Two things answer that. `ContentView` calls this from `HostStore`'s
    /// deletion hook, which runs synchronously inside `remove(_:)` — before
    /// the catalog change has propagated anywhere — so the first attempt is
    /// made while the projection is still up. And the attempt is retried for
    /// a short while, because a projection that is mid-teardown throws once
    /// and a reconnecting one comes back. Only when every attempt fails is
    /// the entry abandoned, with a note saying so.
    func hostWasRemoved(_ hostID: Host.ID, named hostName: String? = nil) {
        let name = hostName ?? hosts.first { $0.id == hostID }?.displayName
        Task { await forget(hostID, named: name) }
    }

    func forget(_ hostID: Host.ID, named hostName: String? = nil) async {
        guard !forgetting.contains(hostID) else { return }
        let name = hostName ?? hosts.first { $0.id == hostID }?.displayName ?? "that Host"
        forgetting.insert(hostID)
        defer {
            forgetting.remove(hostID)
            registeredTokens.forget(hostID)
            states[hostID] = nil
            if !withdrawalFailures.contains(hostID) { registrationNotes[hostID] = nil }
        }
        if let token = deviceToken() {
            let ceremony = ceremony
            var lastError: (any Error)?
            for attempt in 0..<Self.withdrawalAttempts {
                if attempt > 0 {
                    try? await Task.sleep(for: Self.withdrawalRetryDelay)
                }
                do {
                    try await transports.withNotificationTransport(for: hostID) { transport in
                        // Removes the entry over SSH and then the local key,
                        // in that order, so a failed write keeps the key that
                        // still-armed pushes need.
                        try await ceremony.remove(
                            hostID: hostID, deviceToken: token, over: transport)
                    }
                    withdrawalFailures.remove(hostID)
                    return
                } catch {
                    lastError = error
                }
            }
            if let lastError {
                Self.log.info(
                    "removed Host entry not withdrawn: \(String(describing: lastError), privacy: .public)"
                )
                // Visible, not just logged: the Host keeps pushing to this
                // device until something else retires the entry.
                withdrawalFailures.insert(hostID)
                registrationNotes[hostID] =
                    "Could not withdraw this device from \(name) before it was removed. "
                    + "Its entry stays there until the Host's plugin prunes it "
                    + "on the first failed notification."
            }
        }
        // Unreachable, or no token to name an entry with: the key goes
        // regardless, so nothing on this device can decrypt that Host's
        // pushes any more.
        try? ceremony.keys.removeRecord(forHost: hostID)
    }

    /// Records a failure from registration work this store did not drive, so
    /// it shows on the Host's row instead of a log line nobody reads.
    func recordRegistrationFailure(
        _ error: any Error, source: RegistrationSource, for hostID: Host.ID
    ) {
        registrationNotes[hostID] = "\(source.label) failed. \(Self.message(for: error))"
    }

    /// The matching success: the note goes when that path finally lands.
    func clearRegistrationNote(for hostID: Host.ID) {
        registrationNotes[hostID] = nil
    }

    /// Re-reads every Host's registration file so the toggles reflect what
    /// each Host actually holds.
    func refresh() async {
        await withTaskGroup { group in
            for host in hosts {
                group.addTask { await self.load(host) }
            }
        }
    }

    /// The per-Host on/off (registration add/remove). Enabling registers
    /// this device with both triggers on; disabling removes its entry and
    /// drops the local Notification Key.
    func setNotificationsEnabled(_ enabled: Bool, for host: Host) async {
        guard let settings = confirmedSettings(for: host.id),
            settings.isRegistered != enabled
        else { return }
        let relay = relayBaseURL()
        await write(for: host, from: settings) { ceremony, token, transport in
            if enabled {
                let notify = NotificationTriggerPreferences()
                try await ceremony.register(
                    hostID: host.id, hostName: host.displayName,
                    deviceToken: token, notify: notify, relayBaseURL: relay, over: transport)
                return HostSettings(isRegistered: true, notify: notify)
            } else {
                try await ceremony.remove(
                    hostID: host.id, deviceToken: token, over: transport)
                return HostSettings(
                    isRegistered: false, notify: NotificationTriggerPreferences())
            }
        }
    }

    /// The separate Done flag (User Story 9): rewrites this device's entry
    /// over SSH so the plugin stops (or resumes) sending Done pushes at the
    /// source. Ignored while unregistered — there is no entry to update.
    func setDoneEnabled(_ enabled: Bool, for host: Host) async {
        guard let settings = confirmedSettings(for: host.id),
            settings.isRegistered, settings.notify.done != enabled
        else { return }
        let notify = NotificationTriggerPreferences(
            blocked: settings.notify.blocked, done: enabled)
        let relay = relayBaseURL()
        await write(for: host, from: settings) { ceremony, token, transport in
            // Re-registration is the flag update: it upserts this device's
            // entry reusing the stored Notification Key (#72 idempotence).
            try await ceremony.register(
                hostID: host.id, hostName: host.displayName,
                deviceToken: token, notify: notify, relayBaseURL: relay, over: transport)
            return HostSettings(isRegistered: true, notify: notify)
        }
    }

    private func load(_ host: Host) async {
        if case .updating = states[host.id] { return }
        guard let token = deviceToken() else {
            states[host.id] = .unavailable(
                message: "Waiting for push registration on this device.")
            return
        }
        states[host.id] = .loading
        do {
            let file = try await readFile(for: host.id)
            let preferences = file.preferences(token: token.hex)
            states[host.id] = .idle(
                HostSettings(
                    isRegistered: preferences != nil,
                    notify: preferences ?? NotificationTriggerPreferences(),
                    environment: file.environment(token: token.hex)))
        } catch {
            states[host.id] = .unavailable(message: Self.message(for: error))
        }
    }

    /// Shared write choreography: hold the confirmed settings while the
    /// ceremony runs, publish the new truth on success, snap back with the
    /// error on failure (fail loudly — never a silently divergent toggle).
    private func write(
        for host: Host,
        from settings: HostSettings,
        _ operation: @escaping @Sendable (
            NotificationRegistrationCeremony, APNSDeviceToken, any Transport
        ) async throws -> HostSettings
    ) async {
        guard let token = deviceToken() else {
            states[host.id] = .unavailable(
                message: "Waiting for push registration on this device.")
            return
        }
        states[host.id] = .updating(settings)
        do {
            let ceremony = ceremony
            var confirmed = try await transports.withNotificationTransport(
                for: host.id
            ) { transport in
                try await operation(ceremony, token, transport)
            }
            // The entry that was just written names this token's environment
            // by construction.
            confirmed.environment = confirmed.isRegistered ? token.environment : nil
            states[host.id] = .idle(confirmed)
            registrationNotes[host.id] = nil
            // The entry the Host now holds carries this token and this
            // environment; recording the pair keeps the launch sweep below
            // from rewriting an entry that is already current.
            if confirmed.isRegistered {
                registeredTokens.record(token, for: host.id)
            } else {
                registeredTokens.forget(host.id)
            }
        } catch {
            states[host.id] = .failed(message: Self.message(for: error), settings: settings)
        }
    }

    /// Rewrites this device's entry on every Host whose registration file
    /// still carries a different (token, environment) pair than the one APNs
    /// handed this launch — the TestFlight switch that leaves a Host pushing
    /// to the sandbox APNs host, and Apple's own token rotation.
    ///
    /// Only Hosts this device is known to have registered with are touched —
    /// the Host's confirmed settings say so, or the recorded pair does — and
    /// the existing notify flags are re-sent as they are, so the ceremony is
    /// the idempotent upsert it already is (#72) and no preference is
    /// invented. A Host whose truth is still unknown — never refreshed,
    /// unreachable, mid-write — is skipped and picked up by a later trigger.
    /// Failures are logged, never surfaced: nothing the user did went wrong,
    /// and the next launch tries again.
    func reregisterChangedDevices() async {
        guard let token = deviceToken() else { return }
        for host in hosts {
            await reregisterIfPairChanged(host, token: token)
        }
    }

    private func reregisterIfPairChanged(_ host: Host, token: APNSDeviceToken) async {
        let last = registeredTokens.lastRegistered(for: host.id)
        // Three shapes of change reach here. The environment moving under a
        // token that is still in the file (a development install becoming a
        // TestFlight one) leaves this device registered, so its confirmed
        // flags are re-sent as they are. A token APNs rotated is missing from
        // the file entirely — the Host reads as unregistered — and only the
        // recorded pair proves this install registered there before.
        //
        // The third is a reinstall or a restore onto a new device without
        // pairing sync: `UserDefaults` is gone, so there is no recorded pair,
        // and APNs issued a token no entry carries, so the Host reads as
        // unregistered too. The Notification Key in the Keychain is what
        // survives both and proves this install was registered here — and
        // without this, the install stays permanently silent while a dead
        // entry sits on the Host drawing `400`s that prune nothing.
        // `try?` on an optional-returning throwing call double-wraps; the
        // flatten is what makes "no record" and "Keychain unreadable" alike.
        let hasNotificationKey = ((try? ceremony.keys.record(forHost: host.id)) ?? nil) != nil
        guard last != token, !reregistering.contains(host.id),
            let settings = confirmedSettings(for: host.id),
            settings.isRegistered || last != nil || hasNotificationKey
        else { return }
        reregistering.insert(host.id)
        // `.updating` for the duration: the confirmed truth is unchanged
        // until the Host acknowledges, and it keeps a toggle the user hits
        // meanwhile from racing this write.
        states[host.id] = .updating(settings)
        var confirmed = settings
        defer {
            reregistering.remove(host.id)
            states[host.id] = .idle(confirmed)
        }
        let ceremony = ceremony
        let relay = relayBaseURL()
        let hostName = host.displayName
        do {
            guard
                let notify = try await flagsToCarry(
                    for: host.id, settings: settings, last: last,
                    hasNotificationKey: hasNotificationKey)
            else { return }
            _ = try await transports.withNotificationTransport(for: host.id) { transport in
                try await ceremony.register(
                    hostID: host.id, hostName: hostName, deviceToken: token,
                    notify: notify, relayBaseURL: relay, over: transport)
            }
            registeredTokens.record(token, for: host.id)
            confirmed = HostSettings(
                isRegistered: true, notify: notify, environment: token.environment)
            registrationNotes[host.id] = nil
        } catch {
            Self.log.info(
                "re-registration failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// The notify flags the rewritten entry must carry, or nil when there is
    /// nothing to keep current. A rotated token reads them off the entry the
    /// old token still holds, so the user's Done choice survives the
    /// rotation; that dead entry is left for the plugin to prune on the first
    /// APNs `410` (ADR 0008), which is also what would retire it if this
    /// device never came back.
    private func flagsToCarry(
        for hostID: Host.ID, settings: HostSettings, last: APNSDeviceToken?,
        hasNotificationKey: Bool
    ) async throws -> NotificationTriggerPreferences? {
        if settings.isRegistered { return settings.notify }
        if let last, let carried = try await readFile(for: hostID).preferences(token: last.hex) {
            return carried
        }
        // A reinstall has no entry to read flags off, and the only record
        // that this device was ever registered is its surviving Notification
        // Key. Disabling notifications deletes that key (`ceremony.remove`),
        // so a key present means the user last chose "on" — restore the
        // defaults that choice writes rather than leaving the install silent.
        return hasNotificationKey ? NotificationTriggerPreferences() : nil
    }

    private func readFile(for hostID: Host.ID) async throws -> NotificationRegistrationFile {
        try NotificationRegistrationFile.decode(
            try await transports.withNotificationTransport(for: hostID) { transport in
                try await transport.readNotificationRegistration()
            })
    }

    /// The gate the in-app banner reads (#77): the Host's confirmed notify
    /// flags, or nil when this device is not registered or the Host's truth
    /// is unknown (unreachable, still loading, never refreshed) — in which
    /// case the banner fails closed, matching the plugin's semantics.
    /// When this device last wrote its (token, environment) pair into the
    /// Host's file. Nil when it never did, or when the record predates this
    /// bookkeeping — an old record is itself worth showing as "unknown"
    /// rather than as "never".
    func lastRegistrationDate(for hostID: Host.ID) -> Date? {
        registeredTokens.lastRegistration(for: hostID)?.date
    }

    func confirmedTriggers(for hostID: Host.ID) -> NotificationTriggerPreferences? {
        guard let settings = confirmedSettings(for: hostID), settings.isRegistered
        else { return nil }
        return settings.notify
    }

    private func confirmedSettings(for hostID: Host.ID) -> HostSettings? {
        switch states[hostID] {
        case .idle(let settings), .failed(_, let settings):
            settings
        case .loading, .unavailable, .updating, nil:
            nil
        }
    }

    static func message(for error: any Error) -> String {
        switch error {
        case NotificationRegistrationError.pluginNotInstalled:
            "Install the Heeler plugin on this Host, then check again."
        case NotificationRegistrationError.pluginProbeFailed:
            "Could not check the Heeler plugin on this Host. "
                + "Check the connection and try again."
        case NotificationRegistrationError.readFailed:
            "Could not read notification settings from this Host. "
                + "Check the connection and try again."
        case NotificationRegistrationError.writeFailed:
            "Could not update notification settings on this Host. "
                + "Check the connection and try again."
        case NotificationRegistrationError.unsupportedFileVersion:
            "This Host was registered by a newer app version. Update the app."
        case NotificationRegistrationError.deviceNotRegistered:
            "Register this device for notifications on this Host first."
        case TransportError.sshUnreachable:
            "The Host is not connected."
        case TransportError.timedOut:
            "The Host did not answer in time."
        case TransportError.herdrBinaryNotFound:
            TransportError.herdrBinaryNotFound.presentation.message
        case is TransportError:
            "The connection to the Host failed."
        default:
            "Could not update notification settings. Try again."
        }
    }
}

extension NotificationPreferencesStore: RegistrationFailureRecording {}
