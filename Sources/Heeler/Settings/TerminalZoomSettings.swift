import CoreGraphics
import Foundation
import Observation
import UIKit

/// The app-wide terminal font size, in points. Pinch-to-zoom on an Attach
/// terminal writes here, so a zoom survives leaving the screen and applies to
/// every terminal the app opens afterwards.
///
/// What is persisted is the user's *offset* from the default, not the size
/// itself. On an iPad the default follows the window's width — a Split View
/// third is not a full screen, and 12 pt there costs herdr its sidebar — and
/// an offset is the only shape that lets the default move underneath a chosen
/// zoom without wiping it.
@MainActor
@Observable
final class TerminalZoomSettings {
    /// The phone's default, and the floor every other default is compared
    /// against.
    static let defaultFontSize: Float = 8
    /// An iPad window at full width is wide enough that 8 pt reads as a
    /// squint; herdr's own sidebar, tabs and panes all still fit at 12. Only
    /// the *unzoomed* default differs — once the user pinches, the offset is
    /// the offset on every device.
    static let regularWidthDefaultFontSize: Float = 12
    /// A Split View half (or a Stage Manager window of about that size): the
    /// sidebar and one pane still fit, but only a point smaller.
    static let mediumWidthDefaultFontSize: Float = 11
    /// A Slide Over panel or a Split View third. Narrower than this and the
    /// default gives up a point rather than the pane's columns.
    static let compactWidthDefaultFontSize: Float = 10
    /// Width breakpoints for the iPad default, in points, widest first.
    static let regularWidthThreshold: CGFloat = 700
    static let mediumWidthThreshold: CGFloat = 500
    /// Whole points only. The low end goes all the way down to libghostty's
    /// own minimum: 4 pt is unreadable, but it fits a wide TUI on screen, and
    /// zooming out for the shape of a layout is a real thing people do.
    static let range: ClosedRange<Float> = 4...32

    private static let defaultsKey = "terminal-font-size"
    private static let offsetDefaultsKey = "terminal-font-size-offset"

    private(set) var fontSize: Float
    /// The user's zoom, as points either side of whatever the current default
    /// is. Survives every width change; only an explicit zoom moves it.
    @ObservationIgnored private var offset: Float
    /// The width-derived default this instance is currently sitting on.
    @ObservationIgnored private var baseFontSize: Float
    @ObservationIgnored private let idiom: UIUserInterfaceIdiom
    @ObservationIgnored private nonisolated(unsafe) let defaults: UserDefaults

    init(
        defaults: UserDefaults = .standard,
        idiom: UIUserInterfaceIdiom = UIDevice.current.userInterfaceIdiom
    ) {
        self.defaults = defaults
        self.idiom = idiom
        let base = Self.defaultFontSize(for: idiom)
        baseFontSize = base
        // Installs that predate the offset stored an absolute size. Read it as
        // the zoom it was: the distance from the default that was in force
        // when it was chosen, which on both idioms is the idiom's own default.
        if defaults.object(forKey: Self.offsetDefaultsKey) != nil {
            offset = defaults.float(forKey: Self.offsetDefaultsKey)
        } else if defaults.object(forKey: Self.defaultsKey) != nil {
            offset = defaults.float(forKey: Self.defaultsKey) - base
        } else {
            offset = 0
        }
        fontSize = Self.clamped(base + offset)
    }

    /// The size a device that has never been pinched starts at.
    static func defaultFontSize(for idiom: UIUserInterfaceIdiom) -> Float {
        idiom == .pad ? regularWidthDefaultFontSize : defaultFontSize
    }

    /// The unzoomed default for one window width. iPhone windows are the
    /// phone's own size and never multitask, so only the iPad reads the width.
    static func defaultFontSize(
        forWindowWidth width: CGFloat,
        idiom: UIUserInterfaceIdiom
    ) -> Float {
        guard idiom == .pad else { return defaultFontSize }
        guard width > 0 else { return regularWidthDefaultFontSize }
        if width >= regularWidthThreshold { return regularWidthDefaultFontSize }
        if width >= mediumWidthThreshold { return mediumWidthDefaultFontSize }
        return compactWidthDefaultFontSize
    }

    /// The window the terminals are drawn in changed width — a Split View
    /// drag, a Stage Manager resize, a rotation. The default moves; the user's
    /// zoom rides on top of it untouched.
    func windowWidthDidChange(_ width: CGFloat) {
        let base = Self.defaultFontSize(forWindowWidth: width, idiom: idiom)
        guard base != baseFontSize else { return }
        baseFontSize = base
        let resolved = Self.clamped(base + offset)
        guard resolved != fontSize else { return }
        fontSize = resolved
    }

    func setFontSize(_ size: Float) {
        let clamped = Self.clamped(size)
        guard clamped != fontSize else { return }
        fontSize = clamped
        offset = clamped - baseFontSize
        defaults.set(offset, forKey: Self.offsetDefaultsKey)
        // Kept in step for anything still reading the absolute key, and so a
        // downgrade lands on the size the user last saw rather than 8 pt.
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
