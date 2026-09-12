import Foundation

/// The Host + pane an Agent Notification points at, resolved from a push's
/// encrypted envelope (#74). The key id → Host mapping is the one
/// established at Notification Registration: each `NotificationKeyRecord`
/// carries the hostID it was minted for, and the kid is derived from its key.
struct AgentNotificationTarget: Hashable, Sendable {
    let hostID: UUID
    let paneID: String

    /// The Console row this target lands on.
    var agentID: ConsoleAgent.ID {
        ConsoleAgent.ID(hostID: hostID, paneID: paneID)
    }
}

/// The deep-link and suppression decisions (#74) as pure functions, so the
/// UNUserNotificationCenter delegate stays a thin shim around them: real
/// notification presentation is not automatable, but these are.
enum AgentNotificationRouting {
    /// Resolves a push's `userInfo` to its Agent target: select the
    /// Notification Key by the envelope's kid, decrypt, read the pane. Nil —
    /// route to the Console — when the push carries no envelope, the kid
    /// matches no registered Host, or the envelope does not decrypt.
    static func target(
        userInfo: [AnyHashable: Any], keys: [NotificationKeyRecord]
    ) -> AgentNotificationTarget? {
        guard let (record, payload) = NotificationEnvelope.open(userInfo: userInfo, keys: keys)
        else { return nil }
        return AgentNotificationTarget(hostID: record.hostID, paneID: payload.paneID)
    }

    /// The presentation-time rule (spec #68, user story 8), applied by the
    /// in-app banner store when a held transition fires (#77): suppress the
    /// banner only when the user is already viewing that exact Agent; any
    /// mismatch — another pane, another Host, the Console list, an
    /// unresolvable target — shows it.
    static func shouldSuppressBanner(
        target: AgentNotificationTarget?, presentedAgent: ConsoleAgent.ID?
    ) -> Bool {
        guard let target, let presentedAgent else { return false }
        return target.agentID == presentedAgent
    }

    /// What a push delivered while the app is foregrounded should do.
    ///
    /// A delivered push is the one piece of evidence that the whole chain —
    /// plugin, relay, APNs, this device's registration — works, so it is
    /// never dropped on the assumption that some other pipeline will speak
    /// up. The in-app banner is preferred (it carries the tap target and
    /// matches the app's own presentation), but when it cannot be shown the
    /// system banner is, rather than silence.
    static func foregroundPresentation(
        target: AgentNotificationTarget?,
        presentedAgent: ConsoleAgent.ID?,
        canPresentInApp: Bool
    ) -> ForegroundPushPresentation {
        // The presented Agent stays silent either way: the user is looking
        // at the thing the push is about (spec #68, story 8).
        if shouldSuppressBanner(target: target, presentedAgent: presentedAgent) {
            return .suppressed
        }
        // No target — an unknown key id, or an envelope this device cannot
        // decrypt — has nowhere to tap through to, so iOS presents it and a
        // tap at least opens the app.
        guard let target, canPresentInApp else { return .systemBanner }
        return .inAppBanner(target)
    }
}

/// The outcome of `foregroundPresentation`.
enum ForegroundPushPresentation: Equatable, Sendable {
    /// Hand the push to the in-app banner; present nothing through iOS.
    case inAppBanner(AgentNotificationTarget)
    /// The user is already on this Agent; present nothing at all.
    case suppressed
    /// Let iOS present its own banner.
    case systemBanner
}
