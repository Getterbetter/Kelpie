import Foundation
import Testing
import UIKit

@testable import Heeler

struct TerminalSurfaceLinkQueryTests {
    private let point = CGPoint(x: 40, y: 40)

    /// The text scan is authoritative when it answers: libghostty is never
    /// asked, so an ordinary tap on ordinary output costs nothing new.
    @Test func aTextScanHitIsNeverPutToTheSurface() throws {
        let scanned = try #require(URL(string: "https://scanned.dev"))
        var asks = 0
        let match = TerminalSurfaceLinkQuery.match(
            at: point,
            textScan: { _ in .url(scanned) },
            surfaceLink: { _ in
                asks += 1
                return "https://surface.dev"
            })
        #expect(match == .url(scanned))
        #expect(asks == 0)
    }

    /// A Host path is an answer too, and stops the query just as a URL does.
    @Test func aTextScanPathIsNeverPutToTheSurface() {
        var asks = 0
        let match = TerminalSurfaceLinkQuery.match(
            at: point,
            textScan: { _ in .hostPath("/tmp/out.log") },
            surfaceLink: { _ in
                asks += 1
                return "https://surface.dev"
            })
        #expect(match == .hostPath("/tmp/out.log"))
        #expect(asks == 0)
    }

    /// The OSC 8 case: nothing in the row names the URL, and the core does.
    @Test func aTextScanMissTakesTheSurfaceURL() throws {
        var askedPoints: [CGPoint] = []
        let match = TerminalSurfaceLinkQuery.match(
            at: point,
            textScan: { _ in nil },
            surfaceLink: {
                askedPoints.append($0)
                return "https://claude.ai/artifact/1"
            })
        #expect(match == .url(try #require(URL(string: "https://claude.ai/artifact/1"))))
        #expect(askedPoints == [point])
    }

    @Test func aSurfaceWithNoLinkResolvesToNothing() {
        let match = TerminalSurfaceLinkQuery.match(
            at: point, textScan: { _ in nil }, surfaceLink: { _ in nil })
        #expect(match == nil)
    }

