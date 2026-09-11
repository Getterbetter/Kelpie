//
//  Drive.swift
//  HeelerUITests
//
//  The UI-automation lane (docs/guides/driving-the-ipad.md). These are not
//  behaviour tests: `testDrive` is a *driver*. The shell hands it a
//  `;`-separated step script in KELPIE_DRIVE_STEPS, it replays the steps on
//  the physical iPad in order, and it attaches a screenshot after each one —
//  so an agent with no eyes on the device can ask for a sequence and read
//  back what the screen did. `testDump` is the reconnaissance run: launch,
//  attach the element tree, attach one screenshot.
//
//  Every KELPIE_-prefixed variable in the invoking shell is forwarded into
//  the app's launch environment, so a step script is not the only thing the
//  driver can pass through (e.g. -kelpie.key-trace style switches have their
//  own launch arguments; KELPIE_ variables are for the app to read).
//
//  scripts/drive-ipad.sh is the front door: it runs this class through the
//  HeelerUIDrive scheme and exports the attachments out of the result bundle.
//

import XCTest

final class Drive: XCTestCase {

    /// A step that misses its element makes every later step meaningless —
    /// stop at the first failure and let the screenshots so far explain it.
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// How long any one element is given to appear before the step fails.
    private static let existenceTimeout: TimeInterval = 10

    // MARK: - Launch

    @MainActor
    private func launchedApp() -> XCUIApplication {
        let app = XCUIApplication()
        var environment = app.launchEnvironment
        for (key, value) in ProcessInfo.processInfo.environment where key.hasPrefix("KELPIE_") {
            environment[key] = value
        }
        app.launchEnvironment = environment
        app.launch()
        return app
    }

    // MARK: - Attachments

    @MainActor
    private func attachScreenshot(named name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor
    private func attachTree(_ app: XCUIApplication, named name: String) {
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = name
        tree.lifetime = .keepAlways
        add(tree)
    }

    private func settle(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    // MARK: - The driver

    @MainActor
    func testDrive() throws {
        let script = ProcessInfo.processInfo.environment["KELPIE_DRIVE_STEPS"] ?? ""
        let steps = script
            .split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let app = launchedApp()
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: Self.existenceTimeout),
            "launch: Kelpie never reached the foreground — is the iPad unlocked?"
        )
        settle(1.5)

        guard !steps.isEmpty else {
            attachScreenshot(named: "00-launch")
            return XCTFail("KELPIE_DRIVE_STEPS is empty — nothing to drive")
        }

        for (index, step) in steps.enumerated() {
            try perform(step, in: app)
            settle(0.8)
            attachScreenshot(named: String(format: "%02d-%@", index + 1, sanitized(step)))
        }
    }

