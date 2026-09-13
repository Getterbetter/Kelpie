import Foundation
import Testing

@testable import Heeler

@MainActor
@Suite("Primary host selection")
struct PrimaryHostStoreTests {
    private func makeDefaults() throws -> (UserDefaults, cleanup: () -> Void) {
        let suiteName = "hm-primary-host-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return (defaults, { defaults.removePersistentDomain(forName: suiteName) })
    }

    private func makeHost(_ name: String) -> Host {
        Host.fixture(name: name, address: "\(name).local")
    }

    @Test func defaultsToTheFirstHost() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let hosts = [makeHost("one"), makeHost("two")]

        let store = PrimaryHostStore(defaults: defaults)

        #expect(store.selectedID == nil)
        #expect(store.host(in: hosts)?.id == hosts[0].id)
        #expect(store.host(in: []) == nil)
    }

    @Test func selectionPersistsAcrossStoreInstances() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let hosts = [makeHost("one"), makeHost("two")]
        let store = PrimaryHostStore(defaults: defaults)

        store.select(hosts[1].id)

        #expect(PrimaryHostStore(defaults: defaults).host(in: hosts)?.id == hosts[1].id)
    }

    @Test func healsWhenTheChosenHostIsDeleted() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let hosts = [makeHost("one"), makeHost("two")]
        let store = PrimaryHostStore(defaults: defaults)
        store.select(hosts[1].id)

        let remaining = [hosts[0]]
        store.hostsDidChange(remaining)

        #expect(store.selectedID == nil)
        #expect(store.host(in: remaining)?.id == hosts[0].id)
        // And the healed choice does not come back on the next launch.
        #expect(PrimaryHostStore(defaults: defaults).selectedID == nil)
    }

    /// A tap naming the Host already on screen changes nothing but still
    /// reports that it landed — the cover comes down on the strength of it.
    @Test func aTapOnThePrimaryHostLandsAndLeavesItAlone() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let hosts = [makeHost("one"), makeHost("two")]
        let store = PrimaryHostStore(defaults: defaults)
        store.select(hosts[1].id)

        #expect(store.land(onHostID: hosts[1].id, in: hosts))

        #expect(store.selectedID == hosts[1].id)
        #expect(store.host(in: hosts)?.id == hosts[1].id)
    }

    /// A notification from the other Host switches the root screen to it,
    /// through the same persisted selection the menu's Switch Host writes.
    @Test func aTapOnAnotherHostMakesItPrimaryAndPersists() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let hosts = [makeHost("one"), makeHost("two")]
        let store = PrimaryHostStore(defaults: defaults)

        #expect(store.land(onHostID: hosts[1].id, in: hosts))

        #expect(store.host(in: hosts)?.id == hosts[1].id)
        #expect(PrimaryHostStore(defaults: defaults).selectedID == hosts[1].id)
    }

    /// A stale push for a Host that has since been deleted: nothing to show,
    /// so nothing moves.
    @Test func aTapOnAnUnknownHostChangesNothing() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let hosts = [makeHost("one"), makeHost("two")]
        let store = PrimaryHostStore(defaults: defaults)
        store.select(hosts[0].id)

        #expect(store.land(onHostID: UUID(), in: hosts) == false)

        #expect(store.selectedID == hosts[0].id)
        #expect(PrimaryHostStore(defaults: defaults).selectedID == hosts[0].id)
    }

    @Test func aStoredHostThatIsStillPresentSurvivesACatalogChange() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let hosts = [makeHost("one"), makeHost("two")]
        let store = PrimaryHostStore(defaults: defaults)
        store.select(hosts[1].id)

        store.hostsDidChange(hosts.reversed())

        #expect(store.host(in: hosts)?.id == hosts[1].id)
    }
}
