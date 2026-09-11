import Foundation
import Observation

/// Stages pasted, dropped and picked media onto the Host and types each
/// resulting path into the live client PTY.
///
/// The Client screen has no draft to insert into — the pane is the draft — so
/// `ComposerDraftOperations` is satisfied by pasting the path as text down the
/// same route a text paste takes.
///
/// One `ComposerStagingStore` runs one operation at a time (ADR 0005), so a
/// multi-item drop is queued here and staged in order: each item waits for the
/// one before it to finish, and a failure stops the queue with the paths that
/// already landed left in the pane.
@MainActor
@Observable
final class HerdrMediaStagingStore: ComposerDraftOperations {
    /// Breaks the retain cycle `ComposerStagingStore` would otherwise form:
    /// it holds its composer strongly, and this store holds it.
    private final class ComposerBridge: ComposerDraftOperations {
        weak var owner: HerdrMediaStagingStore?

        func replaceDraft(with text: String) {
            owner?.replaceDraft(with: text)
        }

        func insertIntoDraft(_ text: String) {
            owner?.insertIntoDraft(text)
        }
    }

    let staging: ComposerStagingStore

    @ObservationIgnored private let insert: @MainActor (String) -> Void
    @ObservationIgnored private var queue: [MediaIntakeItem] = []
    @ObservationIgnored private var queueTask: Task<Void, Never>?

    init(
        stageImage: @escaping ImageStager,
        stageFile: @escaping FileStager,
        insert: @escaping @MainActor (String) -> Void
    ) {
        let bridge = ComposerBridge()
        self.insert = insert
        staging = ComposerStagingStore(
            stageImage: stageImage,
            stageFile: stageFile,
            composer: bridge)
        bridge.owner = self
        // Intake copies from a run that ended mid-upload have no owner left
        // to delete them.
        MediaIntake.sweepIntakeCopies()
    }

    var presentation: ComposerStagingStore.Presentation? { staging.presentation }

    var canBegin: Bool { staging.canBegin }

    /// Cancel is the only command that abandons the batch. Dismiss only takes
    /// a finished outcome off the screen — including the bar's own timed
    /// dismiss, which must never eat the items still waiting behind it.
    func perform(_ command: ComposerStagingStore.Command) {
        if command == .cancel { discardQueuedIntakeCopies() }
        staging.perform(command)
    }

    func didEnterBackground() {
        staging.didEnterBackground()
    }

    func leave() async {
        discardQueuedIntakeCopies()
        queueTask?.cancel()
        queueTask = nil
        await staging.leave()
    }

    /// Queues `items` and stages them one at a time, in order.
    func stage(_ items: [MediaIntakeItem]) {
        guard !items.isEmpty else { return }
        queue.append(contentsOf: items)
        guard queueTask == nil else { return }
        queueTask = Task { [weak self] in
            await self?.drainQueue()
            self?.queueTask = nil
        }
    }

    // MARK: - ComposerDraftOperations

    /// `ComposerStagingStore` hands over `"<path> "`. The pane wants the same
    /// path shaped for a shell, which is what `MediaIntake.pasteText` does.
    func insertIntoDraft(_ text: String) {
        let path = text.hasSuffix(" ") ? String(text.dropLast()) : text
        guard !path.isEmpty else { return }
        insert(MediaIntake.pasteText(forStagedPath: path))
    }

    /// Nothing in staging replaces a draft; the pane has no draft to replace.
    /// Typing the text is the only honest equivalent.
    func replaceDraft(with text: String) {
        insert(text)
    }

    // MARK: - Queue

    private func drainQueue() async {
        while !queue.isEmpty {
            guard !Task.isCancelled else { break }
            // `begin` no-ops on a busy store — a Retry running alongside a new
            // drop — and the item would be dropped unstaged and unreported.
            while !staging.canBegin {
                guard !Task.isCancelled else { return }
                await nextStateChange()
            }
            guard !queue.isEmpty else { break }
            let item = queue.removeFirst()
            staging.begin(source(for: item))
            let outcome = await awaitOutcome()
            discardIntakeCopy(for: item)
            guard case .completed = outcome else {
                // A failure keeps its message on screen, and a cancel means
                // the user is done: either way the rest of the batch stops.
                discardQueuedIntakeCopies()
                break
            }
        }
    }

    /// An intake copy exists only for the operation that consumes it:
    /// `FilePreparer` has already made its own protected copy by the time the
    /// outcome lands. A picker's security-scoped URL is not ours to delete,
    /// and `discardIntakeCopy` leaves it alone.
    private func discardIntakeCopy(for item: MediaIntakeItem) {
        guard case .file(let url) = item else { return }
        MediaIntake.discardIntakeCopy(at: url)
    }

    private func discardQueuedIntakeCopies() {
        for item in queue { discardIntakeCopy(for: item) }
        queue.removeAll()
    }

    private func source(for item: MediaIntakeItem) -> ComposerStagingStore.Source {
        switch item {
        case .image(let data, _):
            .photo(DataImageSelection(data: data))
        case .photo(let selection):
            .photo(selection)
        case .file(let url):
            .file(url)
        }
    }

    /// Waits for the wrapped store to leave its busy states. `.idle` is how a
    /// cancellation reads from outside.
    private func awaitOutcome() async -> ComposerStagingStore.State {
        while staging.state.isBusy {
            guard !Task.isCancelled else { return staging.state }
            await nextStateChange()
        }
        return staging.state
    }

    private func nextStateChange() async {
        await withCheckedContinuation { continuation in
            withObservationTracking {
                _ = staging.state
            } onChange: {
                continuation.resume()
            }
        }
    }
}
