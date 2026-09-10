import GameController
import Observation

/// Whether a hardware keyboard is attached right now.
///
/// The app has no other way to ask: UIKit only ever reports the *software*
/// keyboard's frame (`TerminalKeyboardInset`), which is zero both when a
/// hardware keyboard is attached and when nothing has focus. GameController's
/// coalesced keyboard is the one public answer, and it changes live — a Magic
/// Keyboard is undocked mid-session as often as it is attached.
@MainActor
@Observable
final class HardwareKeyboardObserver {
    private(set) var isConnected: Bool
    @ObservationIgnored private let center: NotificationCenter
    /// Held only so they can be removed when this object goes. `deinit` is
    /// nonisolated and nothing else ever touches them, so the unchecked
    /// spelling is the honest one.
    @ObservationIgnored private nonisolated(unsafe) var observers: [any NSObjectProtocol] = []

    /// `isConnected` is injectable so tests (and previews) can state the
    /// answer instead of depending on the host machine's keyboard.
    init(
        center: NotificationCenter = .default,
        isConnected: Bool = GCKeyboard.coalesced != nil
    ) {
        self.center = center
        self.isConnected = isConnected
        observers = [
            observe(.GCKeyboardDidConnect, connected: true),
            observe(.GCKeyboardDidDisconnect, connected: false),
        ]
    }

    deinit {
        for observer in observers { center.removeObserver(observer) }
    }

    private func observe(
        _ name: Notification.Name, connected: Bool
    ) -> any NSObjectProtocol {
        let observer = center.addObserver(
            forName: name, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                // One keyboard leaving while another stays attached still
                // leaves a coalesced keyboard behind, so a disconnect re-reads
                // rather than trusting its own edge. Tests have no
                // GameController state, so the re-read is simply nil there.
                self?.isConnected = connected || GCKeyboard.coalesced != nil
            }
        }
        return observer
    }
}
