import Foundation
import os

/// TOFU persistence: fingerprints are keyed by endpoint and SSH key
/// algorithm, matching OpenSSH's ability to trust more than one host-key
/// algorithm for the same machine. Not a secret: it guards against future
/// impostors, it does not authenticate us.
protocol KnownHostsStore: Sendable {
    func fingerprints(host: String, port: Int) async -> [HostKeyFingerprint]
    func fingerprint(host: String, port: Int, algorithm: String) async -> HostKeyFingerprint?
    func fingerprint(host: String, port: Int) async -> HostKeyFingerprint?
    func setFingerprint(_ fingerprint: HostKeyFingerprint, host: String, port: Int) async
}

extension KnownHostsStore {
    func fingerprint(host: String, port: Int) async -> HostKeyFingerprint? {
        await fingerprints(host: host, port: port).first
    }
}

/// Volatile store for tests and previews.
actor InMemoryKnownHostsStore: KnownHostsStore {
    private var storedFingerprints: [String: HostKeyFingerprint] = [:]

    func fingerprints(host: String, port: Int) -> [HostKeyFingerprint] {
        let prefix = Self.algorithmKeyPrefix(host: host, port: port)
        return storedFingerprints
            .filter { $0.key.hasPrefix(prefix) }
            .map(\.value)
    }

    func fingerprint(host: String, port: Int, algorithm: String) -> HostKeyFingerprint? {
        storedFingerprints[Self.algorithmKey(host: host, port: port, algorithm: algorithm)]
            ?? storedFingerprints[
                Self.algorithmKey(
                    host: host, port: port, algorithm: HostKeyFingerprint.unknownAlgorithm)]
    }

    func setFingerprint(_ fingerprint: HostKeyFingerprint, host: String, port: Int) {
        if fingerprint.algorithm != HostKeyFingerprint.unknownAlgorithm {
            storedFingerprints[
                Self.algorithmKey(
                    host: host, port: port, algorithm: HostKeyFingerprint.unknownAlgorithm)] = nil
        }
        storedFingerprints[
            Self.algorithmKey(host: host, port: port, algorithm: fingerprint.algorithm)] =
            fingerprint
    }

    static func endpointKey(host: String, port: Int) -> String {
        "\(host):\(port)"
    }

    static func algorithmKeyPrefix(host: String, port: Int) -> String {
        let endpoint = endpointKey(host: host, port: port)
        return "v2|\(endpoint.utf8.count)|\(endpoint)|"
    }

    static func algorithmKey(host: String, port: Int, algorithm: String) -> String {
        algorithmKeyPrefix(host: host, port: port) + algorithm
    }
}

/// The app's persistent store. Production uses one shared actor so concurrent
/// first connects cannot lose each other's read-modify-write updates.
actor UserDefaultsKnownHostsStore: KnownHostsStore {
    static let shared = UserDefaultsKnownHostsStore()
    private static let defaultsKey = "knownHostFingerprints"
    private static let log = Logger(subsystem: "dev.bybee.heeler", category: "known-hosts")
    private let defaults: UserDefaults
    /// One line per store, not one per read.
    private var hasLoggedDroppedEntries = false

    init() {
        defaults = .standard
    }

    init?(suiteName: String) {
        guard let defaults = UserDefaults(suiteName: suiteName) else { return nil }
        self.defaults = defaults
    }

    func fingerprints(host: String, port: Int) -> [HostKeyFingerprint] {
        let stored = storedValues()
        let prefix = InMemoryKnownHostsStore.algorithmKeyPrefix(host: host, port: port)
        var fingerprints = stored.compactMap { key, base64 -> HostKeyFingerprint? in
            guard key.hasPrefix(prefix), let digest = Data(base64Encoded: base64) else {
                return nil
            }
            let algorithm = String(key.dropFirst(prefix.count))
            return HostKeyFingerprint(digest: digest, algorithm: algorithm)
        }
        if let legacy = legacyFingerprint(in: stored, host: host, port: port) {
            fingerprints.append(legacy)
        }
        return fingerprints
    }

    func fingerprint(host: String, port: Int, algorithm: String) -> HostKeyFingerprint? {
        let stored = storedValues()
        let key = InMemoryKnownHostsStore.algorithmKey(
            host: host, port: port, algorithm: algorithm)
        if let base64 = stored[key], let digest = Data(base64Encoded: base64) {
            return HostKeyFingerprint(digest: digest, algorithm: algorithm)
        }
        return legacyFingerprint(in: stored, host: host, port: port)
    }

    /// Writes through the stored dictionary itself rather than through the
    /// filtered copy reads use, so a value this build cannot interpret is
    /// carried forward instead of being deleted by the next pin. Nothing is
    /// written at all unless something actually changed — re-confirming a
    /// fingerprint already on file is not a write.
    func setFingerprint(_ fingerprint: HostKeyFingerprint, host: String, port: Int) {
        let stored = defaults.dictionary(forKey: Self.defaultsKey) ?? [:]
        guard
            let updated = Self.applying(fingerprint, host: host, port: port, to: stored)
        else { return }
        defaults.set(updated, forKey: Self.defaultsKey)
    }

    /// The stored dictionary with this pin applied, or nil when it already
    /// says exactly that — nothing is written back unless something really
    /// changed. Values this build cannot read are carried through untouched
    /// rather than dropped by the next pin.
    nonisolated static func applying(
        _ fingerprint: HostKeyFingerprint, host: String, port: Int, to stored: [String: Any]
    ) -> [String: Any]? {
        var updated = stored
        let legacyKey = InMemoryKnownHostsStore.endpointKey(host: host, port: port)
        var changed = false
        if fingerprint.algorithm != HostKeyFingerprint.unknownAlgorithm,
            updated.removeValue(forKey: legacyKey) != nil
        {
            changed = true
        }
        let key = InMemoryKnownHostsStore.algorithmKey(
            host: host, port: port, algorithm: fingerprint.algorithm)
        let encoded = fingerprint.digest.base64EncodedString()
        if (updated[key] as? String) != encoded {
            updated[key] = encoded
            changed = true
        }
        return changed ? updated : nil
    }

    /// The trusted fingerprints, decoded one entry at a time. A single value
    /// of the wrong type used to make the whole TOFU database read as empty —
    /// and the next pin then wrote that empty dictionary back, discarding
    /// every other Host's trusted key. One bad entry is now dropped from the
    /// read, logged once, and left untouched on disk.
    private func storedValues() -> [String: String] {
        guard let raw = defaults.dictionary(forKey: Self.defaultsKey) else { return [:] }
        var values: [String: String] = [:]
        var dropped = 0
        for (key, value) in raw {
            if let string = value as? String {
                values[key] = string
            } else {
                dropped += 1
            }
        }
        if dropped > 0, !hasLoggedDroppedEntries {
            hasLoggedDroppedEntries = true
            Self.log.info(
                "known hosts: \(dropped, privacy: .public) unreadable entries ignored")
        }
        return values
    }

    private func legacyFingerprint(
        in stored: [String: String], host: String, port: Int
    ) -> HostKeyFingerprint? {
        guard
            let base64 = stored[InMemoryKnownHostsStore.endpointKey(host: host, port: port)],
            let digest = Data(base64Encoded: base64)
        else { return nil }
        return HostKeyFingerprint(digest: digest)
    }
}
