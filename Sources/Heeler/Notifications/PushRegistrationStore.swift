import Foundation
import Observation
import UIKit
import UserNotifications

/// Which APNs environment this install's device tokens belong to — the `env`
/// field of the Notification Registration file contract.
///
/// The deciding fact is the `aps-environment` entitlement the install was
/// signed with, not the build configuration: a Release-configuration build
/// run from Xcode or installed from an ad-hoc archive is signed with a
/// development profile and gets **sandbox** tokens, while the same source
/// through TestFlight gets production ones. Writing the build configuration's
/// guess into a Host's entry points its pushes at the wrong APNs host, where
/// they are answered `400 BadDeviceToken` — never the `410` the plugin's
/// prune path waits for — so nothing on either side ever notices (ADR 0008).
///
/// The entitlement is read from the embedded provisioning profile, which is
/// the only copy of it a running app can see. `#if DEBUG` remains the
/// fallback for the one case where there is no profile to read: an App Store
/// install, which Apple re-signs for production.
enum APNSEnvironment: String, Sendable, Codable {
    case sandbox
    case production

    /// What this install actually registers in. Resolved once — the profile
    /// cannot change under a running process.
    static let current: APNSEnvironment = resolved(
        provisioningProfile: Bundle.main.url(
            forResource: "embedded", withExtension: "mobileprovision"
        ).flatMap { try? Data(contentsOf: $0) })

    /// The build configuration's guess; only correct when the signing
    /// identity matches the configuration.
    static var compiled: APNSEnvironment {
        #if DEBUG
            .sandbox
        #else
            .production
        #endif
    }

    /// The entitlement's environment, or the compiled fallback when there is
    /// no readable profile (App Store installs) or it declares no
    /// `aps-environment` (an install that cannot receive pushes at all, where
    /// the value is moot).
    static func resolved(provisioningProfile data: Data?) -> APNSEnvironment {
        guard let data, let declared = apsEnvironment(inProvisioningProfile: data) else {
            return compiled
        }
        return declared
    }

    /// `aps-environment` from a `.mobileprovision`: a CMS-signed blob with an
    /// XML plist in the middle, so the plist is sliced out by its own
    /// delimiters rather than by decoding the signature.
    static func apsEnvironment(inProvisioningProfile data: Data) -> APNSEnvironment? {
        guard let plist = embeddedPropertyList(in: data),
            let profile = try? PropertyListSerialization.propertyList(
                from: plist, options: [], format: nil) as? [String: Any],
            let entitlements = profile["Entitlements"] as? [String: Any],
            let declared = entitlements["aps-environment"] as? String
        else { return nil }
        switch declared {
        // Apple spells the sandbox one "development"; the file contract and
        // the relay both call it "sandbox".
        case "development": return .sandbox
        case "production": return .production
        default: return nil
        }
    }

    private static func embeddedPropertyList(in data: Data) -> Data? {
        guard let start = data.range(of: Data("<?xml".utf8)),
            let end = data.range(of: Data("</plist>".utf8), options: .backwards)
        else { return nil }
        guard start.lowerBound < end.upperBound else { return nil }
        return data[start.lowerBound..<end.upperBound]
    }
}

/// A captured APNs device token in the wire form the registration file
/// wants: lowercase hex plus the environment it belongs to.
struct APNSDeviceToken: Sendable, Equatable {
    let hex: String
    let environment: APNSEnvironment

    init(hex: String, environment: APNSEnvironment) {
        self.hex = hex
        self.environment = environment
    }

    init(tokenData: Data, environment: APNSEnvironment) {
        self.init(
            hex: tokenData.map { String(format: "%02x", $0) }.joined(),
            environment: environment)
    }
}

/// The system boundary of push bootstrap: iOS permission state and APNs
/// registration. A protocol so the store's state machine is testable; the
/// token itself still arrives through `UIApplicationDelegate` callbacks,
/// which `PushRegistrationDelegate` forwards into the store.
protocol PushRegistrationClient: Sendable {
    func authorizationStatus() async -> UNAuthorizationStatus
    func requestAuthorization() async throws -> Bool
    @MainActor func registerForRemoteNotifications()
}

struct SystemPushRegistrationClient: PushRegistrationClient {
    func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    func requestAuthorization() async throws -> Bool {
        try await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])
    }

    @MainActor func registerForRemoteNotifications() {
        UIApplication.shared.registerForRemoteNotifications()
    }
}

