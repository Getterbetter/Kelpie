import Foundation

/// The exec command that reads one byte range of a Host file, and the
/// parser for its marker-framed output. A sibling of `SkillProbe` with one
/// difference that matters: the body is handled as bytes end to end, never
/// decoded or newline-normalised, because the caller (Kelpie Chat's
/// transcript reader, ADR 0019) pages through the file by byte offset and a
/// single normalised CRLF would shift every offset after it.
enum HostFileProbe {
    static let beginMarker = "__HEELER_FILE_BEGIN__"
    static let endMarkerPrefix = "__HEELER_FILE_END__="
    /// One exec channel carries one page; a megabyte is several seconds of
    /// transcript and well under any SSH window worth worrying about.
    static let maximumBytesPerRead = 1 << 20

    /// `/bin/sh` reads `maxBytes` from byte `offset` of `$1`. The path is a
    /// positional argument (never interpolated into the script); the offset
    /// and cap are formatted integers. `tail -c +N` counts from 1, hence the
    /// `+ 1`. The file's size is printed *after* the body, in the end
    /// marker, so a file that grows during the read reports the larger size
    /// and the caller sees it has not reached the end. A missing file prints
    /// no marker at all (parses as nil); an unreadable one prints the begin
    /// marker, an empty body and an empty size.
    static func command(quotedPath: String, offset: Int, maxBytes: Int) -> String {
        let start = max(offset, 0) + 1
        let cap = min(max(maxBytes, 1), maximumBytesPerRead)
        return "/bin/sh -c '[ -f \"$1\" ] || exit 0; "
            + "printf \"\(beginMarker)\\n\"; "
            + "tail -c +\(start) \"$1\" | head -c \(cap); "
            + "printf \"\\n\(endMarkerPrefix)%s\\n\" \"$(wc -c < \"$1\" | tr -d \" \")\""
            + "' herdr-file-range \(quotedPath)"
    }

    /// The framed page: the raw bytes between the markers and the size the
    /// end marker carried (nil when `wc` printed nothing, i.e. the file
    /// could not be read).
    struct Framed: Equatable, Sendable {
        let body: Data
        let fileSize: Int?
    }

    /// Finds the first begin marker (anything before it is login-shell
    /// noise) and the *last* end marker after it (the body may contain the
    /// end marker's text), and returns the bytes strictly between them. The
    /// newline the command prints before the end marker is not part of the
    /// body. Nil when either marker is missing.
    static func framedOutput(in output: Data) -> Framed? {
        let begin = Data("\(beginMarker)\n".utf8)
        let end = Data("\n\(endMarkerPrefix)".utf8)
        guard let beginRange = output.range(of: begin) else { return nil }
        let afterBegin = beginRange.upperBound
        guard
            let endRange = output.range(
                of: end, options: .backwards, in: afterBegin..<output.endIndex)
        else { return nil }
        let body = output.subdata(in: afterBegin..<endRange.lowerBound)
        let sizeStart = endRange.upperBound
        let sizeEnd =
            output[sizeStart...].firstIndex(of: UInt8(ascii: "\n")) ?? output.endIndex
        let digits = output[sizeStart..<sizeEnd]
        let fileSize: Int?
        if digits.isEmpty || !digits.allSatisfy({ $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }) {
            fileSize = nil
        } else {
            fileSize = Int(String(decoding: digits, as: UTF8.self))
        }
        return Framed(body: body, fileSize: fileSize)
    }
}
