import Foundation
import Observation

/// User-facing outcome of a failed pairing attempt, classified per ceremony
/// step (ADR 0007) so the copy says whether to rescan, fix the network, or
/// regenerate the Pairing Code on the computer.
struct PairingFailure: Equatable, Sendable {
    /// The Pairing step the failure is attributed to. `.parse` marks
    /// failures caught before any connection was attempted (an expired code,
    /// an unloadable Device Key): no ceremony step ran, so none is to blame.
    let step: PairingStep
    /// Step-specific copy, including its recovery guidance.
    let message: String
    /// Whether trying again with the same scanned code (inside its TTL) can
    /// succeed; false means the user needs a fresh Pairing Code or the
    /// manual form.
    let canRetry: Bool
}

/// What one successful pairing did: which Host it belongs to, and whether
/// that Host already existed here. A second pairing of the same machine
/// updates the Host it finds, so the user is told which of the two happened
/// rather than left to notice a duplicate row.
struct PairingOutcome: Equatable, Sendable {
    let host: Host
    let updatedExisting: Bool

    var message: String {
        updatedExisting ? "Updated \(host.displayName)" : "Added \(host.displayName)"
    }
}

/// Drives Scan to Pair (#62, #66, #204): turns strings recognized by the QR
/// scanner or pasted from the clipboard into a parsed Pairing Code, runs
/// the ceremony through the injected `PairingConnector`, and persists the
/// Host only after the verified reconnect, with its fingerprint pinned so
/// preflight never TOFU-prompts. Camera capture and pasteboard access stay
/// in the view layer; everything downstream of the scanned string is
/// testable here with scripted connector fakes.
@MainActor
@Observable
final class PairingScanStore {
    /// Set once a scan parses; further scans are ignored until `rescan()`.
    private(set) var pairingCode: PairingCode?
    /// User-facing copy for the last failed scan, per the pairing failure
    /// taxonomy's parse step. Cleared by a successful scan or `rescan()`.
    private(set) var scanFailureMessage: String?
    /// True while a ceremony attempt is in flight.
    private(set) var isPairing = false
    /// The ceremony step currently underway, for progress UI.
    private(set) var step: PairingStep?
    /// The last attempt's failure, with its recovery options.
    private(set) var failure: PairingFailure?
    /// The persisted Host, set only after the verified reconnect succeeded.
    /// The view hands it to the same preflight a manually added Host enters.
    private(set) var pairedHost: Host?
    /// Whether the pairing landed on a Host this device already had rather
    /// than creating one. Set with `pairedHost`, and the reason the user is
    /// told "Updated <name>" instead of quietly getting a second row.
    private(set) var didUpdateExistingHost = false

    @ObservationIgnored private let catalog: HostStore
    @ObservationIgnored private let connector: any PairingConnector
    @ObservationIgnored private let knownHosts: any KnownHostsStore
    @ObservationIgnored private let credentials: HostCredentialsProvider
    /// Pairing onto a Host this device already has keeps its address, port and
    /// username, so iCloud pairing sync would see no edit at all — and a
    /// sibling's tombstone from before the re-pair would then delete the Host
    /// that was just paired. The pairing stamps the Host itself (ADR 0018).
    @ObservationIgnored private let hostEdits: PairingSyncHostEdits
    @ObservationIgnored private let now: @Sendable () -> Date
    /// The code the next attempt will use: the scanned code, except after a
    /// verify-step failure, where the Bootstrap Key is dropped — Enrollment
    /// already took effect, so only the Device Key reconnect remains.
    @ObservationIgnored private var attemptCode: PairingCode?
    /// True once a bootstrap ceremony reached Enrollment and we stripped the
    /// Bootstrap Key from `attemptCode`. A later verify failure then carries a
    /// bootstrap-less `attemptCode`, but the device really was enrolled, so
    /// this keeps the enrolled-then-unverified copy instead of regressing to
    /// the config-only "add your authorized_keys line" guidance.
    @ObservationIgnored private var enrolledViaBootstrap = false
    /// Invalidates step callbacks still in flight from earlier attempts.
    @ObservationIgnored private var attemptGeneration = 0

