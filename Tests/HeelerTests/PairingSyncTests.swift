import CryptoKit
import Foundation
import Testing

@testable import Heeler

@Suite("Pairing sync record")
struct PairingSyncRecordTests {
    @Test func roundTripsThroughJSON() throws {
        let record = PairingSyncRecord(
            host: Host(name: "Studio", address: "a.example", username: "anthony"),
            fingerprints: [
                "v1|a.example|22|ssh-ed25519|"
                    + Data(repeating: 7, count: 32).base64EncodedString()
            ],
            notificationKey: Data(repeating: 3, count: 32),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            pendingPublicKeys: ["ssh-ed25519 AAAA kelpie"])

        let decoded = try #require(PairingSyncRecord.decode(try record.encoded()))

        #expect(decoded == record)
        #expect(decoded.contentDigest == record.contentDigest)
    }

    @Test func digestIgnoresTheTimestampOnly() throws {
        let host = Host(address: "a.example", username: "anthony")
        let first = PairingSyncRecord(host: host, updatedAt: Date(timeIntervalSince1970: 1))
        var later = first
        later.updatedAt = Date(timeIntervalSince1970: 9_999)

        #expect(first.contentDigest == later.contentDigest)

        later.pendingPublicKeys = ["ssh-ed25519 AAAA kelpie"]
        #expect(first.contentDigest != later.contentDigest)
    }

    @Test func rejectsAnUnknownSchema() throws {
        var record = PairingSyncRecord(
            host: Host(address: "a.example", username: "anthony"), updatedAt: .now)
        record.schema = PairingSyncRecord.currentSchema + 1

        #expect(PairingSyncRecord.decode(try record.encoded()) == nil)
    }

    @Test func fingerprintEntriesRoundTrip() throws {
        let entry = PairingSyncFingerprint(
            address: "a.example",
            port: 2222,
            fingerprint: HostKeyFingerprint(publicKeyBlob: Data("blob".utf8)))

        let decoded = try #require(PairingSyncFingerprint(encoded: entry.encoded))

        #expect(decoded == entry)
        #expect(PairingSyncFingerprint(encoded: "nonsense") == nil)
    }
}

// MARK: Reconcile

@MainActor
final class FakePairingSyncHostCatalog: PairingSyncHostCatalog {
    private(set) var hosts: [Host]

    init(hosts: [Host] = []) {
        self.hosts = hosts
    }

    func add(_ host: Host, password: String?) throws {
        hosts.append(host)
    }
}

/// Stands in for the persisted primary-Host id, which production reads
/// straight out of UserDefaults on every adopt.
@MainActor
final class FakePairingSyncPrimary: PairingSyncPrimarySelecting {
    var values: [String: String] = [:]

    func persistedPrimaryHostID() -> String? {
        values[UserDefaultsPrimaryHostSelection.defaultsKey]
    }

    func setPrimaryHostID(_ id: String) {
        values[UserDefaultsPrimaryHostSelection.defaultsKey] = id
    }
}

@MainActor
@Suite("Pairing sync reconcile")
struct PairingSyncReconcileTests {
    private let host = Host(name: "Studio", address: "a.example", username: "anthony")

    private struct Rig {
        let records: VolatileSecretStore
        let deviceKeySlot: VolatileSecretStore
        let catalog: FakePairingSyncHostCatalog
        let primary: FakePairingSyncPrimary
        let knownHosts: InMemoryKnownHostsStore
        let notificationKeys: NotificationKeyStore
        let deviceKeys: DeviceKeyStore
        let settings: PairingSyncSettings
        let defaults: UserDefaults
        let suiteName: String
        let sync: PairingSync
    }

