import Foundation
import Synchronization

/// A diagnostic trace of every connect / reconnect outcome the Host's
/// `EventsSession` reaches, written to `Documents/connection-trace.log` so the
/// reason a Host is stuck can be pulled off a device over USB instead of read
/// off the screen:
///
///     xcrun devicectl device copy from --device <id> --domain-type appDataContainer \
///         --domain-identifier TME.Kelpie --source Documents/connection-trace.log \
///         --destination <path>
///
/// Off unless the app is launched with `kelpie.connection-trace` set — or with
/// `kelpie.key-trace`, so the one flag that is already muscle memory turns both
/// traces on:
///
///     xcrun devicectl device process launch --device <id> TME.Kelpie \
///         -kelpie.connection-trace YES
///
/// This exists because Open item 22 (the root screen hangs on Reconnecting off
/// Wi-Fi over Tailscale, while the Host-settings Preflight succeeds) has never
/// been seen with its reason attached: the failure is on a device, in a place
/// os_log cannot be read from without root, and the retry loop erases each
/// attempt as it starts the next one.
///
/// Unlike `TerminalKeyTrace`, this trace records no keystrokes and no pane
/// content — only connection phases, error descriptions, and the network path
/// summary — so it is safe to leave on for an ordinary session.
///
/// The phase of one connection attempt an entry describes.
enum ConnectionTracePhase: String, Sendable {
    /// Dialling, or deciding to reuse, the Host's SSH transport.
    case connect
    /// The `ping` every new connection path proves itself with. This is the
    /// closest thing the session has to Preflight's own check.
    case ping
    /// `events.subscribe`, and the lifetime of the stream it returns.
    case subscribe
    /// A published `EventsSessionStatus` transition.
    case status
    /// An Attach waiting for, or receiving, the session's Transport.
    case attach
    /// The device's network path moved.
    case path
    /// The installed Transport was marked untrustworthy.
    case suspect
    /// resume / retry / suspend / end.
    case lifecycle
}

/// One line of the connection trace.
struct ConnectionTraceEntry: Sendable, Equatable {
    enum Outcome: Sendable, Equatable {
        case started
        case succeeded
        /// `retryable` is the session's own classification — the fact that
        /// decides whether the loop keeps going silently or stops and reports.
        case failed(reason: String, retryable: Bool)
        case note(String)

        var label: String {
            switch self {
            case .started: "started"
            case .succeeded: "ok"
            case .failed: "failed"
            case .note: "note"
            }
        }
    }

    /// The Host this entry belongs to: its id where the caller has one, its
    /// label otherwise. Never an address, so the trace can be pasted into an
    /// issue.
    var host: String
    var phase: ConnectionTracePhase
    var outcome: Outcome
    /// The reconnect loop's 1-based attempt number, where one is running.
    var attempt: Int?
    /// The backoff the loop chose before the next attempt.
    var backoff: Duration?
    /// The most recent network path summary, filled in by the log when the
    /// caller has none of its own.
    var path: String?
    /// Anything phase-specific worth a word: a measured latency, a generation.
    var detail: String?

    init(
        host: String,
        phase: ConnectionTracePhase,
        outcome: Outcome,
        attempt: Int? = nil,
        backoff: Duration? = nil,
        path: String? = nil,
        detail: String? = nil
    ) {
        self.host = host
        self.phase = phase
        self.outcome = outcome
        self.attempt = attempt
        self.backoff = backoff
        self.path = path
        self.detail = detail
    }

    /// One space-separated `key=value` line, stable enough to grep and to
    /// diff between two device runs.
    func formatted(timestamp: Date) -> String {
        var fields = [
            String(format: "%.3f", timestamp.timeIntervalSince1970),
            "host=\(Self.field(host))",
            "phase=\(phase.rawValue)",
            "outcome=\(outcome.label)",
        ]
        if let attempt {
            fields.append("attempt=\(attempt)")
        }
        switch outcome {
        case .failed(let reason, let retryable):
            fields.append("reason=\(Self.quoted(reason))")
            fields.append("retryable=\(retryable ? "yes" : "no")")
        case .note(let note):
            fields.append("note=\(Self.quoted(note))")
        case .started, .succeeded:
            break
        }
        if let backoff {
            fields.append("backoff=\(Self.seconds(backoff))s")
        }
        if let detail {
            fields.append("detail=\(Self.quoted(detail))")
        }
        if let path {
            fields.append("path=\(Self.quoted(path))")
        }
        return fields.joined(separator: " ")
    }

    /// A bare token: whitespace would split one field into two.
    private static func field(_ value: String) -> String {
        let collapsed = value.unicodeScalars.map { scalar in
            CharacterSet.whitespacesAndNewlines.contains(scalar) ? "_" : String(scalar)
        }
        return collapsed.isEmpty ? "-" : collapsed.joined()
    }

    private static func quoted(_ value: String) -> String {
        var out = "\""
        for character in value {
            switch character {
            case "\n", "\r": out += " "
            case "\"": out += "'"
            default: out.append(character)
            }
        }
        return out + "\""
    }

