import Foundation

/// One row of Kelpie Chat's read model: a turn of a Claude Code session as
/// its transcript recorded it (ADR 0019). Built by `ClaudeTranscriptParser`;
/// the UI (round 43b) renders it and never sees the transcript's own shape.
struct ChatMessage: Identifiable, Sendable, Equatable {
    enum Role: Sendable, Equatable {
        case user
        case assistant
        /// A tool result. Its own row rather than part of the assistant's
        /// turn, so the UI can collapse it independently.
        case tool
    }

    enum Block: Sendable, Equatable {
        case text(String)
        /// A tool call the assistant made: the id herdr's transcript pairs
        /// the result with, the tool's name, and a one-line summary of its
        /// input (the command, the path, the pattern).
        case toolUse(id: String, name: String, inputSummary: String)
        /// The result of a tool call, capped so a 100 KB build log does not
        /// become a 100 KB row; `isTruncated` says the cap applied.
        case toolResult(toolUseID: String?, text: String, isError: Bool, isTruncated: Bool)
        /// An image the agent looked at, inline in the transcript as base64
        /// and decoded here; `mediaType` is the transcript's, when present.
        case image(Data, mediaType: String?)
    }

    /// The transcript's own id: the line `uuid` for user and tool rows, the
    /// API message id for assistant rows (one API message spans several
    /// lines, one content block each).
    let id: String
    let role: Role
    var blocks: [Block]
    let timestamp: Date?
}

/// Claude Code's permission mode, as its transcript writes it in the
/// `permission-mode` line. The permission card (round 43c) reads it before
/// offering buttons: auto mode passes through herdr's `blocked` for a few
/// seconds and answers itself.
struct ClaudePermissionMode: RawRepresentable, Hashable, Sendable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    static let auto = ClaudePermissionMode(rawValue: "auto")
    static let `default` = ClaudePermissionMode(rawValue: "default")
    static let acceptEdits = ClaudePermissionMode(rawValue: "acceptEdits")
    static let plan = ClaudePermissionMode(rawValue: "plan")

    /// Whether a permission prompt in this mode waits for a person.
    var expectsHumanAnswer: Bool { self != .auto }
}