    init(
        catalog: HostStore,
        connector: any PairingConnector = SSHPairingConnector(),
        knownHosts: any KnownHostsStore = UserDefaultsKnownHostsStore.shared,
        credentials: HostCredentialsProvider = HostCredentialsProvider(),
        hostEdits: PairingSyncHostEdits = PairingSyncHostEdits(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.catalog = catalog
        self.connector = connector
        self.knownHosts = knownHosts
        self.credentials = credentials
        self.hostEdits = hostEdits
        self.now = now
    }

    func submit(scannedCode: String) {
        guard pairingCode == nil else { return }
        // Paste (and a trailing newline from pbcopy/manual selection) is the
        // same parse path as a scan; trim so the two cannot disagree.
        let scanned = scannedCode.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let code = try PairingCode.decode(scanned)
            pairingCode = code
            attemptCode = code
            enrolledViaBootstrap = false
            scanFailureMessage = nil
        } catch {
            scanFailureMessage = Self.message(for: error)
        }
    }

    /// Runs one ceremony attempt against the scanned code. Reentrancy-safe:
    /// a call while an attempt runs, or after one succeeded, does nothing.
    /// Calling it again after a retryable failure is the Try Again action.
    func pair() async {
        guard let code = attemptCode, !isPairing, pairedHost == nil else { return }
        isPairing = true
        failure = nil
        attemptGeneration += 1
        let generation = attemptGeneration
        defer {
            isPairing = false
            step = nil
        }

        if let bootstrap = code.bootstrap, bootstrap.expiresAt <= now() {
            // Locally detectable expiry: skip the doomed connection and go
            // straight to the regenerate guidance.
            failure = PairingFailure(step: .parse, message: Self.expiredCopy, canRetry: false)
            return
        }

        let deviceKey: DeviceKey
        do {
            deviceKey = try credentials.deviceKey()
        } catch {
            failure = PairingFailure(
                step: .parse,
                message: "This device's Device Key could not be loaded. "
                    + "Open the manual Add Host form to inspect or replace it.",
                canRetry: false)
            return
        }

        let result: PairingResult
        do {
            result = try await connector.pair(code: code, deviceKey: deviceKey) { [weak self] step in
                Task { @MainActor [weak self] in
                    guard let self, self.attemptGeneration == generation, self.isPairing else {
                        return
                    }
                    self.step = step
                }
            }
        } catch let error as PairingCeremonyError {
            if case .verificationFailed = error, code.bootstrap != nil {
                attemptCode = code.withoutBootstrap
                enrolledViaBootstrap = true
            }
            failure = Self.failure(
                for: error, isConfigOnly: code.bootstrap == nil && !enrolledViaBootstrap)
            return
        } catch is CancellationError {
            // The scan sheet went away mid-ceremony; nobody is left to tell.
            return
        } catch {
            failure = PairingFailure(
                step: .reach,
                message: "Pairing failed unexpectedly. Try again with the same code. (\(error))",
                canRetry: true)
            return
        }

        // Only a fully verified ceremony creates a Host (ADR 0007). The
        // fingerprint pin lands with it, against the address that actually
        // answered, so preflight connects without a TOFU prompt.
        let existing = await existingHost(matching: result)
        var host =
            existing
            ?? Host(
                address: result.address, port: result.port, username: result.username,
                authMethod: .deviceKey)
        if existing != nil {
            // The ceremony's coordinates are the live ones, and the device is
            // now enrolled by key. Everything else about the Host — its name,
            // its session, its Jump Host — is this device's own and is kept.
            host.address = result.address
            host.port = result.port
            host.username = result.username
            host.authMethod = .deviceKey
        }
        do {
            if existing != nil {
                try catalog.update(host)
                // Stamped before the catalog write reaches the reconcile that
                // write triggers, so this pass already sees the re-pair as a
                // local edit: newer than any tombstone, and republished.
                hostEdits.markEdited(host, at: now())
            } else {
                try catalog.add(host)
            }
        } catch {
            failure = PairingFailure(
                step: .verify,
                message: "Pairing succeeded, but the Host could not be saved because the Host "
                    + "catalog on this device is unreadable. Resolve that first, then pair again "
                    + "with a fresh code.",
                canRetry: false)
            return
        }
        await knownHosts.setFingerprint(
            result.hostKeyFingerprint, host: result.address, port: result.port)
        didUpdateExistingHost = existing != nil
        pairedHost = host
    }

    /// What the pairing did, for the screen the user lands on. Nil until a
    /// pairing succeeds.
    var outcome: PairingOutcome? {
        pairedHost.map { PairingOutcome(host: $0, updatedExisting: didUpdateExistingHost) }
    }

    /// Back to a fresh scanning state (the "Scan Again" action).
    func rescan() {
        guard !isPairing else { return }
        pairingCode = nil
        attemptCode = nil
        enrolledViaBootstrap = false
        scanFailureMessage = nil
        failure = nil
        pairedHost = nil
        didUpdateExistingHost = false
    }

