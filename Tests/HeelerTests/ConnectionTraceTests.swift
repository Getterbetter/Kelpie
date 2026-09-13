import Foundation
import Testing

@testable import Heeler

/// The connection trace (Open item 22): the reason a Host never comes back has
/// to be pullable off the device, because nobody has yet read it off the
/// screen. Bounded on purpose — a regression here is a session that never
/// reaches its failure, which must fail rather than hang the run.
@Suite("Connection trace", .timeLimit(.minutes(1)))
struct ConnectionTraceTests {
    /// A sink that keeps what the trace wrote, and a counter proving whether
    /// the entry was ever built.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        private var entriesBuilt = 0

        var written: [String] {
            lock.lock()
            defer { lock.unlock() }
            return lines
        }

        var built: Int {
            lock.lock()
            defer { lock.unlock() }
            return entriesBuilt
        }

        func log(isEnabled: Bool) -> ConnectionTraceLog {
            ConnectionTraceLog(
                isEnabled: isEnabled,
                sink: { [self] line in
                    lock.lock()
                    lines.append(line)
                    lock.unlock()
                },
                now: { Date(timeIntervalSince1970: 1_700_000_000.5) })
        }

        /// An entry whose construction is counted, so "no string formatting
        /// when disabled" is a fact rather than a claim.
        func countedEntry(_ phase: ConnectionTracePhase) -> ConnectionTraceEntry {
            lock.lock()
            entriesBuilt += 1
            lock.unlock()
            return ConnectionTraceEntry(host: "host-1", phase: phase, outcome: .started)
        }
    }

    /// The connect closure's scripted failures, one per attempt.
    private final class FailureQueue: @unchecked Sendable {
        private let lock = NSLock()
        private var failures: [TransportError]

        init(_ failures: [TransportError]) {
            self.failures = failures
        }

        func next() -> TransportError {
            lock.lock()
            defer { lock.unlock() }
            return failures.isEmpty ? .timedOut : failures.removeFirst()
        }
    }

    // MARK: Gating

    @Test func aDisabledTraceWritesNothingAndBuildsNothing() {
        let recorder = Recorder()
        let log = recorder.log(isEnabled: false)

        log.record(recorder.countedEntry(.connect))
        log.record(recorder.countedEntry(.subscribe))
        log.notePath("satisfied via en0", change: "interfacesChanged")

        #expect(recorder.written.isEmpty)
        // The autoclosure was never forced: disabled costs one early return.
        #expect(recorder.built == 0)
        #expect(log.currentPath == nil)
    }

    @Test func anEnabledTraceWritesOneLinePerEntry() {
        let recorder = Recorder()
        let log = recorder.log(isEnabled: true)

        log.record(recorder.countedEntry(.connect))
        log.record(recorder.countedEntry(.subscribe))

        #expect(recorder.written.count == 2)
        #expect(recorder.built == 2)
        // One entry is one line: the file is parsed a line at a time.
        #expect(recorder.written.allSatisfy { !$0.contains("\n") })
    }

    // MARK: The line's fields

    @Test func aFailureLineCarriesEveryFieldTheDiagnosisNeeds() {
        let entry = ConnectionTraceEntry(
            host: "abcd1234",
            phase: .connect,
            outcome: .failed(
                reason: String(
                    describing: TransportError.sshUnreachable(detail: "no route to host")),
                retryable: true),
            attempt: 3,
            backoff: .seconds(4),
            path: "satisfied via pdp_ip0",
            detail: "dialled")
        let line = entry.formatted(timestamp: Date(timeIntervalSince1970: 1_700_000_000.5))

        #expect(line.hasPrefix("1700000000.500 "))
        #expect(line.contains("host=abcd1234"))
        #expect(line.contains("phase=connect"))
        #expect(line.contains("outcome=failed"))
        #expect(line.contains("attempt=3"))
        #expect(line.contains("no route to host"))
        #expect(line.contains("retryable=yes"))
        #expect(line.contains("backoff=4.000s"))
        #expect(line.contains("detail=\"dialled\""))
        #expect(line.contains("path=\"satisfied via pdp_ip0\""))
    }

    @Test func aReasonWithNewlinesStaysOnOneLine() {
        let entry = ConnectionTraceEntry(
            host: "abcd1234",
            phase: .subscribe,
            outcome: .failed(reason: "first line\nsecond \"quoted\" line", retryable: false))
        let line = entry.formatted(timestamp: Date(timeIntervalSince1970: 0))

        #expect(!line.contains("\n"))
        #expect(line.contains("retryable=no"))
    }

    @Test func thePathSummaryRidesEveryLaterLine() {
        let recorder = Recorder()
        let log = recorder.log(isEnabled: true)

        log.notePath("satisfied via en0,utun4", change: "interfacesChanged")
        log.record(ConnectionTraceEntry(host: "abcd1234", phase: .connect, outcome: .started))

        let lines = recorder.written
        #expect(lines.count == 2)
        #expect(lines[0].contains("phase=path"))
        #expect(lines[0].contains("note=\"interfacesChanged\""))
        #expect(lines[1].contains("path=\"satisfied via en0,utun4\""))
        #expect(log.currentPath == "satisfied via en0,utun4")
    }

    @Test func aPathSnapshotSummarisesSatisfactionAndInterfaces() {
        #expect(
            NetworkPathSnapshot(isSatisfied: true, interfaces: ["en0", "utun4"]).summary
                == "satisfied via en0,utun4")
        #expect(
            NetworkPathSnapshot(isSatisfied: false).summary == "unsatisfied via none")
    }

    // MARK: The file sink

    /// The sink's callers are the MainActor path observer and the session
    /// actor, so `append` must not write the file itself: it hands one
    /// coalesced rewrite to a serial queue, and `flush()` is the only thing
    /// that waits for it.
    @Test func theFileSinkCoalescesItsWritesAndKeepsTheNewestLines() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("connection-trace.log")
        let file = ConnectionTraceFile(fileURL: url, limit: 3)

        for index in 1...5 {
            file.append("line \(index)")
        }
        // Nothing is promised before the flush; everything is after it.
        file.flush()

        #expect(try String(contentsOf: url, encoding: .utf8) == "line 3\nline 4\nline 5\n")
    }

    // MARK: The session's own outcomes

    /// The point of the whole facility: the Host that hangs is retrying
    /// something, and the trace has to name it — including the classification
    /// that decides whether the loop keeps going silently (retryable) or stops
    /// and reports (not).
    @Test func aSessionRecordsBothRetryableAndNonRetryableOutcomes() async {
        let recorder = Recorder()
        let log = recorder.log(isEnabled: true)
        let failures = FailureQueue([
            .sshUnreachable(detail: "no route to host"),
            .socketNotFound(path: "~/.config/herdr/herdr.sock"),
        ])
        let session = EventsSession(
            subscriptions: [.global(.paneAgentDetected)],
            connect: { throw failures.next() },
            reconnectPolicy: ReconnectPolicy(
                initialDelay: .milliseconds(10), multiplier: 2, maxDelay: .milliseconds(20)),
            keepalive: nil,
            connectionTrace: log,
            traceHost: "abcd1234")
        var updates = session.updates.makeAsyncIterator()

        await session.resume()
        #expect(await updates.next() == .status(.connecting))
        guard case .status(.reconnecting) = await updates.next() else {
            Issue.record("expected .reconnecting after the first retryable failure")
            await session.end()
            return
        }
        guard case .status(.failed) = await updates.next() else {
            Issue.record("expected .failed after the non-retryable failure")
            await session.end()
            return
        }
        await session.end()

        let lines = recorder.written
        #expect(lines.allSatisfy { $0.contains("host=abcd1234") })
        // The retryable one: recorded, classified, and never shown as final.
        #expect(
            lines.contains {
                $0.contains("phase=connect") && $0.contains("outcome=failed")
                    && $0.contains("retryable=yes") && $0.contains("no route to host")
            })
        // The non-retryable one, recorded just as fully.
        #expect(
            lines.contains {
                $0.contains("phase=connect") && $0.contains("outcome=failed")
                    && $0.contains("retryable=no") && $0.contains("herdr.sock")
            })
        // The backoff the loop chose, against its attempt number.
        #expect(
            lines.contains {
                $0.contains("phase=status") && $0.contains("reconnecting")
                    && $0.contains("attempt=1") && $0.contains("backoff=")
            })
        #expect(lines.contains { $0.contains("phase=lifecycle") && $0.contains("activate") })
        #expect(lines.contains { $0.contains("phase=connect") && $0.contains("outcome=started") })
    }

    /// A path change is the other half of the Tailscale story: it is what
    /// makes a live-looking socket worthless, and it must be in the file
    /// whatever the session's phase — a suspended session records it too.
    @Test func aSessionRecordsPathChangesAndTheSuspicionTheyCause() async {
        let recorder = Recorder()
        let log = recorder.log(isEnabled: true)
        let session = EventsSession(
            subscriptions: [.global(.paneAgentDetected)],
            connect: { throw TransportError.sshUnreachable(detail: "never dialled") },
            keepalive: nil,
            connectionTrace: log,
            traceHost: "abcd1234")

        await session.networkPathDidChange()

        #expect(await session.transportIsSuspect)
        #expect(
            recorder.written.contains {
                $0.contains("phase=path") && $0.contains("the network path changed")
            })
        await session.end()
    }

    @Test func aSessionWithTheTraceOffRecordsNothing() async {
        let recorder = Recorder()
        let session = EventsSession(
            subscriptions: [.global(.paneAgentDetected)],
            connect: { throw TransportError.sshUnreachable(detail: "never dialled") },
            keepalive: nil,
            connectionTrace: recorder.log(isEnabled: false),
            traceHost: "abcd1234")

        await session.networkPathDidChange()
        await session.end()

        #expect(recorder.written.isEmpty)
    }
}
