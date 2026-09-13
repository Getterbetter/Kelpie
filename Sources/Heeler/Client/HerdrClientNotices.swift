import Foundation
import Observation

/// One-line notices the root screen shows, over whichever of its two screens
/// is on top.
///
/// Two things need to say something to the user from outside the view tree,
/// and neither has an owner that can reach it:
///
/// * an Agent Notification tap whose envelope this device cannot read — an
///   unknown key id, or a Notification Key lost to a reinstall while the
///   Host's stale entry still pushes. It resolves to no Host, so there is
///   nothing for the tap to land on and it would otherwise do literally
///   nothing (N5). The router's contract is "falling back always means
///   somewhere, quietly"; this is what makes the quiet part land.
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
    /// screen reads `notice`, draws it over the screen that is up, and
    /// clears it.
    static let shared = HerdrClientNoticeStore()

    private(set) var notice: Notice?

    init() {}

    func post(_ notice: Notice) {
        self.notice = notice
    }

    func dismiss() {
        notice = nil
    }
}
