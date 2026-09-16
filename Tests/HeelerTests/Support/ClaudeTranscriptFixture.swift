import Foundation

@testable import Heeler

/// The redacted Claude Code transcript cut from real lines by
/// `scripts/cut-transcript-fixture.py`: one tool-using turn kept contiguous,
/// then one line of every other shape seen. Loaded as raw bytes because the
/// parser's chunking tests need the exact bytes on disk.
enum ClaudeTranscriptFixture {
    static let data: Data = {
        guard
            let url = Bundle(for: BundleLocator.self)
                .url(forResource: "claude-transcript-v1", withExtension: "jsonl")
        else {
            fatalError("claude-transcript-v1.jsonl is missing from the test bundle")
        }
        do {
            return try Data(contentsOf: url)
        } catch {
            fatalError("claude-transcript-v1.jsonl failed to load: \(error)")
        }
    }()

    /// Each line's bytes, without its newline.
    static var lines: [Data] {
        var lines: [Data] = []
        var start = data.startIndex
        while let newline = data[start...].firstIndex(of: UInt8(ascii: "\n")) {
            if newline > start { lines.append(data.subdata(in: start..<newline)) }
            start = newline + 1
        }
        if start < data.endIndex { lines.append(data.subdata(in: start..<data.endIndex)) }
        return lines
    }

    /// The first line whose `type` (and, for `system`, `subtype`) matches.
    static func line(ofType type: String, subtype: String? = nil) -> Data? {
        lines.first { line in
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                object["type"] as? String == type
            else { return false }
            guard let subtype else { return true }
            return object["subtype"] as? String == subtype
        }
    }

    private final class BundleLocator {}
}
