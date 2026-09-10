import Foundation
import Observation
import UIKit

/// The app-wide terminal font size, in points. Pinch-to-zoom on an Attach
/// terminal writes here, so a zoom survives leaving the screen and applies to
/// every terminal the app opens afterwards.
@MainActor
@Observable
final class TerminalZoomSettings {
    /// The phone's default, and the floor every other default is compared
    /// against.
    static let defaultFontSize: Float = 8
    /// An iPad window is wide enough that 8 pt reads as a squint; herdr's own
    /// sidebar, tabs and panes all still fit at 12. Only the *unzoomed*
    /// default differs — once the user pinches, the stored value is the value
    /// on every device.
    static let regularWidthDefaultFontSize: Float = 12
    /// Whole points only. The low end goes all the way down to libghostty's
    /// own minimum: 4 pt is unreadable, but it fits a wide TUI on screen, and
    /// zooming out for the shape of a layout is a real thing people do.
    static let range: ClosedRange<Float> = 4...32

    private static let defaultsKey = "terminal-font-size"

    private(set) var fontSize: Float
    @ObservationIgnored private nonisolated(unsafe) let defaults: UserDefaults

    init(
        defaults: UserDefaults = .standard,
        idiom: UIUserInterfaceIdiom = UIDevice.current.userInterfaceIdiom
    ) {
        self.defaults = defaults
        let stored =
            defaults.object(forKey: Self.defaultsKey) == nil
            ? Self.defaultFontSize(for: idiom)
            : defaults.float(forKey: Self.defaultsKey)
        fontSize = Self.clamped(stored)
    }

    /// The size a device that has never been pinched starts at.
    static func defaultFontSize(for idiom: UIUserInterfaceIdiom) -> Float {
        idiom == .pad ? regularWidthDefaultFontSize : defaultFontSize
    }

    func setFontSize(_ size: Float) {
        let clamped = Self.clamped(size)
        guard clamped != fontSize else { return }
        fontSize = clamped
        defaults.set(clamped, forKey: Self.defaultsKey)
    }

    func adjust(by points: Float) {
        setFontSize(fontSize + points)
    }

    /// The single clamping policy, shared by the settings control, pinch-zoom,
    /// and the keyboard shortcut so they can never disagree on a boundary.
    static func clamped(_ size: Float) -> Float {
        guard size.isFinite else { return defaultFontSize }
        return min(max(size.rounded(), range.lowerBound), range.upperBound)
    }
}
