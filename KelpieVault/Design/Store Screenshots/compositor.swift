// compositor.swift — the production path for Kelpie's four ASC store panels.
// usage: swift compositor.swift [--only N] [--raw <dir>] [--out <dir>]
//        swift compositor.swift --export-landscape <dir>
//        swift compositor.swift --upright <in.png> <out.png>
//
// Mirrors the Weights store-panel pipeline (WeightsVault/Design/Store
// Screenshots/compositor.swift): a layout is described once, rendered with
// CoreGraphics + CoreText, and written as exact-size PNGs. gen-panels.py
// writes the same layout as hand-tweakable .dc.html artboards in canvas/;
// THIS file is the production path, because an HTML canvas export
// substitutes fallback fonts.
//
// Output: final-13in/0N-*.png at exactly 2752x2064 — the ASC 13-inch iPad
// (APP_IPAD_PRO_3GEN_129) landscape slot — sRGB, no alpha.
//
// Design (ruled 2026-09-11): near-black ground in the terminal's own family,
// one short white caption in SF Pro above, the capture as a rounded-corner
// card scaled to fit with generous margins. No device bezel, no other
// decoration.
//
// The raw captures are PORTRAIT 1940x2816 files whose pixels hold the
// LANDSCAPE UI rotated a quarter turn (verified 2026-09-11: as stored, the
// status bar runs down the right-hand edge). uprighted() puts them back;
// the rotation direction is the one whose top 2% band carries the status
// bar's left/right bright clusters and nothing in between.
import Foundation
import AppKit
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

// MARK: - Paths + arguments

let baseDir = URL(fileURLWithPath: "/Users/anthonytopalides/Developer/Kelpie/KelpieVault/Design/Store Screenshots")
var rawDir = baseDir.appendingPathComponent("raw")
var outDir = baseDir.appendingPathComponent("final-13in")
var onlyPanel: Int? = nil
var exportLandscapeDir: URL? = nil
var uprightPair: (input: URL, output: URL)? = nil
var argIt = CommandLine.arguments.dropFirst().makeIterator()
while let a = argIt.next() {
    if a == "--only", let v = argIt.next() { onlyPanel = Int(v) }
    if a == "--raw", let v = argIt.next() { rawDir = URL(fileURLWithPath: v) }
    if a == "--out", let v = argIt.next() { outDir = URL(fileURLWithPath: v) }
    // Write the uprighted captures somewhere (gen-panels.py uses this to feed
    // the canvas artboards), then exit. One source of truth for the rotation.
    if a == "--export-landscape", let v = argIt.next() { exportLandscapeDir = URL(fileURLWithPath: v) }
    // Upright ONE arbitrary capture through the same uprighted() rotation, for
    // captures that are not in the `panels` list (the tip sheet, say). Writes a
    // freshly rendered CoreGraphics bitmap, so no EXIF orientation tag survives.
    if a == "--upright", let i = argIt.next(), let o = argIt.next() {
        uprightPair = (URL(fileURLWithPath: i), URL(fileURLWithPath: o))
    }
}
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

// MARK: - Canvas geometry (13-inch iPad, landscape)

let PW = 2752, PH = 2064
let sideMargin: CGFloat = 180          // minimum gutter for the caption
let captionSize: CGFloat = 104
let captionBaseline: CGFloat = 266     // top-down baseline of the caption
let cardHeight: CGFloat = 1540
let cardTop: CGFloat = 376
let cardRadius: CGFloat = 40

// MARK: - Colours (sRGB)

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: srgb, components: [r / 255, g / 255, b / 255, a])!
}
let ground = rgb(8, 8, 10)        // #08080A — the terminal's #101010 family, a shade under it
let captionColor = rgb(255, 255, 255)

// MARK: - Bitmap helpers

func loadImage(_ url: URL) -> CGImage {
    guard let s = CGImageSourceCreateWithURL(url as CFURL, nil),
          let i = CGImageSourceCreateImageAtIndex(s, 0, nil) else { fatalError("load failed: \(url.path)") }
    return i
}
// noneSkipLast keeps the written PNG opaque (no alpha channel), as ASC wants.
func makeContext(_ w: Int, _ h: Int) -> CGContext {
    let info = CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
    return CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                     bytesPerRow: w * 4, space: srgb, bitmapInfo: info)!
}
func savePNG(_ image: CGImage, _ url: URL) {
    guard let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { fatalError("dest failed") }
    CGImageDestinationAddImage(d, image, nil)
    guard CGImageDestinationFinalize(d) else { fatalError("write failed: \(url.path)") }
}
// Top-down rect -> CG rect on a canvas of height H.
func td(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, canvasH: CGFloat = CGFloat(PH)) -> CGRect {
    CGRect(x: x, y: canvasH - y - h, width: w, height: h)
}

