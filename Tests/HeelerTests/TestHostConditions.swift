import Foundation
import GameController
import Testing

/// Preconditions a test host may not meet, declared as traits so a run on
/// hardware records a skip with its reason instead of a failure. Round 19
/// ended with "15 issues, only the known ones" on the iPad; a suite that is
/// red by design is where the next regression hides (Open item 39), and the
/// device run is now the gate at the end of every change.
enum TestHostConditions {
    /// The checkout's own files, for tests that read source or the licence
    /// inventory. `#filePath` resolves on the simulator and in CI; a device
    /// test host has no view of the Mac's filesystem.
    static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // HeelerTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // repo root

    static var repositoryIsReachable: Bool {
        FileManager.default.fileExists(
            atPath: repositoryRoot.appendingPathComponent("project.yml").path)
    }

    static var readsRepository: ConditionTrait {
        .enabled(
            if: repositoryIsReachable,
            "reads repository files; a device test host cannot see the checkout")
    }

    /// A hardware keyboard docked to a physical device keeps the software
    /// keyboard down, so nothing the keyboard layout guide measures ever
    /// appears. The simulator is exempt: it presents the software keyboard
    /// whatever GameController reports, so CI's coverage stays whole.
    static var softwareKeyboardIsPresentable: Bool {
        #if targetEnvironment(simulator)
            return true
        #else
            return GCKeyboard.coalesced == nil
        #endif
    }

    static var presentsSoftwareKeyboard: ConditionTrait {
        .enabled(
            if: softwareKeyboardIsPresentable,
            "needs the software keyboard; a hardware keyboard is attached to this device")
    }
}