    /// libghostty will report any scheme it was handed — `file:`, `mailto:`, a
    /// crafted `javascript:`. Only what the scan would have opened is opened.
    @Test func aSurfaceLinkObeysTheSameURLPolicyAsTheScan() {
        for reported in ["file:///etc/passwd", "mailto:a@b.dev", "https://", "not a url"] {
            #expect(
                TerminalSurfaceLinkQuery.match(
                    at: point, textScan: { _ in nil }, surfaceLink: { _ in reported })
                    == nil,
                "\(reported) should not open")
        }
    }

    /// The probe's own report, in both encodings a tracking application can ask
    /// for: SGR button 35, legacy `Cb` 67 — each also carrying the modifier
    /// bits the probe's shift adds, which is the shape measured on the iPad
    /// (SGR 39 = 35 + shift).
    @Test func buttonlessMotionReportsAreRecognized() {
        #expect(
            TerminalSurfaceLinkQuery.isButtonlessMotionReport(
                Data("\u{1B}[<35;20;10M".utf8)))
        #expect(
            TerminalSurfaceLinkQuery.isButtonlessMotionReport(
                Data("\u{1B}[<35;1;1m".utf8)))
        #expect(
            TerminalSurfaceLinkQuery.isButtonlessMotionReport(
                Data("\u{1B}[<39;5;5M".utf8)))
        #expect(
            TerminalSurfaceLinkQuery.isButtonlessMotionReport(
                Data("\u{1B}[<51;5;5M".utf8)))
        #expect(
            TerminalSurfaceLinkQuery.isButtonlessMotionReport(
                Data([0x1B, 0x5B, 0x4D, 67, 52, 34])))
        #expect(
            TerminalSurfaceLinkQuery.isButtonlessMotionReport(
                Data([0x1B, 0x5B, 0x4D, 71, 52, 34])))
    }

    /// Nothing Kelpie reports for a real touch may be mistaken for one: every
    /// one of its reports carries a button, motion included.
    @Test func realReportsAreNeverMistakenForAProbe() {
        let real: [Data] = [
            TerminalMouseEncoding.sgr.report(button: .left, column: 4, row: 2),
            TerminalMouseEncoding.sgr.report(
                button: .left, column: 4, row: 2, isRelease: true),
            TerminalMouseEncoding.sgr.report(
                button: .left, column: 4, row: 2, isMotion: true),
            TerminalMouseEncoding.sgr.report(
                button: .right, column: 4, row: 2, isMotion: true),
            TerminalMouseEncoding.sgr.report(button: .wheelUp, column: 4, row: 2),
            TerminalMouseEncoding.legacy.report(button: .left, column: 4, row: 2),
            TerminalMouseEncoding.legacy.report(
                button: .left, column: 4, row: 2, isMotion: true),
            Data("hello".utf8),
            Data("\u{1B}[A".utf8),
        ]
        for report in real {
            #expect(
                !TerminalSurfaceLinkQuery.isButtonlessMotionReport(report),
                "\(Array(report)) is real input")
        }
        // A legacy *release* is button 3 without motion — 35, not 67.
        #expect(
            !TerminalSurfaceLinkQuery.isButtonlessMotionReport(
                TerminalMouseEncoding.legacy.report(
                    button: .left, column: 1, row: 1, isRelease: true)))
    }

    /// The whole point, against the real surface: an OSC 8 hyperlink whose row
    /// shows only a title resolves to its URL, libghostty answers from inside
    /// the call that asks, and the Host hears nothing about it.
    @MainActor
    @Test func osc8HyperlinksResolveThroughTheLiveSurface() async throws {
        var sent = Data()
        let terminal = TerminalScreenView.makeConfiguredTerminal(
            onSend: { sent.append($0) })
        terminal.frame = CGRect(x: 0, y: 0, width: 390, height: 720)
        let controller = UIViewController()
        controller.view = terminal
        let window = try await makeTestWindow(
            frame: terminal.bounds,
            rootViewController: controller)
        defer { window.isHidden = true }

        // Any-motion tracking, as Claude Code sets it: the mode that makes a
        // stray mouse move visible to the remote application.
        terminal.receive(Data("\u{1B}[?1049h\u{1B}[?1003;1006h".utf8))
        terminal.layoutIfNeeded()
        try await settle()

        let row = 5
        let column = 3
        let title = "Release notes"
        let link = "https://claude.ai/artifact/abc"
        terminal.receive(
            Data(
                ("\u{1B}[\(row);\(column)H"
                    + "\u{1B}]8;;\(link)\u{1B}\\\(title)\u{1B}]8;;\u{1B}\\").utf8))
        try await settle()
        sent.removeAll()

        let mapper = terminal.gridPointMapper
        let cellSize = mapper.cellSize
        #expect(cellSize.width > 0)
        // The middle of the title's third cell, well inside the link run.
        let point = CGPoint(
            x: mapper.gridOrigin.x + (CGFloat(column) + 1.5) * cellSize.width,
            y: mapper.gridOrigin.y + (CGFloat(row) - 0.5) * cellSize.height)
        let expected = try #require(URL(string: link))
        let context: Comment =
            "point=\(point) mapper=\(mapper) viewport=\(terminal.terminalSession.readViewportText() ?? "nil")"

        // The probe moves the core's mouse with the link modifier — mods 0
        // reports nothing at all — and the core answers from inside that call.
        let resolved = terminal.linkMatch(at: point)
        let wasSynchronous = terminal.didReportHoverLinkSynchronously
        let probed: Comment = "\(context) probe=\(terminal.lastLinkProbeTrace)"
        #expect(resolved == .url(expected), probed)
        #expect(wasSynchronous, probed)

        // A cell outside any link stays unresolved either way.
        let bare = CGPoint(
            x: mapper.gridOrigin.x + cellSize.width / 2,
            y: mapper.gridOrigin.y + (CGFloat(row) + 4.5) * cellSize.height)
        #expect(terminal.linkMatch(at: bare) == nil, context)

        // Whatever the probe provoked, nothing reached the Host: the motion
        // report `?1003h` earns from moving the core's mouse is dropped.
        try await settle()
        #expect(sent.isEmpty, "leaked \(Array(sent))")
    }

    /// Ghostty needs a few render passes before its grid metrics settle.
    private func settle() async throws {
        for _ in 0..<10 {
            try await Task.sleep(for: .milliseconds(50))
            await Task.yield()
        }
    }
}
