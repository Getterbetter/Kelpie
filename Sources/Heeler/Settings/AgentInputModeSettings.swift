import Foundation
import Observation

/// How Agent detail accepts authored input. Composer is the ADR 0013 default;
/// Direct Input is the exception that routes the system keyboard into the live
/// Attach PTY (ADR 0016).
enum AgentInputMode: String, CaseIterable, Identifiable, Sendable {
    case composer
    case direct

    var id: Self { self }

    /// Short segment title for the iPad mode control. VoiceOver speaks this
    /// value under the "Input mode" label.
    var segmentTitle: String {
        switch self {
        case .composer: "Composer"
        case .direct: "Keyboard"
        }
    }
}

/// What the user asked for, as opposed to what it resolves to.
///
/// Automatic is the default (ADR 0017): a hardware keyboard makes the Composer
/// a detour — the keys are already there — while without one, Direct Input has
/// no chrome of its own to type into. Either explicit choice still wins and
/// still persists.
enum AgentInputModePreference: String, CaseIterable, Identifiable, Sendable {
    case automatic
    case composer
    case direct

    var id: Self { self }

    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .composer: AgentInputMode.composer.segmentTitle
        case .direct: AgentInputMode.direct.segmentTitle
        }
    }

    func resolved(hardwareKeyboardConnected: Bool) -> AgentInputMode {
        switch self {
        case .automatic: hardwareKeyboardConnected ? .direct : .composer
        case .composer: .composer
        case .direct: .direct
        }
    }
}

/// App-wide Agent detail input mode. Persists across navigation, reconnect,
/// and Agent switches. The default is Automatic; an unknown stored value falls
/// back to it rather than inventing a mode the user never picked.
@MainActor
@Observable
final class AgentInputModeSettings {
    private static let defaultsKey = "agent-input-mode"

    private(set) var preference: AgentInputModePreference
    /// Set by the app root from `HardwareKeyboardObserver`. Only Automatic
    /// reads it.
    private(set) var isHardwareKeyboardConnected: Bool
    @ObservationIgnored private nonisolated(unsafe) let defaults: UserDefaults

    init(defaults: UserDefaults = .standard, isHardwareKeyboardConnected: Bool = false) {
        self.defaults = defaults
        self.isHardwareKeyboardConnected = isHardwareKeyboardConnected
        preference =
            defaults.string(forKey: Self.defaultsKey)
            .flatMap(AgentInputModePreference.init(rawValue:)) ?? .automatic
    }

    /// The mode Agent detail actually runs in.
    var mode: AgentInputMode {
        preference.resolved(hardwareKeyboardConnected: isHardwareKeyboardConnected)
    }

    var isDirect: Bool { mode == .direct }

    /// The two-way control on the Agent screen: picking a mode there is an
    /// explicit choice, so it leaves Automatic behind.
    func select(_ mode: AgentInputMode) {
        select(preference: mode == .direct ? .direct : .composer)
    }

    func select(preference: AgentInputModePreference) {
        guard preference != self.preference else { return }
        self.preference = preference
        defaults.set(preference.rawValue, forKey: Self.defaultsKey)
    }

    func hardwareKeyboardDidChange(_ isConnected: Bool) {
        guard isConnected != isHardwareKeyboardConnected else { return }
        isHardwareKeyboardConnected = isConnected
    }
}
