import Foundation
import Testing

@testable import Heeler

/// `NotificationTransportProvider` double: hands each Host's scripted (or
/// real, in the e2e suite) Transport to the operation. Hosts without one are
/// unreachable, exactly like a Console projection that never connected — and
/// a Host can be cut off mid-test, like a connection dropping between the
/// settings screen loading and a toggle.
actor ScriptedTransportProvider: NotificationTransportProvider {
    private var transports: [Host.ID: any Transport]

    init(transports: [Host.ID: any Transport]) {
        self.transports = transports
    }

    func setTransport(_ transport: (any Transport)?, for hostID: Host.ID) {
        transports[hostID] = transport
    }

    func withNotificationTransport<Value: Sendable>(
        for hostID: Host.ID,
        _ operation: @escaping @Sendable (any Transport) async throws -> Value
    ) async throws -> Value {
        guard let transport = transports[hostID] else {
            throw TransportError.sshUnreachable(detail: "The Host is not connected.")
        }
        return try await operation(transport)
    }
}

/// A provider whose Host is unreachable for its first `failuresBeforeServing`
/// calls — the projection being torn down and rebuilt underneath a
/// withdrawal.
actor FlakyTransportProvider: NotificationTransportProvider {
    private let transport: any Transport
    private let hostID: Host.ID
    private var remainingFailures = 0
    private(set) var callCount = 0

    init(transport: any Transport, hostID: Host.ID) {
        self.transport = transport
        self.hostID = hostID
    }

    /// The next `count` borrows fail, as they do while the Console is
    /// tearing the Host's projection down.
    func failNext(_ count: Int) {
        remainingFailures = count
    }

    func withNotificationTransport<Value: Sendable>(
        for hostID: Host.ID,
        _ operation: @escaping @Sendable (any Transport) async throws -> Value
    ) async throws -> Value {
        callCount += 1
        guard hostID == self.hostID, remainingFailures <= 0 else {
            remainingFailures -= 1
            throw TransportError.sshUnreachable(detail: "The Host is not connected.")
        }
        return try await operation(transport)
    }
}

@MainActor
@Suite("Notification preferences store")
struct NotificationPreferencesStoreTests {
    private let host = Host(name: "mac-studio", address: "10.0.0.2", username: "z")
    private let token = APNSDeviceToken(hex: "0a1b2c3d", environment: .sandbox)
    private let secrets = InMemorySecretStore()
    private var keys: NotificationKeyStore { NotificationKeyStore(secrets: secrets) }

    private func makeStore(
        provider: any NotificationTransportProvider,
        deviceToken: APNSDeviceToken?
    ) -> NotificationPreferencesStore {
        let store = NotificationPreferencesStore(
            transports: provider,
            deviceToken: { deviceToken },
            ceremony: NotificationRegistrationCeremony(keys: keys))
        store.setHosts([host])
        return store
    }

    private func makeStore(
        transport: any Transport,
        deviceToken: APNSDeviceToken? = nil
    ) -> NotificationPreferencesStore {
        makeStore(
            provider: ScriptedTransportProvider(transports: [host.id: transport]),
            deviceToken: deviceToken ?? token)
    }

    private func makeStore(
        transport: any Transport,
        relayBaseURL: @escaping @MainActor () -> URL?
    ) -> NotificationPreferencesStore {
        let store = NotificationPreferencesStore(
            transports: ScriptedTransportProvider(transports: [host.id: transport]),
            deviceToken: { self.token },
            relayBaseURL: relayBaseURL,
            ceremony: NotificationRegistrationCeremony(keys: keys))
        store.setHosts([host])
        return store
    }

    // MARK: Reflecting the Host's truth

