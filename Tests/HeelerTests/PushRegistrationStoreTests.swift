import Foundation
import Synchronization
import Testing
import UserNotifications

@testable import Heeler

/// State machine of the app-side push bootstrap (#71): permission request,
/// APNs registration, and token capture, driven through a scripted stand-in
/// for the UNUserNotificationCenter/UIApplication boundary (the only part
/// that cannot run for real in tests).
@MainActor
@Suite("Push registration store")
struct PushRegistrationStoreTests {
    private let client = ScriptedPushRegistrationClient()

    private func makeStore(environment: APNSEnvironment = .sandbox) -> PushRegistrationStore {
        PushRegistrationStore(client: client, environment: environment)
    }

    @Test func enableRequestsPermissionThenRegistersForAToken() async {
        client.grantResult = .success(true)
        let store = makeStore()

        await store.enable()

        #expect(store.state == .waitingForToken)
        #expect(client.registerCallCount == 1)
    }

    @Test func deviceTokenArrivalCapturesLowercaseHexAndEnvironment() async {
        client.grantResult = .success(true)
        let store = makeStore(environment: .sandbox)
        await store.enable()

        store.deviceTokenDidArrive(Data([0xDE, 0xAD, 0xBE, 0xEF]))

        let token = APNSDeviceToken(hex: "deadbeef", environment: .sandbox)
        #expect(store.state == .registered(token))
        #expect(store.deviceToken == token)
    }

    @Test func refusedPermissionReadsAsDenied() async {
        client.grantResult = .success(false)
        let store = makeStore()

        await store.enable()

        #expect(store.state == .denied)
        #expect(client.registerCallCount == 0)
    }

    @Test func permissionRequestFailureSurfaces() async {
        client.grantResult = .failure(ScriptedPushRegistrationClient.Failure())
        let store = makeStore()

        await store.enable()

        guard case .failed = store.state else {
            Issue.record("expected .failed, got \(store.state)")
            return
        }
    }

    @Test func registrationFailureSurfaces() async {
        client.grantResult = .success(true)
        let store = makeStore()
        await store.enable()

        store.registrationDidFail(ScriptedPushRegistrationClient.Failure())

        guard case .failed = store.state else {
            Issue.record("expected .failed, got \(store.state)")
            return
        }
    }

    /// APNs tokens can change between launches, so an already-authorized app
    /// silently re-registers on refresh instead of waiting for the user to
    /// tap anything again.
    @Test func refreshWhenAuthorizedRegistersSilently() async {
        client.status = .authorized
        let store = makeStore()

        await store.refresh()

        #expect(store.state == .waitingForToken)
        #expect(client.registerCallCount == 1)
    }

    @Test func refreshWhenUndeterminedAsksForThePermissionStep() async {
        client.status = .notDetermined
        let store = makeStore()

        await store.refresh()

        #expect(store.state == .needsPermission)
        #expect(client.registerCallCount == 0)
    }

    @Test func refreshWhenDeniedReadsAsDenied() async {
        client.status = .denied
        let store = makeStore()

        await store.refresh()

        #expect(store.state == .denied)
    }

    /// A foreground refresh must not throw away a token that already arrived
    /// this launch — but it must still re-read the permission that token
    /// depends on.
    @Test func refreshKeepsAnAlreadyCapturedTokenAndStillRereadsPermission() async {
        client.status = .authorized
        client.grantResult = .success(true)
        let store = makeStore()
        await store.enable()
        store.deviceTokenDidArrive(Data([0x01]))

        await store.refresh()

        #expect(store.state == .registered(APNSDeviceToken(hex: "01", environment: .sandbox)))
        #expect(client.registerCallCount == 1)
        #expect(client.statusCallCount == 1, "the early return used to skip the status read")
    }

    /// The bug the early return hid: permission switched off in the Settings
    /// app while the app held a token left Settings showing a green tick, the
    /// Host entry armed, and every push dropped by iOS.
    @Test func refreshAfterPermissionIsWithdrawnReadsAsRevoked() async {
        client.status = .authorized
        client.grantResult = .success(true)
        let store = makeStore()
        await store.enable()
        store.deviceTokenDidArrive(Data([0x01]))

        client.status = .denied
        await store.refresh()

        #expect(store.state == .revoked)
        #expect(store.deviceToken == nil, "nothing may keep writing that token to a Host")
    }

