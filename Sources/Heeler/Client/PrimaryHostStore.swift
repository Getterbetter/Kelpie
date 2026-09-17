import Foundation
import Observation

/// Which Host the root screen shows herdr's client for.
///
/// One Host is on screen at a time, so the choice is a single persisted id
/// rather than a navigation stack. It heals itself: a stored id whose Host has
/// been deleted falls back to the first Host, which is also what an install
/// that has never chosen sees.
@MainActor
@Observable
final class PrimaryHostStore {
    /// The single definition of the persisted-selection key; `PairingSync`
    /// reads and writes the same one.
    static let defaultsKey = "kelpie.primary-host"

    private(set) var selectedID: Host.ID?
    @ObservationIgnored private nonisolated(unsafe) let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selectedID = defaults.string(forKey: Self.defaultsKey).flatMap(UUID.init(uuidString:))
    }

    /// The Host to show, given the current catalog. Nil only when there are
    /// no Hosts at all.
    func host(in hosts: [Host]) -> Host? {
        if let selectedID, let host = hosts.first(where: { $0.id == selectedID }) {
            return host
        }
        return hosts.first
    }

    func select(_ id: Host.ID) {
        guard selectedID != id else { return }
        selectedID = id
        defaults.set(id.uuidString, forKey: Self.defaultsKey)
    }

    /// Where a notification or Live Activity tap lands (Open item 28): the
    /// root screen shows herdr for the Host the tap named, chosen and
    /// persisted exactly as the menu's Switch Host chooses it. Returns false
    /// when the link names a Host this install no longer has — a deleted
    /// Host, or one paired on another device — in which case the screen stays
    /// on the Host it was already showing.
    @discardableResult
    func land(onHostID hostID: Host.ID, in hosts: [Host]) -> Bool {
        guard hosts.contains(where: { $0.id == hostID }) else { return false }
        select(hostID)
        return true
    }

    /// Drops a stored id the catalog no longer contains, so the fallback is
    /// not re-evaluated on every read and a re-added Host with a new id does
    /// not inherit the old choice.
    func hostsDidChange(_ hosts: [Host]) {
        guard let selectedID, !hosts.contains(where: { $0.id == selectedID }) else { return }
        self.selectedID = nil
        defaults.removeObject(forKey: Self.defaultsKey)
    }
}
