import GhosttyTerminal
import UIKit

/// herdr's desktop notifications, adopted on the iPad.
///
/// With `ui.toast.delivery = "terminal"` herdr stops drawing its own toast and
/// asks the outer terminal for a desktop notification instead (OSC 9 /
/// OSC 777). libghostty decodes that into the vendored
/// `TerminalSurfaceDesktopNotificationDelegate`, which the surface reaches by
/// casting whatever `delegate` it has — so the conformance can live here,
/// beside the screen that cares, rather than in the terminal view's own file.
/// `HeelerTerminalView` is already its own surface delegate, so nothing else
/// has to be wired for this to fire.
///
/// Everything after the decode is `TerminalDesktopNotificationRelay`'s: banner
/// while foregrounded, local notification otherwise.
extension HeelerTerminalView: TerminalSurfaceDesktopNotificationDelegate {
    func terminalDidRequestDesktopNotification(title: String, body: String) {
        TerminalDesktopNotificationRelay.shared.receive(title: title, body: body)
    }
}
