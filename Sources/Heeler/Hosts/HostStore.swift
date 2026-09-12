import Foundation
import Observation

enum HostStoreError: Error, Equatable {
    /// `update`/`remove` addressed a Host id the catalog does not contain.
    case unknownHost
    /// Persisted bytes could not be decoded. They are deliberately left
    /// untouched so a later write cannot turn a recoverable catalog into loss.
    case catalogUnreadable
}

/// Owns the Host catalog: add/edit/remove plus persistence. Host records go
/// to UserDefaults (no secrets in them); passwords go straight to the
/// injected `SecretStore` (the Keychain in the app), keyed by Host id.
@MainActor
@Observable
final class HostStore {
    private static let defaultsKey = "hosts"
    private static let catalogVersion = 1

    /// What is written. Reading goes through `DecodedCatalog` instead, which
    /// is deliberately more forgiving than this.
    private struct PersistedCatalog: Encodable {
        let version: Int
        let hosts: [Host]
    }

    /// What is read: a version, and Hosts decoded one at a time. Unknown keys
    /// are ignored by `JSONDecoder` already, and a Host this build cannot
    /// decode leaves a hole rather than taking the catalog with it.
    private struct DecodedCatalog: Decodable {
        let version: Int
        let hosts: [DecodedHost]
    }

    private struct DecodedHost: Decodable {
        let host: Host?

        init(from decoder: any Decoder) throws {
            host = try? Host(from: decoder)
        }
    }

    private(set) var hosts: [Host]
    private(set) var catalogLoadError: HostStoreError?
    /// One line about a catalog that was read but not wholly understood — a
    /// newer build's file, or one with an entry this build could not decode.
    /// Unlike `catalogLoadError` it never blocks a write: a user who cannot
    /// add a Host has no way back, and that is worse than the notice.
    private(set) var catalogNotice: String?
    /// Called after a Host leaves the catalog. iCloud pairing sync hangs on
    /// here so a deleted Host's synced record goes too — otherwise the next
    /// reconcile would adopt the Host straight back (ADR 0018).
    @ObservationIgnored var didRemoveHost: (@MainActor (Host.ID) -> Void)?
    // UserDefaults is documented thread-safe; Sendable modulo that promise.
    @ObservationIgnored private nonisolated(unsafe) let defaults: UserDefaults?
    @ObservationIgnored private let secrets: any SecretStore

    init(
        defaults: UserDefaults = .standard,
        secrets: any SecretStore = KeychainSecretStore(service: "dev.bybee.heeler.ssh")
    ) {
        self.defaults = defaults
        self.secrets = secrets
        guard let data = defaults.data(forKey: Self.defaultsKey) else {
            hosts = []
            catalogLoadError = nil
            catalogNotice = nil
            return
        }
        let loaded = Self.loadCatalog(data)
        hosts = loaded.hosts
        catalogLoadError = loaded.error
        catalogNotice = loaded.notice
        if loaded.migratesInPlace, let encoded = try? Self.encodedCatalog(loaded.hosts) {
            defaults.set(encoded, forKey: Self.defaultsKey)
        }
    }

    private struct LoadedCatalog {
        var hosts: [Host] = []
        var error: HostStoreError?
        var notice: String?
        /// Only a whole, clean legacy catalog is rewritten in place. Anything
        /// partial is left exactly as it is on disk, so a build that can read
        /// the rest still finds it there.
        var migratesInPlace = false
    }

