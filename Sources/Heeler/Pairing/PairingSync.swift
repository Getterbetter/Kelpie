import CryptoKit
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
    /// Replaces the Host with the same id. Pairing sync calls this only to
    /// take a sibling's newer address, port and username onto a Host this
    /// device already holds.
    func update(_ host: Host, password: String?) throws
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
    private static let hostEditsKey = "kelpie.pairing-sync.host-edits"

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
    /// Whether a pass is running, and whether one more is owed to a call that
    /// arrived while it was. Both are `MainActor` state read and written only
    /// between awaits, so the flag can never be missed.
    private var isReconciling = false
    private var rerunRequested = false

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
    ///
    /// Never re-entrant. Saving a Host runs a reconcile, and a reconcile that
    /// adopts a Host writes the catalog — so a second call routinely arrives
    /// while the first is suspended at an `await`. Two interleaved runs would
    /// each carry their own snapshot of the edit stamps across those awaits
    /// and the slower one would write its stale copy back, reverting a stamp
    /// the other had just set. A call that finds a run in flight asks for one
    /// more pass instead, and the in-flight run re-reads the stamps at the top
    /// of every pass.
    func reconcile() async {
        guard !isReconciling else {
            rerunRequested = true
            return
        }
        isReconciling = true
        defer { isReconciling = false }
        repeat {
            rerunRequested = false
            await runReconcile()
        } while rerunRequested
    }

    private func runReconcile() async {
        guard settings.isEnabled else {
            withdraw()
            return
        }
        let synced = loadRecords()
        let deviceKey = reconcileDeviceKey()
        var stamps = refreshedHostEditStamps()
        await adopt(synced, stamps: &stamps)
        hostEditStamps = stamps
        await publish(synced, deviceKey: deviceKey, stamps: stamps)
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
        var stamps = hostEditStamps
        stamps[id.uuidString] = nil
        hostEditStamps = stamps
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

    private func adopt(
        _ synced: [UUID: PairingSyncRecord], stamps: inout [String: HostEditStamp]
    ) async {
        let known = Dictionary(
            hosts.hosts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var firstAdopted: Host.ID?
        for record in synced.values.sorted(by: { $0.updatedAt < $1.updatedAt }) {
            if let local = known[record.host.id] {
                adoptCoordinates(from: record, onto: local, stamps: &stamps)
                continue
            }
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
            // The adopted Host is exactly the record's, so its local
            // last-modified time is the record's own: nothing here is a local
            // edit, and the next reconcile must not read it as one.
            stamps[record.host.id.uuidString] = HostEditStamp(
                digest: Self.digest(of: record.host), at: record.updatedAt)
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

    /// Takes a sibling's **address, port and username** onto a Host this
    /// device already holds, when the record was written after this device's
    /// own last edit of that Host. A Host that moves — Anthony's mini moving
    /// from its LAN address to its Tailscale one — must reach both devices,
    /// and the alternative is the second device holding an address that is
    /// simply unreachable.
    ///
    /// Only those three fields: the name, the session and the jump host are
    /// each device's own business, no key or fingerprint is ever revoked by a
    /// record, and nothing is deleted here.
    private func adoptCoordinates(
        from record: PairingSyncRecord, onto local: Host, stamps: inout [String: HostEditStamp]
    ) {
        let key = local.id.uuidString
        let lastLocalEdit = stamps[key]?.at ?? .distantPast
        // Strictly newer. A record that merely ties with the local edit —
        // including the echo of this device's own publish — leaves it alone.
        guard record.updatedAt > lastLocalEdit else { return }
        var updated = local
        updated.address = record.host.address
        updated.port = record.host.port
        updated.username = record.host.username
        guard updated != local else { return }
        do {
            try hosts.update(updated, password: nil)
        } catch {
            logOnce("host-coordinates-adopt", error)
            return
        }
        stamps[key] = HostEditStamp(digest: Self.digest(of: updated), at: record.updatedAt)
    }

    // MARK: Local edits

    /// What this device last saw of one Host's synced coordinates, and when.
    /// `digest` covers the three fields adoption governs and nothing else: a
    /// rename, a session change or a jump-host edit is not a claim on the
    /// address, and stamping one would both block a newer remote address and
    /// push the stale local one back over it. `at` is when this device first
    /// saw those coordinates — the Host's local last-modified time, which is
    /// what the conflict rule weighs against a record's `updatedAt`.
    private struct HostEditStamp: Codable {
        var digest: String
        var at: Date
    }

    /// Stamps every Host whose coordinates changed since the last reconcile,
    /// and returns the stamps. A Host this device has never stamped — every
    /// Host that predates this bookkeeping — is stamped `.distantPast`, so the
    /// first synced record that disagrees with it wins.
    private func refreshedHostEditStamps() -> [String: HostEditStamp] {
        var stamps = hostEditStamps
        let live = Set(hosts.hosts.map(\.id.uuidString))
        for host in hosts.hosts {
            let key = host.id.uuidString
            let digest = Self.digest(of: host)
            guard let stamp = stamps[key] else {
                stamps[key] = HostEditStamp(digest: digest, at: .distantPast)
                continue
            }
            guard stamp.digest != digest else { continue }
            stamps[key] = HostEditStamp(digest: digest, at: now())
        }
        stamps = stamps.filter { live.contains($0.key) }
        hostEditStamps = stamps
        return stamps
    }

    /// The three fields a record governs — address, port, username — and only
    /// those. Neither an address nor a username can contain a newline, so the
    /// join is unambiguous.
    private static func digest(of host: Host) -> String {
        var hasher = SHA256()
        hasher.update(
            data: Data("\(host.address)\n\(host.port)\n\(host.username)".utf8))
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Publish

    private func publish(
        _ synced: [UUID: PairingSyncRecord], deviceKey: DeviceKeyState,
        stamps: [String: HostEditStamp]
    ) async {
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
                // Last writer wins by `updatedAt`: a record at least as new as
                // this device's own last edit of the Host keeps its version of
                // the Host payload, and only an edit made here since then
                // republishes it. When we are adding something else of our own
                // — a fingerprint, a pending key — we publish regardless.
                var yielding = mine
                yielding.host = existing.host
                if yielding.contentDigest == existing.contentDigest,
                    existing.updatedAt >= (stamps[host.id.uuidString]?.at ?? .distantPast)
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

    /// Host id → the shape this device last saw that Host in, and when. JSON
    /// rather than a plist dictionary because the value is a pair; an
    /// unreadable blob reads as "no Host was ever stamped", which only means
    /// the next synced record wins.
    private var hostEditStamps: [String: HostEditStamp] {
        get {
            guard let data = defaults.data(forKey: Self.hostEditsKey),
                let decoded = try? JSONDecoder().decode([String: HostEditStamp].self, from: data)
            else { return [:] }
            return decoded
        }
        set {
            guard !newValue.isEmpty, let data = try? JSONEncoder().encode(newValue) else {
                defaults.removeObject(forKey: Self.hostEditsKey)
                return
            }
            defaults.set(data, forKey: Self.hostEditsKey)
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
