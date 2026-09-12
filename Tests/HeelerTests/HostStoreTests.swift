import Foundation
import Synchronization
import Testing

@testable import Heeler

@Suite("Host model")
struct HostTests {
    @Test func socketLocationDefaultsWhenSessionNameIsBlank() {
        var host = Host.fixture()
        host.sessionName = ""
        #expect(host.socketLocation == .defaultSession)
        host.sessionName = "   "
        #expect(host.socketLocation == .defaultSession)
    }

    @Test func socketLocationUsesTrimmedNamedSession() {
        var host = Host.fixture()
        host.sessionName = " work "
        #expect(host.socketLocation == .namedSession("work"))
    }

    /// Hosts serialized before ADR 0011 carry a `socatPath` the product
    /// no longer has (ADR 0011). It must never fail a decode — not even when it
    /// holds a value the old validation would have rejected — and the next save
    /// must drop it rather than carry a dead field forward forever.
    @Test func obsoleteSocatFieldDecodesAndIsNotWrittenBack() throws {
        let legacy = """
            {"id":"\(UUID().uuidString)","name":"Old","address":"old.example","port":22,
             "username":"dev","authMethod":"deviceKey","socatPath":"socat"}
            """

        let host = try JSONDecoder().decode(Host.self, from: Data(legacy.utf8))
        #expect(host.address == "old.example")

        let fields = try #require(
            JSONSerialization.jsonObject(with: try JSONEncoder().encode(host)) as? [String: Any])
        #expect(fields["socatPath"] == nil)
    }

    @Test func displayNameFallsBackToUserAtAddress() {
        var host = Host.fixture(name: "", address: "box.example", username: "dev")
        #expect(host.displayName == "dev@box.example")
        host.name = "Workbox"
        #expect(host.displayName == "Workbox")
    }
}

@MainActor
@Suite("Host store")
struct HostStoreTests {
    private func makeDefaults() throws -> (UserDefaults, cleanup: () -> Void) {
        let suiteName = "hm-hosts-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return (defaults, { defaults.removePersistentDomain(forName: suiteName) })
    }

    @Test func addPersistsAcrossInstances() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let secrets = InMemorySecretStore()
        let host = Host.fixture(name: "Workbox")

        try HostStore(defaults: defaults, secrets: secrets).add(host)

