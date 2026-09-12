import Foundation
import UserNotifications

/// Thin UNUserNotificationCenter delegate (#74). Every decision is pure and
/// unit-tested — `AgentNotificationRouting` resolves the push,
/// `AgentDeepLinkPolicy` picks the window, and each window's MainActor
/// `AgentNotificationRouter` holds its navigation state — because real iOS
/// notification presentation is not automatable (spec #68).
///
/// The completion-handler forms are deliberate: UIKit invokes these callbacks
/// on a background queue, and the tap completion drives main-thread-only
/// UIKit state restoration (SIGABRT otherwise). The async forms hand the
/// completion to whatever executor the continuation resumes on, so only the
/// handler forms let us pin it to the main thread. The push is resolved on
/// the callback queue; only the Sendable target crosses.
final class AgentNotificationCenterDelegate: NSObject, UNUserNotificationCenterDelegate,
    @unchecked Sendable
{
    private let directory: AgentSceneDirectory
    private let loadKeys: @Sendable () -> [NotificationKeyRecord]
    private let bannerStore: @MainActor @Sendable () -> AgentNotificationBannerStore?

    init(
        directory: AgentSceneDirectory,
        loadKeys: @escaping @Sendable () -> [NotificationKeyRecord] = {
            (try? NotificationKeyStore().allRecords()) ?? []
        },
        bannerStore: @escaping @MainActor @Sendable () -> AgentNotificationBannerStore? = {
            AgentNotificationBannerPresenter.store
        }
    ) {
        self.directory = directory
        self.loadKeys = loadKeys
        self.bannerStore = bannerStore
    }

    /// A push delivered while the app is foregrounded (#77, revised round
    /// 12b). It used to return `[]` unconditionally, on the assumption that
    /// the Console's live event stream would announce the same transition
    /// through the in-app banner. The two pipelines are independent and
    /// neither knows about the other: whenever the banner's own gates do not
    /// fire — the Host's confirmed flags unknown, the Console reconnecting,
    /// its list not yet synced — the one message that *did* arrive was
    /// thrown away, and the user saw nothing at all.
    ///
    /// So the push is always presented: in-app when it resolves to an Agent
    /// (the banner store de-duplicates it against a transition it just
    /// announced itself), through iOS otherwise. Only the Agent the user is
    /// actually looking at stays silent.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions)
            -> Void
    ) {
        // Resolved on the callback queue; only Sendable values cross. The
        // copy is the service extension's: decrypted and rewritten there, or
        // the relay's generic fallback when it could not be.
        let content = notification.request.content
        let target = AgentNotificationRouting.target(
            userInfo: content.userInfo, keys: loadKeys())
        let alert = AgentNotificationAlert(title: content.title, body: content.body)
        let complete = UncheckedSendable(completionHandler)
        Task { @MainActor [directory, bannerStore] in
            let store = bannerStore()
            switch AgentNotificationRouting.foregroundPresentation(
                target: target, presentedAgent: directory.keyScenePresentedAgent,
                canPresentInApp: store != nil)
            {
            case .inAppBanner(let target):
                store?.presentPush(target: target, alert: alert)
                complete.value([])
            case .suppressed:
                complete.value([])
            case .systemBanner:
                complete.value([.banner, .list, .sound])
            }
        }
    }

    /// A tap (the default action) deep-links to the Agent's Attach through
    /// the single-window rule; explicit dismissal routes nowhere.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let isDefaultTap = response.actionIdentifier == UNNotificationDefaultActionIdentifier
        let target: AgentNotificationTarget? =
            isDefaultTap
            ? AgentNotificationRouting.target(
                userInfo: response.notification.request.content.userInfo, keys: loadKeys())
            : nil
        let complete = UncheckedSendable(completionHandler)
        Task { @MainActor [directory] in
            if isDefaultTap {
                directory.open(target)
                // `open(nil)` sets `path = []`, which on Kelpie's root is not
                // a change at all — the tap would otherwise do literally
                // nothing. Say so, and present the Console behind the notice
                // (N5).
                if target == nil {
                    HerdrClientNoticeStore.shared.post(.unreadableNotification)
                }
            }
            complete.value()
        }
    }
}

/// Carries UIKit's non-Sendable completion handlers to the main actor; each
/// is invoked exactly once there.
private struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
