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
    let sessionName: String?
    let input = TerminalInputController()
    private(set) var terminal: AttachTerminalStore

    @ObservationIgnored private let runTerminal: TerminalSessionRunner
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
        runTerminal: @escaping TerminalSessionRunner
    ) {
        self.hostID = hostID
        self.sessionName = sessionName
        self.transportGeneration = transportGeneration
        self.runTerminal = runTerminal
        terminal = Self.makeTerminal(
            sessionName: sessionName,
            input: input,
            transportGeneration: transportGeneration,
            runTerminal: runTerminal)
    }

    private func isOnStage() -> Bool { isPresented }

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
        guard lifecycleState == .active, isOnStage() else { return }
        if terminal.status == .stopped || isReplacing {
            replaceTerminal()
        } else {
            terminal.retry()
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
