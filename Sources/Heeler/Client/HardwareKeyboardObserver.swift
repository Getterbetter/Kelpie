import GameController
import Observation
import UIKit

/// Whether a hardware keyboard is attached right now.
///
/// The app has no other way to ask: UIKit only ever reports the *software*
/// keyboard's frame (`TerminalKeyboardInset`), which is zero both when a
/// hardware keyboard is attached and when nothing has focus. GameController's
/// coalesced keyboard is the one public answer, and it changes live — a Magic
/// Keyboard is undocked mid-session as often as it is attached.
///
/// The notifications are not the whole answer. A Magic Keyboard docked or
/// undocked while Kelpie is suspended posts `GCKeyboardDidConnect` /
/// `Disconnect` to a process that is not running them, and nothing re-reads
/// the coalesced keyboard on the way back — so the app could return holding a
/// stale answer, with the key bar, `claimsKeyboard`, scroll-to-dismiss and the
/// Console's input mode all wrong at once (round 12, finding 3). Every
/// activation re-reads the live answer instead, and the edges only ever
/// corroborate it.
@MainActor
@Observable
final class HardwareKeyboardObserver {
    private(set) var isConnected: Bool
    @ObservationIgnored private let center: NotificationCenter
    /// The live answer, asked afresh rather than remembered. Injectable so
    /// tests (and previews) can state it instead of depending on the host
    /// machine's keyboard.
    @ObservationIgnored private let probe: @MainActor () -> Bool
    /// Held only so they can be removed when this object goes. `deinit` is
    /// nonisolated and nothing else ever touches them, so the unchecked
    /// spelling is the honest one.
    @ObservationIgnored private nonisolated(unsafe) var observers: [any NSObjectProtocol] = []

    /// The notifications that mean "the app is on screen again, and whatever
    /// happened while it was not has already happened". Both are posted:
    /// `didBecomeActive` for the app, `didActivate` for each scene, which is
    /// the one that fires for a window brought forward in Stage Manager.
    private static let activationNotifications: [Notification.Name] = [
        UIApplication.didBecomeActiveNotification,
        UIScene.didActivateNotification,
    ]

    init(
        center: NotificationCenter = .default,
        probe: @escaping @MainActor () -> Bool = { GCKeyboard.coalesced != nil }
    ) {
        self.center = center
        self.probe = probe
        isConnected = probe()
        observers =
            [
                observe(.GCKeyboardDidConnect, connected: true),
                observe(.GCKeyboardDidDisconnect, connected: false),
            ] + Self.activationNotifications.map { observe($0, connected: false) }
    }

    deinit {
        for observer in observers { center.removeObserver(observer) }
    }

    /// Re-reads the live answer. Called on every activation, and available to
    /// anything else that has reason to believe the answer moved unobserved.
    func refresh() {
        let answer = probe()
        guard isConnected != answer else { return }
        isConnected = answer
    }

    private func observe(
        _ name: Notification.Name, connected: Bool
    ) -> any NSObjectProtocol {
        let observer = center.addObserver(
            forName: name, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // One keyboard leaving while another stays attached still
                // leaves a coalesced keyboard behind, so a disconnect re-reads
                // rather than trusting its own edge — and so does an
                // activation, which carries no edge of its own.
                let answer = connected || self.probe()
                guard self.isConnected != answer else { return }
                self.isConnected = answer
            }
        }
        return observer
    }
}
