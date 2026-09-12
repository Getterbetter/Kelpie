import Foundation
import GhosttyTerminal

/// A diagnostic trace of hardware-key delivery, written to
/// `Documents/key-trace.log` so it can be pulled off a device over USB:
///
///     xcrun devicectl device copy from --device <id> --domain-type appDataContainer \
///         --domain-identifier TME.Kelpie --source Documents/key-trace.log --destination <path>
///
/// Off unless the app is launched with the `kelpie.key-trace` default set
/// (`xcrun devicectl device process launch ... TME.Kelpie -kelpie.key-trace YES`),
/// because when on it records every key's code and characters — it is a
/// keystroke log and must never be on for ordinary use. It also takes over
/// the vendored terminal's debug log for the input category.
///
/// This is how the round-3 Escape bug was found: XCUITest cannot press
/// hardware keys on iOS and device logs need root, so the app writes its own.
enum TerminalKeyTrace {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var lines: [String] = []
    nonisolated(unsafe) private static var installed = false

    static var fileURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("key-trace.log")
    }

    /// Routes the vendored input log here and writes the first line. Idempotent.
    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "kelpie.key-trace")
    }

    static func installOnce() {
        guard isEnabled else { return }
        lock.lock()
        let first = !installed
        installed = true
        lock.unlock()
        guard first else { return }
        TerminalDebugLog.isEnabled = true
        TerminalDebugLog.categories = [.input, .actions]
        TerminalDebugLog.sink = { message in
            if message.contains("host <- terminal"), !message.contains("[<") { return }
            TerminalKeyTrace.write("pkg " + message)
        }
        write("trace start pid=\(ProcessInfo.processInfo.processIdentifier)")
    }

    static func log(_ message: @autoclosure () -> String) {
        guard installed else { return }
        write("app " + message())
    }

    /// A quoted, escape-free spelling of text UIKit handed the terminal, so a
    /// trace line can show a space, a newline or a stop without ambiguity.
    /// The software keyboard's rewrites (the "." shortcut above all) are only
    /// readable if the exact argument is visible.
    static func describe(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    out += String(format: "\\x%02X", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    /// Rewrites the whole file each time: the trace is small, and an
    /// atomic rewrite cannot leave a half-written or unflushed file behind.
    private static func write(_ line: String) {
        let stamp = String(format: "%.3f", Date().timeIntervalSince1970)
        lock.lock()
        lines.append("\(stamp) \(line)")
        if lines.count > 4000 { lines.removeFirst(lines.count - 4000) }
        let snapshot = lines.joined(separator: "\n") + "\n"
        lock.unlock()
        guard let url = fileURL, let data = snapshot.data(using: .utf8) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
