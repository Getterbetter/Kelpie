import SwiftUI
import Testing
import UIKit

@testable import Heeler

/// The dialog's whole job is to be legible over a live terminal. Its first
/// version was a bare `ContentUnavailableView`, which draws no background at
/// all, so the copy sat directly on top of whatever glyphs happened to be
/// underneath. That is invisible to every kind of test except one that looks
/// at the pixels, so this suite looks at the pixels.
@MainActor
@Suite("Terminal status dialog")
struct TerminalStatusDialogTests {
    @Test func theDialogCoversWhateverTheTerminalWasShowing() async throws {
        let image = try await Self.render(
            TerminalStatusDialog(
                glyph: .symbol("cable.connector.slash"),
                title: "Session Ended",
                message: "The session ended."
            ) {
                Button("Reattach") {}
                    .buttonStyle(.borderedProminent)
            })

        let behind = try #require(Self.color(in: image, atUnit: CGPoint(x: 0.5, y: 0.5)))
        #expect(behind != Self.backdrop, "the dialog let the terminal through")
    }

    @Test func theDimOnlyAppliesWhereItIsAskedFor() async throws {
        // A corner is outside the card but inside the scrim.
        let corner = CGPoint(x: 0.03, y: 0.06)

        let dimmed = try await Self.render(
            TerminalStatusDialog(
                glyph: .symbol("cable.connector.slash"), title: "Session Ended"))
        let undimmed = try await Self.render(
            TerminalStatusDialog(glyph: .progress, title: "Connecting…", dimsBackground: false))

        guard Self.rendersRealPixels(dimmed), Self.rendersRealPixels(undimmed) else {
            // Nothing was drawn — see `rendersRealPixels`. Sampling an
            // unrendered bitmap would assert against black, not against the
            // dialog, so this stands down rather than lying either way.
            return
        }
        // Compared with the same tolerance the card test uses: the device
        // composites through its own wide-gamut pipeline, so the backdrop
        // round-trips a channel or two off pure red.
        let scrimmed = try #require(Self.color(in: dimmed, atUnit: corner))
        let plain = try #require(Self.color(in: undimmed, atUnit: corner))
        #expect(
            Self.channelDistance(scrimmed, Self.backdrop) > Self.tolerance,
            "the scrim drew \(String(scrimmed, radix: 16)), the bare backdrop")
        // Transient states leave the terminal alone; dimming on every reconnect
        // would flash the screen.
        #expect(
            Self.channelDistance(plain, Self.backdrop) <= Self.tolerance,
            "undimmed drew \(String(plain, radix: 16)), expected ~\(String(Self.backdrop, radix: 16))")
    }

    @Test func theCardWearsTheTerminalThemeRatherThanTheSystem() async throws {
        // The theme owns the whole screen; a system material card over a
        // Solarized grid reads as a piece of some other app.
        let palette = TerminalThemeOption.solarized.palette(for: .dark)
        let image = try await Self.render(
            TerminalStatusDialog(
                glyph: .progress, title: "Connecting…", palette: palette,
                dimsBackground: false))

        guard Self.rendersRealPixels(image) else {
            // Nothing was drawn — see `rendersRealPixels`.
            return
        }
        // Inside the card, clear of the centred spinner and copy.
        let inside = try #require(Self.color(in: image, atUnit: CGPoint(x: 0.15, y: 0.5)))
        let expected = Self.packed(palette.background.mix(with: palette.foreground, by: 0.08))
        #expect(
            Self.channelDistance(inside, expected) <= Self.tolerance,
            "card drew \(String(inside, radix: 16)), expected ~\(String(expected, radix: 16))")
    }

    /// Pure red, so anything drawn over it is unmistakable.
    private static let backdrop: UInt32 = 0xFF00_0000 >> 8

    /// Per-channel slack for "the same colour". A snapshot taken on the device
    /// goes through its own wide-gamut compositing, so an exact match is not a
    /// thing to assert; anything the dialog actually draws is far further off
    /// than this.
    private static let tolerance = 8

    /// Whether `render` produced real pixels. `drawHierarchy` needs the host's
    /// scene to be **foreground**; running on the device without one it logs
    /// "Rendering a window (…) requires it to be in a foreground scene" and
    /// hands back an unrendered, wholly black bitmap. Every one of these
    /// snapshots has the red backdrop or the scrim over it in all four
    /// corners, so four black corners means nothing was drawn at all.
    private static func rendersRealPixels(_ image: UIImage) -> Bool {
        let corners = [
            CGPoint(x: 0.02, y: 0.02), CGPoint(x: 0.98, y: 0.02),
            CGPoint(x: 0.02, y: 0.98), CGPoint(x: 0.98, y: 0.98),
        ]
        return corners.contains { (color(in: image, atUnit: $0) ?? 0) != 0 }
    }

    private static func packed(_ color: Color) -> UInt32 {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return [red, green, blue].reduce(0) { packed, channel in
            packed << 8 | UInt32((channel * 255).rounded())
        }
    }

    private static func channelDistance(_ lhs: UInt32, _ rhs: UInt32) -> Int {
        (0..<3).reduce(0) { worst, shift in
            let left = Int((lhs >> (shift * 8)) & 0xFF)
            let right = Int((rhs >> (shift * 8)) & 0xFF)
            return max(worst, abs(left - right))
        }
    }

    private static func render(_ dialog: some View) async throws -> UIImage {
        let bounds = CGRect(x: 0, y: 0, width: 390, height: 720)
        let controller = UIHostingController(
            rootView: ZStack {
                Color(red: 1, green: 0, blue: 0).ignoresSafeArea()
                dialog
            })
        controller.view.frame = bounds

        let window = try await makeTestWindow(
            frame: bounds,
            rootViewController: controller)
        defer { window.isHidden = true }
        controller.view.layoutIfNeeded()

        return UIGraphicsImageRenderer(bounds: bounds).image { _ in
            window.drawHierarchy(in: bounds, afterScreenUpdates: true)
        }
    }

    private static func color(in image: UIImage, atUnit point: CGPoint) -> UInt32? {
        guard let cgImage = image.cgImage else { return nil }
        let width = cgImage.width, height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard
            let context = CGContext(
                data: &pixels, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        let x = min(width - 1, max(0, Int(point.x * CGFloat(width))))
        let y = min(height - 1, max(0, Int(point.y * CGFloat(height))))
        let i = (y * width + x) * 4
        return UInt32(pixels[i]) << 16 | UInt32(pixels[i + 1]) << 8 | UInt32(pixels[i + 2])
    }
}
