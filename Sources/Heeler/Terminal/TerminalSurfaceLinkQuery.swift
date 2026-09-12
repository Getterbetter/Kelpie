import CoreGraphics
import Foundation
import UIKit

/// Resolves a tap on a terminal cell in two steps, because a terminal carries
/// links two ways and only one of them is in the text.
///
/// ``TerminalLinkDetector`` reads the viewport's characters, which is
/// everything a bare `https://…` needs and nothing an OSC 8 hyperlink has:
/// Claude Code pins its artifact links below the input bar as
/// `ESC ] 8 ; ; <url> ESC \ title ESC ] 8 ; ; ESC \`, so the row holds a title
/// and the URL exists only in libghostty's hyperlink table. `ghostty.h` has no
/// link-at-point query, but the core hit-tests links wherever its own mouse is
/// put and reports what it found through `GHOSTTY_ACTION_MOUSE_OVER_LINK`.
///
/// So the text scan answers first — it is pure, cheap and already trusted —
/// and only a cell it cannot explain is put to the core.
///
/// **The core's half is not yet live.** libghostty reports a hovered link only
/// when the mouse mods match its link modifier — super on Apple platforms — and
/// every call that can carry mods (`TerminalSurface.sendMousePos`,
/// `sendMouseButton`, `sendKeyEvent`) is `internal` to the vendored package.
/// The one `open` member that moves the core's mouse, the context-menu hook,
/// hardcodes mods 0. Measured on the iPad: the move lands (the package logs
/// `surface mousePos … mods=0x0`) and `GHOSTTY_ACTION_MOUSE_OVER_LINK` never
/// fires, for an OSC 8 hyperlink and for a bare `https://` run alike, with
/// `link-url = true` and the surface focused. Unblocking it takes one member of
/// `Packages/GhosttyTerminal` becoming reachable — a vendored-package change,
/// which is Anthony's call — and nothing else here changes when it does.
enum TerminalSurfaceLinkQuery {
    /// `textScan` is the viewport answer for the tapped cell; `surfaceLink` is
    /// the core's hover hit test, asked at most once and only when the scan
    /// found nothing. Whatever the core reports is held to the same policy a
    /// scanned URL is — http(s) with a host, or nothing.
    static func match(
        at point: CGPoint,
        textScan: (CGPoint) -> TerminalLinkDetector.Match?,
        surfaceLink: (CGPoint) -> String?
    ) -> TerminalLinkDetector.Match? {
        if let match = textScan(point) { return match }
        guard let reported = surfaceLink(point),
            let url = TerminalLinkPolicy.url(for: reported)
        else { return nil }
        return .url(url)
    }

    /// A pointer-motion mouse report with no button held: `ESC [ < 35 ; c ; r M`
    /// under SGR tracking (DECSET 1006), `ESC [ M` with `Cb` 67 under legacy
    /// tracking (1000/1002/1003).
    ///
    /// This is the one byte sequence a link probe can provoke. With `?1003h` in
    /// force — Claude Code, codex and grok all set it — moving the core's mouse
    /// onto a cell is an event the remote application asked to hear about, and
    /// it must not hear about a question the app asked on its own behalf. The
    /// probe drops exactly this shape while it is in flight. Nothing Kelpie
    /// reports itself can be mistaken for one: every ``TerminalMouseEncoding``
    /// report carries a real button, its drag motions included.
    static func isButtonlessMotionReport(_ data: Data) -> Bool {
        // 3 is "no button" in both encodings, +32 marks motion.
        let motionWithoutButton = TerminalMouseEncoding.motionFlag + 3
        if data.count == 6 {
            let bytes = Array(data)
            if bytes[0] == 0x1B, bytes[1] == 0x5B, bytes[2] == 0x4D,
                bytes[3] == UInt8(motionWithoutButton + 32)
            {
                return true
            }
        }
        guard let text = String(data: data, encoding: .utf8),
            text.hasPrefix("\u{1B}[<\(motionWithoutButton);"),
            text.hasSuffix("M") || text.hasSuffix("m")
        else { return false }
        let fields = text.dropFirst(3).dropLast().split(separator: ";")
        return fields.count == 3 && fields.allSatisfy { $0.allSatisfy(\.isNumber) }
    }
}

/// The delegate the link probe's context-menu interaction holds.
///
/// The probe reaches libghostty's hit test through the one `open` member of the
/// vendored terminal view that moves the core's mouse — its context-menu hook —
/// and that hook ignores the interaction it is handed. The interaction is never
/// installed on a view, so nothing ever asks this delegate anything; it exists
/// only so the terminal is not its own interaction's delegate.
@MainActor
final class TerminalLinkProbeMenuDelegate: NSObject, UIContextMenuInteractionDelegate {
    func contextMenuInteraction(
        _: UIContextMenuInteraction,
        configurationForMenuAtLocation _: CGPoint
    ) -> UIContextMenuConfiguration? {
        nil
    }
}
