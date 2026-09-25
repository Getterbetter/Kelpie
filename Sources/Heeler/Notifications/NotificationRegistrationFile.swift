import Foundation

/// Why Notification Registration failed. A closed taxonomy so the UI can
/// distinguish "install the plugin on this Host" from "the write broke"
/// (#72 acceptance criteria) instead of string-matching. Transport-level
/// failures (unreachable Host, timeout, cancellation) stay `TransportError`.
enum NotificationRegistrationError: Error, Sendable, Equatable {
    /// The Heeler plugin is not installed — or is disabled — on the
    /// Host, so nothing there would ever read a registration file.
    case pluginNotInstalled
    /// The plugin probe broke: `herdr plugin list` or `herdr plugin
    /// config-dir` could not run or printed something unparseable, so the
    /// plugin's presence and config dir are unknown.
    case pluginProbeFailed(detail: String)
    /// The registration file exists but could not be read.
    case readFailed(detail: String)
    /// The registration file could not be replaced atomically.
    case writeFailed(detail: String)
    /// The Host's registration file declares a version this build does not
    /// write. Clobbering it could destroy a newer app's registrations, so
    /// the ceremony refuses (the v1 contract bumps `v` only on breaking
    /// changes, honored by plugin and app together).
    case unsupportedFileVersion(Int)
    /// This device has no entry in the Host's registration file, so a Live
    /// Activity token cannot be attached (fail closed).
    case deviceNotRegistered
}

/// The `notify` preference flags of a registration file entry: which Agent
/// Status transitions this device wants pushed. Per the v1 contract a
/// missing flag means "do not send" (fail closed), so both are always
/// written explicitly.
struct NotificationTriggerPreferences: Sendable, Equatable {
    var blocked: Bool
    var done: Bool

    init(blocked: Bool = true, done: Bool = true) {
        self.blocked = blocked
        self.done = done
    }
}

/// One v1 device entry as this device writes it: the APNs token (with its
/// environment), the Host's Notification Key, and the notify flags.
struct NotificationDeviceEntry: Sendable, Equatable {
    let token: APNSDeviceToken
    /// Raw 32-byte Notification Key; encoded as unpadded base64url on the
    /// wire, like every cross-implementation byte field.
    let key: Data
    let notify: NotificationTriggerPreferences

    /// The wire form of this entry, keyed per the contract table.
    fileprivate var wireValue: JSONValue {
        .object([
            "token": .string(token.hex),
            "key": .string(key.base64URLEncodedString()),
            "env": .string(token.environment.rawValue),
            "notify": .object([
                "blocked": .bool(notify.blocked),
                "done": .bool(notify.done),
            ]),
        ])
    }
}

/// The `live_activity` field of a device entry: the per-activity push token
/// and when the app started that activity. `startedAt` is the ISO 8601
/// string as stored, so a rewrite can be compared without re-formatting.
/// `pinnedPaneIDs` is most-recently-pinned first; a missing or malformed
/// field reads as empty (docs/agents/live-activity-contract.md).
struct LiveActivityRegistration: Sendable, Equatable {
    var token: String
    var startedAt: String
    var pinnedPaneIDs: [String] = []
}

/// The Notification Registration file v1 (`plugin/README.md`): the whole
/// `notifications.json` a Host holds, keyed one entry per device token.
/// Entries this device did not write are carried verbatim as JSON — a newer
/// app's additive v1 metadata on another device's entry must survive a
/// rewrite from this one — and only the entry matching a given token is ever
/// replaced or removed, plus, on a re-registration that carries one, the
/// entry of the token this install previously registered here (open item 42:
/// a token change would otherwise leave its dead entry behind forever).
struct NotificationRegistrationFile: Sendable, Equatable {
    static let version = 1

    /// Every device entry, in file order; foreign entries preserved verbatim.
    private(set) var devices: [JSONValue]

    /// A file with no registered devices ("empty means no notifications").
    init() {
        devices = []
    }

    private init(devices: [JSONValue]) {
        self.devices = devices
    }

    /// Decodes the file a Host currently holds. Absent (`nil`) or corrupt
    /// content decodes as empty: the plugin reader treats both as "send
    /// nothing", and the next registration self-heals the file. A parseable
    /// file declaring a different version belongs to a different contract
    /// revision and is refused instead of clobbered.
    static func decode(_ data: Data?) throws -> NotificationRegistrationFile {
        guard let data, let wire = try? JSONDecoder().decode(WireFile.self, from: data) else {
            return NotificationRegistrationFile()
        }
        guard wire.v == version else {
            throw NotificationRegistrationError.unsupportedFileVersion(wire.v)
        }
        return NotificationRegistrationFile(devices: wire.devices ?? [])
    }

