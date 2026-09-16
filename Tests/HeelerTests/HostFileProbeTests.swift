import Foundation
import Testing

@testable import Heeler

/// The byte-range read behind Kelpie Chat's transcript paging (ADR 0019):
/// the command it runs on the Host and the framing it parses back, as pure
/// functions over the bytes.
@Suite("Host file probe")
struct HostFileProbeTests {
    // MARK: Command

    @Test func commandPassesThePathAsAPositionalArgumentOnly() {
        let command = HostFileProbe.command(quotedPath: "'/tmp/a b.jsonl'", offset: 0, maxBytes: 100)
        #expect(command.hasPrefix("/bin/sh -c '"))
        #expect(command.hasSuffix("' herdr-file-range '/tmp/a b.jsonl'"))
        let script = command.dropLast("' herdr-file-range '/tmp/a b.jsonl'".count)
        #expect(!script.contains("/tmp/a b.jsonl"))
        #expect(script.contains("\"$1\""))
    }

    @Test func tailOffsetIsOneBased() {
        #expect(HostFileProbe.command(quotedPath: "'/f'", offset: 0, maxBytes: 8).contains("tail -c +1 \"$1\""))
        #expect(HostFileProbe.command(quotedPath: "'/f'", offset: 4096, maxBytes: 8).contains("tail -c +4097 \"$1\""))
        #expect(HostFileProbe.command(quotedPath: "'/f'", offset: -5, maxBytes: 8).contains("tail -c +1 \"$1\""))
    }

    @Test func capIsAppliedAndClamped() {
        #expect(HostFileProbe.command(quotedPath: "'/f'", offset: 0, maxBytes: 8).contains("| head -c 8;"))
        #expect(HostFileProbe.command(quotedPath: "'/f'", offset: 0, maxBytes: 0).contains("| head -c 1;"))
        #expect(
            HostFileProbe.command(quotedPath: "'/f'", offset: 0, maxBytes: .max)
                .contains("| head -c \(HostFileProbe.maximumBytesPerRead);"))
    }

    @Test func commandPrintsTheSizeAfterTheBodyAndSkipsAMissingFile() throws {
        let command = HostFileProbe.command(quotedPath: "'/f'", offset: 0, maxBytes: 8)
        #expect(command.contains("[ -f \"$1\" ] || exit 0;"))
        let bodyIndex = try #require(command.range(of: "tail -c")).lowerBound
        let sizeIndex = try #require(command.range(of: "wc -c < \"$1\"")).lowerBound
        #expect(bodyIndex < sizeIndex)
        #expect(command.contains("printf \"\\n\(HostFileProbe.endMarkerPrefix)%s\\n\""))
    }

    // MARK: Parsing

    private func framed(_ body: String, size: String, noise: String = "") -> Data {
        Data("\(noise)\(HostFileProbe.beginMarker)\n\(body)\n\(HostFileProbe.endMarkerPrefix)\(size)\n".utf8)
    }

    @Test func parsesBodyAndSizeAndDropsLoginShellNoise() throws {
        let output = framed("{\"type\":\"user\"}\n{\"type\":\"assistant\"}", size: "1234", noise: "Last login: Tue\nmotd\n")
        let page = try #require(HostFileProbe.framedOutput(in: output))
        #expect(page.body == Data("{\"type\":\"user\"}\n{\"type\":\"assistant\"}".utf8))
        #expect(page.fileSize == 1234)
    }

    @Test func emptyBodyAtEndOfFileStillCarriesTheSize() throws {
        let page = try #require(HostFileProbe.framedOutput(in: framed("", size: "77")))
        #expect(page.body.isEmpty)
        #expect(page.fileSize == 77)
    }

    @Test func missingMarkersParseAsNil() {
        #expect(HostFileProbe.framedOutput(in: Data("Last login\n".utf8)) == nil)
        #expect(HostFileProbe.framedOutput(in: Data("\(HostFileProbe.beginMarker)\nbody\n".utf8)) == nil)
        #expect(HostFileProbe.framedOutput(in: Data()) == nil)
    }

    @Test func emptyOrGarbledSizeParsesAsUnknown() throws {
        #expect(try #require(HostFileProbe.framedOutput(in: framed("x", size: ""))).fileSize == nil)
        #expect(try #require(HostFileProbe.framedOutput(in: framed("x", size: "12a"))).fileSize == nil)
    }

    @Test func bodyBytesPassThroughUntouched() throws {
        var body = Data("a\r\nb".utf8)
        body.append(contentsOf: [0xFF, 0xFE, 0x00, 0x0A, 0x0D])
        var output = Data("\(HostFileProbe.beginMarker)\n".utf8)
        output.append(body)
        output.append(Data("\n\(HostFileProbe.endMarkerPrefix)9\n".utf8))
        let page = try #require(HostFileProbe.framedOutput(in: output))
        #expect(page.body == body)
        #expect(page.fileSize == 9)
    }

    @Test func aBodyContainingTheEndMarkerTextIsKeptWhole() throws {
        let body = "before\n\(HostFileProbe.endMarkerPrefix)5\nafter"
        let page = try #require(HostFileProbe.framedOutput(in: framed(body, size: "40")))
        #expect(page.body == Data(body.utf8))
        #expect(page.fileSize == 40)
    }

    // MARK: HostFileRange

    @Test func rangeReportsTheNextOffsetAndTheEnd() {
        let first = HostFileRange(offset: 0, data: Data(repeating: 1, count: 10), fileSize: 25)
        #expect(first.nextOffset == 10)
        #expect(!first.reachedEnd)
        let last = HostFileRange(offset: 10, data: Data(repeating: 1, count: 15), fileSize: 25)
        #expect(last.nextOffset == 25)
        #expect(last.reachedEnd)
        let grown = HostFileRange(offset: 10, data: Data(repeating: 1, count: 15), fileSize: 30)
        #expect(!grown.reachedEnd)
        let empty = HostFileRange(offset: 25, data: Data(), fileSize: 25)
        #expect(empty.reachedEnd)
    }
}