    /// Reconnaissance: what is on screen and what every element is called.
    @MainActor
    func testDump() throws {
        let app = launchedApp()
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: Self.existenceTimeout),
            "launch: Kelpie never reached the foreground — is the iPad unlocked?"
        )
        settle(2)
        attachTree(app, named: "00-tree")
        attachScreenshot(named: "00-dump")
    }

    // MARK: - Step dispatch

    @MainActor
    private func perform(_ step: String, in app: XCUIApplication) throws {
        let name = step.prefix(while: { $0 != ":" }).lowercased()
        let argument = step.dropFirst(name.count).hasPrefix(":")
            ? String(step.dropFirst(name.count + 1)).trimmingCharacters(in: .whitespaces)
            : ""

        switch name {
        case "shot":
            return                                  // the per-step screenshot is the step
        case "wait":
            settle(TimeInterval(argument) ?? 1)
        case "menu":
            if argument.isEmpty {
                tapKelpieMenu(in: app)
            } else {
                tapKelpieMenu(in: app)
                settle(0.8)
                tapMenuItem(argument, in: app)
            }
        case "tap":
            tapLabelled(argument, in: app)
        case "toggle":
            toggleSwitch(argument, in: app)
        case "type":
            app.typeText(argument)
        case "key":
            try pressKey(argument, in: app)
        case "back":
            tapBack(in: app)
        case "swipe":
            swipe(argument, in: app)
        case "dump":
            attachTree(app, named: "tree")
        case "allow":
            tapSystemAlert(argument.isEmpty ? "Allow" : argument)
        default:
            XCTFail("unknown step '\(step)' — steps are shot, wait:, menu, menu:, tap:, toggle:, type:, key:, back, swipe:, dump, allow[:label]")
        }
    }

    /// Taps a button on a system permission alert (notifications, camera,
    /// local network), which belongs to SpringBoard rather than the app.
    private func tapSystemAlert(_ label: String) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let button = springboard.alerts.buttons[label].firstMatch
        guard button.waitForExistence(timeout: 10) else {
            return XCTFail("allow:\(label): no system alert button '\(label)' appeared")
        }
        button.tap()
    }

    // MARK: - Steps

    /// The floating capsule at the top right of the root screen. It is a
    /// `Menu`, so it surfaces as a button carrying the accessibility label
    /// set in HerdrClientRootView.
    @MainActor
    private func tapKelpieMenu(in app: XCUIApplication) {
        let menu = app.buttons["Kelpie Menu"]
        guard menu.waitForExistence(timeout: Self.existenceTimeout) else {
            return XCTFail("menu: no 'Kelpie Menu' control on screen — run --dump to see the tree")
        }
        menu.tap()
    }

    /// A menu item inside the opened `Kelpie Menu`. Menu content is presented
    /// in its own layer, so search the whole app rather than a container.
    @MainActor
    private func tapMenuItem(_ prefix: String, in app: XCUIApplication) {
        let predicate = NSPredicate(format: "label BEGINSWITH[c] %@", prefix)
        let item = app.buttons.matching(predicate).firstMatch
        guard item.waitForExistence(timeout: Self.existenceTimeout) else {
            return XCTFail("menu:\(prefix): no menu item whose label starts with '\(prefix)' — run --dump with the menu open")
        }
        item.tap()
    }

    /// First match by label prefix across the element kinds a tap can land
    /// on, buttons first (SwiftUI exposes most controls as buttons).
    @MainActor
    private func tapLabelled(_ prefix: String, in app: XCUIApplication) {
        let predicate = NSPredicate(format: "label BEGINSWITH[c] %@", prefix)
        let queries: [XCUIElementQuery] = [
            app.buttons, app.cells, app.switches,
            app.links, app.staticTexts, app.otherElements,
        ]
        let deadline = Date().addingTimeInterval(Self.existenceTimeout)
        while Date() < deadline {
            for query in queries {
                let element = query.matching(predicate).firstMatch
                if element.exists, element.isHittable {
                    element.tap()
                    return
                }
            }
            settle(0.5)
        }
        XCTFail("tap:\(prefix): nothing hittable whose label starts with '\(prefix)' — run --dump to see the tree")
    }

    /// Switches read as on/off before and after, so both frames are kept.
    @MainActor
    private func toggleSwitch(_ prefix: String, in app: XCUIApplication) {
        let predicate = NSPredicate(format: "label BEGINSWITH[c] %@", prefix)
        let toggle = app.switches.matching(predicate).firstMatch
        guard toggle.waitForExistence(timeout: Self.existenceTimeout) else {
            return XCTFail("toggle:\(prefix): no switch whose label starts with '\(prefix)'")
        }
        attachScreenshot(named: "toggle-before-\(sanitized(prefix))")
        // A SwiftUI Toggle row exposes an outer switch whose centre is the
        // label; the knob is the inner switch at the trailing edge.
        let knob = toggle.switches.firstMatch
        if knob.exists {
            knob.tap()
        } else {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
        }
        settle(0.8)
        attachScreenshot(named: "toggle-after-\(sanitized(prefix))")
    }

    /// Hardware keys, the way Anthony's Magic Keyboard sends them: `return`,
    /// `escape`, or `mod+key` (`cmd+.`, `cmd+v`, `ctrl+c`).
    @MainActor
    private func pressKey(_ spec: String, in app: XCUIApplication) throws {
        let parts = spec.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let last = parts.last, !last.isEmpty else {
            return XCTFail("key:\(spec): no key named")
        }

        var flags: XCUIElement.KeyModifierFlags = []
        for modifier in parts.dropLast() {
            switch modifier.lowercased() {
            case "cmd", "command": flags.insert(.command)
            case "ctrl", "control": flags.insert(.control)
            case "opt", "option", "alt": flags.insert(.option)
            case "shift": flags.insert(.shift)
            default:
                return XCTFail("key:\(spec): unknown modifier '\(modifier)' — cmd, ctrl, opt, shift")
            }
        }

        let key: String
        switch last.lowercased() {
        case "return", "enter": key = XCUIKeyboardKey.return.rawValue
        case "escape", "esc": key = XCUIKeyboardKey.escape.rawValue
        case "tab": key = XCUIKeyboardKey.tab.rawValue
        case "space": key = XCUIKeyboardKey.space.rawValue
        case "delete", "backspace": key = XCUIKeyboardKey.delete.rawValue
        case "up": key = XCUIKeyboardKey.upArrow.rawValue
        case "down": key = XCUIKeyboardKey.downArrow.rawValue
        case "left": key = XCUIKeyboardKey.leftArrow.rawValue
        case "right": key = XCUIKeyboardKey.rightArrow.rawValue
        default: key = last
        }
        app.typeKey(key, modifierFlags: flags)
    }

    /// Navigation-bar back first (its label is the previous screen's title,
    /// so match the button rather than a name), then the sheet dismissals.
    @MainActor
    private func tapBack(in app: XCUIApplication) {
        let navBack = app.navigationBars.buttons.element(boundBy: 0)
        if navBack.exists, navBack.isHittable {
            navBack.tap()
            return
        }
        for name in ["Done", "Close", "Back"] {
            let button = app.buttons[name].firstMatch
            if button.exists, button.isHittable {
                button.tap()
                return
            }
        }
        XCTFail("back: no navigation-bar back button and no Done/Close/Back")
    }

    @MainActor
    private func swipe(_ direction: String, in app: XCUIApplication) {
        let window = app.windows.firstMatch
        guard window.waitForExistence(timeout: Self.existenceTimeout) else {
            return XCTFail("swipe:\(direction): no window to swipe")
        }
        switch direction.lowercased() {
        case "up": window.swipeUp()
        case "down": window.swipeDown()
        case "left": window.swipeLeft()
        case "right": window.swipeRight()
        default:
            XCTFail("swipe:\(direction): direction is up, down, left or right")
        }
    }

    // MARK: - Naming

    /// Attachment names become filenames on export; keep them boring.
    private func sanitized(_ step: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let mapped = step.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        return String(mapped).lowercased()
    }
}
