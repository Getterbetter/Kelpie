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

    /// One persisted Host: one this build decodes, or one it cannot — a
    /// newer build's authentication method, or a field it cannot read. An
    /// entry this build cannot decode is hidden but written back exactly as it
    /// was, so saving a Host here never deletes a Host another build can read.
    private enum CatalogEntry {
        case known(Host)
        case unknown(JSONValue)

        init(decoding rawHost: JSONValue) {
            if let data = try? JSONEncoder().encode(rawHost),
                let host = try? JSONDecoder().decode(Host.self, from: data)
            {
                self = .known(host)
            } else {
                self = .unknown(rawHost)
            }
        }

        var knownHost: Host? {
            guard case .known(let host) = self else { return nil }
            return host
        }

        var knownHostID: Host.ID? { knownHost?.id }
    }

    /// The Host array, decoded one entry at a time so one entry this build
    /// cannot read leaves a hole rather than taking the catalog with it.
    private struct PersistedHosts: Codable {
        let entries: [CatalogEntry]

        init(entries: [CatalogEntry]) {
            self.entries = entries
        }

        init(from decoder: any Decoder) throws {
            var container = try decoder.unkeyedContainer()
            var entries: [CatalogEntry] = []
            while !container.isAtEnd {
                entries.append(CatalogEntry(decoding: try container.decode(JSONValue.self)))
            }
            self.entries = entries
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.unkeyedContainer()
            for entry in entries {
                switch entry {
                case .known(let host):
                    try container.encode(host)
                case .unknown(let rawHost):
                    try container.encode(rawHost)
                }
            }
        }
    }

    /// What is written and read: a version and the Hosts. Unknown top-level
    /// keys are ignored on read and not written back.
    private struct PersistedCatalog: Codable {
        let version: Int
        let hosts: PersistedHosts
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
    /// Every persisted entry in order, including the ones `hosts` hides.
    @ObservationIgnored private var catalogEntries: [CatalogEntry]

    init(
        defaults: UserDefaults = .standard,
        secrets: any SecretStore = KeychainSecretStore(service: "dev.bybee.heeler.ssh")
    ) {
        self.defaults = defaults
        self.secrets = secrets
        guard let data = defaults.data(forKey: Self.defaultsKey) else {
            hosts = []
            catalogEntries = []
            catalogLoadError = nil
            catalogNotice = nil
            return
        }
        let loaded = Self.loadCatalog(data)
        catalogEntries = loaded.entries
        hosts = loaded.entries.compactMap(\.knownHost)
        catalogLoadError = loaded.error
        catalogNotice = loaded.notice
        if loaded.migratesInPlace,
            let encoded = try? Self.encodedCatalog(entries: loaded.entries)
        {
            defaults.set(encoded, forKey: Self.defaultsKey)
        }
    }

    private struct LoadedCatalog {
        var entries: [CatalogEntry] = []
        var error: HostStoreError?
        var notice: String?
        /// Only a legacy (version 0) catalog is rewritten on load. Entries
        /// this build cannot decode go into the envelope unchanged; a
        /// versioned catalog is never rewritten just for having been read.
        var migratesInPlace = false
    }

    /// Reads the persisted catalog as far as it can. A newer version, or an
    /// entry this build cannot decode, yields the Hosts it did read plus a
    /// notice; only bytes that are not a catalog at all are an error.
    private static func loadCatalog(_ data: Data) -> LoadedCatalog {
        let decoder = JSONDecoder()
        var loaded = LoadedCatalog()
        if let catalog = try? decoder.decode(PersistedCatalog.self, from: data) {
            loaded.entries = catalog.hosts.entries
            // A newer build's catalog is read, not refused: refusing it left
            // the list empty *and* blocked every add, with no way back but
            // reinstalling the newer build.
            if catalog.version > catalogVersion {
                loaded.notice = newerCatalogNotice
            }
            if let hidden = hiddenHostsNotice(loaded.entries) {
                loaded.notice = [loaded.notice, hidden].compactMap { $0 }.joined(separator: " ")
            }
            return loaded
        }
        // Version 0 was the bare Host array. Decode it leniently too, then
        // persist the versioned envelope, carrying hidden entries unchanged.
        guard let legacy = try? decoder.decode(PersistedHosts.self, from: data) else {
            loaded.error = .catalogUnreadable
            return loaded
        }
        loaded.entries = legacy.entries
        loaded.notice = hiddenHostsNotice(legacy.entries)
        loaded.migratesInPlace = true
        return loaded
    }

    private static let newerCatalogNotice =
        "This Host list was last saved by a newer version of Kelpie. "
        + "Anything that version added is not shown here, and saving a Host drops it."

    private static func hiddenHostsNotice(_ entries: [CatalogEntry]) -> String? {
        let count = entries.filter { $0.knownHost == nil }.count
        switch count {
        case 0: return nil
        case 1: return "One saved Host could not be read and is not shown."
        default: return "\(count) saved Hosts could not be read and are not shown."
        }
    }

    /// A process-local catalog for previews and development compositions.
    /// Mutations remain in memory, and secrets use process-local storage.
    init(volatileHosts: [Host]) {
        defaults = nil
        secrets = VolatileSecretStore()
        hosts = volatileHosts
        catalogEntries = volatileHosts.map(CatalogEntry.known)
        catalogLoadError = nil
    }

    /// Adds a Host, storing `password` in the secret store when given.
    func add(_ host: Host, password: String? = nil) throws {
        try ensureCatalogIsWritable()
        try applyPassword(password, to: host)
        hosts.append(host)
        catalogEntries.append(.known(host))
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
        guard let entryIndex = catalogEntries.firstIndex(where: {
            $0.knownHostID == host.id
        }) else {
            throw HostStoreError.catalogUnreadable
        }
        catalogEntries[entryIndex] = .known(host)
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
        catalogEntries.removeAll { $0.knownHostID == id }
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
        case .deviceKey, .rsaKey:
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
        defaults?.set(
            try Self.encodedCatalog(entries: catalogEntries),
            forKey: Self.defaultsKey)
    }

    private static func encodedCatalog(entries: [CatalogEntry]) throws -> Data {
        try JSONEncoder().encode(
            PersistedCatalog(
                version: catalogVersion,
                hosts: PersistedHosts(entries: entries)))
    }
}
