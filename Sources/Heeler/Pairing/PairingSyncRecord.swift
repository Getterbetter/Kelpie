import CryptoKit
import Foundation

/// One Host's pairing as it travels through iCloud Keychain (ADR 0018): what
/// a sibling device needs to reach that Host and decrypt its notifications,
/// without pairing again.
///
/// Everything here is either public (coordinates, fingerprints, public key
/// lines) or a shared secret the Host already holds (the Notification Key).
/// The Host password is deliberately absent — it is a user secret this app
/// has no reason to move — and so is the Device Key, which travels in its own
/// synced slot rather than once per Host.
struct PairingSyncRecord: Codable, Equatable, Sendable {
    /// Bumped only by a change older builds cannot read; a record with an
    /// unknown schema is skipped, never adopted half-decoded.
    static let currentSchema = 1

    var schema: Int
    var host: Host
    /// Encoded `PairingSyncFingerprint` entries for this Host's endpoint and,
    /// when it uses one, its Jump Host's — a device that adopts the Host
    /// without them would face a first-connect confirmation it cannot answer.
    var fingerprints: [String]
    /// The Host's 32-byte Notification Key. Nil until some device has run the
    /// Notification Registration ceremony against this Host.
    var notificationKey: Data?
    var updatedAt: Date
    /// OpenSSH public-key lines of devices that hold their own Device Key and
    /// still need a line in this Host's `authorized_keys`. Whichever sibling
    /// can already reach the Host enrols them and moves them to
    /// `authorizedPublicKeys`.
    var pendingPublicKeys: [String]
    /// Lines this Host's `authorized_keys` already carries. Without it a
    /// device could not tell "never enrolled" from "enrolled and cleared",
    /// and would re-add its own line on every reconcile forever.
    var authorizedPublicKeys: [String]

    init(
        schema: Int = PairingSyncRecord.currentSchema,
        host: Host,
        fingerprints: [String] = [],
        notificationKey: Data? = nil,
        updatedAt: Date,
        pendingPublicKeys: [String] = [],
        authorizedPublicKeys: [String] = []
    ) {
        self.schema = schema
        self.host = host
        self.fingerprints = fingerprints
        self.notificationKey = notificationKey
        self.updatedAt = updatedAt
        self.pendingPublicKeys = pendingPublicKeys
        self.authorizedPublicKeys = authorizedPublicKeys
    }