    /// Merges `entry`'s keys over the existing object carrying that token,
    /// or appends one: re-registration stays idempotent and additive fields
    /// this type does not own (`live_activity`, future metadata) survive.
    func upserting(_ entry: NotificationDeviceEntry) -> NotificationRegistrationFile {
        upserting(entry, replacing: nil)
    }

    /// The upsert above, but for an install whose APNs token changed: the
    /// entry carrying `previousToken` — the token this install last
    /// registered on this Host — is dropped first, so a rotation (or an
    /// Xcode-signed install becoming a TestFlight one) leaves one entry per
    /// device rather than a dead one per token. The old entry goes whole:
    /// its `live_activity` and `foreground_until` belong to the dead token
    /// and must not be carried onto the new one. `nil`, or the same token as
    /// `entry`, is the plain upsert.
    func upserting(
        _ entry: NotificationDeviceEntry, replacing previousToken: String?
    ) -> NotificationRegistrationFile {
        var updated = devices
        if let previousToken, previousToken != entry.token.hex {
            updated.removeAll { $0["token"]?.stringValue == previousToken }
        }
        if let index = updated.firstIndex(where: { $0["token"]?.stringValue == entry.token.hex }) {
            updated[index].mergeKeys(from: entry.wireValue)
        } else {
            updated.append(entry.wireValue)
        }
        return NotificationRegistrationFile(devices: updated)
    }

    /// Drops the entry carrying `token`; removing an entry revokes that
    /// device.
    func removing(token: String) -> NotificationRegistrationFile {
        NotificationRegistrationFile(
            devices: devices.filter { $0["token"]?.stringValue != token })
    }

    func containsDevice(token: String) -> Bool {
        devices.contains { $0["token"]?.stringValue == token }
    }

    /// Writes `live_activity` on the matching device entry and leaves every
    /// other field on that object untouched. Merges into an existing
    /// `live_activity` object so unknown fields and a prior pin list
    /// survive. An unknown token is a no-op; the ceremony refuses that case
    /// instead of inventing an entry.
    func settingLiveActivity(
        token: String,
        startedAt: Date,
        forDeviceToken deviceToken: String,
        pinnedPaneIDs: [String] = [],
        rowLayout: AgentRowLayout? = nil,
        hostName: String? = nil
    ) -> NotificationRegistrationFile {
        mutatingDevice(token: deviceToken) { entry in
            var live = objectValue(entry["live_activity"]) ?? .object([:])
            live.setKey("token", to: .string(token))
            live.setKey("started_at", to: .string(Self.iso8601String(from: startedAt)))
            live.setKey("pinned_pane_ids", to: .array(pinnedPaneIDs.map { .string($0) }))
            if let rowLayout { live.setKey("row_layout", to: rowLayout.activityRegistrationValue) }
            if let hostName { live.setKey("host_name", to: .string(hostName)) }
            entry.setKey("live_activity", to: live)
        }
    }

    /// Writes `pinned_pane_ids` on an existing `live_activity` object and
    /// leaves token, started_at, and unknown fields untouched. No-op when
    /// the device is missing or has no `live_activity` yet.
    func settingLiveActivityPinnedPaneIDs(
        _ pinnedPaneIDs: [String], forDeviceToken deviceToken: String
    ) -> NotificationRegistrationFile {
        mutatingDevice(token: deviceToken) { entry in
            guard var live = objectValue(entry["live_activity"]) else { return }
            live.setKey("pinned_pane_ids", to: .array(pinnedPaneIDs.map { .string($0) }))
            entry.setKey("live_activity", to: live)
        }
    }

    /// Updates the layout without replacing tokens, pins, or unknown fields.
    func settingLiveActivityRowLayout(
        _ layout: AgentRowLayout, hostName: String? = nil, forDeviceToken deviceToken: String
    ) -> NotificationRegistrationFile {
        mutatingDevice(token: deviceToken) { entry in
            guard var live = objectValue(entry["live_activity"]) else { return }
            live.setKey("row_layout", to: layout.activityRegistrationValue)
            if let hostName { live.setKey("host_name", to: .string(hostName)) }
            entry.setKey("live_activity", to: live)
        }
    }

    /// Writes (or with `nil` removes) `foreground_until` on the matching
    /// device entry: the foreground lease the plugin's notify hook reads to
    /// keep an alert off every *other* device while this one is on screen
    /// (open item 36). Every other field of the entry, and every other
    /// entry, is left as it was; an unknown token is a no-op.
    func settingForegroundUntil(
        _ date: Date?, forDeviceToken deviceToken: String
    ) -> NotificationRegistrationFile {
        mutatingDevice(token: deviceToken) { entry in
            entry.setKey("foreground_until", to: date.map { .string(Self.iso8601String(from: $0)) })
        }
    }

