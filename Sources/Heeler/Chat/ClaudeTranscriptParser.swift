import Foundation

/// Incremental reader of a Claude Code transcript: feed it the file's bytes
/// in any chunking (a page at a time from `Transport.readHostFileRange`),
/// and it keeps the `ChatMessage`s, the session's title and permission
/// mode, and the byte offset to resume from. Lines are consumed only once
/// their newline has arrived; a partial tail waits for the next chunk.
///
/// Verified against real transcripts on 2026-09-16 (Claude Code 2.1.27x):
/// an assistant API message arrives as several lines, one content block
/// each, sharing `message.id`; tool results are `user` lines whose content
/// is a `tool_result` block list; `attachment` lines carry the agent's
/// context and dominate the first turn. Everything the chat does not
/// render is skipped by type, and an unknown type is skipped too.
struct ClaudeTranscriptParser: Sendable {
    /// A line longer than this is not a message anyone can read; it is
    /// dropped (and counted) rather than buffered without bound.
    static let maximumLineBytes = 16 * 1024 * 1024
    static let maximumToolResultCharacters = 4096
    static let maximumInputSummaryCharacters = 200

    /// Line types the chat never renders. `permission-mode`, `ai-title` and
    /// `system` are read for their state and also produce no message.
    static let skippedTypes: Set<String> = [
        "attachment", "mode", "atis-latch", "last-prompt", "file-history-snapshot",
        "file-history-delta", "queue-operation", "agent-name", "cost-state",
    ]

    /// The last tool call with no result yet. With herdr reporting
    /// `blocked`, this is the permission prompt the card (round 43c) shows.
    struct PendingToolUse: Sendable, Equatable {
        let id: String
        let name: String
        let inputSummary: String
    }

    private(set) var messages: [ChatMessage] = []
    /// Bytes consumed so far, not counting a partial tail still waiting for
    /// its newline. Resuming a fresh parser here is safe: it lands on a line
    /// boundary, except while an oversized line is being discarded, where it
    /// lands inside that line and the remainder decodes as one more dropped
    /// line.
    private(set) var bytesConsumed: Int
    private(set) var permissionMode: ClaudePermissionMode?
    private(set) var title: String?
    /// The Claude Code version the transcript's lines carry, for diagnostics.
    private(set) var version: String?
    private(set) var lastTurnDurationMs: Int?
    /// Lines that did not decode or exceeded `maximumLineBytes`.
    private(set) var droppedLineCount = 0
    private(set) var pendingToolUse: PendingToolUse?

    private var partial = Data()
    private var discardingOversizedLine = false

    init(startingAt offset: Int = 0) {
        bytesConsumed = max(offset, 0)
    }

    /// Where the next read should start: everything fed so far, including
    /// the partial tail, which the next chunk continues.
    var nextOffset: Int { bytesConsumed + partial.count }

    mutating func feed(_ chunk: Data) {
        var buffer: Data
        if partial.isEmpty {
            buffer = chunk
        } else {
            buffer = partial
            buffer.append(chunk)
            partial = Data()
        }
        var lineStart = buffer.startIndex
        while let newline = buffer[lineStart...].firstIndex(of: UInt8(ascii: "\n")) {
            let lineBytes = newline - lineStart
            if discardingOversizedLine {
                discardingOversizedLine = false
                droppedLineCount += 1
            } else if lineBytes > Self.maximumLineBytes {
                droppedLineCount += 1
            } else if lineBytes > 0 {
                consume(buffer.subdata(in: lineStart..<newline))
            }
            bytesConsumed += lineBytes + 1
            lineStart = newline + 1
        }
        let tail = buffer[lineStart...]
        if discardingOversizedLine || tail.count > Self.maximumLineBytes {
            // Account for the bytes now rather than hold them.
            discardingOversizedLine = true
            bytesConsumed += tail.count
        } else {
            partial = Data(tail)
        }
    }

    private mutating func consume(_ line: Data) {
        // A stray "\r" before the newline (CRLF-authored lines) is not JSON.
        var line = line
        if line.last == UInt8(ascii: "\r") { line.removeLast() }
        guard !line.isEmpty else { return }
        guard let decoded = try? ClaudeTranscriptLine.decode(line) else {
            droppedLineCount += 1
            return
        }
        if let lineVersion = decoded.version { version = lineVersion }
        switch decoded.type {
        case "user":
            consumeUser(decoded)
        case "assistant":
            consumeAssistant(decoded)
        case "system":
            if decoded.subtype == "turn_duration", let duration = decoded.durationMs {
                lastTurnDurationMs = duration
            }
        case "permission-mode":
            if let mode = decoded.permissionMode {
                permissionMode = ClaudePermissionMode(rawValue: mode)
            }
        case "ai-title":
            if let aiTitle = decoded.aiTitle, !aiTitle.isEmpty { title = aiTitle }
        default:
            // `skippedTypes` and anything newer than this parser.
            break
        }
    }

