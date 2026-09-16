import Foundation

/// Maps a herdr pane to the Claude Code transcript behind it (ADR 0019):
/// `pane.process_info` gives the pane's foreground process, Claude Code
/// registers each running session in `~/.claude/sessions/<pid>.json`, and
/// that record's `cwd` and `sessionId` name the transcript file
/// `~/.claude/projects/<encoded cwd>/<sessionId>.jsonl`. Verified live on
/// 2026-09-16 (herdr 0.8.2, Claude Code 2.1.273). The pure steps are
/// separate from `locate` so they test without a transport.
enum ClaudeSessionLocator {
    /// The sessions record is a few hundred bytes; the cap only bounds a
    /// file that is not what we think it is.
    static let maximumSessionRecordBytes = 64 * 1024

    /// The Claude Code process in a pane's foreground, or why there is none.
    /// A process is Claude when its executable's basename is exactly
    /// `claude` (`argv0`, then `argv[0]`, then `name`): a wrapper called
    /// `claude-something` is not the CLI.
    static func claudeProcess(in info: PaneProcessInfo) throws(ClaudeSessionLocatorError)
        -> PaneProcessInfoProcess
    {
        let processes = info.foregroundProcesses ?? []
        guard let first = processes.first else { throw .noForegroundProcess }
        if let claude = processes.first(where: isClaude) { return claude }
        throw .foregroundIsNotClaude(name: first.name)
    }

    private static func isClaude(_ process: PaneProcessInfoProcess) -> Bool {
        let candidates = [process.argv0, process.argv?.first, process.name].compactMap { $0 }
        return candidates.contains { candidate in
            let basename = candidate.split(separator: "/", omittingEmptySubsequences: true).last
            return basename == "claude"
        }
    }

    /// `~`-relative on purpose: the transport resolves `~` against the
    /// Host's home once per connection, so the locator never needs it.
    static func sessionsFilePath(pid: Int) -> String {
        "~/.claude/sessions/\(pid).json"
    }

    /// Claude Code's project directory name for a cwd: every character
    /// outside ASCII letters and digits becomes `-` (a leading `/` gives a
    /// leading `-`; `claude-501/-Users` gives `claude-501--Users`). Not
    /// injective, so it is never decoded. Matched per UTF-16 unit, as the
    /// JavaScript that writes the directory does.
    static func encodedProjectDirectory(cwd: String) -> String {
        var scalars = String.UnicodeScalarView()
        for unit in cwd.utf16 {
            let isAlphanumeric =
                (unit >= 0x30 && unit <= 0x39) || (unit >= 0x41 && unit <= 0x5A)
                || (unit >= 0x61 && unit <= 0x7A)
            if isAlphanumeric, let scalar = Unicode.Scalar(unit) {
                scalars.append(scalar)
            } else {
                scalars.append("-")
            }
        }
        return String(scalars)
    }

    /// The transcript path for a session, or nil when the session id could
    /// not be a file name we would put in a shell command.
    static func transcriptPath(cwd: String, sessionID: String) -> String? {
        guard !sessionID.isEmpty,
            sessionID.unicodeScalars.allSatisfy({
                ($0 >= "0" && $0 <= "9") || ($0 >= "a" && $0 <= "z") || ($0 >= "A" && $0 <= "Z")
                    || $0 == "-"
            })
        else { return nil }
        return "~/.claude/projects/\(encodedProjectDirectory(cwd: cwd))/\(sessionID).jsonl"
    }

    static func decodeSession(_ data: Data) throws -> ClaudeSessionRecord {
        try JSONDecoder().decode(ClaudeSessionRecord.self, from: data)
    }

    /// The whole route for one pane. Errors are the transport's own
    /// (`HerdrAPIError` for a dead pane, `HostFileDownloadError.notFound`
    /// when the session has exited and its record is gone) or a
    /// `ClaudeSessionLocatorError`.
    static func locate(paneID: String, transport: any Transport) async throws
        -> ClaudeSessionLocation
    {
        let info = try await transport.paneProcessInfo(PaneProcessInfoParams(paneID: paneID))
        let process = try claudeProcess(in: info)
        let sessionsPath = sessionsFilePath(pid: process.pid)
        let page = try await transport.readHostFileRange(
            path: sessionsPath, offset: 0, maxBytes: maximumSessionRecordBytes)
        let record: ClaudeSessionRecord
        do {
            record = try decodeSession(page.data)
        } catch {
            throw ClaudeSessionLocatorError.malformedSessionsFile
        }
        guard let transcript = transcriptPath(cwd: record.cwd, sessionID: record.sessionID)
        else {
            throw ClaudeSessionLocatorError.malformedSessionsFile
        }
        return ClaudeSessionLocation(
            pid: process.pid, session: record, sessionsFilePath: sessionsPath,
            transcriptPath: transcript)
    }
}

enum ClaudeSessionLocatorError: Error, Equatable, Sendable {
    case noForegroundProcess
    case foregroundIsNotClaude(name: String)
    case malformedSessionsFile
}

/// `~/.claude/sessions/<pid>.json`, leniently: only the two fields the
/// route needs are required. `status` is Claude Code's own (`idle`, `busy`,
/// `waiting` on a permission prompt).
struct ClaudeSessionRecord: Decodable, Sendable, Equatable {
    let pid: Int?
    let sessionID: String
    let cwd: String
    let status: ClaudeSessionStatus?
    let name: String?
    let version: String?
    let startedAt: String?
    let updatedAt: String?

    private enum CodingKeys: String, CodingKey {
        case pid, cwd, status, name, version, startedAt, updatedAt
        case sessionID = "sessionId"
    }
}

struct ClaudeSessionStatus: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    static let idle = ClaudeSessionStatus(rawValue: "idle")
    static let busy = ClaudeSessionStatus(rawValue: "busy")
    static let waiting = ClaudeSessionStatus(rawValue: "waiting")
}

struct ClaudeSessionLocation: Sendable, Equatable {
    let pid: Int
    let session: ClaudeSessionRecord
    let sessionsFilePath: String
    let transcriptPath: String
}