    /// The foreground lease instant the entry carrying `token` holds, nil
    /// when the device is unregistered or the field is missing, null, empty
    /// or unparseable — all of which mean "no lease", matching the plugin's
    /// lenient `Date.parse` reading.
    func foregroundUntil(token: String) -> Date? {
        guard let entry = devices.first(where: { $0["token"]?.stringValue == token }),
            let raw = entry["foreground_until"]?.stringValue, !raw.isEmpty
        else { return nil }
        return Self.iso8601Date(from: raw)
    }

    /// Drops `live_activity` from the matching device entry, preserving
    /// every other field. An unknown token is a no-op.
    func clearingLiveActivity(forDeviceToken deviceToken: String) -> NotificationRegistrationFile {
        mutatingDevice(token: deviceToken) { entry in
            entry.setKey("live_activity", to: nil)
        }
    }

    /// The `live_activity` field of the entry carrying `deviceToken`, nil
    /// when that device is not registered or the field is missing/mistyped.
    func liveActivity(forDeviceToken deviceToken: String) -> LiveActivityRegistration? {
        guard let entry = devices.first(where: { $0["token"]?.stringValue == deviceToken }),
            let liveToken = entry["live_activity"]?["token"]?.stringValue, !liveToken.isEmpty,
            let startedAt = entry["live_activity"]?["started_at"]?.stringValue, !startedAt.isEmpty
        else { return nil }
        return LiveActivityRegistration(
            token: liveToken,
            startedAt: startedAt,
            pinnedPaneIDs: Self.pinnedPaneIDs(from: entry["live_activity"]?["pinned_pane_ids"]))
    }

    /// Lenient reader for `live_activity.pinned_pane_ids`. Missing, null, a
    /// non-array, or any non-string entry yields an empty list — never a throw.
    static func pinnedPaneIDs(from value: JSONValue?) -> [String] {
        guard case .array(let items)? = value else { return [] }
        var ids: [String] = []
        ids.reserveCapacity(items.count)
        for item in items {
            guard case .string(let id) = item else { return [] }
            ids.append(id)
        }
        return ids
    }

    /// The APNs environment the entry carrying `token` names, nil when that
    /// device is not registered or the field is missing or unrecognised.
    /// Read rather than assumed: an entry whose `env` disagrees with the one
    /// this install registers in sends every push to the wrong APNs host,
    /// which answers `400 BadDeviceToken` and prunes nothing (ADR 0008).
    func environment(token: String) -> APNSEnvironment? {
        guard let entry = devices.first(where: { $0["token"]?.stringValue == token }),
            let raw = entry["env"]?.stringValue
        else { return nil }
        return APNSEnvironment(rawValue: raw)
    }

    /// The notify flags of the entry carrying `token`, nil when that device
    /// is not registered. A missing or mistyped flag reads as off — the same
    /// fail-closed reading the plugin's notify hook applies (v1 contract).
    func preferences(token: String) -> NotificationTriggerPreferences? {
        guard let entry = devices.first(where: { $0["token"]?.stringValue == token }) else {
            return nil
        }
        return NotificationTriggerPreferences(
            blocked: entry["notify"]?["blocked"] == .bool(true),
            done: entry["notify"]?["done"] == .bool(true))
    }

    /// The serialized file for an atomic whole-file replace. Sorted keys keep
    /// the output deterministic; the v1 contract imposes no canonical order.
    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(WireFile(v: Self.version, devices: devices))
    }

    private func objectValue(_ value: JSONValue?) -> JSONValue? {
        guard let value, case .object = value else { return nil }
        return value
    }

    private func mutatingDevice(
        token: String, update: (inout JSONValue) -> Void
    ) -> NotificationRegistrationFile {
        var updated = devices
        guard let index = updated.firstIndex(where: { $0["token"]?.stringValue == token }) else {
            return self
        }
        update(&updated[index])
        return NotificationRegistrationFile(devices: updated)
    }

    private static func iso8601String(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    /// Parses what `iso8601String(from:)` writes; fractional seconds are
    /// accepted too, since another writer's instant is still a valid lease.
    private static func iso8601Date(from string: String) -> Date? {
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: string) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: string)
    }

    /// The wire shape: `v` stays an integer end to end (`JSONValue` would
    /// round-trip it through Double), devices stay schema-free.
    private struct WireFile: Codable {
        let v: Int
        let devices: [JSONValue]?

        init(v: Int, devices: [JSONValue]) {
            self.v = v
            self.devices = devices
        }
    }
}

extension JSONValue {
    fileprivate mutating func mergeKeys(from other: JSONValue) {
        guard case .object(var fields) = self, case .object(let incoming) = other else {
            self = other
            return
        }
        for (key, value) in incoming {
            fields[key] = value
        }
        self = .object(fields)
    }

    fileprivate mutating func setKey(_ key: String, to value: JSONValue?) {
        guard case .object(var fields) = self else { return }
        if let value {
            fields[key] = value
        } else {
            fields.removeValue(forKey: key)
        }
        self = .object(fields)
    }
}

