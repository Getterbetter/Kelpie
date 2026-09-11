import UIKit

/// The visual acknowledgement of a one-finger hold.
///
/// A hold is the touch spelling of a right click, and on iPhone the medium
/// impact haptic is what tells the user it was recognized. iPads have no
/// Taptic Engine, so that feedback is silent on the device Kelpie is built
/// for: the hold either works or appears to do nothing at all. A translucent
/// disc under the finger says the same thing with light — it appears when the
/// press is recognized, follows the finger through a drag, and fades when the
/// finger lifts.
///
/// Purely decorative: it never takes a touch, so the hold, the drag and every
/// recognizer underneath carry on exactly as they would without it.
@MainActor
final class TerminalHoldCueView: UIView {
    static let diameter: CGFloat = 44

    private static let appearDuration: TimeInterval = 0.12
    private static let fadeDuration: TimeInterval = 0.15
    private static let appearScale: CGFloat = 0.6

    /// Whether a fade-out is running, so a hold that begins again during it
    /// re-shows rather than being removed out from under itself.
    private var isFading = false

    init() {
        super.init(
            frame: CGRect(x: 0, y: 0, width: Self.diameter, height: Self.diameter))
        isUserInteractionEnabled = false
        layer.cornerRadius = Self.diameter / 2
        layer.borderWidth = 1.5
        alpha = 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    /// Shows the cue centred on `point` in `container`'s coordinates, scaling
    /// in from a smaller disc so the hold reads as something that just
    /// happened rather than something that was always there.
    func show(at point: CGPoint, in container: UIView) {
        isFading = false
        layer.removeAllAnimations()
        applyColors(from: container.tintColor)
        if superview !== container {
            removeFromSuperview()
            container.addSubview(self)
        }
        container.bringSubviewToFront(self)
        center = point
        alpha = 0
        transform = CGAffineTransform(scaleX: Self.appearScale, y: Self.appearScale)
        UIView.animate(
            withDuration: Self.appearDuration,
            delay: 0,
            options: [.beginFromCurrentState, .curveEaseOut]
        ) {
            self.alpha = 1
            self.transform = .identity
        }
    }

    /// Follows the finger. No animation: the disc is the finger's position,
    /// and a lag would read as the drag itself lagging.
    func move(to point: CGPoint) {
        guard superview != nil else { return }
        center = point
    }

    /// Fades out and removes itself. `animated: false` for a teardown that
    /// cannot wait, such as the terminal leaving its window.
    func hide(animated: Bool = true) {
        guard superview != nil else { return }
        guard animated else {
            layer.removeAllAnimations()
            isFading = false
            alpha = 0
            removeFromSuperview()
            return
        }
        isFading = true
        UIView.animate(
            withDuration: Self.fadeDuration,
            delay: 0,
            options: [.beginFromCurrentState, .curveEaseIn]
        ) {
            self.alpha = 0
        } completion: { _ in
            // A hold that began again mid-fade owns the cue now.
            guard self.isFading else { return }
            self.isFading = false
            self.removeFromSuperview()
        }
    }

    private func applyColors(from tint: UIColor?) {
        let color = tint ?? .tintColor
        backgroundColor = color.withAlphaComponent(0.35)
        layer.borderColor = color.withAlphaComponent(0.85).cgColor
    }
}