    /// The Host this pairing belongs to, when the device already has one:
    /// the same endpoint and account, or a Host whose pinned key is the one
    /// that just answered — a machine whose address changed, or that was
    /// re-paired after a wipe. Without this, pairing the mini a second time
    /// leaves two rows for one machine, and the Host's `notifications.json`
    /// (keyed by device token) keeps only the newer registration, so the
    /// first row's push path goes quietly dead.
    ///
    /// Hosts reached through a Jump Host are never matched: their address is
    /// a loopback port on the tunnel, which says nothing about the machine.
    private func existingHost(matching result: PairingResult) async -> Host? {
        let address = result.address.lowercased()
        let candidates = catalog.hosts.filter { !$0.usesJumpHost }
        if let byCoordinates = candidates.first(where: {
            $0.address.lowercased() == address && $0.port == result.port
                && $0.username == result.username
        }) {
            return byCoordinates
        }
        for host in candidates where host.username == result.username {
            // The key identifies the machine, not the account on it. Two Hosts
            // can be the same machine under different logins, and pairing as
            // one of them says nothing about the other.
            let pinned = await knownHosts.fingerprints(host: host.address, port: host.port)
            if pinned.contains(result.hostKeyFingerprint) { return host }
        }
        return nil
    }

    // MARK: Failure copy

    private static let expiredCopy =
        "This Pairing Code has expired. Generate a new one on the computer and scan it."

    private static func failure(
        for error: PairingCeremonyError, isConfigOnly: Bool
    ) -> PairingFailure {
        switch error {
        case .hostUnreachable:
            PairingFailure(
                step: .reach,
                message: "The Host did not answer at any of its addresses. Check that this "
                    + "device is on the same network or VPN as the computer, then try again "
                    + "with the same code.",
                canRetry: true)
        case .bootstrapRejected:
            PairingFailure(
                step: .authenticate,
                message: "The Host rejected this Pairing Code. It may have been used already, "
                    + "expired, or its popup was closed. Generate a new Pairing Code on the "
                    + "computer and scan it.",
                canRetry: false)
        case .enrollmentRefused(.expired):
            PairingFailure(step: .enroll, message: expiredCopy, canRetry: false)
        case .enrollmentRefused(.unknownPairing):
            PairingFailure(
                step: .enroll,
                message: "The Host has no pairing in progress for this code. Generate a new "
                    + "Pairing Code on the computer and scan it.",
                canRetry: false)
        case .enrollmentRefused(.invalidKey):
            PairingFailure(
                step: .enroll,
                message: "The Host did not accept this device's key. Try again; if it keeps "
                    + "failing, update the app and the pairing plugin so they match.",
                canRetry: true)
        case .enrollmentRefused(.noInput):
            PairingFailure(
                step: .enroll,
                message: "This device's key never reached the Host. Try again with the same code.",
                canRetry: true)
        case .enrollmentRefused(.unrecognized(let code)):
            PairingFailure(
                step: .enroll,
                message: "The Host refused Enrollment (\(code)). Update the app and the pairing "
                    + "plugin so they match, then generate a new Pairing Code.",
                canRetry: false)
        case .enrollmentFailed:
            PairingFailure(
                step: .enroll,
                message: "Enrollment did not complete, likely a network hiccup. "
                    + "Try again with the same code.",
                canRetry: true)
        case .verificationFailed where isConfigOnly:
            PairingFailure(
                step: .verify,
                message: "The Host did not accept the Device Key, so it is not authorized there "
                    + "yet. Add this device's authorized_keys line on the Host, or generate a "
                    + "Pairing Code in herdr instead.",
                canRetry: false)
        case .verificationFailed:
            PairingFailure(
                step: .verify,
                message: "This device was enrolled, but the verifying reconnect did not get "
                    + "through. Try again to finish with the enrolled key.",
                canRetry: true)
        }
    }

    private static func message(for error: PairingCodeError) -> String {
        switch error {
        case .badPrefix:
            "That QR code is not a herdr Pairing Code."
        case .unsupportedVersion(let found):
            "This Pairing Code uses version \(found), which this app does not "
                + "understand. Update the app and the pairing plugin so they match."
        case .badEncoding, .badPayload:
            "The Pairing Code could not be read. Regenerate it in herdr and scan again."
        }
    }
}

extension PairingCode {
    /// The same Host coordinates without the Bootstrap Key: what a retry
    /// needs once Enrollment has already landed on the Host.
    fileprivate var withoutBootstrap: PairingCode {
        PairingCode(
            addresses: addresses, port: port, username: username,
            hostKeyFingerprint: hostKeyFingerprint, bootstrap: nil)
    }
}
