import Foundation

enum HostCredentialsError: Error, Equatable, LocalizedError {
    /// The Host authenticates by password but none is stored. Routine on a
    /// Host adopted from a sibling device: the password is deliberately the
    /// one thing pairing sync does not carry (ADR 0018), so the Host arrives
    /// complete except for it.
    case passwordNotSet

    var errorDescription: String? {
        switch self {
        case .passwordNotSet: HostCredentialsProvider.passwordEntryNeededMessage
        }
    }
}

/// Resolves a Host's `SSHCredentials`: the device key (generated on first
/// use) or the Keychain-stored password. Secrets stay inside the stores;
/// this type only hands them onward to the transport.
struct HostCredentialsProvider: Sendable {
    private let deviceKeys: DeviceKeyStore
    private let secrets: any SecretStore

    init(
        deviceKeys: DeviceKeyStore = DeviceKeyStore(),
        secrets: any SecretStore = KeychainSecretStore(service: "dev.bybee.heeler.ssh")
    ) {
        self.deviceKeys = deviceKeys
        self.secrets = secrets
    }

    func credentials(for host: Host) throws -> SSHCredentials {
        switch host.authMethod {
        case .deviceKey:
            return .ed25519(try deviceKeys.loadOrCreate().privateKey)
        case .password:
            guard
                let data = try secrets.read(account: HostStore.passwordAccount(for: host.id)),
                !data.isEmpty
            else {
                throw HostCredentialsError.passwordNotSet
            }
            return .password(String(decoding: data, as: UTF8.self))
        }
    }

    /// What to say when a Host has no password on this device. A Host that
    /// came from a sibling reads as "authentication failed" otherwise, which
    /// sends the user looking for a wrong key or a wrong account.
    static let passwordEntryNeededMessage =
        "No password is saved for this Host on this device. "
        + "Enter this Host's password here to connect."

    /// Whether this Host authenticates by password and has none stored here.
    /// Distinct from a rejected password: nothing was offered at all.
    ///
    /// A Keychain that refuses to answer is deliberately *not* reported as a
    /// missing password — inventing that state would send the user to retype
    /// a password that is already there.
    func needsPasswordEntry(for host: Host) -> Bool {
        guard host.authMethod == .password else { return false }
        do {
            let stored = try secrets.read(account: HostStore.passwordAccount(for: host.id))
            return stored?.isEmpty ?? true
        } catch {
            return false
        }
    }

    /// The device public key material shown during Host setup.
    func deviceKey() throws -> DeviceKey {
        try deviceKeys.loadOrCreate()
    }

    /// User-approved recovery for a corrupt device key. Callers must explain
    /// that every device-key Host will need the replacement public key.
    func replaceDeviceKey() throws -> DeviceKey {
        try deviceKeys.replaceStoredKey()
    }
}