        let reloaded = HostStore(defaults: defaults, secrets: secrets)
        #expect(reloaded.hosts == [host])
    }

    @Test func legacyCatalogMissingNewFieldsMigratesWithDefaults() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let id = UUID()
        let legacy = """
            [{"id":"\(id.uuidString)","name":"Old","address":"old.example","port":22,
              "username":"dev","authMethod":"deviceKey"}]
            """
        defaults.set(Data(legacy.utf8), forKey: "hosts")

        let store = HostStore(defaults: defaults, secrets: InMemorySecretStore())

        let host = try #require(store.hosts.first)
        #expect(host.sessionName == "")
        // Hosts saved before jump-host support must keep connecting directly.
        #expect(!host.usesJumpHost)
        #expect(host.jumpPort == 22)
    }

    @Test func corruptCatalogCannotBeSilentlyOverwritten() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let corrupt = Data("not-json".utf8)
        defaults.set(corrupt, forKey: "hosts")
        let store = HostStore(defaults: defaults, secrets: InMemorySecretStore())

        #expect(throws: HostStoreError.catalogUnreadable) {
            try store.add(Host.fixture())
        }
        #expect(defaults.data(forKey: "hosts") == corrupt)
    }

    /// Going back to an older build (or any future version bump) used to
    /// present an empty Host list *and* refuse every add — no way out but
    /// reinstalling the newer build.
    @Test func newerCatalogVersionIsReadAndStillWritable() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let id = UUID()
        let future = """
            {"version":99,"hosts":[
              {"id":"\(id.uuidString)","name":"Studio","address":"a.example","port":22,
               "username":"anthony","authMethod":"deviceKey","somethingNew":true}],
             "aFutureField":7}
            """
        defaults.set(Data(future.utf8), forKey: "hosts")

        let store = HostStore(defaults: defaults, secrets: InMemorySecretStore())

        #expect(store.hosts.map(\.id) == [id])
        #expect(store.catalogLoadError == nil)
        #expect(store.catalogNotice != nil)
        // And the file is not rewritten just for having been read.
        #expect(
            String(decoding: try #require(defaults.data(forKey: "hosts")), as: UTF8.self)
                .contains("somethingNew"))
        try store.add(Host.fixture(name: "Added"))
        #expect(store.hosts.count == 2)
    }

    /// One Host this build cannot decode is one hole, not the whole catalog.
    @Test func oneUnreadableHostDoesNotTakeTheCatalogWithIt() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let good = UUID()
        let mixed = """
            {"version":1,"hosts":[
              {"id":"not-a-uuid","name":"Broken","address":"b.example","port":22,
               "username":"dev","authMethod":"deviceKey"},
              {"id":"\(good.uuidString)","name":"Good","address":"a.example","port":22,
               "username":"anthony","authMethod":"deviceKey"}]}
            """
        defaults.set(Data(mixed.utf8), forKey: "hosts")

        let store = HostStore(defaults: defaults, secrets: InMemorySecretStore())

        #expect(store.hosts.map(\.id) == [good])
        #expect(store.catalogLoadError == nil)
        #expect(store.catalogNotice?.contains("could not be read") == true)
        // The bytes stay as they are: a build that can read the other Host
        // must still find it there.
        #expect(
            String(decoding: try #require(defaults.data(forKey: "hosts")), as: UTF8.self)
                .contains("Broken"))
    }

    @Test func updateReplacesTheStoredHost() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let store = HostStore(defaults: defaults, secrets: InMemorySecretStore())
        var host = Host.fixture()
        try store.add(host)

        host.address = "renamed.example"
        try store.update(host)

        #expect(store.hosts == [host])
    }

    @Test func updateUnknownHostThrows() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let store = HostStore(defaults: defaults, secrets: InMemorySecretStore())

        #expect(throws: HostStoreError.unknownHost) {
            try store.update(Host.fixture())
        }
    }

    @Test func removeDeletesHostAndItsPassword() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let secrets = InMemorySecretStore()
        let store = HostStore(defaults: defaults, secrets: secrets)
        let host = Host.fixture(authMethod: .password)
        try store.add(host, password: "hunter2")

        try store.remove(host.id)

        #expect(store.hosts.isEmpty)
        #expect(try store.password(for: host) == nil)
    }

    @Test func removalRequestRequiresExplicitConfirmation() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let secrets = InMemorySecretStore()
        let store = HostStore(defaults: defaults, secrets: secrets)
        let host = Host.fixture(name: "Workbox", authMethod: .password)
        try store.add(host, password: "hunter2")
        let removal = HostRemovalStore(store: store)

        removal.requestRemoval([host.id])

        #expect(store.hosts == [host])
        #expect(try store.password(for: host) == "hunter2")
        let request = try #require(removal.pendingRequest)
        #expect(request.title == "Remove Workbox?")
        #expect(request.message.contains("Keychain"))
        #expect(request.message.contains("cannot be undone"))

        removal.cancelRemoval()
        #expect(removal.pendingRequest == nil)
        #expect(store.hosts == [host])

        removal.requestRemoval([host.id])
        removal.confirmRemoval(try #require(removal.pendingRequest))

        #expect(removal.pendingRequest == nil)
        #expect(store.hosts.isEmpty)
        #expect(try store.password(for: host) == nil)
    }

    @Test func passwordRoundTripsThroughTheSecretStore() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let store = HostStore(defaults: defaults, secrets: InMemorySecretStore())
        let host = Host.fixture(authMethod: .password)

        try store.add(host, password: "hunter2")

        #expect(try store.password(for: host) == "hunter2")
        // The catalog record itself never carries the secret.
        #expect(defaults.data(forKey: "hosts").map { String(decoding: $0, as: UTF8.self) }?
            .contains("hunter2") == false)
    }

    @Test func editKeepingPasswordFieldEmptyPreservesTheStoredPassword() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let store = HostStore(defaults: defaults, secrets: InMemorySecretStore())
        var host = Host.fixture(authMethod: .password)
        try store.add(host, password: "hunter2")

        host.port = 2222
        try store.update(host, password: nil)

        #expect(try store.password(for: host) == "hunter2")
    }

    @Test func switchingToDeviceKeyDeletesTheStoredPassword() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let store = HostStore(defaults: defaults, secrets: InMemorySecretStore())
        var host = Host.fixture(authMethod: .password)
        try store.add(host, password: "hunter2")

        host.authMethod = .deviceKey
        try store.update(host)

        #expect(try store.password(for: host) == nil)
    }

    @Test func removalFailureStaysVisibleAndKeepsTheHost() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let secrets = RemovalFailingSecretStore()
        let store = HostStore(defaults: defaults, secrets: secrets)
        let host = Host.fixture(authMethod: .password)
        try store.add(host, password: "hunter2")
        secrets.failRemovals()
        let removal = HostRemovalStore(store: store)

        removal.requestRemoval([host.id])
        removal.confirmRemoval(try #require(removal.pendingRequest))

        #expect(store.hosts == [host])
        #expect(removal.errorMessage != nil)
        removal.dismissError()
        #expect(removal.errorMessage == nil)
    }
}

@MainActor
@Suite("Host credentials")
struct HostCredentialsProviderTests {
    /// The adopted-Host state: a password Host whose password stayed on the
    /// other device. Distinct from a password that was offered and refused.
    @Test func aPasswordHostWithNoStoredPasswordNeedsEntryHere() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let secrets = InMemorySecretStore()
        let store = HostStore(defaults: defaults, secrets: secrets)
        let credentials = HostCredentialsProvider(
            deviceKeys: DeviceKeyStore(secrets: InMemorySecretStore()), secrets: secrets)
        let adopted = Host.fixture(authMethod: .password)
        try store.add(adopted)

        #expect(credentials.needsPasswordEntry(for: adopted))
        #expect(throws: HostCredentialsError.passwordNotSet) {
            _ = try credentials.credentials(for: adopted)
        }

        try store.update(adopted, password: "hunter2")
        #expect(!credentials.needsPasswordEntry(for: adopted))
        // A device-key Host never asks for one.
        #expect(!credentials.needsPasswordEntry(for: Host.fixture()))
    }

    private func makeDefaults() throws -> (UserDefaults, cleanup: () -> Void) {
        let suiteName = "hm-credentials-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return (defaults, { defaults.removePersistentDomain(forName: suiteName) })
    }
}

private final class RemovalFailingSecretStore: SecretStore {
    private let shouldFailRemoval = Mutex(false)

    func failRemovals() {
        shouldFailRemoval.withLock { $0 = true }
    }

    func read(account: String) throws -> Data? { nil }
    func readAll() throws -> [String: Data] { [:] }
    func write(_ secret: Data, account: String) throws {}

    func removeSecret(account: String) throws {
        if shouldFailRemoval.withLock({ $0 }) {
            throw KeychainError.unexpectedStatus(-1)
        }
    }
}

extension Host {
    static func fixture(
        id: UUID = UUID(),
        name: String = "",
        address: String = "host.example",
        username: String = "dev",
        authMethod: AuthMethod = .deviceKey
    ) -> Host {
        Host(id: id, name: name, address: address, username: username, authMethod: authMethod)
    }
}
