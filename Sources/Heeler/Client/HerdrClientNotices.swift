import Foundation
import Observation

/// One-line notices the root screen shows over the Console cover.
///
/// Two things need to say something to the user from outside the view tree,
/// and neither has an owner that can reach it:
///
/// * an Agent Notification tap whose envelope this device cannot read — an
///   unknown key id, or a Notification Key lost to a reinstall while the
///   Host's stale entry still pushes. `AgentNotificationRouter.open(nil)`
///   sets `path = []`, which on Kelpie's root is not a change at all, so the
///   tap did literally nothing (N5). The router's contract is "falling back
///   always means the Console, quietly"; this is what makes the quiet part
///   land somewhere.
/// * the Console hand-off timing out: a Transport serves one Attach channel
///   at a time, so the Client lets go before the cover comes up, and a
///   teardown that does not return within its deadline means an Agent Attach
///   may be refused (S4).
///
/// A single shared inbox rather than an injected store: the notification
/// delegate is a `UNUserNotificationCenterDelegate` built at launch, with no
/// path to anything SwiftUI owns, and threading one through every screen to
/// deliver one line of copy would cost more than it explains.
@MainActor
@Observable
final class HerdrClientNoticeStore {
    enum Notice: Equatable, Identifiable {
        /// A tapped notification this device could not decrypt.
        case unreadableNotification
        /// The Client did not hand its Attach channel back in time.
        case consoleHandoffTimedOut

        var id: Self { self }

        var message: String {
            switch self {
            case .unreadableNotification:
                "A notification arrived that this device could not read; re-pair or check notification settings."
            case .consoleHandoffTimedOut:
                "Kelpie could not hand this Host's terminal over in time; agent terminals may refuse to open."
            }
        }

        var symbol: String {
            switch self {
            case .unreadableNotification: "bell.badge.slash"
            case .consoleHandoffTimedOut: "exclamationmark.triangle"
            }
        }

        /// Whether the notice can be acted on as well as dismissed. Only the
        /// hand-off has anything to retry — the unreadable envelope is gone.
        var isRetryable: Bool {
            switch self {
            case .unreadableNotification: false
            case .consoleHandoffTimedOut: true
            }
        }
    }

    /// The one seam a delegate outside the view tree posts to. The root
    /// screen reads `notice`, shows it over the Console, and clears it.
    static let shared = HerdrClientNoticeStore()

    private(set) var notice: Notice?

    /// A notice posted while the Console is not on screen still has to be
    /// shown, because both notices are *about* the Console: the root presents
    /// the cover on this, then renders `notice` over it.
    private(set) var requestsConsole = false

    init() {}

    func post(_ notice: Notice, presentingConsole: Bool = true) {
        self.notice = notice
        if presentingConsole { requestsConsole = true }
    }

    func consoleWasPresented() { requestsConsole = false }

    func dismiss() {
        notice = nil
        requestsConsole = false
    }
}
