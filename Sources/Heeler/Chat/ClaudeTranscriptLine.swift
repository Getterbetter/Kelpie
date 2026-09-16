import Foundation

/// One line of a Claude Code transcript (`~/.claude/projects/<cwd>/<session>.jsonl`),
/// decoded leniently: only `type` is required, every other field is
/// optional, unknown fields are ignored. The format is Claude Code's own
/// and unversioned in shape (each line carries the CLI `version`), so the
/// parser tolerates what it does not know rather than refusing the file.
struct ClaudeTranscriptLine: Decodable, Sendable, Equatable {
    let type: String
    let uuid: String?
    let parentUuid: String?
    let timestamp: String?
    let version: String?
    let isMeta: Bool?
    /// `system` lines: `turn_duration`, `local_command`, ...
    let subtype: String?
    let durationMs: Int?
    /// `permission-mode` lines.
    let permissionMode: String?
    /// `ai-title` lines.
    let aiTitle: String?
    let message: Message?

    struct Message: Decodable, Sendable, Equatable {
        let id: String?
        let role: String?
        let content: Content?
    }

    /// `message.content` is a bare string for a typed prompt and a block
    /// list for everything else.
    enum Content: Decodable, Sendable, Equatable {
        case text(String)
        case blocks([ContentBlock])

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let text = try? container.decode(String.self) {
                self = .text(text)
            } else {
                self = .blocks(try container.decode([ContentBlock].self))
            }
        }
    }

    struct ContentBlock: Decodable, Sendable, Equatable {
        let type: String
        // text
        let text: String?
        // tool_use
        let id: String?
        let name: String?
        let input: JSONValue?
        // tool_result
        let toolUseId: String?
        let content: Content?
        let isError: Bool?
        // image
        let source: ImageSource?

        private enum CodingKeys: String, CodingKey {
            case type, text, id, name, input, content, source
            case toolUseId = "tool_use_id"
            case isError = "is_error"
        }
    }

    struct ImageSource: Decodable, Sendable, Equatable {
        let type: String?
        let mediaType: String?
        let data: String?

        private enum CodingKeys: String, CodingKey {
            case type, data
            case mediaType = "media_type"
        }
    }

    static func decode(_ line: Data) throws -> ClaudeTranscriptLine {
        try JSONDecoder().decode(ClaudeTranscriptLine.self, from: line)
    }
}
