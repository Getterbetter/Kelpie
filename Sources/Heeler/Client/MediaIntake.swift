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
    /// then a file. Text wins because a terminal's first answer to a paste is
    /// still to type it — but only when the item is *purely* text. A document
    /// dragged out of Files registers its own content type — `public.plain-text` for a
    /// `.txt`, `com.adobe.pdf` for a PDF — alongside `public.file-url`, and
    /// reading that as text would refuse exactly the drops this exists for.
    static func classify(typeIdentifiers: [String]) -> MediaIntakeClassification {
        let types = typeIdentifiers.compactMap { UTType($0) }
        guard !types.isEmpty else { return .unsupported }
        let hasFileRepresentation = types.contains { $0.conforms(to: .fileURL) }
        if !hasFileRepresentation, types.contains(where: Self.isText) { return .text }
        if types.contains(where: { $0.conforms(to: .image) }) { return .image }
        // `.data`/`.content` are what a PDF, an archive or a text file from
        // Files conforms to; `public.file-url` is only the wrapper some
        // providers add on top.
        if types.contains(where: Self.isFile) { return .file }
        return .unsupported
    }

    /// A file URL is a file, not text, even though it conforms to `public.url`.
    private static func isText(_ type: UTType) -> Bool {
        if type.conforms(to: .fileURL) { return false }
        return type.conforms(to: .plainText) || type.conforms(to: .text)
            || type.conforms(to: .url)
    }

    private static func isFile(_ type: UTType) -> Bool {
        type.conforms(to: .fileURL) || type.conforms(to: .data)
            || type.conforms(to: .content) || type.conforms(to: .item)
    }

    /// Every type identifier a drop session must carry for this app to offer
    /// to take it. `UIDropSession.hasItemsConforming` is a cheap first pass;
    /// ``classify(typeIdentifiers:)`` is the decision.
    static let acceptedDropTypeIdentifiers = [
        UTType.image.identifier,
        UTType.fileURL.identifier,
        UTType.data.identifier,
        UTType.content.identifier,
    ]

    /// Starts every provider's load **now**, before returning, and hands back
    /// the task its results arrive on.
    ///
    /// A drop's item providers are only guaranteed to work while the drop
    /// session is alive, which ends when `performDrop` returns. An `async`
    /// load suspends before it ever calls `loadFileRepresentation`, so the
    /// request went out against a dead session and the drop silently staged
    /// nothing (Files → terminal, observed on device). Every request therefore
    /// leaves synchronously here; only the gathering is asynchronous.
    ///
    /// The task is also remembered, so the ``loadItems(from:)`` the owner
    /// awaits a turn later joins this load rather than starting a second one.
    ///
    /// Main-actor bound because `NSItemProvider` is not `Sendable`: the
    /// providers arrive from UIKit on the main thread and are read there.
    @MainActor
    @discardableResult
    static func beginLoading(_ providers: [NSItemProvider]) -> Task<[MediaIntakeItem], Never> {
        let task = startLoading(providers)
        primedLoads.append((providers.map(ObjectIdentifier.init), task))
        // A primed load nobody claims holds its intake copy until
        // `sweepIntakeCopies` takes it; the cap keeps the list from growing.
        if primedLoads.count > Self.primedLoadLimit { primedLoads.removeFirst() }
        return task
    }

    /// Loads providers into items, in order, skipping the ones that carry text
    /// or nothing this app can stage. Text providers are not this function's
    /// business: the terminal's own paste path already handles them.
    ///
    /// Joins the load ``beginLoading(_:)`` already started for these same
    /// providers when there is one — the drop path starts its loads inside
    /// `performDrop` and calls this afterwards.
    @MainActor
    static func loadItems(from providers: [NSItemProvider]) async -> [MediaIntakeItem] {
        let task = takePrimedLoad(for: providers) ?? startLoading(providers)
        return await task.value
    }

    /// How many started-but-unclaimed loads are remembered at once. One drop
    /// or paste is claimed on the next turn; the rest is slack.
    private static let primedLoadLimit = 4

    @MainActor
    private static var primedLoads:
        [(providers: [ObjectIdentifier], task: Task<[MediaIntakeItem], Never>)] = []

    @MainActor
    private static func takePrimedLoad(
        for providers: [NSItemProvider]
    ) -> Task<[MediaIntakeItem], Never>? {
        let identities = providers.map(ObjectIdentifier.init)
        guard let index = primedLoads.firstIndex(where: { $0.providers == identities })
        else { return nil }
        return primedLoads.remove(at: index).task
    }

    /// Issues every provider's load request before returning.
    @MainActor
    private static func startLoading(
        _ providers: [NSItemProvider]
    ) -> Task<[MediaIntakeItem], Never> {
        let collector = MediaIntakeLoadCollector(expecting: providers.count)
        for (index, provider) in providers.enumerated() {
            let identifiers = provider.registeredTypeIdentifiers
            switch classify(typeIdentifiers: identifiers) {
            case .image:
                guard let identifier = identifiers.first(where: {
                    UTType($0)?.conforms(to: .image) == true
                }) else {
                    collector.finish(index, with: nil)
                    continue
                }
                let suggestedName = provider.suggestedName
                provider.loadDataRepresentation(forTypeIdentifier: identifier) { data, _ in
                    guard let data, !data.isEmpty else {
                        collector.finish(index, with: nil)
                        return
                    }
                    collector.finish(
                        index, with: .image(data, suggestedName: suggestedName))
                }
            case .file:
                guard let identifier = fileTypeIdentifier(in: identifiers) else {
                    collector.finish(index, with: nil)
                    continue
                }
                // The URL the loader hands over is deleted when the callback
                // returns, so the copy has to happen inside it.
                provider.loadFileRepresentation(forTypeIdentifier: identifier) { url, _ in
                    guard let url, let copy = copyIntoIntakeDirectory(url) else {
                        collector.finish(index, with: nil)
                        return
                    }
                    collector.finish(index, with: .file(copy))
                }
            case .text, .unsupported:
                collector.finish(index, with: nil)
            }
        }
        return Task { await collector.items() }
    }

    /// The identifier to ask a file provider for. A document's own content
    /// type is preferred over the `public.file-url` wrapper: Files registers
    /// both, and the content type is the one that reliably yields a file.
    private static func fileTypeIdentifier(in identifiers: [String]) -> String? {
        let concrete = identifiers.first { identifier in
            guard let type = UTType(identifier), !type.conforms(to: .fileURL)
            else { return false }
            return type.conforms(to: .data) || type.conforms(to: .content)
        }
        if let concrete { return concrete }
        return identifiers.first { UTType($0)?.conforms(to: .item) == true }
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

/// Gathers the results of provider loads that were all *started* before the
/// caller got control back, keeping each item in the position its provider
/// held. Loads complete on whatever queue `NSItemProvider` chooses, so the
/// bookkeeping is under a lock rather than an actor: making it an actor would
/// put a suspension between starting the loads and returning, which is the
/// very thing the drop path cannot afford.
private final class MediaIntakeLoadCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Int: MediaIntakeItem] = [:]
    private var outstanding: Int
    private var gathered: [MediaIntakeItem]?
    private var continuation: CheckedContinuation<[MediaIntakeItem], Never>?

    init(expecting count: Int) {
        outstanding = count
        if count == 0 { gathered = [] }
    }

    /// Records one provider's outcome; `nil` is a provider that yielded
    /// nothing this app can stage.
    func finish(_ index: Int, with item: MediaIntakeItem?) {
        lock.lock()
        if let item { results[index] = item }
        outstanding -= 1
        guard outstanding <= 0, gathered == nil else {
            lock.unlock()
            return
        }
        let items = results.keys.sorted().compactMap { results[$0] }
        gathered = items
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(returning: items)
    }

    func items() async -> [MediaIntakeItem] {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let gathered {
                lock.unlock()
                continuation.resume(returning: gathered)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }
    }
}
