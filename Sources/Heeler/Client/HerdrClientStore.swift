import Foundation
import Observation

/// Owns the PTY pipeline behind herdr's own client — the full TUI, with its
/// workspaces sidebar, tabs and panes — for one Host.
///
/// A thin owner around the shared Attach pipeline, the ordinary shell
/// terminal's shape (see `ShellTerminalStore`): it adds only the lifecycle
/// needed to replace that pipeline across Host generations, to recover after a
/// suspension, and to hand the Host's single Attach channel back while the
/// native Console is on screen — one channel per Transport, so the Client has
/// to let go before an Agent Attach can open.
@MainActor
@Observable
final class HerdrClientStore {
    private enum LifecycleState {
        case active
        case rejoinRequired
        case left
    }

    let hostID: Host.ID
    /// herdr's named session, when the Host names one; nil attaches to the
    /// default session, exactly as bare `herdr` does on the desktop.
    ///
    /// Read live, not captured (M1). The root view keeps one store per Host
    /// id for the life of that Host, and `Host.id` survives an edit, so a
    /// store that snapshotted this at init would keep exec-ing
    /// `herdr --session "<old name>"` on every reattach, reconnect and
    /// transport-generation replacement until the app was relaunched. Every
    /// other Host field the attach depends on is already late-bound through
    /// `ConsoleStore.terminalRunner(for:)`, which resolves the Host's live
    /// projection on each call; this was the one exception.
    private(set) var sessionName: String?
    /// Where the Host's own events session stands, as `ConsoleStore.hostStatuses`
    /// reports it for this Host.
    ///
    /// The attach does not own its connection: it parks on the session's
    /// ping-proven Transport (`EventsSession.withTerminalTransport`). While
    /// that session is in its retryable reconnect loop the pipeline has
    /// nothing to say, so before this input the root screen showed a bare,
    /// reasonless spinner for as long as the Host stayed unreachable — while
    /// the Console cover, one tap behind it, named the failure and its
    /// attempt. Observed, not `@ObservationIgnored`: the overlay is redrawn
    /// from it.
    private(set) var hostStatus: EventsSessionStatus?
    let input = TerminalInputController()
    private(set) var terminal: AttachTerminalStore

    @ObservationIgnored private let runTerminal: TerminalSessionRunner
    /// Repairs the Host's own events session — `ConsoleStore.retryHost`.
    ///
    /// Rebuilding the pipeline cannot fix a session that has stopped: the
    /// attach parks on that session's Transport, and a `.failed` one answers
    /// every new attach with its sticky failure. So Reconnect — the overlay's
    /// button and the Kelpie menu's item alike — has to reach the session too,
    /// or it is a no-op exactly when the user needs it.
    @ObservationIgnored private let retryHost: (@MainActor @Sendable () async -> Void)?
    /// The repair in flight, if any. Reconnect is a button on a screen that
    /// invites a second tap; a second dial would restart the first.
    @ObservationIgnored private var hostRetryTask: Task<Void, Never>?
    /// False while the native Console covers the Client. A Transport serves
    /// one Attach channel at a time, so the Client has to be off stage — and
    /// its channel closed — before an Agent Attach can open.
    @ObservationIgnored private var isPresented = true
    @ObservationIgnored private var transportGeneration: UInt64?
    @ObservationIgnored private var lifecycleState = LifecycleState.active
    @ObservationIgnored private var lifecycleTask: Task<Void, Never>?
    @ObservationIgnored private var lifecycleID: UInt64 = 0
    @ObservationIgnored private var isReplacing = false
    @ObservationIgnored private var replacementID: UInt64 = 0
    @ObservationIgnored private var activationRecovery = TerminalRecoveryGenerationLatch()

    init(
        hostID: Host.ID,
        sessionName: String?,
        transportGeneration: UInt64?,
        hostStatus: EventsSessionStatus? = nil,
        retryHost: (@MainActor @Sendable () async -> Void)? = nil,
        runTerminal: @escaping TerminalSessionRunner
    ) {
        self.retryHost = retryHost
        self.hostID = hostID
        self.sessionName = Self.normalizedSessionName(sessionName)
        self.transportGeneration = transportGeneration
        self.hostStatus = hostStatus
        self.runTerminal = runTerminal
        terminal = Self.makeTerminal(
            sessionName: Self.normalizedSessionName(sessionName),
            input: input,
            transportGeneration: transportGeneration,
            runTerminal: runTerminal)
    }

    private func isOnStage() -> Bool { isPresented }

