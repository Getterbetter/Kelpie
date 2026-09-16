import Foundation
import Testing

@testable import Heeler

/// The transcript read model (ADR 0019) against the fixture cut from real
/// Claude Code lines (`scripts/cut-transcript-fixture.py`) and against
/// hand-written lines for the edge cases the fixture cannot pin.
@Suite("Claude transcript parser")
struct ClaudeTranscriptParserTests {
    private func parse(_ data: Data, chunk: Int? = nil) -> ClaudeTranscriptParser {
        var parser = ClaudeTranscriptParser()
        if let chunk {
            var start = data.startIndex
            while start < data.endIndex {
                let end = min(start + chunk, data.endIndex)
                parser.feed(data.subdata(in: start..<end))
                start = end
            }
        } else {
            parser.feed(data)
        }
        return parser
    }

    private func lines(_ jsonLines: String...) -> Data {
        Data((jsonLines.joined(separator: "\n") + "\n").utf8)
    }

    // MARK: The fixture

    @Test func fixtureParsesWithNothingDropped() {
        let parser = parse(ClaudeTranscriptFixture.data)
        #expect(parser.droppedLineCount == 0)
        #expect(parser.bytesConsumed == ClaudeTranscriptFixture.data.count)
        #expect(parser.nextOffset == ClaudeTranscriptFixture.data.count)
        #expect(parser.version != nil)
        #expect(parser.title == "Fixture session title")
        #expect(parser.permissionMode == .plan)
        #expect(parser.lastTurnDurationMs != nil)
        #expect(!parser.messages.isEmpty)
    }

    @Test func fixtureStartsWithTheTypedPromptAndSkipsMetaUserLines() {
        let parser = parse(ClaudeTranscriptFixture.data)
        let first = parser.messages[0]
        #expect(first.role == .user)
        #expect(first.blocks == [.text("<prompt 1>")])
        #expect(first.timestamp != nil)
        // The fixture's other `user` lines are tool results or `isMeta`
        // local-command echoes; only the one prompt is a user row.
        #expect(parser.messages.filter { $0.role == .user }.count == 1)
    }