    private func makeRig(hosts: [Host] = []) throws -> Rig {
        let suiteName = "kelpie-pairing-sync-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let records = VolatileSecretStore()
        let deviceKeySlot = VolatileSecretStore()
        let catalog = FakePairingSyncHostCatalog(hosts: hosts)
        let primary = FakePairingSyncPrimary()
        let knownHosts = InMemoryKnownHostsStore()
        let notificationKeys = NotificationKeyStore(secrets: VolatileSecretStore(), mirror: nil)
        let deviceKeys = DeviceKeyStore(secrets: VolatileSecretStore())
        let settings = PairingSyncSettings(defaults: defaults)
        return Rig(
            records: records,
            deviceKeySlot: deviceKeySlot,
            catalog: catalog,
            primary: primary,
            knownHosts: knownHosts,
            notificationKeys: notificationKeys,
            deviceKeys: deviceKeys,
            settings: settings,
            defaults: defaults,
            suiteName: suiteName,
            sync: PairingSync(
                records: records,
                deviceKeySlot: deviceKeySlot,
                hosts: catalog,
                primaryHost: primary,
                knownHosts: knownHosts,
                notificationKeys: notificationKeys,
                deviceKeys: deviceKeys,
                settings: settings,
                defaults: defaults))
    }

    private func seedRecord(_ record: PairingSyncRecord, into rig: Rig) throws {
        try rig.records.write(try record.encoded(), account: record.host.id.uuidString)
    }