    @Test func refreshReflectsAnUnregisteredHost() async throws {
        let store = makeStore(transport: ScriptedTransport())

        await store.refresh()

        #expect(
            store.states[host.id]
                == .idle(
                    .init(isRegistered: false, notify: NotificationTriggerPreferences())))
    }

    @Test func refreshReflectsThisDevicesEntryFlags() async throws {
        let transport = ScriptedTransport()
        await transport.setNotificationRegistration(
            Data(
                (#"{"v":1,"devices":[{"token":"\#(token.hex)","key":"kk","env":"sandbox","#
                    + #""notify":{"blocked":true,"done":false}}]}"#).utf8))
        let store = makeStore(transport: transport)

        await store.refresh()

        #expect(
            store.states[host.id]
                == .idle(
                    .init(
                        isRegistered: true,
                        notify: NotificationTriggerPreferences(blocked: true, done: false),
                        environment: .sandbox)))
    }

    @Test func refreshWithoutAPushTokenIsUnavailable() async throws {
        let store = makeStore(
            provider: ScriptedTransportProvider(transports: [host.id: ScriptedTransport()]),
            deviceToken: nil)

        await store.refresh()

        guard case .unavailable = store.states[host.id] else {
            Issue.record("expected .unavailable, got \(String(describing: store.states[host.id]))")
            return
        }
    }

    @Test func refreshSurfacesAnUnreachableHost() async throws {
        let store = makeStore(
            provider: ScriptedTransportProvider(transports: [:]), deviceToken: token)

        await store.refresh()

        #expect(store.states[host.id] == .unavailable(message: "The Host is not connected."))
    }

    @Test func refreshSurfacesAMissingPlugin() async throws {
        let transport = ScriptedTransport()
        await transport.setNotificationRegistrationReadFailure(.pluginNotInstalled)
        let store = makeStore(transport: transport)

        await store.refresh()

        guard case .unavailable(let message) = store.states[host.id] else {
            Issue.record("expected .unavailable, got \(String(describing: store.states[host.id]))")
            return
        }
        #expect(message == "Install the Heeler plugin on this Host, then check again.")
    }

    @Test func removingAHostFromTheCatalogDropsItsState() async throws {
        let store = makeStore(transport: ScriptedTransport())
        await store.refresh()

        store.setHosts([])

        #expect(store.hosts.isEmpty)
        #expect(store.states.isEmpty)
    }

    // MARK: Per-Host on/off

    @Test func enablingRegistersTheDevice() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport)
        await store.refresh()

        await store.setNotificationsEnabled(true, for: host)

        #expect(
            store.states[host.id]
                == .idle(
                    .init(
                        isRegistered: true, notify: NotificationTriggerPreferences(),
                        environment: .sandbox)))
        let file = try NotificationRegistrationFile.decode(
            await transport.notificationRegistration)
        #expect(file.containsDevice(token: token.hex))
        #expect(try keys.record(forHost: host.id) != nil)
    }

    @Test func disablingRemovesTheDeviceEntryAndTheKey() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport)
        await store.refresh()
        await store.setNotificationsEnabled(true, for: host)

        await store.setNotificationsEnabled(false, for: host)

        #expect(
            store.states[host.id]
                == .idle(
                    .init(isRegistered: false, notify: NotificationTriggerPreferences())))
        let file = try NotificationRegistrationFile.decode(
            await transport.notificationRegistration)
        #expect(!file.containsDevice(token: token.hex))
        #expect(try keys.record(forHost: host.id) == nil)
    }

    @Test func aFailedEnableDoesNotFlipTheToggle() async throws {
        let transport = ScriptedTransport()
        await transport.setNotificationRegistrationWriteFailure(
            .writeFailed(detail: "disk full"))
        let store = makeStore(transport: transport)
        await store.refresh()

        await store.setNotificationsEnabled(true, for: host)

        guard case .failed(let message, let settings) = store.states[host.id] else {
            Issue.record("expected .failed, got \(String(describing: store.states[host.id]))")
            return
        }
        #expect(
            message
                == "Could not update notification settings on this Host. "
                + "Check the connection and try again.")
        #expect(!settings.isRegistered)
    }

    @Test func togglingAnUnreachableHostFailsLoudlyWithoutFlipping() async throws {
        let provider = ScriptedTransportProvider(transports: [host.id: ScriptedTransport()])
        let store = makeStore(provider: provider, deviceToken: token)
        await store.refresh()
        // The Host drops off the network after the settings screen loaded.
        await provider.setTransport(nil, for: host.id)

        await store.setNotificationsEnabled(true, for: host)

        #expect(
            store.states[host.id]
                == .failed(
                    message: "The Host is not connected.",
                    settings: .init(
                        isRegistered: false, notify: NotificationTriggerPreferences())))
    }

    @Test func disablingAgainstAMissingPluginSurfacesAndKeepsTheKey() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport)
        await store.refresh()
        await store.setNotificationsEnabled(true, for: host)
        // The plugin was uninstalled on the Host after registration; `remove`
        // throws pluginNotInstalled and keeps the local key by design (#72).
        await transport.setNotificationRegistrationReadFailure(.pluginNotInstalled)

        await store.setNotificationsEnabled(false, for: host)

        guard case .failed(let message, let settings) = store.states[host.id] else {
            Issue.record("expected .failed, got \(String(describing: store.states[host.id]))")
            return
        }
        #expect(message.localizedCaseInsensitiveContains("plugin"))
        #expect(settings.isRegistered)
        #expect(try keys.record(forHost: host.id) != nil)
    }

    @Test func togglingToTheCurrentValueWritesNothing() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport)
        await store.refresh()

        await store.setNotificationsEnabled(false, for: host)

        #expect(await transport.replacedNotificationRegistrations.isEmpty)
    }

    @Test func enablingWritesTheCustomRelayURLIntoNotifyConfig() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(
            transport: transport,
            relayBaseURL: { URL(string: "https://relay.example.com") })
        await store.refresh()

        await store.setNotificationsEnabled(true, for: host)

        let written = try #require(await transport.notificationConfig)
        let config = try NotificationConfigFile.decode(written)
        #expect(config.relayURL == "https://relay.example.com")
    }

    @Test func enablingWithNoCustomRelayWritesTheProductionRelay() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, relayBaseURL: { nil })
        await store.refresh()

        await store.setNotificationsEnabled(true, for: host)

        let written = try #require(await transport.notificationConfig)
        let config = try NotificationConfigFile.decode(written)
        #expect(config.relayURL == "https://kelpie-apns.getter-tilbury-0m.workers.dev")
    }

    // MARK: Done flag

    @Test func doneToggleRewritesTheFlagOverSSH() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport)
        await store.refresh()
        await store.setNotificationsEnabled(true, for: host)
        let keyBefore = try #require(try keys.record(forHost: host.id)).key

        await store.setDoneEnabled(false, for: host)

        #expect(
            store.states[host.id]
                == .idle(
                    .init(
                        isRegistered: true,
                        notify: NotificationTriggerPreferences(blocked: true, done: false),
                        environment: .sandbox)))
        let file = try NotificationRegistrationFile.decode(
            await transport.notificationRegistration)
        let entry = try #require(
            file.devices.first { $0["token"]?.stringValue == token.hex })
        #expect(entry["notify"]?["done"] == .bool(false))
        #expect(entry["notify"]?["blocked"] == .bool(true))
        // Rewriting a flag must not rotate the Notification Key.
        #expect(try keys.record(forHost: host.id)?.key == keyBefore)
    }

    @Test func aFailedDoneToggleStaysOnTheConfirmedValue() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport)
        await store.refresh()
        await store.setNotificationsEnabled(true, for: host)
        await transport.setNotificationRegistrationWriteFailure(
            .writeFailed(detail: "read-only"))

        await store.setDoneEnabled(false, for: host)

        guard case .failed(_, let settings) = store.states[host.id] else {
            Issue.record("expected .failed, got \(String(describing: store.states[host.id]))")
            return
        }
        // Not flipped: the Host still holds done=true, so the UI must too.
        #expect(settings.notify.done)
        let file = try NotificationRegistrationFile.decode(
            await transport.notificationRegistration)
        let entry = try #require(
            file.devices.first { $0["token"]?.stringValue == token.hex })
        #expect(entry["notify"]?["done"] == .bool(true))
    }

    @Test func doneToggleOnAnUnregisteredHostIsIgnored() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport)
        await store.refresh()

        await store.setDoneEnabled(false, for: host)

        #expect(await transport.replacedNotificationRegistrations.isEmpty)
        #expect(
            store.states[host.id]
                == .idle(
                    .init(isRegistered: false, notify: NotificationTriggerPreferences())))
    }

    // MARK: Confirmed triggers for the in-app banner (#77)

    @Test func confirmedTriggersOfARegisteredHostAreItsFlags() async throws {
        let transport = ScriptedTransport()
        await transport.setNotificationRegistration(
            Data(
                (#"{"v":1,"devices":[{"token":"\#(token.hex)","key":"kk","env":"sandbox","#
                    + #""notify":{"blocked":true,"done":false}}]}"#).utf8))
        let store = makeStore(transport: transport)
        await store.refresh()

        #expect(
            store.confirmedTriggers(for: host.id)
                == NotificationTriggerPreferences(blocked: true, done: false))
    }

    @Test func confirmedTriggersOfAnUnregisteredHostAreNil() async throws {
        let store = makeStore(transport: ScriptedTransport())
        await store.refresh()

        #expect(store.confirmedTriggers(for: host.id) == nil)
    }

    /// Fail closed: before any refresh, and while the Host is unreachable,
    /// there is no confirmed truth to banner from.
    @Test func confirmedTriggersAreNilWhileTheHostsTruthIsUnknown() async throws {
        let provider = ScriptedTransportProvider(transports: [:])
        let store = makeStore(provider: provider, deviceToken: token)

        #expect(store.confirmedTriggers(for: host.id) == nil)

        await store.refresh()

        #expect(store.confirmedTriggers(for: host.id) == nil)
    }

    /// A failed write leaves the last confirmed truth in place, and that
    /// truth keeps gating banners.
    @Test func confirmedTriggersSurviveAFailedWrite() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport)
        await store.refresh()
        await store.setNotificationsEnabled(true, for: host)
        await transport.setNotificationRegistrationWriteFailure(
            .writeFailed(detail: "disk full"))

        await store.setDoneEnabled(false, for: host)

        #expect(
            store.confirmedTriggers(for: host.id)
                == NotificationTriggerPreferences(blocked: true, done: true))
    }

    // MARK: Re-registration after a token or environment change

    /// A store sharing one suite's `UserDefaults`, so a second store — the
    /// same install on its next launch, with a different APNs token or a
    /// different environment — reads what the first one recorded.
    private func makeStore(
        transport: any Transport, deviceToken: APNSDeviceToken, defaults: UserDefaults
    ) -> NotificationPreferencesStore {
        let store = NotificationPreferencesStore(
            transports: ScriptedTransportProvider(transports: [host.id: transport]),
            deviceToken: { deviceToken },
            defaults: defaults,
            ceremony: NotificationRegistrationCeremony(keys: keys))
        store.setHosts([host])
        return store
    }

    private func deviceEntries(_ transport: ScriptedTransport) async throws -> [[String: Any]] {
        let data = try #require(await transport.notificationRegistration)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(object["devices"] as? [[String: Any]])
    }

    /// The bug from the mini: the Host kept the `env: "sandbox"` entry a
    /// development build wrote, so every push from the TestFlight install
    /// went to the wrong APNs host and was dropped.
    @Test func aChangedAPNSEnvironmentRewritesThisDevicesEntry() async throws {
        let suiteName = "kelpie-notification-registration-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let transport = ScriptedTransport()
        let sandbox = APNSDeviceToken(hex: token.hex, environment: .sandbox)
        let development = makeStore(
            transport: transport, deviceToken: sandbox, defaults: defaults)
        await development.refresh()
        await development.setNotificationsEnabled(true, for: host)
        // The same install, now from TestFlight: production APNs.
        let testFlight = makeStore(
            transport: transport,
            deviceToken: APNSDeviceToken(hex: token.hex, environment: .production),
            defaults: defaults)
        await testFlight.refresh()

        await testFlight.reregisterChangedDevices()

        let devices = try await deviceEntries(transport)
        // The plugin keys a device by its token, so the environment change
        // updates that one entry rather than adding a second.
        #expect(devices.count == 1)
        #expect(devices.first?["env"] as? String == "production")
        #expect(devices.first?["token"] as? String == token.hex)
        // The Host's notify flags are re-sent, never invented.
        #expect(devices.first?["notify"] as? [String: Bool] == ["blocked": true, "done": true])
        #expect(
            testFlight.states[host.id]
                == .idle(
                    .init(
                        isRegistered: true, notify: NotificationTriggerPreferences(),
                        environment: .production)))
    }

    @Test func aChangedDeviceTokenRegistersTheNewToken() async throws {
        let suiteName = "kelpie-notification-registration-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let transport = ScriptedTransport()
        let first = makeStore(transport: transport, deviceToken: token, defaults: defaults)
        await first.refresh()
        await first.setNotificationsEnabled(true, for: host)
        // APNs hands out a different token on a later launch.
        let rotated = APNSDeviceToken(hex: "99887766", environment: token.environment)
        let next = makeStore(transport: transport, deviceToken: rotated, defaults: defaults)
        await next.refresh()

        await next.reregisterChangedDevices()

        let devices = try await deviceEntries(transport)
        #expect(devices.contains { $0["token"] as? String == rotated.hex })
    }

    @Test func anUnchangedTokenAndEnvironmentWriteNothing() async throws {
        let suiteName = "kelpie-notification-registration-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, deviceToken: token, defaults: defaults)
        await store.refresh()
        await store.setNotificationsEnabled(true, for: host)
        let writes = await transport.replacedNotificationRegistrations.count

        await store.reregisterChangedDevices()

        #expect(await transport.replacedNotificationRegistrations.count == writes)
    }

    /// A Host the user never enabled notifications for has no entry to keep
    /// current; the sweep must not create one behind their back.
    @Test func anUnregisteredHostIsNotRegisteredBySweep() async throws {
        let suiteName = "kelpie-notification-registration-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, deviceToken: token, defaults: defaults)
        await store.refresh()

        await store.reregisterChangedDevices()

        #expect(await transport.replacedNotificationRegistrations.isEmpty)
        #expect(RegisteredDeviceTokenLog(defaults: defaults).lastRegistered(for: host.id) == nil)
    }

    /// Turning notifications off drops the record, so turning them back on
    /// writes the pair afresh rather than trusting a stale one.
    @Test func disablingForgetsTheRecordedPair() async throws {
        let suiteName = "kelpie-notification-registration-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, deviceToken: token, defaults: defaults)
        await store.refresh()
        await store.setNotificationsEnabled(true, for: host)
        #expect(RegisteredDeviceTokenLog(defaults: defaults).lastRegistered(for: host.id) == token)

        await store.setNotificationsEnabled(false, for: host)

        #expect(RegisteredDeviceTokenLog(defaults: defaults).lastRegistered(for: host.id) == nil)
    }

    /// A reinstall (or a restore onto a new device) without pairing sync:
    /// `UserDefaults` is gone, so nothing was recorded, and APNs issued a
    /// token the Host's file does not carry, so the Host reads as
    /// unregistered. Only the Notification Key survives in the Keychain —
    /// and without it the install stayed silent forever while a dead entry
    /// drew `400 BadDeviceToken`s that prune nothing (#9).
    @Test func aReinstallReRegistersFromItsSurvivingNotificationKey() async throws {
        let suiteName = "kelpie-notification-registration-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let transport = ScriptedTransport()
        let before = makeStore(transport: transport, deviceToken: token, defaults: defaults)
        await before.refresh()
        await before.setNotificationsEnabled(true, for: host)
        // The reinstall: a fresh defaults domain, a new APNs token, the
        // Keychain record still there.
        let reinstallSuite = "kelpie-notification-registration-\(UUID().uuidString)"
        let reinstallDefaults = try #require(UserDefaults(suiteName: reinstallSuite))
        defer { reinstallDefaults.removePersistentDomain(forName: reinstallSuite) }
        let reinstalled = APNSDeviceToken(hex: "44556677", environment: .production)
        let store = makeStore(
            transport: transport, deviceToken: reinstalled, defaults: reinstallDefaults)
        await store.refresh()
        #expect(store.confirmedTriggers(for: host.id) == nil, "the new token has no entry yet")

        await store.reregisterChangedDevices()

        let devices = try await deviceEntries(transport)
        #expect(devices.contains { $0["token"] as? String == reinstalled.hex })
        #expect(store.confirmedTriggers(for: host.id) == NotificationTriggerPreferences())
        #expect(
            RegisteredDeviceTokenLog(defaults: reinstallDefaults)
                .lastRegistered(for: host.id) == reinstalled)
    }

    /// The record now carries when it was written, so Settings can say how
    /// old a registration is (#6). Records from before it did still read.
    @Test func theRegistrationDateIsRecordedAndLegacyRecordsStillRead() async throws {
        let suiteName = "kelpie-notification-registration-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = makeStore(
            transport: ScriptedTransport(), deviceToken: token, defaults: defaults)
        await store.refresh()

        await store.setNotificationsEnabled(true, for: host)

        let recorded = try #require(store.lastRegistrationDate(for: host.id))
        #expect(abs(recorded.timeIntervalSinceNow) < 60)
        // The two-part shape an earlier build wrote.
        defaults.set(
            [host.id.uuidString: "sandbox:\(token.hex)"],
            forKey: RegisteredDeviceTokenLog.defaultsKey)
        let log = RegisteredDeviceTokenLog(defaults: defaults)
        #expect(log.lastRegistered(for: host.id) == token)
        #expect(log.lastRegistration(for: host.id)?.date == nil)
    }

    // MARK: Foregrounding

    /// Nothing else re-reads the file while the app is away, so the plugin
    /// pruning this device's token (an APNs `410`) or a sibling device
    /// changing a flag went unnoticed for hours (#7).
    @Test func foregroundingRereadsEveryHostsFile() async throws {
        let center = NotificationCenter()
        let transport = ScriptedTransport()
        let store = NotificationPreferencesStore(
            transports: ScriptedTransportProvider(transports: [host.id: transport]),
            deviceToken: { self.token },
            ceremony: NotificationRegistrationCeremony(keys: keys),
            foregroundCenter: center)
        store.setHosts([host])
        await store.refresh()
        let readsBefore = await transport.notificationRegistrationReads

        center.post(name: NotificationPreferencesStore.foregroundNotification, object: nil)

        try await waitUntil("foregrounding should re-read the Host's file") {
            await transport.notificationRegistrationReads > readsBefore
        }
        // Keeps the store — and so its observer — alive to the end.
        #expect(store.hosts.count == 1)
    }

    // MARK: Removal

    /// A deleted Host keeps this device's entry — and this device keeps the
    /// Notification Key that entry was minted with — unless both go.
    @Test func removingAHostWithdrawsItsEntryAndDropsItsKey() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport)
        await store.refresh()
        await store.setNotificationsEnabled(true, for: host)
        #expect(try keys.record(forHost: host.id) != nil)

        await store.forget(host.id)

        let file = try NotificationRegistrationFile.decode(
            await transport.notificationRegistration)
        #expect(!file.containsDevice(token: token.hex))
        #expect(try keys.record(forHost: host.id) == nil)
        #expect(store.states[host.id] == nil)
    }

    /// Best effort, one attempt: an unreachable Host keeps its entry (the
    /// plugin prunes it on the first `410`), but the local key goes anyway —
    /// a notification this device cannot decrypt is the worse outcome.
    @Test func removingAnUnreachableHostStillDropsTheLocalKey() async throws {
        let transport = ScriptedTransport()
        let provider = ScriptedTransportProvider(transports: [host.id: transport])
        let store = makeStore(provider: provider, deviceToken: token)
        await store.refresh()
        await store.setNotificationsEnabled(true, for: host)
        await provider.setTransport(nil, for: host.id)

        await store.forget(host.id)

        #expect(try keys.record(forHost: host.id) == nil)
        #expect(store.states[host.id] == nil)
    }

    /// The withdrawal races `ConsoleStore.setHosts`, which drops the Host's
    /// projection: the first attempt can find the transport already gone,
    /// and one attempt would leave the Host holding an armed entry with a
    /// still-valid token — a `400` for ever, never the `410` that prunes.
    @Test func aWithdrawalRetriesPastTheProjectionBeingTornDown() async throws {
        let transport = ScriptedTransport()
        let provider = FlakyTransportProvider(transport: transport, hostID: host.id)
        let store = makeStore(provider: provider, deviceToken: token)
        await store.refresh()
        await store.setNotificationsEnabled(true, for: host)
        let callsBefore = await provider.callCount
        await provider.failNext(1)

        await store.forget(host.id, named: host.displayName)

        let file = try NotificationRegistrationFile.decode(
            await transport.notificationRegistration)
        #expect(!file.containsDevice(token: token.hex))
        #expect(store.registrationNotes[host.id] == nil)
        #expect(
            await provider.callCount == callsBefore + 2, "the first attempt must be retried")
    }

    /// When every attempt fails the entry is abandoned — but not silently,
    /// and the note names the Host it was still armed on, which is only
    /// possible because the name is captured before the catalog moves.
    @Test func aWithdrawalThatNeverLandsLeavesANamedNote() async throws {
        let provider = ScriptedTransportProvider(transports: [host.id: ScriptedTransport()])
        let store = makeStore(provider: provider, deviceToken: token)
        await store.refresh()
        await store.setNotificationsEnabled(true, for: host)
        await provider.setTransport(nil, for: host.id)

        await store.forget(host.id, named: host.displayName)

        let note = try #require(store.registrationNotes[host.id])
        #expect(note.contains(host.displayName))
        #expect(try keys.record(forHost: host.id) == nil, "the local key goes either way")
        // The Host is gone from the catalog; the note must outlive its row.
        store.setHosts([])
        #expect(store.registrationNotes[host.id] != nil)
    }

    /// The catalog is the backstop trigger: a Host that leaves it is torn
    /// down even if nothing called the deletion hook.
    @Test func aHostLeavingTheCatalogIsForgotten() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport)
        await store.refresh()
        await store.setNotificationsEnabled(true, for: host)

        store.setHosts([])

        try await waitUntil("the Host's key should be dropped") {
            ((try? keys.record(forHost: host.id)) ?? nil) == nil
        }
    }

    // MARK: Side-path failures

    /// `HostLiveActivityCoordinator` and `PairingSync` used to swallow their
    /// registration failures into a once-per-process log line, so a second
    /// device that never armed looked exactly like one that did (#8).
    @Test func aSidePathFailureBecomesAVisiblePerHostNote() async throws {
        let store = makeStore(transport: ScriptedTransport())

        store.recordRegistrationFailure(
            TransportError.sshUnreachable(detail: "no route"),
            source: .liveActivity, for: host.id)

        let note = try #require(store.registrationNotes[host.id])
        #expect(note.contains("Live Activity"))
        #expect(note.contains("not connected"))

        store.clearRegistrationNote(for: host.id)
        #expect(store.registrationNotes[host.id] == nil)
    }

    /// A successful write is the other way a note goes: the path it came
    /// from just proved itself.
    @Test func aSuccessfulWriteClearsTheNote() async throws {
        let store = makeStore(transport: ScriptedTransport())
        await store.refresh()
        store.recordRegistrationFailure(
            TransportError.timedOut, source: .pairingSync, for: host.id)

        await store.setNotificationsEnabled(true, for: host)

        #expect(store.registrationNotes[host.id] == nil)
    }

    /// Polls until `condition` holds, yielding so the store's tasks progress.
    private func waitUntil(
        _ comment: Comment, timeout: Duration = .seconds(2),
        condition: () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await condition(), comment)
    }
}