private extension AgentRowLayout {
    var activityRegistrationValue: JSONValue {
        .object([
            "rows": .array(normalizedForConsole().rows.map { row in
                .array(row.map { field in
                    var value: [String: JSONValue] = ["token": .string(field.token.rawValue)]
                    if let fg = field.fg { value["fg"] = .string(fg.rawValue) }
                    if let bold = field.bold { value["bold"] = .bool(bold) }
                    if let dim = field.dim { value["dim"] = .bool(dim) }
                    return .object(value)
                })
            }),
            "row_gap": .number(Double(rowGap)),
            "rows_by_agent": .object([:]),
        ])
    }
}

/// Sweeps the temporary files an interrupted SFTP replace leaves beside a
/// plugin config file (Open item 52). The replace writes
/// `<name>.tmp-<uuid>` and renames it over `<name>`; a connection that dies
/// mid-write cannot remove it, and 15 had built up on the mini by round 32.
///
/// After a successful replace the Transport lists the siblings over exec,
/// and removes those matching `<name>.tmp-*` whose modification time, by the
/// Host's own clock, is more than an hour old. Never the file it just wrote,
/// never anything else. Best effort: nothing here can fail the replace.
enum NotificationTemporaryFileSweep {
    /// Seconds a temporary file must be older than to be swept: far past any
    /// replace still in flight from another client.
    static let maximumAge: Int64 = 3600

    /// Lists the candidates under `/bin/sh` whatever the login shell (fish
    /// included; the script has no quote or backslash, and the directory and
    /// name arrive as positional parameters). The first line is the Host's
    /// clock, then one `<mtime> <file name>` per candidate; `stat -c %Y` is
    /// GNU, `stat -f %m` BSD and macOS.
    static func listingCommand(directory: String, fileName: String) -> String? {
        guard let quotedDirectory = RemoteShellPath.quotedAbsolute(directory),
            isSafeFileName(fileName)
        else { return nil }
        let script =
            #"cd "$1" || exit 1; date +%s; for f in "$2".tmp-*; do [ -f "$f" ] || continue; "#
            + #"m=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null) || continue; "#
            + #"echo "$m $f"; done"#
        return "/bin/sh -c '\(script)' sh \(quotedDirectory) '\(fileName)'"
    }

    /// The names from `listing` to remove: temporary siblings of
    /// `fileName`, older than `maximumAge` by the listed clock, other than
    /// `justWritten`. An unreadable clock sweeps nothing.
    static func staleNames(
        inListing listing: String, fileName: String, excluding justWritten: String?
    ) -> [String] {
        var lines = listing.split(whereSeparator: \.isNewline)
        guard let clock = lines.first,
            let now = Int64(clock.trimmingCharacters(in: .whitespaces))
        else { return [] }
        lines.removeFirst()
        return lines.compactMap { line in
            let fields = line.split(separator: " ", maxSplits: 1)
            guard fields.count == 2, let modified = Int64(fields[0]) else { return nil }
            let name = String(fields[1])
            guard isTemporaryName(name, of: fileName), name != justWritten,
                now - modified > maximumAge
            else { return nil }
            return name
        }
    }

    /// Whether `name` is one of the replace's own temporary files for
    /// `fileName`: the exact `<fileName>.tmp-` prefix and a non-empty
    /// letters, digits and hyphens suffix (a lowercased UUID).
    static func isTemporaryName(_ name: String, of fileName: String) -> Bool {
        let prefix = "\(fileName).tmp-"
        guard name.hasPrefix(prefix) else { return false }
        let suffix = name.dropFirst(prefix.count)
        return !suffix.isEmpty
            && suffix.unicodeScalars.allSatisfy { scalar in
                scalar.isASCII
                    && (CharacterSet.alphanumerics.contains(scalar) || scalar == "-")
            }
    }

    /// Removes `names` (already vetted by `isTemporaryName`) from the
    /// directory; nil when there is nothing to remove.
    static func removalCommand(directory: String, names: [String]) -> String? {
        guard !names.isEmpty,
            let quotedDirectory = RemoteShellPath.quotedAbsolute(directory),
            names.allSatisfy(isSafeFileName)
        else { return nil }
        let script = #"cd "$1" || exit 1; shift; rm -f -- "$@""#
        let arguments = names.map { "'\($0)'" }.joined(separator: " ")
        return "/bin/sh -c '\(script)' sh \(quotedDirectory) \(arguments)"
    }

    private static func isSafeFileName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix("-")
            && name.unicodeScalars.allSatisfy { scalar in
                scalar.isASCII
                    && (CharacterSet.alphanumerics.contains(scalar)
                        || scalar == "." || scalar == "_" || scalar == "-")
            }
    }
}

