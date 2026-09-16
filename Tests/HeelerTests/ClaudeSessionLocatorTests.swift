import Foundation
import Testing

@testable import Heeler

/// Pane → transcript (ADR 0019): the process rule, the path encoding, the
/// lenient sessions record, and the whole route over a scripted transport.
@Suite("Claude session locator")
struct ClaudeSessionLocatorTests {
    private func process(
        name: String, pid: Int = 86367, argv0: String? = nil, argv: [String]? = nil,
        cwd: String? = "/Users/kelpie/Developer/Kelpie"
    ) -> PaneProcessInfoProcess {
        PaneProcessInfoProcess(name: name, pid: pid, argv: argv, argv0: argv0, cwd: cwd)
    }

    private func info(_ processes: [PaneProcessInfoProcess]?) -> PaneProcessInfo {
        PaneProcessInfo(paneID: "wC:p1", foregroundProcesses: processes, shellPid: 100)
    }

    // MARK: Process selection

    @Test func picksTheClaudeProcessByExecutableBasename() throws {
        #expect(try ClaudeSessionLocator.claudeProcess(in: info([process(name: "2.1.273", argv0: "claude")])).pid == 86367)
        #expect(try ClaudeSessionLocator.claudeProcess(in: info([process(name: "node", argv0: "/opt/homebrew/bin/claude")])).pid == 86367)
        #expect(try ClaudeSessionLocator.claudeProcess(in: info([process(name: "node", argv: ["claude", "--resume"])])).pid == 86367)
        #expect(try ClaudeSessionLocator.claudeProcess(in: info([process(name: "claude")])).pid == 86367)
        // The shell is first in the group; Claude is still found.
        let found = try ClaudeSessionLocator.claudeProcess(
            in: info([process(name: "zsh", pid: 100, argv0: "-zsh"), process(name: "claude", pid: 200)]))
        #expect(found.pid == 200)
    }