/// App-side push bootstrap (#71): asks for notification permission, registers
/// with APNs, and captures the device token that Notification Registration
/// (#72) will write to a Host. Apple says tokens can change between
/// launches, so `refresh` silently re-registers whenever permission already
/// exists instead of caching a token across runs.
@MainActor
@Observable
final class PushRegistrationStore {
    enum State: Equatable {
        /// Not probed yet this launch.
        case unknown
        /// iOS has never asked; the permission prompt is still available.
        case needsPermission
        case denied
        /// Permission was granted and has since been withdrawn in the
        /// Settings app. Distinct from `denied` because the user believes
        /// notifications are configured: every Host still holds this
        /// device's entry, every push is dropped by iOS, and nothing else
        /// on the device would say so.
        case revoked
        /// Registration is in flight; the token callback has not fired yet.
        case waitingForToken
        case registered(APNSDeviceToken)
        case failed(String)
    }

    private(set) var state: State = .unknown

    /// Whether this launch ever held a token, so a withdrawal reads as
    /// `revoked` rather than a first-run `denied`.
    private var didRegisterThisLaunch = false

    private let client: any PushRegistrationClient
    private let environment: APNSEnvironment

    init(
        client: any PushRegistrationClient = SystemPushRegistrationClient(),
        environment: APNSEnvironment = .current
    ) {
        self.client = client
        self.environment = environment
    }

    /// The captured token, once APNs has answered.
    var deviceToken: APNSDeviceToken? {
        if case .registered(let token) = state { return token }
        return nil
    }

    /// Launch/foreground sync: re-register silently when permission already
    /// exists, otherwise reflect where the user left the permission.
    ///
    /// The authorization status is re-read **every** time, token in hand or
    /// not. A written-once state that stops revalidating is how a Host keeps
    /// an armed entry, and Settings keeps showing a green tick, for a device
    /// whose notifications the user switched off hours ago.
    func refresh() async {
        switch await client.authorizationStatus() {
        case .authorized, .provisional, .ephemeral:
            // A token captured this launch survives the re-read; APNs hands
            // out at most one per registration and re-registering would only
            // churn it.
            if case .registered = state { return }
            state = .waitingForToken
            client.registerForRemoteNotifications()
        case .denied:
            state = didRegisterThisLaunch ? .revoked : .denied
        case .notDetermined:
            state = .needsPermission
        @unknown default:
            state = .needsPermission
        }
    }

    /// The user-initiated step: show the iOS permission prompt, then register.
    func enable() async {
        do {
            if try await client.requestAuthorization() {
                state = .waitingForToken
                client.registerForRemoteNotifications()
            } else {
                state = .denied
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func deviceTokenDidArrive(_ tokenData: Data) {
        didRegisterThisLaunch = true
        state = .registered(APNSDeviceToken(tokenData: tokenData, environment: environment))
    }

    func registrationDidFail(_ error: any Error) {
        state = .failed(error.localizedDescription)
    }
}

/// UIKit shim: APNs delivers the device token only through
/// `UIApplicationDelegate` callbacks, so the SwiftUI app installs this via
/// `@UIApplicationDelegateAdaptor`. It owns the store so the callbacks have
/// somewhere to land before any view exists.
@MainActor
final class PushRegistrationDelegate: NSObject, UIApplicationDelegate {
    let registration = PushRegistrationStore()
    /// The windows Agent Notification taps land in (#74). Each window owns
    /// its own navigation router; this app-wide directory picks which one a
    /// tap drives, so it has to exist before any window does.
    let sceneDirectory: AgentSceneDirectory
    private let notificationCenterDelegate: AgentNotificationCenterDelegate

    /// The stores every window shares. Built on first use rather than here,
    /// so the Debug screenshot mode never constructs the production ones.
    private(set) lazy var appModel = HeelerAppModel(
        pushRegistration: registration, sceneDirectory: sceneDirectory)

    override init() {
        let directory = AgentSceneDirectory()
        sceneDirectory = directory
        notificationCenterDelegate = AgentNotificationCenterDelegate(directory: directory)
        super.init()
    }

    func application(
        _ application: UIApplication,
        willFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Apple requires the notification delegate installed before launch
        // finishes; otherwise a tap that cold-starts the app never reaches
        // didReceive and the killed-state deep link is lost.
        UNUserNotificationCenter.current().delegate = notificationCenterDelegate
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        registration.deviceTokenDidArrive(deviceToken)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: any Error
    ) {
        registration.registrationDidFail(error)
    }
}
