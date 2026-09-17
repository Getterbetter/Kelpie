import Darwin
import Foundation
import os

/// Socket-level options applied to a freshly connected SSH TCP socket.
///
/// Without TCP keepalive nothing below the app notices a path that dies
/// silently — an iPad moving from Wi-Fi to cellular, or a Tailscale route
/// changing underneath us — because neither peer sends a FIN or an RST. The
/// socket stays writable, libssh2 stays happy, and the first hint of trouble
/// is the app-level herdr ping in `EventsSession.KeepalivePolicy`, up to 30
/// seconds later (Open items 22 and 27). A short kernel keepalive probes the
/// path itself, so a dead connection surfaces as an error on the socket
/// rather than as an app-level timeout.
///
/// Applying these is best effort: a `setsockopt` failure is logged and the
/// connection proceeds. Keepalive is a detection improvement, never a
/// precondition for connecting.
public enum SSHSocketOptions {
    /// How aggressively the kernel probes an idle connection.
    ///
    /// The default is deliberately far shorter than Darwin's stock two-hour
    /// idle: 15 seconds idle, then probes every 5 seconds, failing after 3
    /// unanswered probes — a dead path is reported in roughly 30 seconds
    /// without waiting on the app-level ping.
    public struct KeepalivePolicy: Sendable, Equatable {
        /// Idle seconds before the first probe (Darwin's `TCP_KEEPALIVE`).
        public var idle: Int32
        /// Seconds between probes once probing has started (`TCP_KEEPINTVL`).
        public var interval: Int32
        /// Unanswered probes before the connection is declared dead
        /// (`TCP_KEEPCNT`).
        public var count: Int32

        public init(idle: Int32, interval: Int32, count: Int32) {
            self.idle = idle
            self.interval = interval
            self.count = count
        }

        public static let `default` = KeepalivePolicy(idle: 15, interval: 5, count: 3)
    }

    /// A `setsockopt` call that did not take effect.
    public struct KeepaliveFailure: Error, Sendable, Equatable {
        /// The option name, for the log line.
        public let option: String
        /// `errno` as captured immediately after the failing call.
        public let code: Int32
    }

    private static let log = Logger(subsystem: "dev.herdr.HeelerSSH", category: "socket")

    /// Turns keepalive on for `fd` and sets the three Darwin timers.
    ///
    /// Throws the first failure so a caller that cares can see it; the SSH
    /// connect path swallows the error after it has been logged.
    public static func applyKeepalive(_ policy: KeepalivePolicy, to fd: Int32) throws {
        try setOption(fd, SOL_SOCKET, SO_KEEPALIVE, 1, name: "SO_KEEPALIVE")
        try setOption(fd, IPPROTO_TCP, TCP_KEEPALIVE, policy.idle, name: "TCP_KEEPALIVE")
        try setOption(fd, IPPROTO_TCP, TCP_KEEPINTVL, policy.interval, name: "TCP_KEEPINTVL")
        try setOption(fd, IPPROTO_TCP, TCP_KEEPCNT, policy.count, name: "TCP_KEEPCNT")
    }

    /// Best-effort form used by the connect path: applies the policy and
    /// logs, rather than propagates, a failure.
    static func applyKeepaliveIgnoringFailure(_ policy: KeepalivePolicy, to fd: Int32) {
        do {
            try applyKeepalive(policy, to: fd)
        } catch let failure as KeepaliveFailure {
            log.notice(
                """
                TCP keepalive not applied: \(failure.option, privacy: .public) \
                failed with errno \(failure.code, privacy: .public)
                """)
        } catch {
            log.notice("TCP keepalive not applied")
        }
    }

    private static func setOption(
        _ fd: Int32,
        _ level: Int32,
        _ name: Int32,
        _ value: Int32,
        name label: String
    ) throws {
        var value = value
        guard
            setsockopt(fd, level, name, &value, socklen_t(MemoryLayout<Int32>.size)) == 0
        else {
            throw KeepaliveFailure(option: label, code: errno)
        }
    }
}
