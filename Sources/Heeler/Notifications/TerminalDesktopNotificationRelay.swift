import Foundation
import UIKit
import UserNotifications

/// One desktop notification the remote terminal asked for, normalized for
/// display. herdr sets `ui.toast.delivery = "terminal"` and the agent or the
/// shell emits OSC 9 / OSC 777; libghostty decodes it into a title and a body,
/// either of which can be empty.
struct TerminalDesktopNotification: Equatable, Sendable {
    let title: String
    let body: String

    /// OSC 9 carries one string and nothing else, so the common case arrives
    /// as an empty title with the whole message in the body — and a banner
    /// whose loud line is blank reads as broken. Promote the body in that
    /// case, and drop a notification that says nothing at all.
    static func normalized(title: String, body: String) -> TerminalDesktopNotification? {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return TerminalDesktopNotification(title: title, body: body) }
        guard !body.isEmpty else { return nil }
        return TerminalDesktopNotification(title: body, body: "")
    }
}

/// The system boundary for a *local* notification: permission plus delivery.
/// A protocol so the relay's decisions are testable — real notification
/// presentation is not automatable, exactly as `PushRegistrationClient` says.
protocol LocalNotificationScheduling: Sendable {
    func authorizationStatus() async -> UNAuthorizationStatus
    /// Returns whether permission was granted.
    func requestAuthorization() async -> Bool
    func schedule(title: String, body: String) async
}

struct SystemLocalNotificationScheduler: LocalNotificationScheduling {
    func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func schedule(title: String, body: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        if !body.isEmpty { content.body = body }
        content.sound = .default
        // No `userInfo` envelope, so `AgentNotificationRouting` resolves no
        // target and the tap routes nowhere — which is the whole contract:
        // tapping brings the app forward and leaves the screen alone.
        let request = UNNotificationRequest(
            identifier: "terminal-desktop-\(UUID().uuidString)",
            content: content,
            trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}

/// Delivers the terminal's own desktop notifications to the iPad: the in-app
/// banner while the app is foregrounded, a local notification while it is not.
///
/// A shared instance because the receiver is the terminal view itself — a
/// UIKit view adopting the vendored delegate has nowhere to hold an injected
/// dependency — and because there is exactly one client screen at a time.
/// `connect(bannerStore:)` is called from the app root, so tests construct
/// their own relay instead.
@MainActor
final class TerminalDesktopNotificationRelay {
    static let shared = TerminalDesktopNotificationRelay()

    private weak var bannerStore: AgentNotificationBannerStore?
    private let scheduler: any LocalNotificationScheduling
    private let applicationState: @MainActor () -> UIApplication.State
    /// The permission prompt is asked for once per launch at most: a terminal
    /// that notifies in a loop must not turn into a prompt loop.
    private var didRequestAuthorization = false

    init(
        scheduler: any LocalNotificationScheduling = SystemLocalNotificationScheduler(),
        applicationState: @escaping @MainActor () -> UIApplication.State = {
            UIApplication.shared.applicationState
        }
    ) {
        self.scheduler = scheduler
        self.applicationState = applicationState
    }

    /// The banner surface, held weakly: the store belongs to the app root and
    /// outlives every terminal, but the relay must not be what keeps it alive.
    func connect(bannerStore: AgentNotificationBannerStore) {
        self.bannerStore = bannerStore
    }

    /// A terminal asked for a desktop notification. Foreground goes to the
    /// in-app banner — the same one Agent Notifications use, so the app never
    /// shows two kinds of banner — and anything else to the notification
    /// centre.
    func receive(title: String, body: String) {
        guard let notification = TerminalDesktopNotification.normalized(title: title, body: body)
        else { return }
        guard applicationState() != .active else {
            bannerStore?.present(notification)
            return
        }
        Task { await deliverLocally(notification) }
    }

    private func deliverLocally(_ notification: TerminalDesktopNotification) async {
        switch await scheduler.authorizationStatus() {
        case .authorized, .provisional, .ephemeral:
            break
        case .notDetermined:
            guard !didRequestAuthorization else { return }
            didRequestAuthorization = true
            guard await scheduler.requestAuthorization() else { return }
        default:
            return
        }
        await scheduler.schedule(title: notification.title, body: notification.body)
    }
}
