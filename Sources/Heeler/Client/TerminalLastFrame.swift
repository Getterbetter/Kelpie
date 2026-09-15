import SwiftUI
import UIKit

/// The last frame a terminal surface drew before the app left the
/// foreground.
///
/// A return from the background usually means a reconnect: the Host tore the
/// SSH connection down after the grace period, so the Client execs a fresh
/// `herdr` and mounts a fresh Ghostty surface, which is blank until that
/// process paints. Holding the old surface's snapshot over the new one for
/// that gap makes the return look like the app never left, and it is
/// released as soon as the new surface has output of its own (Open item 35).
///
/// Captured with `snapshotView(afterScreenUpdates:)`, the one snapshot path
/// that carries a Metal layer's presented drawable; `drawHierarchy` does not.
@MainActor
struct TerminalLastFrame {
    let view: UIView

    /// Nil when there is nothing on screen to keep: the terminal is not
    /// mounted in a window, or UIKit declines the snapshot.
    static func capture(_ terminal: UIView?) -> TerminalLastFrame? {
        guard let terminal, terminal.window != nil,
            let snapshot = terminal.snapshotView(afterScreenUpdates: false)
        else { return nil }
        return TerminalLastFrame(view: snapshot)
    }
}

/// Hosts a ``TerminalLastFrame`` over the live terminal, anchored top-left at
/// its captured size. The keyboard inset can change the terminal's height
/// between capture and release; herdr laid the old frame out for the old
/// size, so it is clipped rather than stretched.
struct TerminalLastFrameView: UIViewRepresentable {
    let lastFrame: TerminalLastFrame

    func makeUIView(context: Context) -> UIView {
        let host = UIView()
        host.isUserInteractionEnabled = false
        host.clipsToBounds = true
        mount(lastFrame.view, in: host)
        return host
    }

    func updateUIView(_ host: UIView, context: Context) {
        guard lastFrame.view.superview !== host else { return }
        host.subviews.forEach { $0.removeFromSuperview() }
        mount(lastFrame.view, in: host)
    }

    private func mount(_ snapshot: UIView, in host: UIView) {
        snapshot.frame.origin = .zero
        snapshot.autoresizingMask = []
        host.addSubview(snapshot)
    }
}