    /// The Host was edited. A changed herdr session name has to reach the
    /// *next* attach, whenever that is: on stage the pipeline is replaced now,
    /// off stage (the Console cover is up, or a rejoin is owed) the new name
    /// is simply what `adoptReplacement` builds with when the Client comes
    /// back. Trimming happens here so "  " and "" both mean the default
    /// session, as `HostFormView` lets the user leave it.
    func hostDidChange(sessionName: String?) {
        let normalized = Self.normalizedSessionName(sessionName)
        guard normalized != self.sessionName else { return }
        self.sessionName = normalized
        replaceTerminal()
    }

    /// The Host's events session changed state. Presentation only: the
    /// pipeline is not disturbed, because the session's own loop owns its
    /// recovery and the parked attach resumes when a Transport lands.
    func hostStatusDidChange(_ status: EventsSessionStatus?) {
        let previous = hostStatus
        hostStatus = status
        // A recovered session does not always announce a new Transport: when
        // the events channel alone died, `ensureTransport` reuses the
        // connection it still trusts, so the generation never advances and
        // `transportGenerationDidChange` never fires. The attach, meanwhile,
        // was failed with that retryable failure and is sitting on an overlay.
        // Nothing else would ever bring it back.
        guard status == .connected, previous != .connected, !isReplacing else { return }
        switch terminal.status {
        case .ended, .stopped: replaceTerminal()
        case .waitingForSize, .connecting, .live: break
        }
    }