    @Test func refusesPanesWithoutClaudeInTheForeground() {
        #expect(throws: ClaudeSessionLocatorError.noForegroundProcess) {
            try ClaudeSessionLocator.claudeProcess(in: info([]))
        }
        #expect(throws: ClaudeSessionLocatorError.noForegroundProcess) {
            try ClaudeSessionLocator.claudeProcess(in: info(nil))
        }
        #expect(throws: ClaudeSessionLocatorError.foregroundIsNotClaude(name: "zsh")) {
            try ClaudeSessionLocator.claudeProcess(in: info([process(name: "zsh", argv0: "-zsh")]))
        }
        #expect(throws: ClaudeSessionLocatorError.foregroundIsNotClaude(name: "codex")) {
            try ClaudeSessionLocator.claudeProcess(in: info([process(name: "codex", argv0: "codex")]))
        }
        #expect(throws: ClaudeSessionLocatorError.foregroundIsNotClaude(name: "node")) {
            try ClaudeSessionLocator.claudeProcess(in: info([process(name: "node", argv0: "/usr/bin/claude-wrapper")]))
        }
    }

    // MARK: Paths

    @Test func sessionsFileIsHomeRelative() {
        #expect(ClaudeSessionLocator.sessionsFilePath(pid: 86367) == "~/.claude/sessions/86367.json")
    }

    @Test(arguments: [
        ("/Users/dev/Developer/Kelpie", "-Users-dev-Developer-Kelpie"),
        ("/private/tmp/claude-501/-Users-x", "-private-tmp-claude-501--Users-x"),
        ("/Users/dev/My Project.app", "-Users-dev-My-Project-app"),
        ("~/x", "--x"),
        ("/", "-"),
        ("/Users/dev/日本", "-Users-dev---"),
    ])
    func encodesEveryNonAlphanumericAsADash(cwd: String, expected: String) {
        #expect(ClaudeSessionLocator.encodedProjectDirectory(cwd: cwd) == expected)
    }

    @Test func transcriptPathJoinsTheEncodedDirectoryAndSessionID() {
        #expect(
            ClaudeSessionLocator.transcriptPath(
                cwd: "/Users/dev/Developer/Kelpie", sessionID: "91233534-abcd-4000-8000-0000deadbeef")
                == "~/.claude/projects/-Users-dev-Developer-Kelpie/91233534-abcd-4000-8000-0000deadbeef.jsonl")
        #expect(ClaudeSessionLocator.transcriptPath(cwd: "/x", sessionID: "") == nil)
        #expect(ClaudeSessionLocator.transcriptPath(cwd: "/x", sessionID: "../etc") == nil)
        #expect(ClaudeSessionLocator.transcriptPath(cwd: "/x", sessionID: "a b") == nil)
    }

    // MARK: The sessions record

    private let liveRecord = #"{"pid":86367,"sessionId":"91233534-1111-4222-8333-444455556666","cwd":"/Users/kelpie/Developer/maple-and-salt","status":"idle","name":"maple-and-salt-c6","version":"2.1.273","startedAt":"2026-09-16T00:10:00.000Z","updatedAt":"2026-09-16T00:16:26.097Z","messagingSocketPath":"/tmp/cc-socks/86367.sock","peerProtocol":1}"#

    @Test func decodesTheLiveRecordShapeAndIgnoresWhatItDoesNotKnow() throws {
        let record = try ClaudeSessionLocator.decodeSession(Data(liveRecord.utf8))
        #expect(record.pid == 86367)
        #expect(record.sessionID == "91233534-1111-4222-8333-444455556666")
        #expect(record.cwd == "/Users/kelpie/Developer/maple-and-salt")
        #expect(record.status == .idle)
        #expect(record.name == "maple-and-salt-c6")
        #expect(record.version == "2.1.273")
    }

    @Test func decodesAMinimalRecordAndAnUnknownStatus() throws {
        let minimal = try ClaudeSessionLocator.decodeSession(Data(#"{"sessionId":"s1","cwd":"/x"}"#.utf8))
        #expect(minimal.status == nil)
        #expect(minimal.pid == nil)
        let odd = try ClaudeSessionLocator.decodeSession(Data(#"{"sessionId":"s1","cwd":"/x","status":"dreaming"}"#.utf8))
        #expect(odd.status == ClaudeSessionStatus(rawValue: "dreaming"))
        #expect(odd.status != .waiting)
    }

    @Test func refusesARecordWithoutASessionID() {
        #expect(throws: (any Error).self) {
            try ClaudeSessionLocator.decodeSession(Data(#"{"pid":1,"cwd":"/x"}"#.utf8))
        }
    }

    // MARK: The route

    @Test func locatesTheTranscriptThroughTheScriptedTransport() async throws {
        let transport = ScriptedTransport()
        await transport.setPaneProcessInfo(
            info([process(name: "2.1.273", argv0: "claude", cwd: "/Users/kelpie/Developer/maple-and-salt")]),
            paneID: "wC:p1")
        await transport.setHostFile(Data(liveRecord.utf8), atPath: "~/.claude/sessions/86367.json")

        let location = try await ClaudeSessionLocator.locate(paneID: "wC:p1", transport: transport)

        #expect(location.pid == 86367)
        #expect(location.sessionsFilePath == "~/.claude/sessions/86367.json")
        #expect(
            location.transcriptPath
                == "~/.claude/projects/-Users-kelpie-Developer-maple-and-salt/91233534-1111-4222-8333-444455556666.jsonl")
        #expect(location.session.status == .idle)
        #expect(await transport.paneProcessInfoParams == [PaneProcessInfoParams(paneID: "wC:p1")])
        let reads = await transport.hostFileRangeReads
        #expect(reads.count == 1)
        #expect(reads.first?.path == "~/.claude/sessions/86367.json")
        #expect(reads.first?.offset == 0)
        #expect(reads.first?.maxBytes == ClaudeSessionLocator.maximumSessionRecordBytes)
    }

    @Test func aDeadPaneAndAnExitedSessionSurfaceTheTransportsErrors() async throws {
        let transport = ScriptedTransport()
        await #expect(throws: HerdrAPIError.self) {
            _ = try await ClaudeSessionLocator.locate(paneID: "wX:p9", transport: transport)
        }
        await transport.setPaneProcessInfo(info([process(name: "claude", pid: 4242)]), paneID: "wC:p1")
        await #expect(throws: HostFileDownloadError.notFound(path: "~/.claude/sessions/4242.json")) {
            _ = try await ClaudeSessionLocator.locate(paneID: "wC:p1", transport: transport)
        }
    }

    @Test func aGarbledSessionsRecordIsItsOwnError() async throws {
        let transport = ScriptedTransport()
        await transport.setPaneProcessInfo(info([process(name: "claude", pid: 7)]), paneID: "wC:p1")
        await transport.setHostFile(Data("not json".utf8), atPath: "~/.claude/sessions/7.json")
        await #expect(throws: ClaudeSessionLocatorError.malformedSessionsFile) {
            _ = try await ClaudeSessionLocator.locate(paneID: "wC:p1", transport: transport)
        }
        await transport.setHostFile(Data(#"{"sessionId":"../x","cwd":"/x"}"#.utf8), atPath: "~/.claude/sessions/7.json")
        await #expect(throws: ClaudeSessionLocatorError.malformedSessionsFile) {
            _ = try await ClaudeSessionLocator.locate(paneID: "wC:p1", transport: transport)
        }
    }

    @Test func aShellPaneIsReportedNotAClaudePane() async throws {
        let transport = ScriptedTransport()
        await transport.setPaneProcessInfo(info([process(name: "zsh", argv0: "-zsh")]), paneID: "wC:p1")
        await #expect(throws: ClaudeSessionLocatorError.foregroundIsNotClaude(name: "zsh")) {
            _ = try await ClaudeSessionLocator.locate(paneID: "wC:p1", transport: transport)
        }
        #expect(await transport.hostFileRangeReads.isEmpty)
    }
}
