import Foundation
import UniformTypeIdentifiers

/// One thing on its way from the iPad into a herdr pane. Images keep their
/// original bytes — `ImagePreparer` re-encodes them — and files are already
/// copies this process owns, because the URL a drop or a picker hands over
/// dies with the callback that produced it.
enum MediaIntakeItem: Sendable {
    case image(Data, suggestedName: String?)
    /// The Photos picker's own lazy selection: loading its data eagerly would
    /// duplicate work `ImagePreparer` does anyway.
    case photo(any ImageSelection)
    case file(URL)
}

enum MediaIntakeClassification: Equatable {
    case text
    case image
    case file
    case unsupported
}

/// Pure intake rules for pasted and dropped item providers. Everything here
/// is decided from registered type identifiers, so it is testable without a
/// pasteboard, a drop session, or a Host.
enum MediaIntake {
    /// Classifies by registered type identifiers, preferring text, then image,
    /// then a file URL. Text wins because a terminal's first answer to a paste
    /// is still to type it.
    static func classify(typeIdentifiers: [String]) -> MediaIntakeClassification {
        let types = typeIdentifiers.compactMap { UTType($0) }
        guard !types.isEmpty else { return .unsupported }
        if types.contains(where: Self.isText) { return .text }
        if types.contains(where: { $0.conforms(to: .image) }) { return .image }
        if types.contains(where: { $0.conforms(to: .fileURL) || $0.conforms(to: .item) }) {
            return .file
        }
        return .unsupported
    }

    /// A file URL is a file, not text, even though it conforms to `public.url`.
    private static func isText(_ type: UTType) -> Bool {
        if type.conforms(to: .fileURL) { return false }
        return type.conforms(to: .plainText) || type.conforms(to: .text)
            || type.conforms(to: .url)
    }

    /// Loads providers into items, in order, skipping the ones that carry text
    /// or nothing this app can stage. Text providers are not this function's
    /// business: the terminal's own paste path already handles them.
    ///
    /// Main-actor bound because `NSItemProvider` is not `Sendable`: the
    /// providers arrive from UIKit on the main thread and are read there.
    @MainActor
    static func loadItems(from providers: [NSItemProvider]) async -> [MediaIntakeItem] {
        var items: [MediaIntakeItem] = []
        for provider in providers {
            let identifiers = provider.registeredTypeIdentifiers
            switch classify(typeIdentifiers: identifiers) {
            case .image:
                guard let identifier = identifiers.first(where: {
                    UTType($0)?.conforms(to: .image) == true
                }), let data = await loadData(from: provider, typeIdentifier: identifier),
                    !data.isEmpty
                else { continue }
                items.append(.image(data, suggestedName: provider.suggestedName))
            case .file:
                guard let identifier = identifiers.first(where: {
                    guard let type = UTType($0) else { return false }
                    return type.conforms(to: .fileURL) || type.conforms(to: .item)
                }), let url = await loadFile(from: provider, typeIdentifier: identifier)
                else { continue }
                items.append(.file(url))
            case .text, .unsupported:
                continue
            }
        }
        return items
    }

    /// A path for a bracketed paste into a shell or an agent prompt: quoted
    /// only when it has to be, and always followed by one space so the next
    /// thing typed does not run into it.
    static func pasteText(forStagedPath path: String) -> String {
        let needsQuoting = path.contains(where: { $0.isWhitespace })
            || path.contains("'")
            || path.contains("\"")
        guard needsQuoting else { return "\(path) " }
        let escaped = path.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)' "
    }

    @MainActor
    private static func loadData(
        from provider: NSItemProvider,
        typeIdentifier: String
    ) async -> Data? {
        await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }

    /// The URL the loader hands over is deleted when the callback returns, so
    /// the copy has to happen inside it.
    @MainActor
    private static func loadFile(
        from provider: NSItemProvider,
        typeIdentifier: String
    ) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, _ in
                guard let url else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: copyIntoIntakeDirectory(url))
            }
        }
    }

    /// Where intake copies live until their staging operation ends.
    /// `FilePreparer` makes its own protected copy, so nothing here is worth
    /// keeping past the upload.
    nonisolated static func intakeDirectory(
        fileManager: FileManager = .default
    ) -> URL {
        fileManager.temporaryDirectory
            .appendingPathComponent("kelpie-intake", isDirectory: true)
    }

    /// Deletes the per-operation directory `url` was copied into. A URL from
    /// outside intake — a picker's own security-scoped file — is left alone.
    nonisolated static func discardIntakeCopy(
        at url: URL,
        fileManager: FileManager = .default
    ) {
        let root = intakeDirectory(fileManager: fileManager).standardizedFileURL
        let directory = url.standardizedFileURL.deletingLastPathComponent()
        guard directory.deletingLastPathComponent() == root else { return }
        try? fileManager.removeItem(at: directory)
    }

    /// Removes intake copies an earlier run left behind. Only ones older than
    /// `age`, so a live operation's copy is never taken out from under it.
    nonisolated static func sweepIntakeCopies(
        olderThan age: TimeInterval = 3_600,
        fileManager: FileManager = .default,
        now: Date = Date()
    ) {
        let root = intakeDirectory(fileManager: fileManager)
        guard let entries = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles])
        else { return }
        for entry in entries {
            let modified = try? entry.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate
            guard let modified, now.timeIntervalSince(modified) > age else { continue }
            try? fileManager.removeItem(at: entry)
        }
    }

    nonisolated private static func copyIntoIntakeDirectory(
        _ sourceURL: URL,
        fileManager: FileManager = .default
    ) -> URL? {
        let scoped = sourceURL.startAccessingSecurityScopedResource()
        defer { if scoped { sourceURL.stopAccessingSecurityScopedResource() } }

        let directory = intakeDirectory(fileManager: fileManager)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let name = sourceURL.lastPathComponent.isEmpty
            ? "attachment"
            : sourceURL.lastPathComponent
        let destination = directory.appendingPathComponent(name, isDirectory: false)
        do {
            try fileManager.createDirectory(
                at: directory, withIntermediateDirectories: true)
            try fileManager.copyItem(at: sourceURL, to: destination)
            return destination
        } catch {
            return nil
        }
    }
}