    /// nil means bare `herdr`, exactly as the desktop's default session does.
    private static func normalizedSessionName(_ name: String?) -> String? {
        guard let name else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The Console cover came up over the Client, or went away again. Coming
    /// back reattaches from scratch: herdr's scrollback lives on the Host, so
    /// nothing local is lost.
    func setPresented(_ presented: Bool) {
        guard presented != isPresented else { return }
        isPresented = presented
        if presented { rejoin() } else { leave() }
    }

    var terminalID: TerminalSurfaceID { terminal.surfaceID }
    var terminalFeed: TerminalByteFeed { terminal.feed }

    var terminalStatus: AttachTerminalStore.Status {
        guard lifecycleState == .active, isOnStage() else { return terminal.status }
        if isReplacing || terminal.status == .stopped { return .connecting }
        return terminal.status
    }

    /// Whether the Client is on screen but detached, owing a rejoin nothing
    /// else will deliver (S3). Two shapes reach it:
    ///
    /// * `.rejoinRequired` — a queued replacement went invalid off stage, so
    ///   `abortReplacementOffStage` parked the store deliberately.
    /// * `.left` while still on stage — an `onDisappear` arrived without the
    ///   balancing `onAppear` the pair assumes, so `leave()` stopped the
    ///   pipeline under a view that is still visible.
    ///
    /// Both left a stopped terminal behind `terminalStatus`'s `.stopped`,
    /// which `TerminalStatusPresentation` maps to no overlay at all: a frozen
    /// last frame with no spinner, no message and no Reconnect.
    var needsRejoin: Bool {
        switch lifecycleState {
        case .rejoinRequired: true
        case .left: isOnStage()
        case .active: false
        }
    }

    /// What the screen draws over the terminal, for every state this store
    /// can be in — the mapping ADR 0017 now enumerates.
    var statusPresentation: TerminalStatusPresentation? {
        if needsRejoin { return .rejoinRequired }
        // Off stage: the Console cover is up and draws its own screen. The
        // Client is deliberately detached, not broken.
        if lifecycleState != .active { return nil }
        // Nothing the pipeline reports while it is not live outranks the
        // Host's own connection state: the attach is parked on that session's
        // Transport, or ended because it went away, and the session is the
        // only place the reason and the attempt exist. A live terminal is
        // never covered — a stale reconnecting status must not draw over
        // output that is arriving — and a healthy session returns nil here,
        // leaving every other state exactly as it was.
        if terminalStatus != .live,
            let session = TerminalStatusPresentation(hostSessionStatus: hostStatus)
        {
            return session
        }
        // A remote exit is the remote program's verdict, not a connection
        // problem, so it stops here and names the session it was given.
        if case .ended(let message) = terminalStatus {
            return .clientEnded(message: message, sessionName: sessionName)
        }
        return TerminalStatusPresentation(status: terminalStatus)
    }

    var pendingPaste: TerminalInputController.PasteReview? { input.pendingPaste }
    var canConfirmPaste: Bool { terminal.status == .live && input.canConfirmPaste }
    var pasteErrorMessage: String? { input.pasteErrorMessage }

    func viewDidResize(cols: Int, rows: Int) {
        guard lifecycleState == .active, isOnStage() else { return }
        terminal.viewDidResize(cols: cols, rows: rows)
    }

    func send(_ data: Data) { terminal.send(data) }

    func scroll(_ sequence: Data, rows: Int) {
        input.scroll(sequence, rows: rows)
    }

    func requestPaste(_ text: String, bracketedPaste: Bool) {
        _ = input.requestPaste(text, bracketedPaste: bracketedPaste)
    }

    func cancelPaste() { input.cancelPaste() }
    func clearPasteError() { input.clearPasteError() }

    func confirmPaste() {
        guard canConfirmPaste else { return }
        _ = input.confirmPaste()
    }

    /// The visible Reconnect affordance, and the menu's Reconnect item: both
    /// rebuild the pipeline rather than nudging the live one.
    func reconnect() {
        repairHostSessionIfNeeded()
        if needsRejoin {
            // The tap came from the Client's own overlay, or from the menu
            // that sits on top of it, so the Client is on screen whatever the
            // last presentation signal said — and `rejoin()` refuses off
            // stage, which is exactly what made this state a dead end (S3).
            isPresented = true
            rejoin()
            return
        }
        guard lifecycleState == .active, isOnStage() else { return }
        if terminal.status == .stopped || isReplacing {
            replaceTerminal()
        } else {
            terminal.retry()
        }
    }

    /// Kicks the Host's session repair when the session is the thing that is
    /// broken, and only then: a healthy Host's Reconnect is about this
    /// pipeline, and restarting its events channel would cost every other
    /// surface its connection for nothing.
    ///
    /// Deliberately not awaited on the caller's path — Reconnect must stay a
    /// synchronous tap that rebuilds the pipeline now; the session's own loop
    /// publishes its progress through `hostStatus`.
    private func repairHostSessionIfNeeded() {
        switch hostStatus {
        case .failed, .reconnecting: break
        case .connecting, .connected, .suspended, .ended, nil: return
        }
        guard let retryHost, hostRetryTask == nil else { return }
        hostRetryTask = Task { @MainActor [weak self] in
            await retryHost()
            // The same settle the Host sheet's manual Reconnect uses: a dial
            // is under way, and a second tap inside this window would only
            // restart it.
            try? await Task.sleep(for: .milliseconds(1_200))
            self?.hostRetryTask = nil
        }
    }

    func didBecomeActive(afterPossibleSuspension: Bool) {
        guard isOnStage() else { return }
        if lifecycleState == .rejoinRequired {
            rejoin()
            return
        }
        guard lifecycleState == .active else { return }
        if afterPossibleSuspension {
            if activationRecovery.isActive { return }
            if isReplacing {
                activationRecovery.begin(projectedGeneration: transportGeneration)
                return
            }
            if terminal.transportGeneration == transportGeneration,
                terminal.status == .waitingForSize || terminal.status == .connecting
            {
                return
            }
            input.detachSessionForReplacement()
            activationRecovery.begin(projectedGeneration: transportGeneration)
            replaceTerminal()
        } else {
            terminal.didBecomeActive()
        }
    }

    func transportGenerationDidChange(_ generation: UInt64?) {
        guard let generation, lifecycleState == .active else { return }
        if let decision = activationRecovery.recordProjection(generation) {
            advanceTransportGeneration(to: generation)
            applyActivationRecovery(decision)
            return
        }
        if terminal.transportGeneration == generation {
            transportGeneration = generation
            return
        }
        guard generation != transportGeneration else { return }
        transportGeneration = generation
        replaceTerminal()
    }

    /// Ends the attach, releasing the Host's single Attach channel explicitly
    /// before the returned task completes so an Agent Attach can take it.
    @discardableResult
    func leave() -> Task<Void, Never> {
        guard lifecycleState != .left else {
            return lifecycleTask ?? Task {}
        }
        lifecycleState = .left
        replacementID &+= 1
        isReplacing = false
        activationRecovery.clear()
        // Nothing is left to show the repair's outcome, and its settle window
        // would otherwise refuse the first Reconnect after the Client returns.
        hostRetryTask?.cancel()
        hostRetryTask = nil
        input.cancelPaste()
        return enqueueLifecycleTransition { [self] in
            await terminal.stop()
        }
    }

    /// Reattaches after a `leave()`.
    func rejoin() {
        guard lifecycleState != .active, isOnStage() else { return }
        activationRecovery.clear()
        lifecycleState = .active
        replacementID &+= 1
        let replacementID = replacementID
        isReplacing = true
        enqueueLifecycleTransition { [weak self] in
            guard let self else { return }
            guard self.canApplyReplacement(replacementID) else {
                self.abortReplacementOffStage(replacementID: replacementID)
                return
            }
            if self.terminal.status != .stopped {
                await self.terminal.stop(preservingPendingPaste: true)
            }
            guard self.canApplyReplacement(replacementID) else {
                self.abortReplacementOffStage(replacementID: replacementID)
                return
            }
            self.adoptReplacement()
        }
    }

    private func terminalTransportDidBecomeReady(
        pipelineID: TerminalSurfaceID,
        generation: UInt64
    ) {
        guard
            let decision = activationRecovery.recordAcquisition(generation, by: pipelineID)
        else { return }
        applyActivationRecovery(decision)
    }

    private func applyActivationRecovery(
        _ decision: TerminalRecoveryGenerationLatch.Decision
    ) {
        switch decision {
        case .pending:
            return
        case .acknowledge(let generation), .retain(let generation):
            advanceTransportGeneration(to: generation)
        case .replace(let generation):
            advanceTransportGeneration(to: generation)
            replaceTerminal()
        }
    }

    private func advanceTransportGeneration(to generation: UInt64) {
        guard transportGeneration.map({ generation > $0 }) ?? true else { return }
        transportGeneration = generation
    }

    private func replaceTerminal() {
        guard lifecycleState == .active, isOnStage() else { return }
        replacementID &+= 1
        let replacementID = replacementID
        isReplacing = true
        enqueueLifecycleTransition { [weak self] in
            guard let self else { return }
            guard self.replacementID == replacementID else { return }
            await self.terminal.stop(preservingPendingPaste: true)
            guard self.canApplyReplacement(replacementID) else {
                self.abortReplacementOffStage(replacementID: replacementID)
                return
            }
            self.adoptReplacement()
        }
    }

    private func canApplyReplacement(_ replacementID: UInt64) -> Bool {
        self.replacementID == replacementID && lifecycleState == .active && isOnStage()
    }

    private func adoptReplacement() {
        let replacement = Self.makeTerminal(
            sessionName: sessionName,
            input: input,
            transportGeneration: transportGeneration,
            runTerminal: runTerminal,
            transportReady: { [weak self] pipelineID, generation in
                self?.terminalTransportDidBecomeReady(
                    pipelineID: pipelineID, generation: generation)
            },
            runDidFinish: { [weak self] pipelineID in
                self?.activationRecovery.clear(boundTo: pipelineID)
            })
        terminal = replacement
        activationRecovery.bind(to: replacement.surfaceID)
        isReplacing = false
    }

    /// A queued replacement can become invalid after its predecessor stopped
    /// but before SwiftUI delivers a balancing disappear/appear pair. Preserve
    /// that incomplete outcome so the next on-stage signal reattaches instead
    /// of leaving a stopped pipeline on screen.
    private func abortReplacementOffStage(replacementID: UInt64) {
        guard self.replacementID == replacementID else { return }
        isReplacing = false
        activationRecovery.clear()
        guard lifecycleState == .active, !isOnStage() else { return }
        lifecycleState = .rejoinRequired
    }

    @discardableResult
    private func enqueueLifecycleTransition(
        _ operation: @escaping @MainActor @Sendable () async -> Void
    ) -> Task<Void, Never> {
        let previous = lifecycleTask
        lifecycleID &+= 1
        let id = lifecycleID
        let task = Task { @MainActor in
            await previous?.value
            await operation()
        }
        lifecycleTask = task
        Task { @MainActor [weak self] in
            await task.value
            guard self?.lifecycleID == id else { return }
            self?.lifecycleTask = nil
        }
        return task
    }

    private static func makeTerminal(
        sessionName: String?,
        input: TerminalInputController,
        transportGeneration: UInt64?,
        runTerminal: @escaping TerminalSessionRunner,
        transportReady: @escaping @MainActor @Sendable (TerminalSurfaceID, UInt64) -> Void = {
            _, _ in
        },
        runDidFinish: @escaping @MainActor @Sendable (TerminalSurfaceID) -> Void = { _ in }
    ) -> AttachTerminalStore {
        AttachTerminalStore(
            target: .client(session: sessionName),
            input: input,
            transportGeneration: transportGeneration,
            transportReady: transportReady,
            runDidFinish: runDidFinish,
            runTerminal: runTerminal)
    }
}
