import CryptoKit
import Foundation

enum DeviceKeyStoreError: Error, Equatable {
    /// The stored bytes no longer parse as an Ed25519 key. Surfaced, never
    /// silently regenerated: a new key would lock the user out of every Host
    /// without explanation.
    case storedKeyCorrupt
}

/// Loads the device's SSH key, generating it on first use. The private key's
/// raw bytes exist only inside the backing `SecretStore` (the Keychain in the
/// app) and the in-memory CryptoKit object; there is no export path.
struct DeviceKeyStore: Sendable {
    private let secrets: any SecretStore
    private let account: String

    init(
        secrets: any SecretStore = KeychainSecretStore(service: "dev.bybee.heeler.ssh"),
        account: String = "device-ed25519-private-key"
    ) {
        self.secrets = secrets
        self.account = account
    }

    func loadOrCreate() throws -> DeviceKey {
        if let stored = try secrets.read(account: account) {
            guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: stored) else {
                throw DeviceKeyStoreError.storedKeyCorrupt
            }
            return DeviceKey(privateKey: key)
        }
        let key = Curve25519.Signing.PrivateKey()
        try secrets.write(key.rawRepresentation, account: account)
        return DeviceKey(privateKey: key)
    }

    /// The stored key, or nil when this device has none yet. Unlike
    /// `loadOrCreate` it never generates one: `PairingSync` has to be able to
    /// ask "is this a fresh device?" without answering the question itself
    /// (ADR 0018).
    func existingKey() throws -> DeviceKey? {
        guard let stored = try secrets.read(account: account) else { return nil }
        guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: stored) else {
            throw DeviceKeyStoreError.storedKeyCorrupt
        }
        return DeviceKey(privateKey: key)
    }

    /// Installs the key a sibling device generated, so both devices present
    /// the same SSH identity and one `authorized_keys` line serves both. Only
    /// ever called on a device that has no key of its own — adopting over an
    /// existing key would revoke that device's access to every Host.
    @discardableResult
    func adopt(rawRepresentation: Data) throws -> DeviceKey {
        guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: rawRepresentation)
        else {
            throw DeviceKeyStoreError.storedKeyCorrupt
        }
        try secrets.write(key.rawRepresentation, account: account)
        return DeviceKey(privateKey: key)
    }

    /// Replaces the stored key only after a user-approved recovery flow. This
    /// is deliberately separate from `loadOrCreate`: silent replacement would
    /// invalidate access to every Host that trusts the previous public key.
    func replaceStoredKey() throws -> DeviceKey {
        let key = Curve25519.Signing.PrivateKey()
        try secrets.write(key.rawRepresentation, account: account)
        return DeviceKey(privateKey: key)
    }
}