/// Put a quarter-turned capture back upright. Portrait in, landscape out.
func uprighted(_ image: CGImage) -> CGImage {
    guard image.height > image.width else { return image }
    let w = image.height, h = image.width
    let ctx = makeContext(w, h)
    ctx.translateBy(x: CGFloat(w) / 2, y: CGFloat(h) / 2)
    ctx.rotate(by: .pi / 2)
    ctx.translateBy(x: -CGFloat(image.width) / 2, y: -CGFloat(image.height) / 2)
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return ctx.makeImage()!
}

// MARK: - Text

let captionFontName = "SFProDisplay-Semibold"
func captionFont(_ size: CGFloat) -> CTFont {
    // The system face by descriptor, so this works without bundling a font.
    NSFont.systemFont(ofSize: size, weight: .semibold) as CTFont
}
func makeLine(_ text: String, _ f: CTFont, kern: CGFloat) -> CTLine {
    var attrs: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): f,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): captionColor,
    ]
    if kern != 0 { attrs[NSAttributedString.Key(kCTKernAttributeName as String)] = kern }
    return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
}
func lineWidth(_ line: CTLine) -> CGFloat {
    CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) - CGFloat(CTLineGetTrailingWhitespaceWidth(line))
}
/// Centred caption, shrunk to fit the gutters if a line ever grows.
func drawCaption(_ ctx: CGContext, _ text: String) {
    let maxWidth = CGFloat(PW) - 2 * sideMargin
    var size = captionSize
    var line = makeLine(text, captionFont(size), kern: -1)
    while lineWidth(line) > maxWidth, size > 40 {
        size -= 2
        line = makeLine(text, captionFont(size), kern: -1)
    }
    ctx.textPosition = CGPoint(x: (CGFloat(PW) - lineWidth(line)) / 2, y: CGFloat(PH) - captionBaseline)
    CTLineDraw(line, ctx)
}

// MARK: - Panel assembly

struct Panel {
    let file: String        // output name
    let capture: String     // raw/<capture>.png
    let caption: String
}
let panels: [Panel] = [
    Panel(file: "01-hero.png", capture: "hero-tidepool",
          caption: "herdr's console, full screen on your iPad"),
    Panel(file: "02-split-panes.png", capture: "infra",
          caption: "Split panes. Keyboard, trackpad or touch."),
    Panel(file: "03-menu.png", capture: "menu-open",
          caption: "Hosts, agents and settings, one tap away"),
    Panel(file: "04-real-terminal.png", capture: "notes-vim",
          caption: "A real terminal for real tools"),
]

func render(_ panel: Panel) {
    let ctx = makeContext(PW, PH)
    ctx.setFillColor(ground)
    ctx.fill(CGRect(x: 0, y: 0, width: PW, height: PH))

    drawCaption(ctx, panel.caption)

    let shot = uprighted(loadImage(rawDir.appendingPathComponent("\(panel.capture).png")))
    let aspect = CGFloat(shot.width) / CGFloat(shot.height)
    var h = cardHeight
    var w = h * aspect
    let maxW = CGFloat(PW) - 2 * sideMargin
    if w > maxW { w = maxW; h = w / aspect }
    let card = td((CGFloat(PW) - w) / 2, cardTop + (cardHeight - h) / 2, w, h)

    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: card, cornerWidth: cardRadius, cornerHeight: cardRadius, transform: nil))
    ctx.clip()
    ctx.interpolationQuality = .high
    ctx.draw(shot, in: card)
    ctx.restoreGState()

    let image = ctx.makeImage()!
    savePNG(image, outDir.appendingPathComponent(panel.file))
    print("wrote final-13in/\(panel.file)  \(image.width)x\(image.height)  card \(Int(w))x\(Int(h))")
}

if let uprightPair {
    let shot = uprighted(loadImage(uprightPair.input))
    try? FileManager.default.createDirectory(
        at: uprightPair.output.deletingLastPathComponent(), withIntermediateDirectories: true)
    savePNG(shot, uprightPair.output)
    print("wrote \(uprightPair.output.path)  \(shot.width)x\(shot.height)")
    exit(0)
}

if let exportLandscapeDir {
    try? FileManager.default.createDirectory(at: exportLandscapeDir, withIntermediateDirectories: true)
    for panel in panels {
        let shot = uprighted(loadImage(rawDir.appendingPathComponent("\(panel.capture).png")))
        let dest = exportLandscapeDir.appendingPathComponent("\(panel.capture)-landscape.png")
        savePNG(shot, dest)
        print("wrote \(dest.lastPathComponent)  \(shot.width)x\(shot.height)")
    }
    exit(0)
}

for (i, panel) in panels.enumerated() {
    if let onlyPanel, onlyPanel != i + 1 { continue }
    render(panel)
}