    private static func seconds(_ duration: Duration) -> String {
        let components = duration.components
        let value =
            Double(components.seconds) + Double(components.attoseconds) / 1e18
        return String(format: "%.3f", value)
    }
}

/// The trace's writer: a gate, a sink, and the latest network path.
///
/// Disabled is a single stored `Bool` and one early return — the entry itself
/// arrives as an autoclosure, so nothing is described, interpolated or
/// formatted when the trace is off.
final class ConnectionTraceLog: Sendable {
    /// Launch argument (or default) that turns this trace on.
    static let enableKey = "kelpie.connection-trace"
    /// The keystroke trace's flag also turns this one on, so one flag enables
    /// both and a device run cannot accidentally carry only half the evidence.
    static let keyTraceKey = "kelpie.key-trace"

    static let shared = ConnectionTraceLog(
        isEnabled: UserDefaults.standard.bool(forKey: enableKey)
            || UserDefaults.standard.bool(forKey: keyTraceKey),
        sink: { line in ConnectionTraceFile.shared.append(line) })

    let isEnabled: Bool
    private let sink: @Sendable (String) -> Void
    private let now: @Sendable () -> Date
    private let latestPath = Mutex<String?>(nil)

    init(
        isEnabled: Bool,
        sink: @escaping @Sendable (String) -> Void,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.isEnabled = isEnabled
        self.sink = sink
        self.now = now
    }

    /// Writes one entry, filling in the last known network path when the
    /// caller did not carry one.
    func record(_ entry: @autoclosure () -> ConnectionTraceEntry) {
        guard isEnabled else { return }
        var entry = entry()
        if entry.path == nil {
            entry.path = latestPath.withLock { $0 }
        }
        sink(entry.formatted(timestamp: now()))
    }

    /// Records the device's current network path and remembers it for every
    /// later entry. The session itself never sees an `NWPath`, and the summary
    /// is exactly the fact that decides whether a live-looking socket is worth
    /// anything.
    ///
    /// Both arguments are autoclosures: this is the one call site outside the
    /// session, and it is on the MainActor, so a disabled trace must not pay
    /// for the summary's join or the change's `String(describing:)` either.
    func notePath(
        _ summary: @autoclosure () -> String,
        change: @autoclosure () -> String
    ) {
        guard isEnabled else { return }
        let summary = summary()
        latestPath.withLock { $0 = summary }
        record(
            ConnectionTraceEntry(
                host: "-", phase: .path, outcome: .note(change()), path: summary))
    }

    /// The path summary later entries will carry. Diagnostic surface.
    var currentPath: String? { latestPath.withLock { $0 } }
}

/// The on-device sink: `Documents/connection-trace.log`, rewritten atomically
/// from a private serial queue, so a trace pulled off a device that was killed
/// mid-run is still whole.
///
/// `append` is O(1) for its caller — a lock, an array append, and at most one
/// `async` — because the callers are the MainActor path observer and the
/// `EventsSession` actor, and neither may block on disk while a reconnect
/// storm is exactly the thing being measured. The whole-file rewrite that
/// `TerminalKeyTrace` does inline happens on the queue instead.
///
/// Writes coalesce: while one is pending no second is enqueued, and the
/// pending write snapshots the ring when it finally runs, so a burst of lines
/// costs one rewrite rather than one per line. The snapshot is taken under the
/// lock on the same serial queue that writes it, so the last write to land is
/// always the newest one.
final class ConnectionTraceFile: Sendable {
    static let shared = ConnectionTraceFile(fileURL: defaultFileURL)

    static var defaultFileURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("connection-trace.log")
    }

    private struct State {
        var lines: [String] = []
        /// A rewrite is enqueued and has not taken its snapshot yet.
        var writeIsPending = false
    }

    private let state = Mutex(State())
    private let fileURL: URL?
    private let limit: Int
    private let queue = DispatchQueue(
        label: "dev.bybee.heeler.connection-trace", qos: .utility)

    init(fileURL: URL?, limit: Int = 4000) {
        self.fileURL = fileURL
        self.limit = limit
    }

    func append(_ line: String) {
        let shouldEnqueue = state.withLock { state -> Bool in
            state.lines.append(line)
            if state.lines.count > limit {
                state.lines.removeFirst(state.lines.count - limit)
            }
            guard !state.writeIsPending else { return false }
            state.writeIsPending = true
            return true
        }
        guard shouldEnqueue else { return }
        queue.async { [self] in write() }
    }

    /// Blocks until every enqueued rewrite has run. For tests and teardown;
    /// nothing on a hot path calls it.
    func flush() {
        queue.sync {}
    }

    private func write() {
        // Cleared before the snapshot, not after: a line appended while this
        // write is in flight enqueues another one rather than being stranded
        // until the next unrelated append.
        let snapshot = state.withLock { state -> String in
            state.writeIsPending = false
            return state.lines.joined(separator: "\n") + "\n"
        }
        guard
            let fileURL,
            let data = snapshot.data(using: .utf8)
        else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