    private mutating func consumeUser(_ line: ClaudeTranscriptLine) {
        guard line.isMeta != true, let content = line.message?.content else { return }
        let timestamp = Self.date(from: line.timestamp)
        let id = line.uuid ?? "user-\(messages.count)"
        switch content {
        case .text(let text):
            messages.append(
                ChatMessage(id: id, role: .user, blocks: [.text(text)], timestamp: timestamp))
            pendingToolUse = nil
        case .blocks(let blocks):
            var textBlocks: [ChatMessage.Block] = []
            var resultIndex = 0
            for block in blocks {
                switch block.type {
                case "text":
                    if let text = block.text { textBlocks.append(.text(text)) }
                case "tool_result":
                    let resultID = resultIndex == 0 ? id : "\(id)-\(resultIndex)"
                    resultIndex += 1
                    messages.append(
                        ChatMessage(
                            id: resultID, role: .tool,
                            blocks: Self.toolResultBlocks(block),
                            timestamp: timestamp))
                    if pendingToolUse?.id == block.toolUseId { pendingToolUse = nil }
                default:
                    break
                }
            }
            if !textBlocks.isEmpty {
                messages.append(
                    ChatMessage(id: id, role: .user, blocks: textBlocks, timestamp: timestamp))
                pendingToolUse = nil
            }
        }
    }

    private static func toolResultBlocks(_ block: ClaudeTranscriptLine.ContentBlock)
        -> [ChatMessage.Block]
    {
        let isError = block.isError ?? false
        var blocks: [ChatMessage.Block] = []
        var text = ""
        switch block.content {
        case .text(let string):
            text = string
        case .blocks(let inner):
            for part in inner {
                switch part.type {
                case "text":
                    if let partText = part.text {
                        text += text.isEmpty ? partText : "\n" + partText
                    }
                case "image":
                    if let encoded = part.source?.data,
                        let data = Data(base64Encoded: encoded)
                    {
                        blocks.append(.image(data, mediaType: part.source?.mediaType))
                    }
                default:
                    // `tool_reference` and whatever comes next: nothing to show.
                    break
                }
            }
        case nil:
            break
        }
        if !text.isEmpty || blocks.isEmpty {
            let truncated = text.count > maximumToolResultCharacters
            let shown = truncated ? String(text.prefix(maximumToolResultCharacters)) : text
            blocks.insert(
                .toolResult(
                    toolUseID: block.toolUseId, text: shown, isError: isError,
                    isTruncated: truncated),
                at: 0)
        }
        return blocks
    }

    private mutating func consumeAssistant(_ line: ClaudeTranscriptLine) {
        guard case .blocks(let blocks)? = line.message?.content else { return }
        var newBlocks: [ChatMessage.Block] = []
        for block in blocks {
            switch block.type {
            case "text":
                if let text = block.text, !text.isEmpty { newBlocks.append(.text(text)) }
            case "tool_use":
                let id = block.id ?? ""
                let name = block.name ?? "tool"
                let summary = Self.inputSummary(name: name, input: block.input)
                newBlocks.append(.toolUse(id: id, name: name, inputSummary: summary))
                pendingToolUse = PendingToolUse(id: id, name: name, inputSummary: summary)
            default:
                // `thinking` is not shown.
                break
            }
        }
        guard !newBlocks.isEmpty else { return }
        let id = line.message?.id ?? line.uuid ?? "assistant-\(messages.count)"
        // One API message spans several lines, and its tool calls' results
        // are written between them (parallel calls land as they finish), so
        // the message to extend is the last assistant row when only tool
        // rows follow it. A user row in between means a new turn; an id
        // that then repeats gets a suffix so rows stay unique.
        if let index = messages.lastIndex(where: { $0.role != .tool }),
            messages[index].role == .assistant, messages[index].id == id
        {
            messages[index].blocks.append(contentsOf: newBlocks)
            return
        }
        var uniqueID = id
        var suffix = 2
        while messages.contains(where: { $0.id == uniqueID }) {
            uniqueID = "\(id)-\(suffix)"
            suffix += 1
        }
        messages.append(
            ChatMessage(
                id: uniqueID, role: .assistant, blocks: newBlocks,
                timestamp: Self.date(from: line.timestamp)))
    }

    /// The one field of a tool's input worth a row: the command, the path,
    /// the pattern. Unknown tools show their first string field.
    static func inputSummary(name: String, input: JSONValue?) -> String {
        guard case .object(let fields)? = input else { return "" }
        let preferred: [String]
        switch name {
        case "Bash": preferred = ["command", "description"]
        case "Read", "Write", "Edit", "NotebookEdit": preferred = ["file_path", "notebook_path"]
        case "Grep", "Glob": preferred = ["pattern"]
        case "Task", "Agent": preferred = ["description", "prompt"]
        case "WebFetch", "WebSearch": preferred = ["url", "query"]
        default: preferred = []
        }
        for key in preferred {
            if let value = fields[key]?.stringValue, !value.isEmpty {
                return collapse(value)
            }
        }
        for key in fields.keys.sorted() {
            if let value = fields[key]?.stringValue, !value.isEmpty {
                return collapse(value)
            }
        }
        return ""
    }

    private static func collapse(_ value: String) -> String {
        let collapsed = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard collapsed.count > maximumInputSummaryCharacters else { return collapsed }
        return String(collapsed.prefix(maximumInputSummaryCharacters - 1)) + "…"
    }

    private static let fractionalFormat = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let wholeSecondFormat = Date.ISO8601FormatStyle()

    static func date(from timestamp: String?) -> Date? {
        guard let timestamp else { return nil }
        return (try? fractionalFormat.parse(timestamp))
            ?? (try? wholeSecondFormat.parse(timestamp))
    }
}
