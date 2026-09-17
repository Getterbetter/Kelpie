import Darwin
import HeelerSSH
import Testing

/// The socket-level keepalive applied right after connect (Open items 22, 27):
/// a path that dies silently is otherwise noticed only by the app-level ping.
@Suite("SSH socket options")
struct SSHSocketOptionsTests {
    @Test func applyKeepaliveSetsEveryOptionOnATCPSocket() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        try #require(fd >= 0)
        defer { Darwin.close(fd) }

        let policy = SSHSocketOptions.KeepalivePolicy.default
        try SSHSocketOptions.applyKeepalive(policy, to: fd)

        #expect(try readOption(fd, SOL_SOCKET, SO_KEEPALIVE) != 0)
        #expect(try readOption(fd, IPPROTO_TCP, TCP_KEEPALIVE) == policy.idle)
        #expect(try readOption(fd, IPPROTO_TCP, TCP_KEEPINTVL) == policy.interval)
        #expect(try readOption(fd, IPPROTO_TCP, TCP_KEEPCNT) == policy.count)
    }

    @Test func defaultPolicyIsTheShortProbeSchedule() {
        let policy = SSHSocketOptions.KeepalivePolicy.default
        #expect(policy.idle == 15)
        #expect(policy.interval == 5)
        #expect(policy.count == 3)
    }

    private func readOption(_ fd: Int32, _ level: Int32, _ name: Int32) throws -> Int32 {
        var value: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        let result = getsockopt(fd, level, name, &value, &length)
        try #require(result == 0)
        return value
    }
}