    @Test func fixtureGroupsOneAPIMessageAcrossItsInterleavedToolResults() {
        let parser = parse(ClaudeTranscriptFixture.data)
        let assistants = parser.messages.filter { $0.role == .assistant }
        let ids = parser.messages.map(\.id)
        #expect(Set(ids).count == ids.count, "row ids are unique")
        // The first assistant row is the first turn's three tool calls,
        // written one per line with their results between them.
        let first = assistants[0]
        let calls = first.blocks.compactMap { block -> String? in
            if case .toolUse(let id, _, _) = block { return id }
            return nil
        }
        #expect(calls.count == 3)
        #expect(first.blocks.count == 3, "thinking blocks are not rows")
        // Every call has its result row, keyed by the same id.
        let results = parser.messages.filter { $0.role == .tool }.flatMap(\.blocks)
        for id in calls {
            #expect(
                results.contains {
                    if case .toolResult(let resultID, _, _, _) = $0 { return resultID == id }
                    return false
                }, "result for \(id)")
        }
    }

    @Test func fixtureCarriesAnInlineImageAndAnErrorResult() throws {
        let parser = parse(ClaudeTranscriptFixture.data)
        let blocks = parser.messages.filter { $0.role == .tool }.flatMap(\.blocks)
        let image = try #require(
            blocks.compactMap { block -> (Data, String?)? in
                if case .image(let data, let mediaType) = block { return (data, mediaType) }
                return nil
            }.first)
        #expect(image.1 == "image/png")
        #expect(image.0.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]), "PNG signature")
        #expect(
            blocks.contains {
                if case .toolResult(_, _, let isError, _) = $0 { return isError }
                return false
            })
    }

    @Test func fixtureParsesTheSameHoweverItIsChunked() {
        let whole = parse(ClaudeTranscriptFixture.data)
        for chunk in [1, 7, 4096] {
            let chunked = parse(ClaudeTranscriptFixture.data, chunk: chunk)
            #expect(chunked.messages == whole.messages, "chunk \(chunk)")
            #expect(chunked.nextOffset == whole.nextOffset)
            #expect(chunked.bytesConsumed == whole.bytesConsumed)
            #expect(chunked.droppedLineCount == 0)
            #expect(chunked.title == whole.title)
            #expect(chunked.permissionMode == whole.permissionMode)
        }
    }

    // MARK: Hand-written lines

    private let user = #"{"type":"user","uuid":"u1","timestamp":"2026-09-16T00:16:23.936Z","version":"2.1.273","message":{"role":"user","content":"Reply with pong"}}"#
    private let assistantText = #"{"type":"assistant","uuid":"a1","timestamp":"2026-09-16T00:16:26.059Z","message":{"id":"msg_1","role":"assistant","content":[{"type":"text","text":"pong"}]}}"#
    private let toolUse = #"{"type":"assistant","uuid":"a2","timestamp":"2026-09-16T00:17:22Z","message":{"id":"msg_2","role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"ls   Sources | head -3","description":"List"}}]}}"#
    private let toolResult = #"{"type":"user","uuid":"u2","timestamp":"2026-09-16T00:17:23.386Z","message":{"role":"user","content":[{"tool_use_id":"toolu_1","type":"tool_result","content":"Heeler\nHeelerActivityCore","is_error":false}]}}"#
    private let interrupted = #"{"type":"user","uuid":"u3","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]}}"#

    @Test func aPartialLineWaitsForItsNewline() {
        var parser = ClaudeTranscriptParser()
        let bytes = Data(user.utf8)
        parser.feed(bytes.prefix(20))
        #expect(parser.messages.isEmpty)
        #expect(parser.bytesConsumed == 0)
        #expect(parser.nextOffset == 20)
        parser.feed(bytes.suffix(from: 20))
        #expect(parser.messages.isEmpty, "still no newline")
        #expect(parser.nextOffset == bytes.count)
        parser.feed(Data("\n".utf8))
        #expect(parser.messages.count == 1)
        #expect(parser.bytesConsumed == bytes.count + 1)
        #expect(parser.nextOffset == parser.bytesConsumed)
    }

    @Test func aLineSplitInsideAMultibyteCharacterStillDecodes() {
        let line = #"{"type":"user","uuid":"u1","message":{"role":"user","content":"日本語のプロンプト"}}"#
        let bytes = Data((line + "\n").utf8)
        let cut = bytes.firstIndex(of: 0xE6).map { $0 + 1 } ?? 10  // inside the first CJK scalar
        var parser = ClaudeTranscriptParser()
        parser.feed(bytes.prefix(cut))
        parser.feed(bytes.suffix(from: cut))
        #expect(parser.messages.first?.blocks == [.text("日本語のプロンプト")])
        #expect(parser.droppedLineCount == 0)
    }

    @Test func startingOffsetSeedsTheByteAccounting() {
        var parser = ClaudeTranscriptParser(startingAt: 500)
        parser.feed(lines(user))
        #expect(parser.bytesConsumed == 500 + user.utf8.count + 1)
    }

    @Test func unknownTypesAndSkippedTypesProduceNothing() {
        let skipped = ClaudeTranscriptParser.skippedTypes.map {
            #"{"type":"\#($0)","sessionId":"s","timestamp":"2026-09-16T00:00:00Z"}"#
        }
        let data = lines(
            (skipped + [
                #"{"type":"something-new","payload":{"x":1}}"#,
                #"{"type":"system","subtype":"local_command","content":"<system>"}"#,
                #"{"type":"user","uuid":"m","isMeta":true,"message":{"role":"user","content":"<caveat>"}}"#,
            ]).joined(separator: "\n"))
        let parser = parse(data)
        #expect(parser.messages.isEmpty)
        #expect(parser.droppedLineCount == 0)
        #expect(parser.pendingToolUse == nil)
    }

    @Test func aMalformedLineIsDroppedAndTheNextOneParses() {
        let parser = parse(lines("{not json", "", #"{"no":"type"}"#, user))
        #expect(parser.droppedLineCount == 2)
        #expect(parser.messages.count == 1)
    }

    @Test func crlfLinesParse() {
        let parser = parse(Data((user + "\r\n" + assistantText + "\r\n").utf8))
        #expect(parser.messages.map(\.role) == [.user, .assistant])
        #expect(parser.droppedLineCount == 0)
    }

    @Test func anOversizedLineIsDroppedWithExactAccounting() {
        var parser = ClaudeTranscriptParser()
        let huge = Data(repeating: UInt8(ascii: "x"), count: ClaudeTranscriptParser.maximumLineBytes + 10)
        parser.feed(huge)
        #expect(parser.bytesConsumed == huge.count, "accounted for, not held")
        parser.feed(Data("yyy\n".utf8))
        parser.feed(lines(user))
        #expect(parser.droppedLineCount == 1)
        #expect(parser.messages.count == 1)
        #expect(parser.bytesConsumed == huge.count + 4 + user.utf8.count + 1)
    }

    @Test func toolUseIsPendingUntilItsResultArrives() {
        var parser = ClaudeTranscriptParser()
        parser.feed(lines(user, toolUse))
        #expect(
            parser.pendingToolUse
                == ClaudeTranscriptParser.PendingToolUse(
                    id: "toolu_1", name: "Bash", inputSummary: "ls Sources | head -3"))
        parser.feed(lines(toolResult))
        #expect(parser.pendingToolUse == nil)
        let tool = parser.messages.last
        #expect(tool?.role == .tool)
        #expect(
            tool?.blocks == [
                .toolResult(
                    toolUseID: "toolu_1", text: "Heeler\nHeelerActivityCore", isError: false,
                    isTruncated: false)
            ])
    }

    @Test func aUserLineClearsAPendingToolUse() {
        var parser = ClaudeTranscriptParser()
        parser.feed(lines(toolUse, interrupted))
        #expect(parser.pendingToolUse == nil)
        #expect(parser.messages.last?.role == .user)
        #expect(parser.messages.last?.blocks == [.text("[Request interrupted by user for tool use]")])
    }

    @Test func assistantRowsMergeByMessageIDAndRepeatIDsStayUnique() {
        let a = #"{"type":"assistant","uuid":"x1","message":{"id":"msg_9","content":[{"type":"text","text":"one"}]}}"#
        let b = #"{"type":"assistant","uuid":"x2","message":{"id":"msg_9","content":[{"type":"text","text":"two"}]}}"#
        let parser = parse(lines(a, b, user, a))
        #expect(parser.messages.count == 3)
        #expect(parser.messages[0].blocks == [.text("one"), .text("two")])
        #expect(parser.messages[0].id == "msg_9")
        #expect(parser.messages[2].id == "msg_9-2")
    }

    @Test func longToolResultsAreTruncatedAndFlagged() {
        let long = String(repeating: "y", count: ClaudeTranscriptParser.maximumToolResultCharacters + 5)
        let line = #"{"type":"user","uuid":"u9","message":{"content":[{"type":"tool_result","tool_use_id":"t","content":"\#(long)","is_error":true}]}}"#
        let parser = parse(lines(line))
        guard case .toolResult(let id, let text, let isError, let truncated)? = parser.messages.first?.blocks.first
        else {
            Issue.record("expected a tool result")
            return
        }
        #expect(id == "t")
        #expect(text.count == ClaudeTranscriptParser.maximumToolResultCharacters)
        #expect(isError)
        #expect(truncated)
    }

    @Test func blockListResultsJoinTextAndDecodeImages() throws {
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg=="
        let line = #"{"type":"user","uuid":"u8","message":{"content":[{"type":"tool_result","tool_use_id":"t","content":[{"type":"text","text":"a"},{"type":"tool_reference","tool_name":"X"},{"type":"text","text":"b"},{"type":"image","source":{"type":"base64","media_type":"image/png","data":"\#(png)"}}]}]}}"#
        let parser = parse(lines(line))
        let blocks = try #require(parser.messages.first?.blocks)
        #expect(blocks.count == 2)
        #expect(blocks[0] == .toolResult(toolUseID: "t", text: "a\nb", isError: false, isTruncated: false))
        guard case .image(let data, let mediaType) = blocks[1] else {
            Issue.record("expected an image")
            return
        }
        #expect(mediaType == "image/png")
        #expect(data == Data(base64Encoded: png))
    }

    @Test func twoResultsInOneLineAreTwoRowsWithDistinctIDs() {
        let line = #"{"type":"user","uuid":"u7","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"x"},{"type":"tool_result","tool_use_id":"t2","content":"y"}]}}"#
        let parser = parse(lines(line))
        #expect(parser.messages.map(\.id) == ["u7", "u7-1"])
    }

    @Test func permissionModeLastWinsAndTitleUpdates() {
        let parser = parse(
            lines(
                #"{"type":"permission-mode","permissionMode":"plan"}"#,
                #"{"type":"ai-title","aiTitle":"First"}"#,
                #"{"type":"permission-mode","permissionMode":"auto"}"#,
                #"{"type":"ai-title","aiTitle":"Second"}"#,
                #"{"type":"ai-title","aiTitle":""}"#,
                #"{"type":"system","subtype":"turn_duration","durationMs":2182}"#))
        #expect(parser.permissionMode == .auto)
        #expect(parser.permissionMode?.expectsHumanAnswer == false)
        #expect(ClaudePermissionMode.plan.expectsHumanAnswer)
        #expect(parser.title == "Second")
        #expect(parser.lastTurnDurationMs == 2182)
    }

    @Test(arguments: [
        ("Bash", #"{"command":"git   status","description":"Show status"}"#, "git status"),
        ("Read", #"{"file_path":"/tmp/a.txt","limit":5}"#, "/tmp/a.txt"),
        ("Grep", #"{"pattern":"TODO","path":"/src"}"#, "TODO"),
        ("Task", #"{"description":"Map the tests","prompt":"long..."}"#, "Map the tests"),
        ("WebFetch", #"{"url":"https://example.com"}"#, "https://example.com"),
        ("Mystery", #"{"zeta":"last","alpha":"first","n":3}"#, "first"),
        ("Empty", #"{}"#, ""),
    ])
    func inputSummaryPicksTheFieldWorthARow(name: String, input: String, expected: String) throws {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(input.utf8))
        #expect(ClaudeTranscriptParser.inputSummary(name: name, input: value) == expected)
    }

    @Test func inputSummaryIsCapped() throws {
        let long = String(repeating: "a", count: 500)
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"command":"\#(long)"}"#.utf8))
        let summary = ClaudeTranscriptParser.inputSummary(name: "Bash", input: value)
        #expect(summary.count == ClaudeTranscriptParser.maximumInputSummaryCharacters)
        #expect(summary.hasSuffix("…"))
    }

    @Test func timestampsParseWithAndWithoutFractions() {
        #expect(ClaudeTranscriptParser.date(from: "2026-09-16T00:16:23.936Z") != nil)
        #expect(ClaudeTranscriptParser.date(from: "2026-09-16T00:16:23Z") != nil)
        #expect(ClaudeTranscriptParser.date(from: "yesterday") == nil)
        #expect(ClaudeTranscriptParser.date(from: nil) == nil)
    }
}