    /// Withdrawal is distinct from a first-run refusal, which has no token
    /// behind it and nothing registered anywhere.
    @Test func aFirstRunRefusalStaysDeniedNotRevoked() async {
        client.status = .denied
        let store = makeStore()

        await store.refresh()

        #expect(store.state == .denied)
    }

    @Test func permissionRestoredAfterARevocationRegistersAgain() async {
        client.status = .authorized
        client.grantResult = .success(true)
        let store = makeStore()
        await store.enable()
        store.deviceTokenDidArrive(Data([0x01]))
        client.status = .denied
        await store.refresh()

        client.status = .authorized
        await store.refresh()

        #expect(store.state == .waitingForToken)
        #expect(client.registerCallCount == 2)
    }

    // MARK: APNs environment

    /// The environment comes from the entitlement the install was *signed*
    /// with, never from the build configuration: a Release build on a
    /// development profile gets sandbox tokens, and writing `production`
    /// beside one points every push at the wrong APNs host.
    @Test func theEnvironmentComesFromTheProvisioningProfilesEntitlement() {
        #expect(
            APNSEnvironment.resolved(provisioningProfile: profile(apsEnvironment: "development"))
                == .sandbox)
        #expect(
            APNSEnvironment.resolved(provisioningProfile: profile(apsEnvironment: "production"))
                == .production)
    }

    /// An App Store install carries no readable profile; the build
    /// configuration is the only thing left to go on.
    @Test func anUnreadableProfileFallsBackToTheBuildConfiguration() {
        #expect(APNSEnvironment.resolved(provisioningProfile: nil) == .compiled)
        #expect(
            APNSEnvironment.resolved(provisioningProfile: Data("not a profile".utf8))
                == .compiled)
        #expect(
            APNSEnvironment.resolved(provisioningProfile: profile(apsEnvironment: nil))
                == .compiled)
    }

    /// A `.mobileprovision` is a CMS-signed blob with an XML plist in the
    /// middle; this is that shape, binary noise included.
    private func profile(apsEnvironment: String?) -> Data {
        let entitlements =
            apsEnvironment.map {
                "<key>aps-environment</key><string>\($0)</string>"
            } ?? "<key>application-identifier</key><string>8JQWBQKEXX.TME.Kelpie</string>"
        let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <plist version="1.0"><dict><key>Name</key><string>Kelpie</string>\
            <key>Entitlements</key><dict>\(entitlements)</dict></dict></plist>
            """
        return Data([0x30, 0x82, 0x00, 0x00]) + Data(plist.utf8)
            + Data([0x00, 0xFF, 0x31, 0x82])
    }
}

/// Scripted stand-in for the system push boundary.
final class ScriptedPushRegistrationClient: PushRegistrationClient {
    struct Failure: Error {}

    private let scriptedStatus = Mutex<UNAuthorizationStatus>(.notDetermined)
    private let scriptedGrant = Mutex<Result<Bool, any Error>>(.success(false))
    private let registerCalls = Mutex<Int>(0)
    private let statusCalls = Mutex<Int>(0)

    var status: UNAuthorizationStatus {
        get { scriptedStatus.withLock { $0 } }
        set { scriptedStatus.withLock { $0 = newValue } }
    }

    var grantResult: Result<Bool, any Error> {
        get { scriptedGrant.withLock { $0 } }
        set { scriptedGrant.withLock { $0 = newValue } }
    }

    var registerCallCount: Int {
        registerCalls.withLock { $0 }
    }

    /// How many times the store re-read permission; a store that stops
    /// reading is a store that cannot notice a revocation.
    var statusCallCount: Int {
        statusCalls.withLock { $0 }
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        statusCalls.withLock { $0 += 1 }
        return status
    }

    func requestAuthorization() async throws -> Bool {
        try grantResult.get()
    }

    func registerForRemoteNotifications() {
        registerCalls.withLock { $0 += 1 }
    }
}
