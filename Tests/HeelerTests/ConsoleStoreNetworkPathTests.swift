import Foundation
import Testing

@testable import Heeler

/// What the Console does when the device's network path moves (S1), against
/// scripted transports: distrust every Host at once, and do not call it
/// recovered until each one is connected on a *new* Transport.
@MainActor
@Suite("Console store network path", .timeLimit(.minutes(1)))
struct ConsoleStoreNetworkPathTests {
    private static nonisolated let fastPolicy = ReconnectPolicy(
        initialDelay: .milliseconds(10), multiplier: 2, maxDelay: .milliseconds(50))

    private func makeStore(
        connectors: [Host.ID: SequencedTransportConnector]
    ) -> ConsoleStore {
        ConsoleStore(
            snapshotRetryDelay: .milliseconds(10),
            pins: PinnedAgentsStore(
                defaults: UserDefaults(suiteName: "kelpie-path-\(UUID().uuidString)")
                    ?? .standard)
        ) { host, subscriptions in
            EventsSession(
                subscriptions: subscriptions,
                connect: {
                    guard let connector = connectors[host.id] else {
                        throw TransportError.sshUnreachable(detail: "unscripted host")
                    }
                    return try await connector.connect()
                },
                reconnectPolicy: Self.fastPolicy,
                keepalive: nil)
        }
    }

    private func waitUntil(
        _ comment: Comment, timeout: Duration = .seconds(5),
        condition: () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await condition(), comment)
    }

    @Test func aPathChangeIsNotSettledUntilTheHostIsBackOnANewTransport() async throws {
        // The bug this closes: ending every live channel made `revalidate()`
        // early-return on its own `liveStream` guard, and `hostStatuses` was
        // still `.connected` when the observer sampled it — so the very first
        // attempt reported "settled" and the capped retry never retried.
        let host = Host.fixture()
        let connector = SequencedTransportConnector([
            ScriptedTransport(), ScriptedTransport(),
        ])
        let store = makeStore(connectors: [host.id: connector])
        store.setHosts([host])
        await store.resume()
        try await waitUntil("the Host should connect") {
            store.hostStatuses[host.id] == .connected
        }
        let baseline = store.hostConnectionGenerations[host.id] ?? 0

        await store.networkPathDidChange()

        // Synchronously on return: nothing on the old path is trustworthy, so
        // the Console must not still read green and the observer must not
        // call this recovered.
        #expect(!store.hostConnectionsAreSettled)
        #expect(store.hostStatuses[host.id] != .connected)

        try await waitUntil("the Host should come back on a fresh Transport") {
            store.hostConnectionsAreSettled
        }
        #expect(store.hostStatuses[host.id] == .connected)
        #expect((store.hostConnectionGenerations[host.id] ?? 0) > baseline)
        #expect(await connector.connectCount == 2)

        await store.suspend()
    }

    @Test func aPathChangeWithNoHostsIsSettledImmediately() async throws {
        let store = makeStore(connectors: [:])
        store.setHosts([])
        await store.resume()

        await store.networkPathDidChange()

        #expect(store.hostConnectionsAreSettled)
        await store.suspend()
    }
}
