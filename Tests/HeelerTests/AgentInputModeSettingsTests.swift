import Foundation
import Testing

@testable import Heeler

@MainActor
@Suite("Agent input mode settings")
struct AgentInputModeSettingsTests {
    private func makeDefaults() throws -> (UserDefaults, cleanup: () -> Void) {
        let suiteName = "hm-agent-input-mode-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return (defaults, { defaults.removePersistentDomain(forName: suiteName) })
    }

    @Test func defaultsToAutomatic() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }

        let settings = AgentInputModeSettings(defaults: defaults)

        #expect(settings.preference == .automatic)
        // Automatic with no keyboard attached is the Composer, as before.
        #expect(settings.mode == .composer)
        #expect(!settings.isDirect)
    }

    @Test func automaticResolvesToDirectWhileAHardwareKeyboardIsConnected() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let settings = AgentInputModeSettings(
            defaults: defaults, isHardwareKeyboardConnected: true)

        #expect(settings.mode == .direct)
        #expect(settings.isDirect)

        settings.hardwareKeyboardDidChange(false)
        #expect(settings.mode == .composer)

        settings.hardwareKeyboardDidChange(true)
        #expect(settings.mode == .direct)
    }

    @Test func anExplicitChoiceIgnoresTheHardwareKeyboard() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let settings = AgentInputModeSettings(
            defaults: defaults, isHardwareKeyboardConnected: true)

        settings.select(.composer)

        #expect(settings.preference == .composer)
        #expect(settings.mode == .composer)
        settings.hardwareKeyboardDidChange(false)
        #expect(settings.mode == .composer)
        // And it is the choice that persists, not the mode it resolved to.
        #expect(AgentInputModeSettings(defaults: defaults).preference == .composer)
    }

    @Test func everyPreferenceIsOfferedInAStableOrder() {
        #expect(AgentInputModePreference.allCases == [.automatic, .composer, .direct])
        #expect(
            AgentInputModePreference.allCases.map(\.title)
                == ["Automatic", "Composer", "Keyboard"])
    }

    @Test func selectionPersistsAcrossStoreInstances() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let settings = AgentInputModeSettings(defaults: defaults)

        settings.select(.direct)

        #expect(AgentInputModeSettings(defaults: defaults).preference == .direct)
        #expect(AgentInputModeSettings(defaults: defaults).mode == .direct)
        #expect(AgentInputModeSettings(defaults: defaults).isDirect)
    }

    @Test func unknownStoredOptionFallsBackToAutomatic() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        defaults.set("keys-mode", forKey: "agent-input-mode")

        #expect(AgentInputModeSettings(defaults: defaults).preference == .automatic)
    }

    @Test func everyModeIsOfferedInAStableOrder() {
        #expect(AgentInputMode.allCases == [.composer, .direct])
        #expect(AgentInputMode.allCases.map(\.segmentTitle) == ["Composer", "Keyboard"])
    }
}
