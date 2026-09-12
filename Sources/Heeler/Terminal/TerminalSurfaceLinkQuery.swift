import CoreGraphics
import Foundation

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
/// The core's half needs the link modifier: libghostty reports a hovered link
/// only when the mouse mods match it, so the probe moves the core's mouse with
/// shift+super, then super, through
/// `TerminalSurface.sendMousePos(x:y:modifiers:)` — the one sanctioned patch to
/// the vendored package, written up in
/// `Packages/GhosttyTerminal/KELPIE-PATCHES.md`. Measured on the iPad: mods 0
/// reports nothing at all, for an OSC 8 hyperlink and a bare `https://` run
/// alike, and shift+super is what answers on a screen with mouse tracking on.
/// See ``HeelerTerminalView/surfaceLinkURL(at:)``.
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
    /// tracking (1000/1002/1003), each plus the modifier bits the probe's own
    /// shift adds — measured on the iPad as SGR `Cb` 39.
    ///
    /// This is the one byte sequence a link probe can provoke. With `?1003h` in
    /// force — Claude Code, codex and grok all set it — moving the core's mouse
    /// onto a cell is an event the remote application asked to hear about, and
    /// it must not hear about a question the app asked on its own behalf. The
    /// probe drops exactly this shape while it is in flight. Nothing Kelpie
    /// reports itself can be mistaken for one: every ``TerminalMouseEncoding``
    /// report carries a real button, its drag motions included.
    static func isButtonlessMotionReport(_ data: Data) -> Bool {
        // 3 is "no button" in both encodings, +32 marks motion. Shift, alt and
        // ctrl ride on the same byte as 4, 8 and 16: the probe holds shift — it
        // is what makes the core hit-test a link while the application has the
        // mouse (see `HeelerTerminalView.linkProbeModifiers`) — so a report
        // carrying those bits is still the probe's own. A real Kelpie report
        // always names a button (0, 1, 2, 64, 65), never 3, so none of these
        // codes can be one.
        let motionWithoutButton = TerminalMouseEncoding.motionFlag + 3
        let modifierBits = 4 | 8 | 16
        func isButtonless(_ code: Int, base: Int) -> Bool {
            code >= base && (code - base) & ~modifierBits == 0
        }
        if data.count == 6 {
            let bytes = Array(data)
            if bytes[0] == 0x1B, bytes[1] == 0x5B, bytes[2] == 0x4D,
                isButtonless(Int(bytes[3]), base: motionWithoutButton + 32)
            {
                return true
            }
        }
        guard let text = String(data: data, encoding: .utf8),
            text.hasPrefix("\u{1B}[<"),
            text.hasSuffix("M") || text.hasSuffix("m")
        else { return false }
        let fields = text.dropFirst(3).dropLast().split(separator: ";")
        guard fields.count == 3, fields.allSatisfy({ $0.allSatisfy(\.isNumber) }),
            let code = Int(fields[0])
        else { return false }
        return isButtonless(code, base: motionWithoutButton)
    }
}
