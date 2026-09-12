import Foundation
import Observation
import os

/// The Host catalog, as pairing sync needs it. A protocol so the reconcile
/// can be driven against an in-memory catalog in tests; `HostStore` is the
/// only production conformer.
@MainActor
protocol PairingSyncHostCatalog: AnyObject {
    var hosts: [Host] { get }
    func add(_ host: Host, password: String?) throws
}

/// The root screen's Host selection, as pairing sync needs it: a fresh device
/// that adopts its first Host must land on it rather than on an empty screen.
///
/// Deliberately the persisted id and not a `PrimaryHostStore`: the live store
/// belongs to the root screen and caches its selection, so an instance of our
/// own would still be holding the value it read at launch and could overwrite
/// a Host the user picked in the meantime.
@MainActor
protocol PairingSyncPrimarySelecting: AnyObject {
    func persistedPrimaryHostID() -> String?
    func setPrimaryHostID(_ id: String)
}

extension HostStore: PairingSyncHostCatalog {}

/// Reads and writes the same defaults key `PrimaryHostStore` persists, fresh
/// on every call.
@MainActor
final class UserDefaultsPrimaryHostSelection: PairingSyncPrimarySelecting {
    /// Mirrors `PrimaryHostStore`'s own (private) key.
    static let defaultsKey = "kelpie.primary-host"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func persistedPrimaryHostID() -> String? {
        defaults.string(forKey: Self.defaultsKey)
    }

    func setPrimaryHostID(_ id: String) {
        defaults.set(id, forKey: Self.defaultsKey)
    }
}

/// The "Sync pairings with iCloud" setting (default on). Separate from
/// `PairingSync` itself so the Settings screen can bind to it through the
/// environment without owning the reconcile.
@MainActor
@Observable
final class PairingSyncSettings {
    static let defaultsKey = "kelpie.pairing-sync"

    private(set) var isEnabled: Bool
    @ObservationIgnored private nonisolated(unsafe) let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Absent means "never chosen", which is on: the whole point is that a
        // second device is ready without being told to be.
        isEnabled = defaults.object(forKey: Self.defaultsKey) as? Bool ?? true
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.defaultsKey)
    }
}

/// Carries pairings between the user's devices through iCloud Keychain
/// (ADR 0018), so a Host paired on the iPad is ready on the iPhone.
///
/// Two synchronizable Keychain item kinds do the work: one shared Device Key,
/// and one record per Host holding the Host itself, its host-key
/// fingerprints, its Notification Key and any sibling public keys still
/// waiting for a line in that Host's `authorized_keys`. Everything here is
/// best-effort and silent — iCloud Keychain switched off, or a Keychain that
/// refuses the entitlement, must never block the app.
@MainActor
final class PairingSync {
    /// Keychain service holding one item per paired Host, account = Host id.
    static let recordService = "TME.Kelpie.pairing"
    /// The synced twin of `DeviceKeyStore`'s slot: same service and account,
    /// but a synchronizable item, which the Keychain keeps distinct from the
    /// device-only one.
    static let deviceKeyService = "dev.bybee.heeler.ssh"
    static let deviceKeyAccount = "device-ed25519-private-key"
    /// Comment on a sibling's `authorized_keys` line, matching what the
    /// pairing ceremony submits.
    static let deviceKeyComment = "kelpie"

    private static let publishedKey = "kelpie.pairing-sync.published"
    private static let pendingRegistrationKey = "kelpie.pairing-sync.pending-registration"

    private let records: any SyncedSecretStore
    private let deviceKeySlot: any SyncedSecretStore
    private let hosts: any PairingSyncHostCatalog
    private let primaryHost: any PairingSyncPrimarySelecting
    private let knownHosts: any KnownHostsStore
    private let notificationKeys: NotificationKeyStore
    private let deviceKeys: DeviceKeyStore
    private let settings: PairingSyncSettings
    private let defaults: UserDefaults
    private let now: @Sendable () -> Date

    /// The live per-Host connections sibling enrolment and first-connect
    /// registration ride. Absent in tests that only exercise the reconcile.
    private let transports: (any NotificationTransportProvider)?
    private let deviceToken: @MainActor () -> APNSDeviceToken?
    private let relayBaseURL: @MainActor () -> URL?
    private let ceremony: NotificationRegistrationCeremony

    private static let log = Logger(subsystem: "dev.bybee.heeler", category: "pairing-sync")
    /// One line per failure kind, not one per activation.
    private var loggedFailures: Set<String> = []