    @Test func freshDeviceAdoptsTheHostItsKeyAndItsNotificationKey() async throws {
        let rig = try makeRig()
        defer { rig.defaults.removePersistentDomain(forName: rig.suiteName) }
        let siblingKey = Curve25519.Signing.PrivateKey()
        try rig.deviceKeySlot.write(
            siblingKey.rawRepresentation, account: PairingSync.deviceKeyAccount)
        let fingerprint = HostKeyFingerprint(publicKeyBlob: Data("blob".utf8))
        let notificationKey = Data(repeating: 5, count: 32)
        try seedRecord(
            PairingSyncRecord(
                host: host,
                fingerprints: [
                    PairingSyncFingerprint(
                        address: host.address, port: host.port, fingerprint: fingerprint
                    ).encoded
                ],
                notificationKey: notificationKey,
                updatedAt: Date(timeIntervalSince1970: 1_000)),
            into: rig)

        await rig.sync.reconcile()

        #expect(rig.catalog.hosts.map(\.id) == [host.id])
        #expect(rig.primary.persistedPrimaryHostID() == host.id.uuidString)
        let adopted = await rig.knownHosts.fingerprint(host: host.address, port: host.port)
        #expect(adopted == fingerprint)
        #expect(try rig.notificationKeys.record(forHost: host.id)?.key == notificationKey)
        #expect(
            try rig.deviceKeys.existingKey()?.openSSHPublicKey
                == DeviceKey(privateKey: siblingKey).openSSHPublicKey)
    }

    @Test func aDeviceWithItsOwnKeyAppendsItToThePendingList() async throws {
        let rig = try makeRig(hosts: [host])
        defer { rig.defaults.removePersistentDomain(forName: rig.suiteName) }
        let localKey = try rig.deviceKeys.loadOrCreate()
        try rig.deviceKeySlot.write(
            Curve25519.Signing.PrivateKey().rawRepresentation,
            account: PairingSync.deviceKeyAccount)
        try seedRecord(
            PairingSyncRecord(host: host, updatedAt: Date(timeIntervalSince1970: 1_000)), into: rig)

        await rig.sync.reconcile()

        let storedData = try #require(try rig.records.read(account: host.id.uuidString))
        let stored = try #require(PairingSyncRecord.decode(storedData))
        #expect(stored.pendingPublicKeys.count == 1)
        #expect(stored.pendingPublicKeys[0].hasPrefix(localKey.openSSHPublicKey))
        // The local key is authoritative; it is never replaced by the synced one.
        #expect(try rig.deviceKeys.existingKey()?.openSSHPublicKey == localKey.openSSHPublicKey)
    }

    @Test func publishesTheHostOnceAndThenLeavesItAlone() async throws {
        let rig = try makeRig(hosts: [host])
        defer { rig.defaults.removePersistentDomain(forName: rig.suiteName) }

        await rig.sync.reconcile()
        let firstData = try #require(try rig.records.read(account: host.id.uuidString))
        let first = try #require(PairingSyncRecord.decode(firstData))

        await rig.sync.reconcile()
        let secondData = try #require(try rig.records.read(account: host.id.uuidString))
        let second = try #require(PairingSyncRecord.decode(secondData))

        #expect(second.updatedAt == first.updatedAt)
        #expect(second.contentDigest == first.contentDigest)
    }

    @Test func aNewFingerprintRepublishesTheRecord() async throws {
        let rig = try makeRig(hosts: [host])
        defer { rig.defaults.removePersistentDomain(forName: rig.suiteName) }

        await rig.sync.reconcile()
        let beforeData = try #require(try rig.records.read(account: host.id.uuidString))
        let before = try #require(PairingSyncRecord.decode(beforeData))

        await rig.knownHosts.setFingerprint(
            HostKeyFingerprint(publicKeyBlob: Data("blob".utf8)),
            host: host.address,
            port: host.port)
        await rig.sync.reconcile()
        let afterData = try #require(try rig.records.read(account: host.id.uuidString))
        let after = try #require(PairingSyncRecord.decode(afterData))

        #expect(after.fingerprints.count == 1)
        #expect(after.contentDigest != before.contentDigest)
    }

    @Test func turningSyncOffRemovesTheRecordsThisDeviceWrote() async throws {
        let rig = try makeRig(hosts: [host])
        defer { rig.defaults.removePersistentDomain(forName: rig.suiteName) }
        _ = try rig.deviceKeys.loadOrCreate()

        await rig.sync.reconcile()
        #expect(try rig.records.read(account: host.id.uuidString) != nil)

        rig.settings.setEnabled(false)
        await rig.sync.reconcile()

        #expect(try rig.records.read(account: host.id.uuidString) == nil)
        // The shared Device Key is never withdrawn — siblings still need it.
        #expect(try rig.deviceKeySlot.read(account: PairingSync.deviceKeyAccount) != nil)
    }

    @Test func anAlreadyEnrolledLineIsNeverProposedAgain() async throws {
        let rig = try makeRig(hosts: [host])
        defer { rig.defaults.removePersistentDomain(forName: rig.suiteName) }
        let localKey = try rig.deviceKeys.loadOrCreate()
        try rig.deviceKeySlot.write(
            Curve25519.Signing.PrivateKey().rawRepresentation,
            account: PairingSync.deviceKeyAccount)
        // The sibling has already enrolled this device and moved its line.
        try seedRecord(
            PairingSyncRecord(
                host: host,
                updatedAt: Date(timeIntervalSince1970: 1_000),
                authorizedPublicKeys: [
                    localKey.authorizedKeysLine(comment: PairingSync.deviceKeyComment)
                ]),
            into: rig)

        await rig.sync.reconcile()
        let firstData = try #require(try rig.records.read(account: host.id.uuidString))
        let first = try #require(PairingSyncRecord.decode(firstData))

        await rig.sync.reconcile()
        let secondData = try #require(try rig.records.read(account: host.id.uuidString))
        let second = try #require(PairingSyncRecord.decode(secondData))

        #expect(first.pendingPublicKeys.isEmpty)
        #expect(second.pendingPublicKeys.isEmpty)
        #expect(second.updatedAt == first.updatedAt)
    }

    @Test func deletingAHostDropsItsSyncedRecord() async throws {
        let rig = try makeRig(hosts: [host])
        defer { rig.defaults.removePersistentDomain(forName: rig.suiteName) }

        await rig.sync.reconcile()
        #expect(try rig.records.read(account: host.id.uuidString) != nil)

        rig.sync.hostWasDeleted(host.id)

        #expect(try rig.records.read(account: host.id.uuidString) == nil)
    }
}