    /// Reads the persisted catalog as far as it can. A newer version, or an
    /// entry this build cannot decode, yields the Hosts it did read plus a
    /// notice; only bytes that are not a catalog at all are an error.
    private static func loadCatalog(_ data: Data) -> LoadedCatalog {
        let decoder = JSONDecoder()
        var loaded = LoadedCatalog()
        if let catalog = try? decoder.decode(DecodedCatalog.self, from: data) {
            loaded.hosts = catalog.hosts.compactMap(\.host)
            let dropped = catalog.hosts.count - loaded.hosts.count
            // A newer build's catalog is read, not refused: refusing it left
            // the list empty *and* blocked every add, with no way back but
            // reinstalling the newer build.
            if catalog.version > catalogVersion {
                loaded.notice = newerCatalogNotice
            }
            if dropped > 0 {
                loaded.notice = [loaded.notice, unreadableHostsNotice(dropped)]
                    .compactMap { $0 }.joined(separator: " ")
            }
            return loaded
        }
        // Version 0 was the bare Host array. Decode it leniently too, and
        // persist the versioned envelope only if nothing was lost.
        guard let legacy = try? decoder.decode([DecodedHost].self, from: data) else {
            loaded.error = .catalogUnreadable
            return loaded
        }
        loaded.hosts = legacy.compactMap(\.host)
        let dropped = legacy.count - loaded.hosts.count
        if dropped > 0 {
            loaded.notice = unreadableHostsNotice(dropped)
        } else {
            loaded.migratesInPlace = true
        }
        return loaded
    }

    private static let newerCatalogNotice =
        "This Host list was last saved by a newer version of Kelpie. "
        + "Anything that version added is not shown here, and saving a Host drops it."

    private static func unreadableHostsNotice(_ count: Int) -> String {
        count == 1
            ? "One saved Host could not be read and is not shown."
            : "\(count) saved Hosts could not be read and are not shown."
    }

    /// A process-local catalog for previews and development compositions.
    /// Mutations remain in memory, and secrets use process-local storage.
    init(volatileHosts: [Host]) {
        defaults = nil
        secrets = VolatileSecretStore()
        hosts = volatileHosts
        catalogLoadError = nil
    }

    /// Adds a Host, storing `password` in the secret store when given.
    func add(_ host: Host, password: String? = nil) throws {
        try ensureCatalogIsWritable()
        try applyPassword(password, to: host)
        hosts.append(host)
        try persist()
    }

    /// Replaces the stored Host with the same id. `password` nil leaves any
    /// stored password untouched, so editing unrelated fields never requires
    /// re-entering it.
    func update(_ host: Host, password: String? = nil) throws {
        try ensureCatalogIsWritable()
        guard let index = hosts.firstIndex(where: { $0.id == host.id }) else {
            throw HostStoreError.unknownHost
        }
        try applyPassword(password, to: host)
        hosts[index] = host
        try persist()
    }

    /// Removes the Host and its stored password.
    func remove(_ id: Host.ID) throws {
        try ensureCatalogIsWritable()
        guard let index = hosts.firstIndex(where: { $0.id == id }) else {
            throw HostStoreError.unknownHost
        }
        try secrets.removeSecret(account: Self.passwordAccount(for: id))
        hosts.remove(at: index)
        try persist()
        didRemoveHost?(id)
    }

    /// The stored password for a Host, or nil when none was saved.
    func password(for host: Host) throws -> String? {
        try secrets.read(account: Self.passwordAccount(for: host.id))
            .map { String(decoding: $0, as: UTF8.self) }
    }

    /// Keychain account for a Host's password; shared with
    /// `HostCredentialsProvider` so lookup and storage cannot drift.
    nonisolated static func passwordAccount(for id: Host.ID) -> String {
        "host-password-\(id.uuidString)"
    }

    private func applyPassword(_ password: String?, to host: Host) throws {
        let account = Self.passwordAccount(for: host.id)
        switch host.authMethod {
        case .deviceKey:
            // Secret hygiene: a Host switched off password auth keeps no
            // stale password around.
            try secrets.removeSecret(account: account)
        case .password:
            if let password {
                try secrets.write(Data(password.utf8), account: account)
            }
        }
    }

    private func ensureCatalogIsWritable() throws {
        if catalogLoadError != nil {
            throw HostStoreError.catalogUnreadable
        }
    }

    private func persist() throws {
        defaults?.set(try Self.encodedCatalog(hosts), forKey: Self.defaultsKey)
    }

    private static func encodedCatalog(_ hosts: [Host]) throws -> Data {
        try JSONEncoder().encode(PersistedCatalog(version: catalogVersion, hosts: hosts))
    }
}