    /// `authorizedPublicKeys` was added after the first records were written,
    /// and an absent list means exactly what an empty one does — nobody is
    /// recorded as enrolled yet. So it decodes as optional and the schema
    /// stays 1: bumping it would make every record a sibling already
    /// published unreadable to the build that published it.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema = try container.decode(Int.self, forKey: .schema)
        host = try container.decode(Host.self, forKey: .host)
        fingerprints = try container.decode([String].self, forKey: .fingerprints)
        notificationKey = try container.decodeIfPresent(Data.self, forKey: .notificationKey)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        pendingPublicKeys = try container.decode([String].self, forKey: .pendingPublicKeys)
        authorizedPublicKeys =
            try container.decodeIfPresent([String].self, forKey: .authorizedPublicKeys) ?? []
    }

    /// The key type and blob of an OpenSSH public-key line, ignoring options
    /// and the trailing comment — two lines carrying the same key are one
    /// enrolment however they were written. Nil for anything that is not a
    /// public-key line.
    static func keyMaterial(_ line: String) -> String? {
        let fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard
            let index = fields.firstIndex(where: {
                $0.hasPrefix("ssh-") || $0.hasPrefix("ecdsa-")
            }),
            index + 1 < fields.count
        else { return nil }
        return fields[index] + " " + fields[index + 1]
    }

    /// Whether `lines` already carries this key, comparing key material
    /// rather than whole lines.
    static func contains(_ lines: some Sequence<String>, keyMaterial material: String?) -> Bool {
        guard let material else { return false }
        return lines.contains { keyMaterial($0) == material }
    }

    /// Union of two line lists keeping one line per key, in a stable order.
    static func merging(_ lines: [String], with additions: [String]) -> [String] {
        var seen: Set<String> = []
        var merged: [String] = []
        for line in (lines + additions).sorted() {
            guard let material = keyMaterial(line) else { continue }
            guard seen.insert(material).inserted else { continue }
            merged.append(line)
        }
        return merged
    }

    /// Hash of everything except `updatedAt`, so an activation that changed
    /// nothing does not rewrite the item (and so does not wake iCloud
    /// Keychain sync on every one of the user's devices).
    var contentDigest: String {
        var hasher = SHA256()
        hasher.update(data: Data(String(schema).utf8))
        hasher.update(data: (try? Self.canonicalEncoder.encode(host)) ?? Data())
        for entry in fingerprints.sorted() {
            hasher.update(data: Data(entry.utf8))
        }
        hasher.update(data: notificationKey ?? Data())
        for line in pendingPublicKeys.sorted() {
            hasher.update(data: Data(line.utf8))
        }
        for line in authorizedPublicKeys.sorted() {
            hasher.update(data: Data("authorized:\(line)".utf8))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    /// Decodes a synced item, returning nil for anything this build cannot
    /// use: a newer schema, or bytes that are not a record at all. One
    /// unreadable record must never stop the others being adopted.
    static func decode(_ data: Data) -> PairingSyncRecord? {
        guard let record = try? JSONDecoder().decode(PairingSyncRecord.self, from: data),
            record.schema == currentSchema
        else { return nil }
        return record
    }

    /// Deterministic key order so the digest depends on values, not on the
    /// encoder's hashing seed.
    private static let canonicalEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
}

/// A known-hosts entry inside a pairing record: which endpoint presented the
/// key, and the fingerprint itself. Encoded as one line so the record stays a
/// flat `[String]` that a future field change cannot break.
struct PairingSyncFingerprint: Equatable, Sendable {
    let address: String
    let port: Int
    let fingerprint: HostKeyFingerprint

    /// `v1|<address>|<port>|<algorithm>|<base64 digest>`. Neither an address
    /// nor an SSH algorithm name can contain a pipe, so the split is safe.
    var encoded: String {
        [
            "v1", address, String(port), fingerprint.algorithm,
            fingerprint.digest.base64EncodedString(),
        ].joined(separator: "|")
    }

    init(address: String, port: Int, fingerprint: HostKeyFingerprint) {
        self.address = address
        self.port = port
        self.fingerprint = fingerprint
    }

    init?(encoded: String) {
        let fields = encoded.split(separator: "|", omittingEmptySubsequences: false)
        guard fields.count == 5, fields[0] == "v1",
            let port = Int(fields[2]),
            let digest = Data(base64Encoded: String(fields[4])),
            digest.count == 32,
            !fields[1].isEmpty, !fields[3].isEmpty
        else { return nil }
        self.init(
            address: String(fields[1]),
            port: port,
            fingerprint: HostKeyFingerprint(digest: digest, algorithm: String(fields[3])))
    }
}

/// A Host's deletion, as it travels through iCloud Keychain: the record for a
/// deleted Host is removed, and this takes its place so the sibling that still
/// holds the Host deletes it too instead of publishing it straight back.
///
/// Stored in the same Keychain service as the records, under an account that
/// is deliberately **not** a bare UUID: a build that predates tombstones skips
/// every account it cannot read as one, so it ignores these rather than
/// choking on them.
struct PairingSyncTombstone: Codable, Equatable, Sendable {
    /// Bumped only by a change older builds cannot read; an unknown schema is
    /// skipped, exactly as a record's is.
    static let currentSchema = 1
    static let accountPrefix = "deleted-"
    /// How long a tombstone suppresses the Host. Long enough for a device
    /// that was in a drawer for a month to see it, short enough that the
    /// synced store does not accumulate them forever.
    static let lifetime: TimeInterval = 30 * 24 * 60 * 60

    var schema: Int
    var hostID: UUID
    var deletedAt: Date

    init(schema: Int = PairingSyncTombstone.currentSchema, hostID: UUID, deletedAt: Date) {
        self.schema = schema
        self.hostID = hostID
        self.deletedAt = deletedAt
    }

    static func account(for id: UUID) -> String {
        accountPrefix + id.uuidString
    }

    /// The Host id an account names, or nil when the account is not a
    /// tombstone at all.
    static func hostID(forAccount account: String) -> UUID? {
        guard account.hasPrefix(accountPrefix) else { return nil }
        return UUID(uuidString: String(account.dropFirst(accountPrefix.count)))
    }

    func hasExpired(at instant: Date) -> Bool {
        instant.timeIntervalSince(deletedAt) > Self.lifetime
    }

    func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    static func decode(_ data: Data) -> PairingSyncTombstone? {
        guard let tombstone = try? JSONDecoder().decode(PairingSyncTombstone.self, from: data),
            tombstone.schema == currentSchema
        else { return nil }
        return tombstone
    }
}