    init(
        records: any SyncedSecretStore = KeychainSecretStore(
            service: PairingSync.recordService, synchronizable: true),
        deviceKeySlot: any SyncedSecretStore = KeychainSecretStore(
            service: PairingSync.deviceKeyService, synchronizable: true),
        hosts: any PairingSyncHostCatalog,
        primaryHost: any PairingSyncPrimarySelecting = UserDefaultsPrimaryHostSelection(),
        knownHosts: any KnownHostsStore = UserDefaultsKnownHostsStore.shared,
        notificationKeys: NotificationKeyStore = NotificationKeyStore(),
        deviceKeys: DeviceKeyStore = DeviceKeyStore(),
        settings: PairingSyncSettings = PairingSyncSettings(),
        defaults: UserDefaults = .standard,
        transports: (any NotificationTransportProvider)? = nil,
        deviceToken: @escaping @MainActor () -> APNSDeviceToken? = { nil },
        relayBaseURL: @escaping @MainActor () -> URL? = { nil },
        ceremony: NotificationRegistrationCeremony = NotificationRegistrationCeremony(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.records = records
        self.deviceKeySlot = deviceKeySlot
        self.hosts = hosts
        self.primaryHost = primaryHost
        self.knownHosts = knownHosts
        self.notificationKeys = notificationKeys
        self.deviceKeys = deviceKeys
        self.settings = settings
        self.defaults = defaults
        self.transports = transports
        self.deviceToken = deviceToken
        self.relayBaseURL = relayBaseURL
        self.ceremony = ceremony
        self.now = now
    }

    // MARK: Reconcile

    /// Adopts what the other devices published, then publishes what this one
    /// knows. Runs at launch and on every foreground; the digest comparison
    /// keeps a no-change activation from rewriting anything.
    func reconcile() async {
        guard settings.isEnabled else {
            withdraw()
            return
        }
        let synced = loadRecords()
        let deviceKey = reconcileDeviceKey()
        await adopt(synced)
        await publish(synced, deviceKey: deviceKey)
    }

    /// Drops a deleted Host's synced record, so the next reconcile does not
    /// adopt the Host straight back. The synced Device Key is never deleted
    /// from here: the siblings still need it.
    func hostWasDeleted(_ id: Host.ID) {
        try? records.removeSecret(account: id.uuidString)
        var published = publishedRecords
        published[id.uuidString] = nil
        publishedRecords = published
        pendingRegistrationHostIDs.remove(id.uuidString)
    }

    /// Post-connect work for Hosts whose connection just came up: enrol the
    /// sibling devices this Host still owes an `authorized_keys` line, and
    /// register this device for the adopted Host's notifications once.
    func hostsDidConnect(_ ids: [Host.ID]) async {
        guard settings.isEnabled else { return }
        for id in ids {
            await enrolPendingKeys(for: id)
            await registerIfNeeded(for: id)
        }
    }

    // MARK: Device key

    /// What this device's SSH identity is, after the shared slot and the
    /// local one have been reconciled.
    private struct DeviceKeyState {
        /// This device's `authorized_keys` line, absent only when it has no
        /// key at all (nothing paired anywhere yet).
        let publicKeyLine: String?
        /// Whether this is the key the siblings share. A shared key is
        /// already in every paired Host's `authorized_keys` — those Hosts
        /// were paired with it — so it never needs enrolling.
        let isShared: Bool

        static let none = DeviceKeyState(publicKeyLine: nil, isShared: false)
    }

    /// Reconciles the shared Device Key: publishes the local one into the
    /// empty synced slot, adopts the synced one onto a fresh device, and
    /// otherwise leaves a device that already minted its own key alone.
    private func reconcileDeviceKey() -> DeviceKeyState {
        let local: DeviceKey?
        do {
            local = try deviceKeys.existingKey()
        } catch {
            // A corrupt local key is the recovery flow's problem, not ours:
            // adopting over it would silently change this device's identity.
            logOnce("device-key-unreadable", error)
            return .none
        }
        let synced = try? deviceKeySlot.read(account: Self.deviceKeyAccount)
        switch (local, synced) {
        case (let local?, nil):
            do {
                try deviceKeySlot.write(
                    local.privateKey.rawRepresentation, account: Self.deviceKeyAccount)
            } catch {
                logOnce("device-key-publish", error)
            }
            return DeviceKeyState(publicKeyLine: line(for: local), isShared: true)
        case (let local?, let synced?):
            let isShared = local.privateKey.rawRepresentation == synced
            // Two devices minted their own key before either synced. The
            // local one stays authoritative here — replacing it would revoke
            // this device from every Host it is already enrolled on — so the
            // sibling that holds the Host enrols this key instead.
            return DeviceKeyState(publicKeyLine: line(for: local), isShared: isShared)
        case (nil, let synced?):
            do {
                let adopted = try deviceKeys.adopt(rawRepresentation: synced)
                return DeviceKeyState(publicKeyLine: line(for: adopted), isShared: true)
            } catch {
                logOnce("device-key-adopt", error)
                return .none
            }
        case (nil, nil):
            // Nothing paired anywhere yet; the first pairing mints the key
            // and the next reconcile publishes it.
            return .none
        }
    }

    private func line(for key: DeviceKey) -> String {
        key.authorizedKeysLine(comment: Self.deviceKeyComment)
    }

    // MARK: Adopt

    private func adopt(_ synced: [UUID: PairingSyncRecord]) async {
        let known = Set(hosts.hosts.map(\.id))
        var firstAdopted: Host.ID?
        for record in synced.values.sorted(by: { $0.updatedAt < $1.updatedAt })
        where !known.contains(record.host.id) {
            do {
                try hosts.add(record.host, password: nil)
            } catch {
                logOnce("host-adopt", error)
                continue
            }
            for entry in record.fingerprints.compactMap(PairingSyncFingerprint.init(encoded:)) {
                await knownHosts.setFingerprint(
                    entry.fingerprint, host: entry.address, port: entry.port)
            }
            if let key = record.notificationKey {
                do {
                    try notificationKeys.save(
                        NotificationKeyRecord(
                            hostID: record.host.id,
                            hostName: record.host.displayName,
                            key: key))
                } catch {
                    logOnce("notification-key-adopt", error)
                }
            }
            // This device has no entry in the Host's registration file yet —
            // the Notification Key is shared, the APNs token is not.
            pendingRegistrationHostIDs.insert(record.host.id.uuidString)
            firstAdopted = firstAdopted ?? record.host.id
        }
        // Read the persisted selection now rather than trusting a cached
        // one: the user may have switched Host since this session started.
        // Only an absent selection, or one naming a Host the catalog no
        // longer holds, is ours to fill.
        if let firstAdopted {
            let selected = primaryHost.persistedPrimaryHostID()
            let catalog = Set(hosts.hosts.map(\.id.uuidString))
            if selected == nil || !catalog.contains(selected ?? "") {
                primaryHost.setPrimaryHostID(firstAdopted.uuidString)
            }
        }
    }

    // MARK: Publish

    private func publish(_ synced: [UUID: PairingSyncRecord], deviceKey: DeviceKeyState) async {
        var published = publishedRecords
        for host in hosts.hosts {
            let existing = synced[host.id]
            var fingerprints = Set(existing?.fingerprints ?? [])
            for entry in await localFingerprints(for: host) {
                fingerprints.insert(entry.encoded)
            }
            var pending = existing?.pendingPublicKeys ?? []
            var authorized = existing?.authorizedPublicKeys ?? []
            if let line = deviceKey.publicKeyLine {
                let material = PairingSyncRecord.keyMaterial(line)
                if deviceKey.isShared {
                    // This Host was paired with the shared key, so the line
                    // is already there; recording it stops a sibling from
                    // proposing it again.
                    authorized = PairingSyncRecord.merging(authorized, with: [line])
                    pending.removeAll { PairingSyncRecord.keyMaterial($0) == material }
                } else if !PairingSyncRecord.contains(authorized, keyMaterial: material),
                    !PairingSyncRecord.contains(pending, keyMaterial: material)
                {
                    // Proposed once. Once a sibling enrols it, the line moves
                    // to `authorizedPublicKeys` and this never fires again.
                    pending = PairingSyncRecord.merging(pending, with: [line])
                }
            }
            let key =
                (try? notificationKeys.record(forHost: host.id))?.key
                ?? existing?.notificationKey
            let mine = PairingSyncRecord(
                host: host,
                fingerprints: fingerprints.sorted(),
                notificationKey: key,
                updatedAt: now(),
                pendingPublicKeys: pending,
                authorizedPublicKeys: authorized)

            if let existing {
                guard mine.contentDigest != existing.contentDigest else { continue }
                // Last writer wins by `updatedAt`, and a sibling that edited
                // the Host after our last publish keeps its version: we only
                // republish when we are adding something of our own.
                var yielding = mine
                yielding.host = existing.host
                if yielding.contentDigest == existing.contentDigest,
                    existing.updatedAt > (published[host.id.uuidString] ?? .distantPast)
                {
                    continue
                }
            }
            do {
                try records.write(try mine.encoded(), account: host.id.uuidString)
                published[host.id.uuidString] = mine.updatedAt
            } catch {
                logOnce("record-publish", error)
            }
        }
        publishedRecords = published
    }

    /// This Host's known-hosts entries: its own endpoint plus, when it is
    /// reached through one, the Jump Host's — a sibling that adopted the Host
    /// without them would face a first-connect confirmation it cannot answer.
    private func localFingerprints(for host: Host) async -> [PairingSyncFingerprint] {
        let direct = await knownHosts.fingerprints(host: host.address, port: host.port)
        var entries = direct.map {
            PairingSyncFingerprint(address: host.address, port: host.port, fingerprint: $0)
        }
        guard host.usesJumpHost else { return entries }
        let jump = await knownHosts.fingerprints(host: host.jumpAddress, port: host.jumpPort)
        entries += jump.map {
            PairingSyncFingerprint(
                address: host.jumpAddress, port: host.jumpPort, fingerprint: $0)
        }
        return entries
    }

    /// Removes every record this device wrote. The synced Device Key stays:
    /// deleting it would strand siblings that adopted it, and the app has no
    /// business revoking an SSH identity behind the user's back.
    private func withdraw() {
        let published = publishedRecords
        guard !published.isEmpty else { return }
        for account in published.keys {
            do {
                try records.removeSecret(account: account)
            } catch {
                logOnce("record-withdraw", error)
            }
        }
        publishedRecords = [:]
    }

    // MARK: Post-connect work

    private func enrolPendingKeys(for id: Host.ID) async {
        guard let transports, let record = syncedRecord(id), !record.pendingPublicKeys.isEmpty
        else { return }
        let lines = record.pendingPublicKeys
        do {
            try await transports.withNotificationTransport(for: id) { transport in
                for line in lines {
                    try await transport.appendAuthorizedKeyLine(line)
                }
            }
        } catch {
            logOnce("sibling-enrolment", error)
            return
        }
        var updated = record
        updated.authorizedPublicKeys = PairingSyncRecord.merging(
            record.authorizedPublicKeys, with: lines)
        updated.pendingPublicKeys = []
        updated.updatedAt = now()
        do {
            try records.write(try updated.encoded(), account: id.uuidString)
            var published = publishedRecords
            published[id.uuidString] = updated.updatedAt
            publishedRecords = published
        } catch {
            logOnce("record-publish", error)
        }
    }

    private func registerIfNeeded(for id: Host.ID) async {
        guard pendingRegistrationHostIDs.contains(id.uuidString),
            let transports,
            let token = deviceToken(),
            let host = hosts.hosts.first(where: { $0.id == id })
        else { return }
        let hostName = host.displayName
        let relayURL = relayBaseURL()
        let ceremony = self.ceremony
        do {
            _ = try await transports.withNotificationTransport(for: id) { transport in
                try await ceremony.register(
                    hostID: id,
                    hostName: hostName,
                    deviceToken: token,
                    relayBaseURL: relayURL,
                    over: transport)
            }
        } catch {
            logOnce("adopted-host-registration", error)
            return
        }
        pendingRegistrationHostIDs.remove(id.uuidString)
    }

    // MARK: Synced items

    private func loadRecords() -> [UUID: PairingSyncRecord] {
        let stored: [String: Data]
        do {
            stored = try records.readAll()
        } catch {
            logOnce("record-read", error)
            return [:]
        }
        var decoded: [UUID: PairingSyncRecord] = [:]
        for (account, data) in stored {
            guard let id = UUID(uuidString: account),
                let record = PairingSyncRecord.decode(data),
                record.host.id == id
            else { continue }
            decoded[id] = record
        }
        return decoded
    }

    private func syncedRecord(_ id: Host.ID) -> PairingSyncRecord? {
        guard let data = try? records.read(account: id.uuidString) else { return nil }
        return PairingSyncRecord.decode(data)
    }

    // MARK: Bookkeeping

    /// Host id → the `updatedAt` of the record this device last wrote. Also
    /// the list of records to withdraw when the user turns sync off.
    private var publishedRecords: [String: Date] {
        get {
            (defaults.dictionary(forKey: Self.publishedKey) as? [String: Date]) ?? [:]
        }
        set {
            if newValue.isEmpty {
                defaults.removeObject(forKey: Self.publishedKey)
            } else {
                defaults.set(newValue, forKey: Self.publishedKey)
            }
        }
    }

    /// Hosts adopted from a sibling that this device has not registered for
    /// notifications yet; cleared on the first successful ceremony.
    private var pendingRegistrationHostIDs: Set<String> {
        get { Set(defaults.stringArray(forKey: Self.pendingRegistrationKey) ?? []) }
        set {
            if newValue.isEmpty {
                defaults.removeObject(forKey: Self.pendingRegistrationKey)
            } else {
                defaults.set(newValue.sorted(), forKey: Self.pendingRegistrationKey)
            }
        }
    }

    /// Sync is best-effort: iCloud Keychain switched off, a missing
    /// entitlement, or an unreachable Host is a logged line and nothing else.
    /// The message never carries key material — only the failure kind and the
    /// error's own description.
    private func logOnce(_ kind: String, _ error: any Error) {
        guard loggedFailures.insert(kind).inserted else { return }
        let detail = String(describing: error)
        Self.log.info(
            "pairing sync step failed: \(kind, privacy: .public) \(detail, privacy: .public)")
    }
}
