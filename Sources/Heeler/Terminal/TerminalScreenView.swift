import GhosttyTerminal
import Observation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Remote terminal output is untrusted. Only ordinary web links cross from
/// Ghostty into the system URL opener; local files and executable schemes do not.
enum TerminalLinkPolicy {
    static func url(for link: String) -> URL? {
        guard let url = URL(string: link), let scheme = url.scheme?.lowercased() else {
            return nil
        }
        guard scheme == "http" || scheme == "https", url.host != nil else { return nil }
        return url
    }
}

/// The standard keyboard asks the terminal for clipboard state synchronously.
/// Keep that system IPC behind a seam so unit tests never depend on the
/// Simulator pasteboard service being responsive.
@MainActor
struct TerminalClipboard {
    let string: () -> String?
    let hasStrings: () -> Bool

    static let system = TerminalClipboard(
        string: { UIPasteboard.general.string },
        hasStrings: { UIPasteboard.general.hasStrings })
}

/// A handle on the live terminal for chrome that sits outside it. The reference
/// is weak and set by the surface itself, so an Agent switch rebuilding the
/// terminal cannot leave the keyboard toggle or Composer quick keys driving a
/// dead one. First-responder state is observable so Direct Input chrome can
/// refresh without waiting on an unrelated SwiftUI invalidation.
@MainActor
@Observable
final class TerminalKeyboardControl {
    weak var terminal: HeelerTerminalView? {
        didSet {
            oldValue?.onFirstResponderChange = nil
            if oldValue?.keyboardControl === self {
                oldValue?.keyboardControl = nil
            }
            terminal?.onFirstResponderChange = { [weak self] in
                self?.syncFirstResponder()
            }
            terminal?.keyboardControl = self
            syncFirstResponder()
        }
    }

    /// Ghostty first-responder intent. Distinct from software-keyboard inset:
    /// a hardware keyboard can keep this true with a zero footprint.
    private(set) var isFirstResponder = false

    var isKeyboardUp: Bool { isFirstResponder }

    func toggleKeyboard() {
        guard let terminal else { return }
        if terminal.isFirstResponder {
            terminal.dismissKeyboard()
        } else {
            terminal.requestKeyboard()
        }
    }

    func requestKeyboard() {
        terminal?.requestKeyboard()
    }

    func dismissKeyboard() {
        _ = terminal?.dismissKeyboard()
    }

    /// One-shot sticky modifiers for the ⌃/⌥ caps on the terminal key
    /// surfaces (#270). Tapping a modifier arms it for the next key only —
    /// on-screen `sendQuickKey` or the next physical press / `insertText`.
    /// Firing any mapped key consumes and clears it; tapping the armed
    /// modifier again disarms it. No lock mode.
    private(set) var pendingModifiers = TerminalKeyModifiers()

    func isModifierArmed(_ modifier: TerminalKeyModifiers) -> Bool {
        pendingModifiers.contains(modifier)
    }

    func setModifierArmed(_ modifier: TerminalKeyModifiers, armed: Bool) {
        if armed {
            pendingModifiers.insert(modifier)
        } else {
            pendingModifiers.remove(modifier)
        }
    }

    func toggleModifier(_ modifier: TerminalKeyModifiers) {
        setModifierArmed(modifier, armed: !isModifierArmed(modifier))
    }

    @discardableResult
    func sendQuickKey(
        _ key: AgentQuickKey,
        combining physicalModifiers: TerminalKeyModifiers = []
    ) -> Bool {
        let modifiers = pendingModifiers.union(physicalModifiers)
        guard let terminal, terminal.sendQuickKey(key, modifiers: modifiers) else {
            return false
        }
        pendingModifiers = []
        return true
    }

    /// Control-only interrupt (Ctrl-C). Pre-armed Alt/Shift are discarded so
    /// the advertised chord cannot become Ctrl+Alt+C.
    func sendInterrupt() {
        pendingModifiers = []
        guard let terminal, terminal.sendQuickKey(.character("c"), modifiers: .control) else {
            return
        }
    }

    /// Open Terminal uses the same key encoding while retaining the Shell's
    /// local-input gate. A blocked key must not consume pending modifiers.
    func sendTerminalKey(_ key: AgentQuickKey) {
        guard let terminal, terminal.isLocalInputEnabled else { return }
        sendQuickKey(key)
    }

    /// Stops inertial remote scroll, matching `sendQuickKey`'s reliable-input
    /// side effect, for routes that do not go through Ghostty `sendInput`.
    func noteReliableInputBegan() {
        terminal?.noteReliableInputBegan()
    }

    func setKeyboardMode(_ mode: TerminalKeyboardMode) {
        terminal?.setKeyboardMode(mode)
    }

    func sendNewLine() {
        terminal?.sendNewLine()
    }

    func paste(_ text: String) {
        terminal?.requestPaste(text)
    }

    /// Whether the application on the other end asked for bracketed paste.
    /// The same answer `onPaste` carries, for the routes that insert text
    /// without going through the surface.
    var usesBracketedPaste: Bool {
        terminal?.usesBracketedPaste ?? false
    }

    private func syncFirstResponder() {
        let next = terminal?.isFirstResponder ?? false
        guard isFirstResponder != next else { return }
        isFirstResponder = next
    }
}

/// The interactive Ghostty surface. PTY bytes flow into an in-memory Ghostty
/// session, while its write and resize callbacks flow back to Attach.
enum TerminalTextInputStyle: Equatable {
    case terminal
    case naturalLanguage
}

enum TerminalKeyboardHandoffOutcome: Equatable {
    case settled
    case timedOut
    case cancelled
}

struct TerminalScreenView: UIViewRepresentable {
    let feed: TerminalByteFeed
    #if DEBUG
    /// Reports creation and feed attachment of the concrete UIKit surface.
    /// It does not claim that Ghostty presented a frame.
    var onSurfaceAttached: (() -> Void)?
    #endif
    var onSizeChanged: ((_ cols: Int, _ rows: Int) -> Void)?
    var onViewportTextChanged: ((String) -> Void)?
    var onSend: ((Data) -> Void)?
    var onScroll: ((_ sequence: Data, _ rows: Int) -> Void)?
    var onPaste: ((_ text: String, _ bracketed: Bool) -> Void)?
    /// Pasted or dropped image and file providers, handed over for staging
    /// onto the Host. Text never arrives here — it pastes as text.
    var onStageItems: (([NSItemProvider]) -> Void)?
    var onHostPathTap: ((String) -> Void)?
    /// Asked exactly once, as the surface is created: does this terminal
    /// inherit the keyboard from the one it replaced? Asking through a
    /// closure rather than a stored flag keeps the answer tied to the
    /// surface's creation instead of to how often SwiftUI evaluates the body.
    var claimsKeyboard: (@MainActor () -> Bool)?
    /// Reports whether an update-time responder handoff reached the current,
    /// visible terminal. The owner keeps Composer mounted on failure.
    var keyboardHandoffID: UUID?
    var isKeyboardHandoffCurrent: (@MainActor (_ id: UUID) -> Bool)?
    var onKeyboardHandoffResult: (@MainActor (_ id: UUID, _ succeeded: Bool) -> Void)?
    /// Reports whether this terminal settled the handoff or had to abandon it.
    var onKeyboardHandoffEnded: (@MainActor (
        _ id: UUID, _ outcome: TerminalKeyboardHandoffOutcome
    ) -> Void)?
    /// Handed the surface once it exists, so the Agent strip's toggle can
    /// raise and lower this terminal's keyboard.
    var keyboardControl: TerminalKeyboardControl?
    /// Handed the surface once it exists, so the message-jump chrome can
    /// drive remote scroll without holding the UIKit view itself.
    var scrollControl: TerminalScrollControl?
    var isLocalInputEnabled = true
    /// Applied before the first focus claim, including Agent tools handoffs.
    var initialKeyboardMode = TerminalKeyboardMode.text
    var textInputStyle = TerminalTextInputStyle.terminal
    var theme: TerminalTheme = .default
    var fontSize: Float = TerminalZoomSettings.defaultFontSize
    var fontFamily: String?
    /// Pinch-to-zoom and the ⌘+/⌘- shortcut change the size in place; the
    /// screen forwards the new value so it lands in the global setting.
    var onFontSizeChanged: ((Float) -> Void)?
    @Environment(\.openURL) private var openURL

    func makeUIView(context: Context) -> HeelerTerminalView {
        let view = Self.makeConfiguredTerminal(
            onSizeChanged: onSizeChanged,
            onViewportTextChanged: onViewportTextChanged,
            onSend: onSend,
            onScroll: onScroll,
            onPaste: onPaste,
            theme: theme,
            fontSize: fontSize,
            fontFamily: fontFamily)
        view.onOpenLink = { url in openURL(url) }
        view.onStageItems = onStageItems
        view.onHostPathTap = onHostPathTap
        // Only here, never in updateUIView: the intent belongs to this
        // terminal's first appearance, not to every state change after it.
        view.setKeyboardMode(initialKeyboardMode)
        view.raisesKeyboardWhenReady = claimsKeyboard?() ?? false
        keyboardControl?.terminal = view
        scrollControl?.terminal = view
        view.onKeyboardHandoffEnded = { [weak view, weak keyboardControl] id, outcome in
            guard let view else { return }
            if let keyboardControl, keyboardControl.terminal !== view { return }
            onKeyboardHandoffEnded?(id, outcome)
        }
        view.setTextInputStyle(textInputStyle)
        view.setLocalInputEnabled(isLocalInputEnabled)
        // The feed holds the surface weakly so a replaced UIKit view cannot be
        // kept alive by an obsolete terminal pipeline.
        feed.attach(view)
        #if DEBUG
        onSurfaceAttached?()
        #endif
        return view
    }

    @MainActor
    static func makeConfiguredTerminal(
        onSizeChanged: ((_ cols: Int, _ rows: Int) -> Void)? = nil,
        onViewportTextChanged: ((String) -> Void)? = nil,
        onSend: ((Data) -> Void)? = nil,
        onScroll: ((_ sequence: Data, _ rows: Int) -> Void)? = nil,
        onPaste: ((_ text: String, _ bracketed: Bool) -> Void)? = nil,
        theme: TerminalTheme = .default,
        fontSize: Float = TerminalZoomSettings.defaultFontSize,
        fontFamily: String? = nil,
        /// The center the terminal observes the keyboard through. Tests pass
        /// their own so one test's keyboard cannot end another test's
        /// handoff (#157); production keeps the default.
        notificationCenter: NotificationCenter = .default,
        clipboard: TerminalClipboard = .system
    ) -> HeelerTerminalView {
        let view = HeelerTerminalView(
            frame: .zero,
            onSizeChanged: onSizeChanged,
            onViewportTextChanged: onViewportTextChanged,
            onSend: onSend,
            onScroll: onScroll,
            onPaste: onPaste,
            theme: theme,
            fontSize: fontSize,
            fontFamily: fontFamily,
            clipboard: clipboard)
        view.installKeyboardSwitcher(notificationCenter: notificationCenter)
        return view
    }

    func updateUIView(_ view: HeelerTerminalView, context: Context) {
        view.updateCallbacks(
            onSizeChanged: onSizeChanged,
            onViewportTextChanged: onViewportTextChanged,
            onSend: onSend,
            onScroll: onScroll,
            onPaste: onPaste)
        keyboardControl?.terminal = view
        scrollControl?.terminal = view
        view.onKeyboardHandoffEnded = { [weak view, weak keyboardControl] id, outcome in
            guard let view else { return }
            if let keyboardControl, keyboardControl.terminal !== view { return }
            onKeyboardHandoffEnded?(id, outcome)
        }
        let claimsKeyboardOnEnable = !view.isLocalInputEnabled
            && isLocalInputEnabled
            && (claimsKeyboard?() ?? false)
        view.setTextInputStyle(textInputStyle)
        view.setLocalInputEnabled(isLocalInputEnabled)
        if claimsKeyboardOnEnable, let keyboardHandoffID {
            DispatchQueue.main.async { [weak view, weak keyboardControl] in
                guard let view,
                      view.window != nil,
                      view.isLocalInputEnabled,
                      keyboardControl?.terminal === view,
                      isKeyboardHandoffCurrent?(keyboardHandoffID) == true
                else {
                    onKeyboardHandoffResult?(keyboardHandoffID, false)
                    return
                }
                onKeyboardHandoffResult?(
                    keyboardHandoffID,
                    view.requestKeyboardHandoff(id: keyboardHandoffID))
            }
        }
        view.applyTheme(theme)
        view.applyFontSize(fontSize)
        view.applyFontFamily(fontFamily)
        view.onFontSizeChanged = onFontSizeChanged
        // Deliberately no viewport read here. A SwiftUI update must not write
        // back into the state it was driven by: reporting the viewport text
        // feeds the Attach Link index, whose observers include this very view,
        // and the update loops on itself until the app is wedged. Terminal
        // output already schedules a snapshot in `receive`.
        view.onOpenLink = { url in openURL(url) }
        view.onStageItems = onStageItems
        view.onHostPathTap = onHostPathTap
    }
}

/// When a terminal re-asserts its Ghostty layer scale after a size change.
///
/// libghostty rebuilds the surface's IOSurface asynchronously. Until its
/// renderer has, the layer's `contentsScale` is derived from the old surface's
/// pixel height over the new point height, and libghostty corrects that drift
/// only after a render it drives itself (`TerminalSurfaceCoordinator`'s
/// `onPostRender`). A terminal with nothing to draw, such as an idle Agent
/// behind a focused Composer with no cursor blink, renders no such frame, so a
/// keyboard raise can leave its content drawn at old-height / new-height of
/// its size in the top-left corner (2/3 on a 13-inch iPad in portrait). A
/// later layout pass sets the scale directly and requests that render.
struct TerminalSurfaceScaleSettle: Equatable, Sendable {
    /// When the follow-up passes run after a size change, in seconds from
    /// that change: once the renderer has had a few frames, and again for a
    /// large surface that takes longer to rebuild.
    static let followUpDelays: [TimeInterval] = [0.1, 0.5]
    private var lastBoundsSize: CGSize?

    /// Records one layout pass at `size`. True when the size changed since
    /// the previous pass, including the first one with a real size. The
    /// follow-up passes themselves keep the size, so they never reschedule.
    mutating func boundsDidLayout(size: CGSize) -> Bool {
        defer { lastBoundsSize = size }
        guard size.width > 0, size.height > 0 else { return false }
        return lastBoundsSize != size
    }
}

/// A grid as the Host is told about it: the columns and rows a resize report
/// carries, with the pixel metrics Ghostty measures them from left behind.
struct TerminalGridSize: Equatable, Sendable, CustomStringConvertible {
    let columns: Int
    let rows: Int

    var description: String { "\(columns)x\(rows)" }
}

/// What the keyboard-transition grid freeze is doing.
///
/// The freeze's edges are lifecycle facts — a keyboard claimed, a settled
/// frame published, the last in-flight callback consumed — but until this
/// existed the only trace of them was *when* resize reports happened to reach
/// the Host. Timing is exactly what cannot be read back: the thaw rides
/// Ghostty's asynchronous resize callbacks, so silence means "still frozen",
/// "nothing to report" and "the engine has not answered yet" all at once, and
/// a caller waiting on reports cannot tell which (#263).
enum TerminalGridReportPhase: Equatable, Sendable {
    /// Reports reach the Host as they arrive.
    case live
    /// Every report is held back; the keyboard is still moving.
    case deferring
    /// The thaw was asked for and is waiting on the callbacks that had
    /// already left Ghostty when it was.
    case flushing
}

/// Bridges Ghostty's sendable session callbacks onto the UI's main-actor
/// closures without making the transport layer depend on Ghostty types.
private final class TerminalResizeSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: UInt64 = 0

    func next() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        latest &+= 1
        return latest
    }

    func current() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }
}

@MainActor
final class TerminalSessionCallbackBridge {
    var onSizeChanged: ((Int, Int) -> Void)?
    var onViewportTextChanged: ((String) -> Void)?
    var onSend: ((Data) -> Void)?
    var onScroll: ((Data, Int) -> Void)?
    var onPaste: ((String, Bool) -> Void)?
    var onViewport: ((InMemoryTerminalViewport) -> Void)?
    var isSizeReportCurrent: ((_ columns: Int, _ rows: Int) -> Bool)?
    var onReliableInput: (() -> Void)?
    var onTerminalInput: ((Data) -> Void)?
    /// Reports every freeze transition. The return to `.live` carries the grid
    /// the thaw forwarded, or `nil` when the freeze had none to forward —
    /// the difference between "the settled grid reached the Host" and "the
    /// freeze ended having told it nothing", which nothing else records.
    var onGridReportPhaseChanged: ((
        _ phase: TerminalGridReportPhase, _ forwarded: TerminalGridSize?
    ) -> Void)?
    nonisolated private let resizeSequence = TerminalResizeSequence()
    private var pendingResizeReports: [UInt64: InMemoryTerminalViewport] = [:]
    private var lastProcessedResizeSequence: UInt64 = 0
    private var discardsResizeReportsThrough: UInt64 = 0
    private var defersSizeReports = false
    private var deferredSize: (columns: Int, rows: Int)?
    private var finishesSizeReportDeferralThrough: UInt64?
    private var suppressesDuplicateSize: (columns: Int, rows: Int)?
    private var lastNotifiedGridReportPhase = TerminalGridReportPhase.live
    /// The last size a burst of bounds-driven reports arrived at, waiting for
    /// the burst to go quiet. See ``coalesceSizeReport(_:)``.
    private var coalescedSize: (columns: Int, rows: Int)?
    private var sizeCoalescingTask: Task<Void, Never>?
    /// Invalidates a trailing report whose window was restarted or cancelled.
    private var sizeCoalescingGeneration: UInt64 = 0
    /// How long a burst of bounds-driven resizes must be quiet before its last
    /// size is reported. A Split View divider drag emits one per layout pass;
    /// 80ms is short enough to feel immediate and long enough to swallow them.
    private static let sizeCoalescingWindow = Duration.milliseconds(80)

    /// Derived from the deferral bookkeeping rather than tracked alongside it,
    /// so the phase callers observe cannot drift from the one the reports obey.
    var gridReportPhase: TerminalGridReportPhase {
        guard defersSizeReports else { return .live }
        return finishesSizeReportDeferralThrough == nil ? .deferring : .flushing
    }

    init(
        onSizeChanged: ((Int, Int) -> Void)?,
        onViewportTextChanged: ((String) -> Void)?,
        onSend: ((Data) -> Void)?,
        onScroll: ((Data, Int) -> Void)?,
        onPaste: ((String, Bool) -> Void)?
    ) {
        TerminalKeyTrace.installOnce()
        self.onSizeChanged = onSizeChanged
        self.onViewportTextChanged = onViewportTextChanged
        self.onSend = onSend
        self.onScroll = onScroll
        self.onPaste = onPaste
    }

    nonisolated func send(_ data: Data) {
        Task { @MainActor [weak self] in
            self?.onReliableInput?()
            self?.onTerminalInput?(data)
            self?.onSend?(data)
        }
    }

    func scroll(_ sequence: Data, rows: Int) {
        onScroll?(sequence, rows)
    }

    nonisolated func resize(_ viewport: InMemoryTerminalViewport) {
        let sequence = resizeSequence.next()
        Task { @MainActor [weak self] in
            self?.receiveResize(viewport, sequence: sequence)
        }
    }

    func beginSizeReportDeferral() {
        // A Ghostty resize may already have left its callback thread while its
        // main-actor delivery is still queued. It describes the layout before
        // this freeze and must not become the deferred result merely because
        // its Task happens to run after the handoff begins.
        discardsResizeReportsThrough = max(
            discardsResizeReportsThrough, resizeSequence.current())
        // A trailing report still waiting is the last layout before this
        // freeze, and the freeze has no way to learn it: send it now rather
        // than lose it. Coalescing may only ever delay the final size.
        flushCoalescedSizeReport()
        defersSizeReports = true
        deferredSize = nil
        finishesSizeReportDeferralThrough = nil
        suppressesDuplicateSize = nil
        notifyGridReportPhase()
    }

    func finishSizeReportDeferral() {
        guard defersSizeReports else { return }
        // `resize` crosses onto the main actor asynchronously. Keep the freeze
        // in force until every callback that had already left Ghostty when the
        // thaw was requested has been consumed in sequence.
        finishesSizeReportDeferralThrough = resizeSequence.current()
        notifyGridReportPhase()
        completeSizeReportDeferralIfReady()
    }

    func provideAuthoritativeDeferredSize(columns: Int, rows: Int) {
        guard defersSizeReports else { return }
        deferredSize = (columns, rows)
    }

    /// Tells the Host a grid it may have missed: a cancelled freeze discards
    /// the grid it held, and Ghostty reports again only when the grid
    /// changes. Held like any other report while a freeze is in force; the
    /// engine's matching callback, if still in flight, is consumed once.
    func reportSettledSize(columns: Int, rows: Int) {
        guard !defersSizeReports else {
            deferredSize = (columns, rows)
            return
        }
        onSizeChanged?(columns, rows)
        suppressesDuplicateSize = (columns, rows)
    }

    func cancelSizeReportDeferral() {
        discardsResizeReportsThrough = max(
            discardsResizeReportsThrough, resizeSequence.current())
        flushCoalescedSizeReport()
        defersSizeReports = false
        deferredSize = nil
        finishesSizeReportDeferralThrough = nil
        suppressesDuplicateSize = nil
        notifyGridReportPhase()
    }

    private func receiveResize(
        _ viewport: InMemoryTerminalViewport,
        sequence: UInt64
    ) {
        pendingResizeReports[sequence] = viewport

        while let viewport = pendingResizeReports.removeValue(
            forKey: lastProcessedResizeSequence &+ 1)
        {
            lastProcessedResizeSequence &+= 1
            if lastProcessedResizeSequence > discardsResizeReportsThrough {
                let size = (columns: Int(viewport.columns), rows: Int(viewport.rows))
                if isSizeReportCurrent?(size.columns, size.rows) != false {
                    onViewport?(viewport)
                    if defersSizeReports {
                        deferredSize = size
                    } else {
                        deliverSize(size)
                    }
                }
            }
            completeSizeReportDeferralIfReady()
        }
    }

    private func completeSizeReportDeferralIfReady() {
        guard let finishSequence = finishesSizeReportDeferralThrough,
              lastProcessedResizeSequence >= finishSequence
        else { return }
        finishesSizeReportDeferralThrough = nil
        defersSizeReports = false
        // The Host hears the settled grid first, and the phase says `.live`
        // only once it has: an observer woken by the thaw must find the
        // report already delivered, not on its way.
        let forwarded = forwardDeferredSize()
        notifyGridReportPhase(forwarded: forwarded)
    }

    /// Hands the Host the one grid the freeze settled on and returns it, or
    /// returns `nil` when the freeze never learned a grid to forward — the
    /// next ordinary report speaks for it then.
    private func forwardDeferredSize() -> TerminalGridSize? {
        // A freeze that measured nothing still forwards a trailing size left
        // over from before it, if one is somehow still waiting: the Host must
        // never be left holding the leading edge of a burst.
        guard let deferredSize = deferredSize ?? coalescedSize else { return nil }
        self.deferredSize = nil
        cancelCoalescedSizeReport()
        guard let onSizeChanged else { return nil }
        onSizeChanged(deferredSize.columns, deferredSize.rows)
        // The surface delegate supplied the settled grid synchronously. The
        // equivalent engine callback can still be in Ghostty's IO pipeline;
        // consume that one duplicate when it arrives. A different current
        // grid clears the token and is delivered normally.
        suppressesDuplicateSize = deferredSize
        return TerminalGridSize(
            columns: deferredSize.columns, rows: deferredSize.rows)
    }

    private func notifyGridReportPhase(forwarded: TerminalGridSize? = nil) {
        let phase = gridReportPhase
        guard phase != lastNotifiedGridReportPhase else { return }
        lastNotifiedGridReportPhase = phase
        onGridReportPhaseChanged?(phase, forwarded)
    }

    private func deliverSize(_ size: (columns: Int, rows: Int)) {
        if let suppressedSize = suppressesDuplicateSize {
            suppressesDuplicateSize = nil
            if suppressedSize.columns == size.columns,
               suppressedSize.rows == size.rows
            {
                return
            }
        }
        coalesceSizeReport(size)
    }

    /// Reports a bounds-driven size change on the leading edge of a burst and
    /// then only once it goes quiet.
    ///
    /// Dragging a Split View divider re-lays the terminal out dozens of times,
    /// and each report is a serialized SSH round trip that makes the remote TUI
    /// redraw whole. The first change still goes out at once — a single resize
    /// must stay instant — and everything inside the quiet window collapses
    /// into the last size, which is the one the drag settled on.
    ///
    /// Keyboard-driven changes never arrive here: they are held by the
    /// freeze and forwarded by ``forwardDeferredSize()``, which reports
    /// directly.
    private func coalesceSizeReport(_ size: (columns: Int, rows: Int)) {
        if sizeCoalescingTask == nil {
            onSizeChanged?(size.columns, size.rows)
        } else {
            coalescedSize = size
        }
        scheduleCoalescedSizeReport()
    }

    private func scheduleCoalescedSizeReport() {
        sizeCoalescingGeneration &+= 1
        let generation = sizeCoalescingGeneration
        sizeCoalescingTask?.cancel()
        sizeCoalescingTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.sizeCoalescingWindow)
            guard !Task.isCancelled, let self,
                generation == sizeCoalescingGeneration
            else { return }
            sizeCoalescingTask = nil
            guard let pending = coalescedSize else { return }
            coalescedSize = nil
            onSizeChanged?(pending.columns, pending.rows)
        }
    }

    /// Sends a waiting trailing report now and ends the burst. Used wherever
    /// the coalescing window is about to be torn down — a freeze beginning or
    /// being cancelled — so no size is ever dropped on the floor.
    private func flushCoalescedSizeReport() {
        let pending = coalescedSize
        cancelCoalescedSizeReport()
        guard let pending else { return }
        onSizeChanged?(pending.columns, pending.rows)
    }

    /// Ends the coalescing window, discarding any trailing report. Only for
    /// callers that have already delivered or superseded that size.
    private func cancelCoalescedSizeReport() {
        sizeCoalescingGeneration &+= 1
        sizeCoalescingTask?.cancel()
        sizeCoalescingTask = nil
        coalescedSize = nil
    }

    func paste(_ text: String, bracketed: Bool) {
        onPaste?(text, bracketed)
    }

    func viewportTextDidChange(_ text: String) {
        onViewportTextChanged?(text)
    }
}

private final class TerminalInputTextPosition: UITextPosition {
    let index: Int

    init(index: Int) {
        self.index = index
        super.init()
    }
}

private final class TerminalInputTextRange: UITextRange {
    private let startPosition: TerminalInputTextPosition
    private let endPosition: TerminalInputTextPosition

    override var start: UITextPosition { startPosition }
    override var end: UITextPosition { endPosition }
    override var isEmpty: Bool { startPosition.index == endPosition.index }
    var location: Int { startPosition.index }
    var length: Int { endPosition.index - startPosition.index }

    init(location: Int, length: Int) {
        startPosition = TerminalInputTextPosition(index: location)
        endPosition = TerminalInputTextPosition(index: location + length)
        super.init()
    }
}

/// Where ``HeelerTerminalView`` sends one hardware key press.
enum HardwarePressRoute: Equatable {
    /// ⌘+ / ⌘−: the view steps the terminal zoom and swallows the press.
    case zoom(Float)
    /// Any other ⌘ chord: past Ghostty, up the responder chain to the scene's
    /// key commands.
    case sceneCommand
    /// Everything else: Ghostty, as before.
    case terminal
}

/// Identity of a physical key plus the modifiers that were actually held.
/// `pressesBegan` maps `UIPress` to this and calls
/// ``HeelerTerminalView/beginPhysicalKeyForArmedModifiers(_:token:)`` — the
/// only consume path for hardware presses.
struct ArmedModifierPhysicalKey: Equatable {
    var key: AgentQuickKey
    var physicalModifiers: TerminalKeyModifiers
}

private struct ArmedModifierEchoSuppression {
    let pressToken: ObjectIdentifier
    let expectedInsert: Character?
    let expectBackspace: Bool
}

/// The app-owned seam around libghostty-spm. It keeps keyboard policy and the
/// host-managed session lifecycle out of the SwiftUI screen.
final class HeelerTerminalView: UITerminalView, TerminalByteSink {
    private let callbackBridge: TerminalSessionCallbackBridge
    private let terminalController: TerminalController
    private let clipboard: TerminalClipboard
    let terminalSession: InMemoryTerminalSession
    private(set) var appliedTheme: TerminalTheme
    private(set) var appliedFontSize: Float
    private(set) var appliedFontFamily: String?
    var onFontSizeChanged: ((Float) -> Void)?
    var onOpenLink: ((URL) -> Void)?
    /// Image and file providers this terminal accepted from a paste or a
    /// drop. Staging them is the owner's business, not the surface's.
    var onStageItems: (([NSItemProvider]) -> Void)?
    var onHostPathTap: ((String) -> Void)?
    /// Whether a paste has already been answered in this run-loop turn.
    private var hasClaimedPasteThisTurn = false
    /// Raises the keyboard once this surface reaches a window. An Agent switch
    /// rebuilds the whole terminal, and the user who tapped a switcher chip
    /// was mid-conversation — dropping the keyboard would hide the switcher
    /// along with it.
    var raisesKeyboardWhenReady = false
    /// Notifies ``TerminalKeyboardControl`` when first-responder intent changes.
    var onFirstResponderChange: (() -> Void)?
    /// One-shot ⌃/⌥/⇧ from the app-owned key surfaces. Physical presses and
    /// `insertText` consult this so an armed modifier applies to the next
    /// hardware key; empty means Ghostty owns the event unchanged.
    weak var keyboardControl: TerminalKeyboardControl?
    /// Notifies ``TerminalScrollControl`` when DECSET alternate-screen state
    /// flips. `refs #268`.
    var onAlternateScreenChange: (() -> Void)?
    /// Notifies ``TerminalScrollControl`` that a touch (drag or momentum)
    /// scrolled by at least one row, and in which direction. Programmatic
    /// steps through ``scrollRows(towardOlderContent:rows:)`` do not fire it.
    var onTouchScroll: ((_ towardOlderContent: Bool) -> Void)?
    /// Completes the app-owned inset freeze for a responder handoff after the
    /// terminal's own keyboard frame has settled.
    var onKeyboardHandoffEnded: ((UUID, TerminalKeyboardHandoffOutcome) -> Void)?
    private var activeKeyboardHandoffID: UUID?
    /// How many times the input views have been rebuilt. Nothing else observes
    /// the rebuild that republishes the keyboard's settled frame after a
    /// handoff, and a lost rebuild costs the terminal a toolbar's worth of
    /// height without a crash to show for it.
    private(set) var inputViewRebuildCount = 0
    private var zoomBaseFontSize: Float?
    private var terminalInputView: UIView?
    private var modeTracker = TerminalModeTracker()
    private var lastInputWindowSize: CGSize?
    private var defersLayoutForKeyboardTransition = false
    /// What ends the current freeze. A dismissal waits for `keyboardDidHide`;
    /// an inherited keyboard never leaves, so its settled signal is the frame
    /// change instead.
    private var keyboardTransitionEndsOnFrameChange = false
    /// An inherited keyboard first publishes the frame that still includes
    /// both responders' accessories. Rebuilding the input views publishes the
    /// destination-only frame; the handoff cannot settle before that second
    /// owned frame arrives.
    private var didReloadInputViewsForKeyboardHandoff = false
    /// The first owned keyboard frame can arrive synchronously from
    /// `becomeFirstResponder()`. Defer rebuilding until the responder-handoff
    /// owner has accepted the request, and coalesce any duplicate first
    /// frames that arrive in the meantime.
    private var keyboardHandoffReloadIsScheduled = false
    private var keyboardTransitionCycleID: UUID?
    private var keyboardTransitionFallbackTask: Task<Void, Never>?
    /// Test seam for process-wide keyboard notification ownership. Production
    /// reads the window-local layout guide directly.
    var keyboardLayoutFrameProvider: ((UIWindow) -> CGRect)?
    /// How long an unsettled handoff may keep the grid frozen before the
    /// freeze force-ends anyway — a leash for production, where the settle
    /// signal can fail to arrive. Tests stretch it so a loaded runner cannot
    /// end a handoff out from under them (#225).
    var keyboardTransitionFallbackDelay: TimeInterval = 0.5
    private var keyboardGridReportTask: Task<Void, Never>?
    /// How long Ghostty gets to answer a settled layout before its grid is
    /// forwarded to the Host — long enough to coalesce one layout pass's
    /// several viewport reports into the final one.
    private static let gridSettleDelay: TimeInterval = 0.05
    /// How long the window must keep one size before its grid is forwarded.
    /// Longer than `gridSettleDelay`: a Stage Manager live resize pauses
    /// between drag samples, and every intermediate grid the Host hears is a
    /// full TUI redraw.
    private static let windowResizeSettleDelay: TimeInterval = 0.15
    private var windowResizeTracker = TerminalWindowResizeTracker()
    private var surfaceScaleSettle = TerminalSurfaceScaleSettle()
    private var surfaceScaleSettleTask: Task<Void, Never>?
    /// A window resize froze grid reports and no thaw has forwarded its
    /// settled grid yet. A cancelled freeze must then report it itself.
    private var windowResizeGridIsPending = false
    private var responderGate = TerminalKeyboardResponderGate()
    private var viewportSnapshotTask: Task<Void, Never>?
    private(set) var isLocalInputEnabled = true
    private var textInputStyle = TerminalTextInputStyle.terminal
    private var defaultLeadingAssistantGroups: [UIBarButtonItemGroup]?
    private var defaultTrailingAssistantGroups: [UIBarButtonItemGroup]?
    // Ghostty keeps only marked text in its UITextInput document. UIKit needs
    // committed text to remain in that document so Backspace can observe a
    // shrinking selection and continue its native key repeat.
    private var textInputStorage = ""
    private var textInputSelection = NSRange(location: 0, length: 0)
    private var terminalGridSize = (columns: 80, rows: 24)
    private var hasTerminalGridMetrics = false
    private var terminalCellSize = CGSize(width: 8, height: 16)
    private var touchScrollAccumulator = TerminalTouchScrollAccumulator()
    private var touchScrollMomentumDisplayLink: CADisplayLink?
    private var touchScrollMomentumVelocityY: CGFloat = 0
    private var touchScrollMomentumTimestamp: CFTimeInterval = 0
    /// Presses whose began event was rewritten through armed modifiers, so
    /// Ghostty must not also see their ended/cancelled counterparts.
    private var pressesConsumedByArmedModifiers: Set<ObjectIdentifier> = []
    /// ⌘ presses sent past Ghostty to the scene's key commands. Their
    /// releases follow the same path, so Ghostty never sees a release for a
    /// press it never received.
    private var pressesRoutedToSceneCommands: Set<ObjectIdentifier> = []
    /// Echo de-dup for the originating consumed press only. Cleared on that
    /// press's ended/cancelled, or on any non-matching insert/delete.
    private var echoSuppression: ArmedModifierEchoSuppression?
    /// Whether the touch sequence in progress already went out as a right
    /// click. Its release is not a tap.
    private var didReportRightClickForTouch = false
    /// The tap count of the direct touch sequence in progress. A one-tap
    /// recognizer fires on the *second* tap of a double tap as well, and that
    /// tap is a word selection: herdr would read two reports as a double
    /// click, and a tap on a link would open it twice.
    private var directTouchTapCount = 0
    /// When the last bell was felt. A TUI that rings on every rejected
    /// keystroke would otherwise buzz continuously.
    private var lastBellFeedbackTime: CFTimeInterval?
    /// The shortest gap between two bell haptics.
    private static let bellFeedbackInterval: CFTimeInterval = 0.3
    /// A one-finger hold in progress, and what it has decided to be. See
    /// ``handleHerdrRightClickGesture(_:)``.
    private var heldPointerDrag: HeldPointerDrag?

    /// The disc drawn under a held finger. The hold's haptic is silent on an
    /// iPad, which has no Taptic Engine.
    private let holdCue = TerminalHoldCueView()

    /// The pointer touch this view took over for a right click, if any.
    private weak var claimedRightButtonTouch: UITouch?
    /// A primary-button pointer touch that began on a URL, with the URL and
    /// the point it began on. Owned here for the whole sequence, exactly as a
    /// right-button touch is, so Ghostty never turns it into a click herdr
    /// would answer by opening the link on the Mac — until it moves far enough
    /// to be a drag-selection instead, at which point the sequence is replayed
    /// to Ghostty and handed back.
    private var claimedLinkTouch: (touch: UITouch, match: TerminalLinkDetector.Match, origin: CGPoint)?
    /// Past this, a pointer press that began on a URL is a selection drag, not
    /// a click on the link.
    private static let linkClaimMovementThreshold: CGFloat = 8

    /// A one-finger hold that has not yet ended. It is a right click until the
    /// finger travels far enough to be a drag, at which point `lastCell` is
    /// set and the left button is down.
    private struct HeldPointerDrag {
        let origin: CGPoint
        let originCell: (column: Int, row: Int)
        /// The cell the last report named, or nil while the hold is still a
        /// right click in waiting.
        var lastCell: (column: Int, row: Int)?
    }

    private lazy var touchScrollGesture = UIPanGestureRecognizer(
        target: self,
        action: #selector(handleHerdrTouchScrollGesture(_:)))

    private lazy var zoomGesture = UIPinchGestureRecognizer(
        target: self,
        action: #selector(handleHerdrZoomGesture(_:)))

    private lazy var tapGesture = UITapGestureRecognizer(
        target: self,
        action: #selector(handleHerdrTap(_:)))

    private lazy var doubleTapGesture = UITapGestureRecognizer(
        target: self,
        action: #selector(handleHerdrDoubleTapGesture(_:)))

    /// Kelpie's own text selection, drawn over the grid. See
    /// ``TerminalTouchSelection`` for why the app owns it rather than Ghostty.
    private let touchSelectionOverlay = TerminalSelectionOverlayView()

    private lazy var selectionEditMenu = UIEditMenuInteraction(delegate: self)

    private lazy var rightClickGesture = UILongPressGestureRecognizer(
        target: self,
        action: #selector(handleHerdrRightClickGesture(_:)))

    private lazy var textSelectionGesture = UILongPressGestureRecognizer(
        target: self,
        action: #selector(handleHerdrTextSelectionGesture(_:)))

    #if !targetEnvironment(macCatalyst)
        private lazy var pointerScrollGesture = UIPanGestureRecognizer(
            target: self,
            action: #selector(handleHerdrPointerScrollGesture(_:)))
    #endif

    override var inputView: UIView? {
        terminalInputView
    }

    override var autocorrectionType: UITextAutocorrectionType {
        get { textInputStyle == .naturalLanguage ? .default : .no }
        set {}
    }

    override var autocapitalizationType: UITextAutocapitalizationType {
        get { textInputStyle == .naturalLanguage ? .sentences : .none }
        set {}
    }

    override var spellCheckingType: UITextSpellCheckingType {
        get { textInputStyle == .naturalLanguage ? .default : .no }
        set {}
    }

    override var smartQuotesType: UITextSmartQuotesType {
        get { textInputStyle == .naturalLanguage ? .default : .no }
        set {}
    }

    override var smartDashesType: UITextSmartDashesType {
        get { textInputStyle == .naturalLanguage ? .default : .no }
        set {}
    }

    override var smartInsertDeleteType: UITextSmartInsertDeleteType {
        get { textInputStyle == .naturalLanguage ? .default : .no }
        set {}
    }

    @available(iOS 17.0, *)
    override var inlinePredictionType: UITextInlinePredictionType {
        get { textInputStyle == .naturalLanguage ? .default : .no }
        set {}
    }

    override var beginningOfDocument: UITextPosition {
        guard super.markedTextRange == nil else {
            return super.beginningOfDocument
        }
        return TerminalInputTextPosition(index: 0)
    }

    override var endOfDocument: UITextPosition {
        guard super.markedTextRange == nil else {
            return super.endOfDocument
        }
        return TerminalInputTextPosition(index: textInputStorage.utf16.count)
    }

    override var selectedTextRange: UITextRange? {
        get {
            guard super.markedTextRange == nil else {
                return super.selectedTextRange
            }
            return TerminalInputTextRange(
                location: textInputSelection.location,
                length: textInputSelection.length)
        }
        set {
            guard super.markedTextRange == nil,
                  let range = newValue as? TerminalInputTextRange
            else {
                super.selectedTextRange = newValue
                return
            }
            let length = textInputStorage.utf16.count
            let location = min(max(range.location, 0), length)
            let end = min(max(range.location + range.length, location), length)
            textInputSelection = NSRange(location: location, length: end - location)
        }
    }

    override func textRange(
        from fromPosition: UITextPosition,
        to toPosition: UITextPosition
    ) -> UITextRange? {
        guard super.markedTextRange == nil,
              let from = fromPosition as? TerminalInputTextPosition,
              let to = toPosition as? TerminalInputTextPosition
        else {
            return super.textRange(from: fromPosition, to: toPosition)
        }
        return TerminalInputTextRange(
            location: min(from.index, to.index),
            length: abs(to.index - from.index))
    }

    override func position(
        from position: UITextPosition,
        offset: Int
    ) -> UITextPosition? {
        guard super.markedTextRange == nil,
              let position = position as? TerminalInputTextPosition
        else {
            return super.position(from: position, offset: offset)
        }
        let index = position.index + offset
        guard index >= 0, index <= textInputStorage.utf16.count else { return nil }
        return TerminalInputTextPosition(index: index)
    }

    override func position(
        from position: UITextPosition,
        in direction: UITextLayoutDirection,
        offset: Int
    ) -> UITextPosition? {
        guard position is TerminalInputTextPosition else {
            return super.position(from: position, in: direction, offset: offset)
        }
        return self.position(from: position, offset: offset)
    }

    override func compare(
        _ position: UITextPosition,
        to other: UITextPosition
    ) -> ComparisonResult {
        guard let lhs = position as? TerminalInputTextPosition,
              let rhs = other as? TerminalInputTextPosition
        else {
            return super.compare(position, to: other)
        }
        if lhs.index < rhs.index { return .orderedAscending }
        if lhs.index > rhs.index { return .orderedDescending }
        return .orderedSame
    }

    override func offset(
        from: UITextPosition,
        to toPosition: UITextPosition
    ) -> Int {
        guard let from = from as? TerminalInputTextPosition,
              let to = toPosition as? TerminalInputTextPosition
        else {
            return super.offset(from: from, to: toPosition)
        }
        return to.index - from.index
    }

    override func text(in range: UITextRange) -> String? {
        guard super.markedTextRange == nil,
              let range = range as? TerminalInputTextRange
        else {
            return super.text(in: range)
        }
        let text = textInputStorage as NSString
        guard range.location >= 0, range.length >= 0,
              range.location + range.length <= text.length
        else { return nil }
        return text.substring(
            with: NSRange(location: range.location, length: range.length))
    }

    /// Nothing rides the keyboard any more: the input row lives in the app
    /// (see `ShellTerminalView`), where a keyboard-mode switch cannot tear it
    /// down, and where UIKit's candidate-row teardown cannot move it.
    override var inputAccessoryView: UIView? {
        nil
    }

    /// Only a tap on the input row raises the keyboard, so the surface refuses
    /// first responder until asked. The gate tracks the *user's* intent, and
    /// that intent survives a UIKit-initiated resign on purpose: backgrounding
    /// the app or presenting a sheet resigns the first responder, and UIKit
    /// restores it afterwards by asking again. Refusing there would leave the
    /// accessory bar on screen with no keyboard behind it and no way to type.
    /// `dismissKeyboard()` is what clears the intent.
    ///
    /// The gate also refuses mid-touch requests: Ghostty's `touchesBegan`
    /// calls `becomeFirstResponder()` on every body touch, which with the
    /// intent armed would raise the keyboard from taps the input-row policy
    /// never approved.
    override var canBecomeFirstResponder: Bool {
        isLocalInputEnabled && responderGate.mayBecomeFirstResponder
    }

    /// UIKit skips the `canBecomeFirstResponder` check when the view already
    /// *is* first responder — and a short backgrounding leaves exactly that
    /// state behind: the keyboard hides but the first responder survives.
    /// Ghostty's `touchesBegan` re-assert would then re-present the keyboard
    /// from any body tap, so the gate has to be applied here as well.
    @discardableResult
    override func becomeFirstResponder() -> Bool {
        if isFirstResponder, !responderGate.mayBecomeFirstResponder {
            return true
        }
        let accepted = super.becomeFirstResponder()
        onFirstResponderChange?()
        return accepted
    }

    /// Ghostty's `touchesEnded` dismisses the keyboard after any body tap or
    /// scroll. The accessory's dismiss button is this app's only intended
    /// dismissal, so a resign arriving mid-touch is Ghostty's and is refused;
    /// UIKit's resigns (sheets, backgrounding) arrive outside touch sequences
    /// and pass.
    @discardableResult
    override func resignFirstResponder() -> Bool {
        guard responderGate.mayResignFirstResponder else { return false }
        let resigned = super.resignFirstResponder()
        if resigned {
            clearTouchSelection()
            onFirstResponderChange?()
        }
        return resigned
    }

    init(
        frame: CGRect,
        onSizeChanged: ((Int, Int) -> Void)?,
        onViewportTextChanged: ((String) -> Void)?,
        onSend: ((Data) -> Void)?,
        onScroll: ((Data, Int) -> Void)?,
        onPaste: ((String, Bool) -> Void)?,
        theme: TerminalTheme,
        fontSize: Float,
        fontFamily: String?,
        clipboard: TerminalClipboard
    ) {
        self.clipboard = clipboard
        let callbackBridge = TerminalSessionCallbackBridge(
            onSizeChanged: onSizeChanged,
            onViewportTextChanged: onViewportTextChanged,
            onSend: onSend,
            onScroll: onScroll,
            onPaste: onPaste)
        self.callbackBridge = callbackBridge
        terminalSession = InMemoryTerminalSession(
            write: { [weak callbackBridge] data in
                callbackBridge?.send(data)
            },
            resize: { [weak callbackBridge] viewport in
                callbackBridge?.resize(viewport)
            },
            suppressesPixelOnlyResizes: true)
        // Font size rides the controller's per-session configuration rather
        // than the surface's one-shot option, so later changes reach the live
        // surface through the same path the initial value took.
        let clampedFontSize = TerminalZoomSettings.clamped(fontSize)
        terminalController = TerminalController(
            theme: theme,
            terminalConfiguration: Self.terminalConfiguration(
                size: clampedFontSize, family: fontFamily))
        appliedTheme = theme
        appliedFontSize = clampedFontSize
        appliedFontFamily = fontFamily
        super.init(frame: frame)
        // The view is its own surface delegate so orphan-layer cleanup runs
        // wherever the view is used, not only under the SwiftUI representable.
        delegate = self
        callbackBridge.onTerminalInput = { [weak self] data in
            self?.recordTerminalInput(data)
        }
        let acceptedPasteTypes = UIPasteConfiguration(forAccepting: String.self)
        // Images and files are pasteable too: they are staged onto the Host
        // and their paths typed into the pane.
        acceptedPasteTypes.addAcceptableTypeIdentifiers([
            UTType.image.identifier,
            UTType.fileURL.identifier,
        ])
        pasteConfiguration = acceptedPasteTypes
        inputAccessoryItems = []
        configuration = TerminalSurfaceOptions(backend: .inMemory(terminalSession))
        controller = terminalController
        callbackBridge.isSizeReportCurrent = { [weak self] columns, rows in
            guard let self, hasTerminalGridMetrics else { return true }
            return terminalGridSize.columns == columns && terminalGridSize.rows == rows
        }
        callbackBridge.onReliableInput = { [weak self] in
            self?.reliableInputDidBegin()
        }
        installTouchScrolling()
        installTouchSelection()
        installZoom()
        installMediaDrop()
        #if !targetEnvironment(macCatalyst)
            installPointerScrolling()
        #endif
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func updateCallbacks(
        onSizeChanged: ((Int, Int) -> Void)?,
        onViewportTextChanged: ((String) -> Void)?,
        onSend: ((Data) -> Void)?,
        onScroll: ((Data, Int) -> Void)?,
        onPaste: ((String, Bool) -> Void)?
    ) {
        callbackBridge.onSizeChanged = onSizeChanged
        callbackBridge.onViewportTextChanged = onViewportTextChanged
        callbackBridge.onSend = onSend
        callbackBridge.onScroll = onScroll
        callbackBridge.onPaste = onPaste
    }

    @discardableResult
    func applyTheme(_ theme: TerminalTheme) -> Bool {
        guard theme != appliedTheme, terminalController.setTheme(theme) else {
            return false
        }
        appliedTheme = theme
        return true
    }

    @discardableResult
    func applyFontSize(_ fontSize: Float) -> Bool {
        let clamped = TerminalZoomSettings.clamped(fontSize)
        guard clamped != appliedFontSize,
            terminalController.setTerminalConfiguration(
                Self.terminalConfiguration(size: clamped, family: appliedFontFamily))
        else {
            return false
        }
        appliedFontSize = clamped
        return true
    }

    @discardableResult
    func applyFontFamily(_ family: String?) -> Bool {
        guard family != appliedFontFamily,
            terminalController.setTerminalConfiguration(
                Self.terminalConfiguration(size: appliedFontSize, family: family))
        else {
            return false
        }
        appliedFontFamily = family
        return true
    }

    /// ghostty treats `font-family` as a set that repeated values append to,
    /// so switching fonts has to clear it with an empty value first or the
    /// old family stays in the fallback chain ahead of the new one.
    private static func terminalConfiguration(size: Float, family: String?) -> TerminalConfiguration {
        // These surfaces forward keys to a remote application. Host shortcuts
        // (paste, zoom, selection) are handled by UIKit/Heeler, so Ghostty's
        // desktop bindings must not intercept the shared keyboard's chords.
        var configuration = TerminalConfiguration()
            .custom("keybind", "clear")
            .fontSize(size)
            .fontFamily("")
        if let family {
            configuration = configuration.fontFamily(family)
        }
        return configuration
    }

    /// Applies a zoom the user performed on this terminal and reports it, so
    /// the global setting follows the gesture instead of fighting it.
    private func zoom(to fontSize: Float) {
        guard applyFontSize(fontSize) else { return }
        onFontSizeChanged?(appliedFontSize)
    }

    func receive(_ data: Data) {
        let wasAlternateScreen = modeTracker.isAlternateScreen
        let didTrackMouse = modeTracker.tracksMouse
        modeTracker.receive(data)
        if modeTracker.isAlternateScreen != wasAlternateScreen
            || modeTracker.tracksMouse != didTrackMouse
        {
            onAlternateScreenChange?()
        }
        terminalSession.receive(data)
        scheduleViewportSnapshot()
    }

    /// Whether the remote application currently has the alternate screen
    /// active (DECSET 47 / 1047 / 1049). Read by ``TerminalScrollControl``.
    var isAlternateScreen: Bool { modeTracker.isAlternateScreen }

    /// Whether the remote application asked for mouse reporting. Only then can
    /// a scroll step reach its own history: without it, `applyScroll` falls
    /// back to cursor keys, which a non-TUI application reads as input rather
    /// than as scrolling. Read by ``TerminalScrollControl``. `refs #268`.
    var remoteTracksMouse: Bool { modeTracker.tracksMouse }

    /// Rows the grid currently shows, or nil until the surface has reported
    /// real metrics. The jump control sizes its scroll steps from this: a step
    /// larger than the viewport would move content past without it ever being
    /// rendered, and a message in that gap would be skipped. `refs #268`.
    var viewportRows: Int? {
        hasTerminalGridMetrics ? terminalGridSize.rows : nil
    }

    /// Viewport reads are supplemental to raw-stream discovery. Ghostty
    /// parses host output off-main, so coalescing briefly lets redraw bursts
    /// settle without making terminal rendering wait on link collection.
    func reportViewportText() {
        guard let text = terminalSession.readViewportText() else { return }
        callbackBridge.viewportTextDidChange(text)
    }

    private func scheduleViewportSnapshot() {
        viewportSnapshotTask?.cancel()
        viewportSnapshotTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else { return }
            self?.reportViewportText()
        }
    }

    /// Takes over the keyboard from the terminal this one replaced.
    ///
    /// The keyboard must not drop between the two: it carries the switcher, so
    /// a dip would make every switch flash the row the user is switching from.
    /// So the surface claims first responder in the same pass it reaches the
    /// window — and freezes its grid until UIKit has settled the keyboard,
    /// because Ghostty's first viewport report on a fresh surface carries a
    /// zero cell size. Measured against that half-built grid, the surface
    /// draws a band shorter than the view and leaves an unpainted strip above
    /// the toolbar.
    private func inheritKeyboard() {
        guard raisesKeyboardWhenReady, window != nil else { return }
        raisesKeyboardWhenReady = false
        // A keyboard that never left reports no did-show, only a frame change.
        beginKeyboardTransitionLayoutDeferral(endsOnFrameChange: true)
        raiseKeyboard()
        // Only a first responder is handed the settle signal that ends this
        // freeze (see `notificationSettlesOwnKeyboard`), so a claim UIKit
        // refused leaves nothing that can end it: the grid stays frozen and
        // `layoutSubviews` stays suppressed until the wall-clock leash fires.
        // No keyboard is coming, so end it here on the same terms the leash
        // would have — thawing rather than cancelling, because the surface's
        // first grid still has to reach the Host.
        if !isFirstResponder {
            finishKeyboardTransitionLayout(handoffOutcome: .cancelled)
        }
    }

    /// Raises the keyboard, and records that the user wants it up.
    func requestKeyboard() {
        guard isLocalInputEnabled else { return }
        if activeKeyboardHandoffID == nil {
            finishKeyboardTransitionLayout(handoffOutcome: .cancelled)
        }
        raiseKeyboard()
    }

    /// Transfers an already-visible keyboard to this terminal without
    /// exposing the intermediate layouts UIKit publishes between responders.
    @discardableResult
    func requestKeyboardHandoff(id: UUID) -> Bool {
        guard isLocalInputEnabled, window != nil else { return false }
        activeKeyboardHandoffID = id
        beginKeyboardTransitionLayoutDeferral(endsOnFrameChange: true)
        raiseKeyboard()
        guard isFirstResponder else {
            cancelKeyboardTransitionLayoutDeferral()
            return false
        }
        return true
    }

    private func raiseKeyboard() {
        responderGate.beginUserDrivenChange(wantsKeyboard: true)
        defer { responderGate.endUserDrivenChange() }
        _ = becomeFirstResponder()
    }

    /// Takes the keyboard down on the user's behalf. This is the *only* way
    /// the keyboard goes away for good: a plain `resignFirstResponder()` is
    /// something UIKit does on its own (backgrounding, a sheet taking focus)
    /// and must stay recoverable.
    @discardableResult
    func dismissKeyboard() -> Bool {
        responderGate.beginUserDrivenChange(wantsKeyboard: false)
        defer { responderGate.endUserDrivenChange() }
        return resignFirstResponder()
    }

    func setLocalInputEnabled(_ isEnabled: Bool) {
        guard isLocalInputEnabled != isEnabled else { return }
        if !isEnabled {
            // Still enabled here, so the release actually goes out: a paused
            // pane must not be left holding the left button down.
            releaseHeldPointerDrag(at: nil)
            holdCue.hide()
        }
        isLocalInputEnabled = isEnabled
        if !isEnabled {
            cancelKeyboardTransitionLayoutDeferral()
        }
        if !isEnabled, isFirstResponder {
            _ = dismissKeyboard()
        }
    }

    func setTextInputStyle(_ style: TerminalTextInputStyle) {
        guard textInputStyle != style else { return }
        textInputStyle = style
        applyInputAssistantStyle()
    }

    func installInputAssistantStyle() {
        defaultLeadingAssistantGroups = inputAssistantItem.leadingBarButtonGroups
        defaultTrailingAssistantGroups = inputAssistantItem.trailingBarButtonGroups
        applyInputAssistantStyle()
    }

    private func applyInputAssistantStyle() {
        switch textInputStyle {
        case .terminal:
            inputAssistantItem.leadingBarButtonGroups = []
            inputAssistantItem.trailingBarButtonGroups = []
        case .naturalLanguage:
            inputAssistantItem.leadingBarButtonGroups = defaultLeadingAssistantGroups ?? []
            inputAssistantItem.trailingBarButtonGroups = defaultTrailingAssistantGroups ?? []
        }
    }

    func requestPaste(_ text: String?) {
        guard isLocalInputEnabled, let text else { return }
        reliableInputDidBegin()
        recordCommittedText(text)
        callbackBridge.paste(text, bracketed: usesBracketedPaste)
    }

    /// Soft-keyboard Return arrives here as `"\n"` (UIKeyInput). Direct Input
    /// and Shell treat Enter as PTY CR (`0x0D`), matching shortcut Enter and
    /// `AgentQuickKey.enter` — not LF.
    override func insertText(_ text: String) {
        guard isLocalInputEnabled else { return }
        if consumeMatchingInsertEcho(text) {
            return
        }
        if applyArmedModifiers(toInsertedText: text) {
            return
        }
        if text == "\n" {
            super.insertText("\r")
            return
        }
        super.insertText(text)
    }

    override func deleteBackward() {
        if consumeMatchingBackspaceEcho() {
            return
        }
        guard isLocalInputEnabled else { return }

        // Option+Backspace has already gone out as ESC DEL. UIKit's echo of
        // the same press would delete a second time, a plain character.
        guard
            !isSuppressingAltEcho(
                forUsage: TerminalHardwareKeyMapping.Usage.deleteOrBackspace)
        else { return }

        // Ghostty already synchronizes marked-text deletion with UIKit. Raw
        // terminal deletion also changes the remote document, so it must send
        // the same notifications or the software keyboard stops key repeat.
        guard markedTextRange == nil else {
            super.deleteBackward()
            return
        }

        guard let deletionRange = textInputDeletionRange() else {
            super.deleteBackward()
            return
        }

        inputDelegate?.textWillChange(self)
        inputDelegate?.selectionWillChange(self)
        deleteFromTextInputStorage(in: deletionRange)
        super.deleteBackward()
        inputDelegate?.selectionDidChange(self)
        inputDelegate?.textDidChange(self)
    }

    private func recordTerminalInput(_ data: Data) {
        guard !data.contains(0x1B), !data.contains(0x7F),
              !data.contains(where: { $0 < 0x20 && $0 != 0x0A && $0 != 0x0D }),
              let text = String(data: data, encoding: .utf8)
        else { return }
        recordCommittedText(text)
    }

    private func recordCommittedText(_ text: String) {
        let storage = NSMutableString(string: textInputStorage)
        storage.replaceCharacters(in: textInputSelection, with: text)
        textInputStorage = storage as String

        if let lineBreak = textInputStorage.rangeOfCharacter(
            from: .newlines, options: .backwards)
        {
            textInputStorage = String(textInputStorage[lineBreak.upperBound...])
        }
        textInputSelection = NSRange(
            location: textInputStorage.utf16.count,
            length: 0)
    }

    private func textInputDeletionRange() -> NSRange? {
        let storage = NSMutableString(string: textInputStorage)
        if textInputSelection.length > 0 {
            return textInputSelection
        }
        guard textInputSelection.location > 0 else { return nil }
        return storage.rangeOfComposedCharacterSequence(
            at: textInputSelection.location - 1)
    }

    private func deleteFromTextInputStorage(in deletionRange: NSRange) {
        let storage = NSMutableString(string: textInputStorage)
        storage.deleteCharacters(in: deletionRange)
        textInputStorage = storage as String
        textInputSelection = NSRange(location: deletionRange.location, length: 0)
    }

    override func paste(_ sender: Any?) {
        guard isLocalInputEnabled, claimPasteForThisTurn() else { return }
        guard let text = clipboard.string() else {
            // No text on the pasteboard: an image or a file is still worth
            // pasting — it goes to the Host and its path is typed here.
            stageMedia(from: UIPasteboard.general.itemProviders)
            return
        }

        // The keyboard's clipboard suggestion invokes this standard action
        // directly, bypassing Ghostty's text-input handler. Tell UIKit about
        // the external document change or the IME keeps its pre-paste context
        // and subsequent phonetic input can remain Latin marked text.
        inputDelegate?.textWillChange(self)
        requestPaste(text)
        inputDelegate?.textDidChange(self)
    }

    override func paste(itemProviders: [NSItemProvider]) {
        guard isLocalInputEnabled else { return }
        for provider in itemProviders where provider.canLoadObject(ofClass: NSString.self) {
            provider.loadObject(ofClass: NSString.self) { [weak self] object, _ in
                guard let text = object as? String else { return }
                Task { @MainActor [weak self] in
                    self?.requestPaste(text)
                }
            }
            return
        }
        stageMedia(from: itemProviders)
    }

    override func canPaste(_ itemProviders: [NSItemProvider]) -> Bool {
        guard isLocalInputEnabled else { return false }
        return itemProviders.contains {
            MediaIntake.classify(typeIdentifiers: $0.registeredTypeIdentifiers)
                != .unsupported
        }
    }

    /// ⌘V can arrive twice for one key event: from `pressesBegan`, which
    /// answers it because Ghostty ignores it, and from UIKit's own editing
    /// shortcut, which `canPerformAction` enables. The second one would type
    /// the text twice — or upload the same file twice — so whichever arrives
    /// first in a run-loop turn wins and the other is dropped. Cleared the way
    /// the hardware-key claim is.
    private func claimPasteForThisTurn() -> Bool {
        guard !hasClaimedPasteThisTurn else { return false }
        hasClaimedPasteThisTurn = true
        DispatchQueue.main.async { [weak self] in
            self?.hasClaimedPasteThisTurn = false
        }
        return true
    }

    /// Hands on the providers this terminal cannot type — the image and file
    /// ones. Staging them is the owner's job; the surface only sorts, and
    /// starts their loads.
    ///
    /// The loads have to begin here, synchronously: a drop's providers stop
    /// working the moment `performDrop` returns, and the owner reads them a
    /// turn later. ``MediaIntake/beginLoading(_:)`` issues every request now
    /// and the owner's `loadItems` joins that same load.
    private func stageMedia(from itemProviders: [NSItemProvider]) {
        guard let onStageItems else { return }
        let media = itemProviders.filter(Self.isStageable)
        guard !media.isEmpty else { return }
        MediaIntake.beginLoading(media)
        onStageItems(media)
    }

    private static func isStageable(_ provider: NSItemProvider) -> Bool {
        switch MediaIntake.classify(
            typeIdentifiers: provider.registeredTypeIdentifiers)
        {
        case .image, .file: true
        case .text, .unsupported: false
        }
    }

    /// ⌘C, and the system Copy item, take the touch selection when there is
    /// one. Ghostty's own `copy(_:)` reads its pointer selection, which a
    /// finger can never make, so it stays the fallback for a trackpad.
    @IBAction override func copy(_ sender: Any?) {
        guard touchSelectionOverlay.selection != nil else {
            super.copy(sender)
            return
        }
        copyTouchSelection()
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(copy(_:)), touchSelectionOverlay.selection != nil {
            return true
        }
        if action == #selector(handleEscapeKeyCommand(_:)) {
            let answer = super.canPerformAction(action, withSender: sender)
            TerminalKeyTrace.log("canPerformAction escape -> \(answer)")
            return answer
        }
        if action == #selector(paste(_:)) {
            // `hasImages`/`hasURLs` answer from the pasteboard's declared
            // types; only reading its contents would raise the paste banner.
            // They count only where something stages them: the Console's
            // terminal has no stager, and a Paste that does nothing is worse
            // than no Paste at all.
            let stagesMedia = onStageItems != nil
                && (UIPasteboard.general.hasImages || UIPasteboard.general.hasURLs)
            return isLocalInputEnabled && (clipboard.hasStrings() || stagesMedia)
        }
        return super.canPerformAction(action, withSender: sender)
    }

    override func reloadInputViews() {
        inputViewRebuildCount += 1
        super.reloadInputViews()
    }

    override func layoutSubviews() {
        guard !defersLayoutForKeyboardTransition else { return }
        // Before Ghostty's layout, so the freeze is in force by the time the
        // pass reports its grid.
        deferGridReportsForWindowResize()
        super.layoutSubviews()
        // Ghostty adds its own layers as the surface attaches, so the overlay
        // is put back on top rather than assumed to have stayed there.
        touchSelectionOverlay.frame = bounds
        bringSubviewToFront(touchSelectionOverlay)
        if holdCue.superview === self { bringSubviewToFront(holdCue) }
        touchSelectionOverlay.refresh()
        reloadInputViewsAfterWindowResize()
        settleSurfaceScaleAfterResize()
    }

    /// Lays out again after a size change so Ghostty's layer scale is set once
    /// its renderer has rebuilt the surface; see ``TerminalSurfaceScaleSettle``.
    /// The follow-up goes through `layoutSubviews`, so the keyboard and window
    /// resize freezes still apply, and an unchanged grid reports nothing.
    private func settleSurfaceScaleAfterResize() {
        guard surfaceScaleSettle.boundsDidLayout(size: bounds.size) else { return }
        surfaceScaleSettleTask?.cancel()
        surfaceScaleSettleTask = Task { @MainActor [weak self] in
            var elapsed: TimeInterval = 0
            for delay in TerminalSurfaceScaleSettle.followUpDelays {
                try? await Task.sleep(for: .seconds(delay - elapsed))
                elapsed = delay
                guard !Task.isCancelled, let self, self.window != nil else { return }
                self.setNeedsLayout()
                self.layoutIfNeeded()
            }
        }
    }

    /// Stage Manager live resize, like rotation, changes the window's size on
    /// consecutive frames, and Ghostty reports a PTY resize for every grid
    /// that passes by. Those reports go through the same freeze the keyboard
    /// handoff uses: held while the window keeps changing, then forwarded
    /// once, as the grid the window settled on. A keyboard or split-view
    /// column change leaves the window's size alone and reports as before.
    private func deferGridReportsForWindowResize() {
        guard let windowSize = window?.bounds.size,
              windowResizeTracker.windowDidLayout(size: windowSize)
        else { return }
        // A freeze already holding (a keyboard settle still waiting to
        // report, or this burst's previous frame) keeps its deferred grid;
        // re-arming it would throw that grid away.
        if callbackBridge.gridReportPhase != .deferring {
            callbackBridge.beginSizeReportDeferral()
        }
        windowResizeGridIsPending = true
        keyboardGridReportTask?.cancel()
        let settleDelay = Self.windowResizeSettleDelay
        keyboardGridReportTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(settleDelay))
            guard !Task.isCancelled, let self else { return }
            keyboardGridReportTask = nil
            windowResizeGridIsPending = false
            if hasTerminalGridMetrics {
                // Ghostty reports a grid only when it changes, so a burst
                // that returns to a grid it already passed through produces
                // no final callback. The surface's synchronous metrics are
                // the grid the window settled on either way.
                callbackBridge.provideAuthoritativeDeferredSize(
                    columns: terminalGridSize.columns,
                    rows: terminalGridSize.rows)
            }
            callbackBridge.finishSizeReportDeferral()
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            stopTouchScrollMomentum()
            clearTouchSelection()
            // A hold cannot survive the view leaving its window: without this
            // the button stays down remotely and `heldPointerDrag` refuses
            // touch scrolling for ever.
            releaseHeldPointerDrag(at: nil)
            holdCue.hide(animated: false)
            responderGate.invalidateTouches()
            surfaceScaleSettleTask?.cancel()
            surfaceScaleSettleTask = nil
        } else {
            inheritKeyboard()
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        // A finger anywhere but on a handle dismisses the selection. A touch
        // that hit-tests to a handle still arrives here through the responder
        // chain, so it is the touch's *view* that decides, not its location.
        if touches.contains(where: {
            $0.type == .direct && !touchSelectionOverlay.owns($0.view)
        }) {
            clearTouchSelection()
        }
        if let tapCount = touches.filter({ $0.type == .direct }).map(\.tapCount).max() {
            directTouchTapCount = tapCount
        }
        if rightClickGesture.state == .possible {
            didReportRightClickForTouch = false
        }
        var forwarded = touches
        if let claimed = rightButtonTouchToClaim(in: touches, with: event) {
            claimedRightButtonTouch = claimed
            // A pointer click claims the keyboard the way Ghostty's own
            // pointer path does; nothing else will, now that it never sees
            // this touch.
            if !isFirstResponder { becomeFirstResponder() }
            forwarded.remove(claimed)
        } else if let claimed = linkTouchToClaim(in: touches, with: event) {
            claimedLinkTouch = claimed
            forwarded.remove(claimed.touch)
        }
        responderGate.directTouchesBegan(Self.directTouchCount(in: touches))
        guard !forwarded.isEmpty else { return }
        super.touchesBegan(forwarded, with: event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        var forwarded = touches.subtracting(claimedRightButtonTouch.map { [$0] } ?? [])
        if let claimed = claimedLinkTouch, touches.contains(claimed.touch) {
            if Self.distance(claimed.touch.location(in: self), claimed.origin)
                > Self.linkClaimMovementThreshold
            {
                // A drag, not a click on the link. Ghostty never saw the
                // press, so replay it before handing the rest over: its
                // pointer selection starts from that `.began`.
                claimedLinkTouch = nil
                super.touchesBegan([claimed.touch], with: event)
            } else {
                forwarded.remove(claimed.touch)
            }
        }
        guard !forwarded.isEmpty else { return }
        super.touchesMoved(forwarded, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        let forwarded = finishClaimedLinkTouch(
            in: finishClaimedRightButtonTouch(in: touches, reporting: true),
            opening: true)
        // Ghostty's touchesEnded is where its tap-to-dismiss resign fires, so
        // the touches stay counted until super returns.
        if !forwarded.isEmpty {
            super.touchesEnded(forwarded, with: event)
        }
        responderGate.directTouchesEnded(Self.directTouchCount(in: touches))
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        let forwarded = finishClaimedLinkTouch(
            in: finishClaimedRightButtonTouch(in: touches, reporting: false),
            opening: false)
        if !forwarded.isEmpty {
            super.touchesCancelled(forwarded, with: event)
        }
        responderGate.directTouchesEnded(Self.directTouchCount(in: touches))
    }

    /// The pointer touch of a right-button press to take over, if this is one.
    ///
    /// Ghostty decides on `.began` whether a right click belongs to its copy
    /// menu, and a stale pointer drag-selection rect is enough for it to
    /// swallow the click before ``selectionMenuPoint(at:)`` is ever asked. So
    /// while a remote application owns the mouse the whole sequence is taken
    /// here and never shown to Ghostty, which leaves its own pointer state
    /// untouched.
    private func rightButtonTouchToClaim(
        in touches: Set<UITouch>,
        with event: UIEvent?
    ) -> UITouch? {
        guard modeTracker.tracksMouse,
            event?.buttonMask.contains(.secondary) == true
        else { return nil }
        return touches.first { $0.type == .indirectPointer }
    }

    /// Reports the claimed sequence's click and returns whatever Ghostty
    /// should still see.
    private func finishClaimedRightButtonTouch(
        in touches: Set<UITouch>,
        reporting: Bool
    ) -> Set<UITouch> {
        guard let claimed = claimedRightButtonTouch, touches.contains(claimed) else {
            return touches
        }
        claimedRightButtonTouch = nil
        if reporting {
            rightClickTouch(at: claimed.location(in: self))
        }
        return touches.subtracting([claimed])
    }

    /// The primary-button pointer touch of a click that landed on a URL.
    private func linkTouchToClaim(
        in touches: Set<UITouch>,
        with event: UIEvent?
    ) -> (touch: UITouch, match: TerminalLinkDetector.Match, origin: CGPoint)? {
        guard event?.buttonMask.contains(.primary) == true,
            let touch = touches.first(where: { $0.type == .indirectPointer })
        else { return nil }
        let origin = touch.location(in: self)
        guard let match = linkMatch(at: origin) else { return nil }
        return (touch, match, origin)
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    /// Opens the claimed link when the click ended on the same URL it began
    /// on, and returns whatever Ghostty should still see.
    private func finishClaimedLinkTouch(
        in touches: Set<UITouch>,
        opening: Bool
    ) -> Set<UITouch> {
        guard let claimed = claimedLinkTouch, touches.contains(claimed.touch) else {
            return touches
        }
        claimedLinkTouch = nil
        let ended = claimed.touch.location(in: self)
        if opening,
            Self.distance(ended, claimed.origin) <= Self.linkClaimMovementThreshold,
            linkMatch(at: ended) == claimed.match
        {
            open(claimed.match)
        }
        return touches.subtracting([claimed.touch])
    }

    private static func directTouchCount(in touches: Set<UITouch>) -> Int {
        touches.count { $0.type == .direct }
    }

    override func gestureRecognizerShouldBegin(
        _ gestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        if gestureRecognizer === touchScrollGesture {
            // A held finger belongs to the hold — a right click or a mouse
            // drag — and never to a scroll. UIKit's own arbitration already
            // prevents the pan once the long press has begun; this says so.
            guard heldPointerDrag == nil else { return false }
            let velocity = touchScrollGesture.velocity(in: self)
            return abs(velocity.y) > abs(velocity.x)
        }
        if gestureRecognizer === tapGesture {
            // A TUI wants every tap — to click, to raise the keyboard, or both.
            // In the normal buffer only the input row is interactive. A running
            // flick claims any tap regardless, to halt itself.
            let location = tapGesture.location(in: self)
            return modeTracker.tracksMouse
                || modeTracker.isAlternateScreen
                || isTouchScrollMomentumRunning
                || keyboardActivationRegion.contains(location)
                // A link is worth a tap wherever it is, including the plain
                // shell's output area, which none of the above answers.
                || linkMatch(at: location) != nil
        }
        if gestureRecognizer === doubleTapGesture {
            // A word is worth selecting wherever it is, in any mode.
            return true
        }
        if gestureRecognizer === rightClickGesture {
            return modeTracker.tracksMouse
        }
        if gestureRecognizer === textSelectionGesture {
            // Only while the one-finger hold is spoken for; otherwise
            // Ghostty's own long press already presents the sheet.
            return modeTracker.tracksMouse
        }
        if gestureRecognizer is UILongPressGestureRecognizer {
            // Ghostty's selection long-press. While a TUI owns the mouse the
            // same hold is a right click, and only one of the two may answer
            // it — two fingers ask for the selection sheet instead.
            guard !modeTracker.tracksMouse else { return false }
            return super.gestureRecognizerShouldBegin(gestureRecognizer)
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    /// While a remote application owns the mouse, a right-click belongs to it,
    /// not to the iPadOS copy menu. Ghostty holds the right press back on
    /// `.began` whenever this returns a point, so nulling it here is what lets
    /// the press and release reach libghostty — and herdr — as SGR reports.
    override func selectionMenuPoint(at point: CGPoint) -> CGPoint? {
        guard !modeTracker.tracksMouse else { return nil }
        return super.selectionMenuPoint(at: point)
    }

    override func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard !modeTracker.tracksMouse else { return nil }
        return super.contextMenuInteraction(
            interaction, configurationForMenuAtLocation: location)
    }

    /// A finger on a selection handle belongs to the overlay alone. The
    /// handles are subviews, so hit-testing already keeps the touch out of
    /// `touchesBegan`, but this view's recognizers see every touch in their
    /// subtree — and a drag of a handle must not also scroll or click.
    func gestureRecognizer(
        _: UIGestureRecognizer,
        shouldReceive touch: UITouch
    ) -> Bool {
        guard touch.type == .direct else { return true }
        return !touchSelectionOverlay.containsHandle(
            at: touch.location(in: touchSelectionOverlay))
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith _: UIGestureRecognizer
    ) -> Bool {
        #if !targetEnvironment(macCatalyst)
            return gestureRecognizer === pointerScrollGesture
        #else
            return false
        #endif
    }

    private func reloadInputViewsAfterWindowResize() {
        guard let windowSize = window?.bounds.size else { return }
        defer { lastInputWindowSize = windowSize }
        guard let lastInputWindowSize, lastInputWindowSize != windowSize, isFirstResponder else {
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self, self.isFirstResponder else { return }
            UIView.performWithoutAnimation {
                self.reloadInputViews()
            }
        }
    }

    /// Ghostty synchronizes its grid and reports a PTY resize from every
    /// `layoutSubviews` pass, and a keyboard changing hands passes through
    /// several transient heights — both accessories ride the keyboard at once
    /// while it does. Each one would cost a full-screen TUI redraw, so the
    /// grid stays fixed until the keyboard has settled.
    ///
    /// Only a handoff needs this. An ordinary presentation or dismissal moves
    /// in one step, because the terminal sizes itself to the keyboard's own
    /// frame rather than through SwiftUI's two-stage avoidance — see
    /// ``TerminalKeyboardInset``.
    private func beginKeyboardTransitionLayoutDeferral(endsOnFrameChange: Bool = false) {
        keyboardGridReportTask?.cancel()
        keyboardGridReportTask = nil
        defersLayoutForKeyboardTransition = true
        keyboardTransitionEndsOnFrameChange = endsOnFrameChange
        didReloadInputViewsForKeyboardHandoff = false
        keyboardHandoffReloadIsScheduled = false
        keyboardTransitionCycleID = UUID()
        callbackBridge.beginSizeReportDeferral()
        keyboardTransitionFallbackTask?.cancel()
        let fallbackDelay = keyboardTransitionFallbackDelay
        keyboardTransitionFallbackTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(fallbackDelay))
            guard !Task.isCancelled else { return }
            self?.finishKeyboardTransitionLayout(handoffOutcome: .timedOut)
        }
    }

    private func scheduleGridReport(after delay: TimeInterval) {
        keyboardGridReportTask?.cancel()
        keyboardGridReportTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.keyboardGridReportTask = nil
            // This thaw forwards the authoritative grid, covering any window
            // resize the freeze had absorbed.
            self?.windowResizeGridIsPending = false
            self?.callbackBridge.finishSizeReportDeferral()
        }
    }

    /// The keyboard reached its end frame. An inherited keyboard never leaves,
    /// so this is the only settled signal it gets — there is no did-show to
    /// wait for. Show/hide notifications are process-wide and carry no scene
    /// ownership, so they cannot safely end a handoff. Whose keyboard it is,
    /// the caller answers from the end frame: only one that leaves the
    /// keyboard covering this terminal's own window may thaw the freeze
    /// (#157).
    func keyboardFrameDidSettle() {
        guard keyboardTransitionEndsOnFrameChange else { return }
        guard didReloadInputViewsForKeyboardHandoff else {
            guard !keyboardHandoffReloadIsScheduled,
                  let cycleID = keyboardTransitionCycleID
            else { return }
            keyboardHandoffReloadIsScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.keyboardTransitionCycleID == cycleID,
                      self.keyboardTransitionEndsOnFrameChange,
                      self.keyboardHandoffReloadIsScheduled
                else { return }
                // Set the phase first because UIKit may synchronously publish
                // the repopulated frame from inside reloadInputViews().
                self.keyboardHandoffReloadIsScheduled = false
                self.didReloadInputViewsForKeyboardHandoff = true
                UIView.performWithoutAnimation { self.reloadInputViews() }
            }
            return
        }
        finishKeyboardTransitionLayout(handoffOutcome: .settled)
    }

    func finishKeyboardTransitionLayout(
        handoffOutcome: TerminalKeyboardHandoffOutcome = .settled
    ) {
        guard defersLayoutForKeyboardTransition else { return }
        let inheritedTheKeyboard = keyboardTransitionEndsOnFrameChange
        let alreadyReloadedInputViews = didReloadInputViewsForKeyboardHandoff
        let settledHandoffID = activeKeyboardHandoffID
        activeKeyboardHandoffID = nil
        defersLayoutForKeyboardTransition = false
        keyboardTransitionEndsOnFrameChange = false
        didReloadInputViewsForKeyboardHandoff = false
        keyboardHandoffReloadIsScheduled = false
        keyboardTransitionCycleID = nil
        keyboardTransitionFallbackTask?.cancel()
        keyboardTransitionFallbackTask = nil
        if inheritedTheKeyboard, !alreadyReloadedInputViews {
            // Both terminals' accessories were on the keyboard while it
            // changed hands, and that is the frame the keyboard published:
            // one accessory too tall. UIKit does not publish another when the
            // outgoing one leaves, so the layout keeps reserving room for an
            // accessory that is gone. Rebuilding the input views makes it
            // publish the settled frame.
            UIView.performWithoutAnimation { reloadInputViews() }
        }
        setNeedsLayout()
        layoutIfNeeded()
        if hasTerminalGridMetrics {
            // A fresh surface can publish its first grid just before the
            // handoff freeze begins. The bridge correctly rejects that queued
            // pre-freeze callback, and libghostty may suppress an identical
            // post-layout callback. Seed the deferral from the surface
            // delegate's synchronous final metrics so Attach still receives
            // its initial size, without letting the stale grid escape.
            callbackBridge.provideAuthoritativeDeferredSize(
                columns: terminalGridSize.columns,
                rows: terminalGridSize.rows)
        }
        scheduleGridReport(after: Self.gridSettleDelay)
        if inheritedTheKeyboard, let settledHandoffID {
            onKeyboardHandoffEnded?(settledHandoffID, handoffOutcome)
        }
    }

    private func cancelKeyboardTransitionLayoutDeferral() {
        let cancelledHandoffID = activeKeyboardHandoffID
        activeKeyboardHandoffID = nil
        defersLayoutForKeyboardTransition = false
        keyboardTransitionEndsOnFrameChange = false
        didReloadInputViewsForKeyboardHandoff = false
        keyboardHandoffReloadIsScheduled = false
        keyboardTransitionCycleID = nil
        keyboardTransitionFallbackTask?.cancel()
        keyboardTransitionFallbackTask = nil
        keyboardGridReportTask?.cancel()
        keyboardGridReportTask = nil
        callbackBridge.cancelSizeReportDeferral()
        if windowResizeGridIsPending {
            windowResizeGridIsPending = false
            if hasTerminalGridMetrics {
                // The cancelled freeze held the grid a window resize settled
                // on. Without this the Host keeps the pre-resize PTY size
                // until the grid happens to change again.
                callbackBridge.reportSettledSize(
                    columns: terminalGridSize.columns,
                    rows: terminalGridSize.rows)
            }
        }
        if let cancelledHandoffID {
            onKeyboardHandoffEnded?(cancelledHandoffID, .cancelled)
        }
    }

    var usesApplicationCursorKeys: Bool {
        modeTracker.usesApplicationCursorKeys
    }

    var usesBracketedPaste: Bool {
        modeTracker.usesBracketedPaste
    }

    func setTerminalInputView(_ inputView: UIView?) {
        terminalInputView = inputView
    }

    var keyboardActivationRegion: CGRect {
        let caret = caretRect(for: endOfDocument)
        return TerminalKeyboardTapTarget.region(
            caretRect: caret,
            in: bounds,
            minimumHeight: modeTracker.isAlternateScreen
                ? TerminalKeyboardTapTarget.alternateScreenMinimumHeight
                : TerminalKeyboardTapTarget.minimumHeight)
    }

    /// The http/https URL the cell under `point` is part of, if any. Read
    /// from the viewport rather than asked of libghostty, which has no such
    /// query on iOS. See ``TerminalLinkDetector``.
    func linkURL(at point: CGPoint) -> URL? {
        if case .url(let url)? = linkMatch(at: point) { return url }
        return nil
    }

    /// The URL or absolute Host path the cell under `point` is part of.
    func linkMatch(at point: CGPoint) -> TerminalLinkDetector.Match? {
        let mapper = gridPointMapper
        guard let cell = mapper.cell(at: point),
            let text = terminalSession.readViewportText()
        else { return nil }
        let match = TerminalLinkDetector.match(
            inViewport: text, column: cell.column, row: cell.row,
            width: mapper.columns)
        // A path is only a link on a screen that can open one; elsewhere the
        // tap must fall through to its click and keyboard behaviour.
        if case .hostPath? = match, onHostPathTap == nil { return nil }
        return match
    }

    /// A URL opens on the iPad; a path opens in the Host file viewer.
    private func open(_ match: TerminalLinkDetector.Match) {
        switch match {
        case .url(let url): onOpenLink?(url)
        case .hostPath(let path): onHostPathTap?(path)
        }
    }

    /// Reports a touch as a left click when the remote application asked for
    /// mouse tracking. Returns whether anything was sent.
    @discardableResult
    func clickTouch(at point: CGPoint) -> Bool {
        guard isLocalInputEnabled,
            let cell = gridPointMapper.cell(at: point),
            let report = modeTracker.remoteClickSequence(
                column: cell.column,
                row: cell.row)
        else { return false }

        terminalSession.sendInput(report)
        return true
    }

    /// Reports a touch as a right click, on the same terms as
    /// ``clickTouch(at:)``. Returns whether anything was sent.
    @discardableResult
    func rightClickTouch(at point: CGPoint) -> Bool {
        guard isLocalInputEnabled,
            let cell = gridPointMapper.cell(at: point),
            let report = modeTracker.remoteRightClickSequence(
                column: cell.column,
                row: cell.row)
        else { return false }

        terminalSession.sendInput(report)
        return true
    }

    /// The grid Ghostty last measured this surface against, or `nil` before
    /// the surface has reported one. This is the value a thawing freeze
    /// forwards to the Host as the settled grid.
    var measuredGrid: TerminalGridSize? {
        guard hasTerminalGridMetrics else { return nil }
        return TerminalGridSize(
            columns: terminalGridSize.columns, rows: terminalGridSize.rows)
    }

    /// Where the keyboard-transition grid freeze currently stands.
    var gridReportPhase: TerminalGridReportPhase {
        callbackBridge.gridReportPhase
    }

    /// Observes the freeze's transitions. See ``TerminalGridReportPhase``.
    var onGridReportPhaseChanged: ((
        _ phase: TerminalGridReportPhase, _ forwarded: TerminalGridSize?
    ) -> Void)? {
        get { callbackBridge.onGridReportPhaseChanged }
        set { callbackBridge.onGridReportPhaseChanged = newValue }
    }

    /// Where Ghostty's grid currently sits inside the view, rebuilt from the
    /// metrics of the last resize.
    var gridPointMapper: TerminalGridPointMapper {
        TerminalGridPointMapper(
            viewSize: bounds.size,
            cellSize: terminalCellSize,
            columns: terminalGridSize.columns,
            rows: terminalGridSize.rows,
            scale: window?.screen.nativeScale ?? traitCollection.displayScale)
    }

    @discardableResult
    func scrollTouch(translationY: CGFloat) -> Int {
        clearTouchSelection()
        let rows = touchScrollAccumulator.rows(
            for: translationY,
            pointsPerRow: max(8, terminalCellSize.height))
        guard rows != 0 else { return 0 }
        applyScroll(towardOlderContent: rows > 0, rowCount: abs(rows))
        onTouchScroll?(rows > 0)
        return rows
    }

    /// One scroll step of `rowCount` lines for chrome that is not a gesture.
    /// Shares ``applyScroll(towardOlderContent:rowCount:)`` with
    /// ``scrollTouch(translationY:)`` and leaves the touch accumulator alone.
    func scrollRows(towardOlderContent: Bool, rows rowCount: Int) {
        guard rowCount > 0 else { return }
        applyScroll(towardOlderContent: towardOlderContent, rowCount: rowCount)
    }

    /// Test seam observing local Ghostty binding actions from scroll paths.
    var didPerformBindingAction: ((String) -> Void)?

    /// Remote wheel / cursor sequence when the mode tracker supplies one;
    /// otherwise local `scroll_page_lines`. Shared by touch and the jump
    /// control so they cannot drift. `refs #268`.
    private func applyScroll(towardOlderContent: Bool, rowCount: Int) {
        if let sequence = modeTracker.remoteScrollSequence(
            towardOlderContent: towardOlderContent,
            columns: terminalGridSize.columns,
            rows: terminalGridSize.rows)
        {
            callbackBridge.scroll(sequence, rows: rowCount)
        } else {
            let localRows = towardOlderContent ? -rowCount : rowCount
            let action = "scroll_page_lines:\(localRows)"
            _ = performBindingAction(action)
            didPerformBindingAction?(action)
        }
    }

    private func installTouchScrolling() {
        let directTouch = NSNumber(value: UITouch.TouchType.direct.rawValue)
        for case let pan as UIPanGestureRecognizer in gestureRecognizers ?? []
        where pan.allowedTouchTypes.contains(directTouch) {
            pan.isEnabled = false
        }

        touchScrollGesture.allowedTouchTypes = [directTouch]
        touchScrollGesture.maximumNumberOfTouches = 1
        touchScrollGesture.cancelsTouchesInView = false
        touchScrollGesture.delegate = self
        addGestureRecognizer(touchScrollGesture)

        tapGesture.allowedTouchTypes = [directTouch]
        tapGesture.numberOfTouchesRequired = 1
        tapGesture.cancelsTouchesInView = false
        tapGesture.delegate = self
        addGestureRecognizer(tapGesture)

        for gesture in [rightClickGesture, textSelectionGesture] {
            gesture.allowedTouchTypes = [directTouch]
            gesture.minimumPressDuration = 0.5
            gesture.allowableMovement = 10
            gesture.cancelsTouchesInView = false
            gesture.delegate = self
            addGestureRecognizer(gesture)
        }
        rightClickGesture.numberOfTouchesRequired = 1
        textSelectionGesture.numberOfTouchesRequired = 2

        doubleTapGesture.allowedTouchTypes = [directTouch]
        doubleTapGesture.numberOfTapsRequired = 2
        doubleTapGesture.numberOfTouchesRequired = 1
        doubleTapGesture.cancelsTouchesInView = false
        doubleTapGesture.delegate = self
        addGestureRecognizer(doubleTapGesture)
    }

    /// The selection overlay and the menu that acts on it.
    ///
    /// The overlay is an ordinary subview above the Ghostty surface: it draws
    /// the highlight and the handles, and answers touches only on the handles.
    private func installTouchSelection() {
        touchSelectionOverlay.frame = bounds
        touchSelectionOverlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        touchSelectionOverlay.gridMetrics = { [weak self] in
            self?.gridPointMapper
                ?? TerminalGridPointMapper(
                    viewSize: .zero, cellSize: .zero, columns: 0, rows: 0, scale: 1)
        }
        touchSelectionOverlay.onDragFinished = { [weak self] selection in
            guard selection != nil else { return }
            self?.presentSelectionEditMenu()
        }
        addSubview(touchSelectionOverlay)
        addInteraction(selectionEditMenu)
    }

    #if !targetEnvironment(macCatalyst)
        /// Trackpad and mouse-wheel scrolling. Ghostty installs a scroll-type
        /// pan under macCatalyst only, so on iPadOS nothing answers a
        /// two-finger trackpad swipe until this one does.
        private func installPointerScrolling() {
            pointerScrollGesture.allowedScrollTypesMask = [.continuous, .discrete]
            pointerScrollGesture.allowedTouchTypes = [
                NSNumber(value: UITouch.TouchType.indirectPointer.rawValue),
            ]
            pointerScrollGesture.cancelsTouchesInView = false
            pointerScrollGesture.delaysTouchesBegan = false
            pointerScrollGesture.delegate = self
            addGestureRecognizer(pointerScrollGesture)
        }
    #endif

    /// A photo or a file dragged onto the terminal is an upload, not a paste:
    /// it goes to the Host over SFTP and its path is typed into the pane.
    /// Text-only drags are left alone — nothing here improves on them.
    private func installMediaDrop() {
        addInteraction(UIDropInteraction(delegate: self))
    }

    /// Ghostty ships its own pinch handler that mutates the surface font size
    /// behind the app's back. Zoom has to be app state to persist, so that
    /// gesture steps aside for one that routes through `onFontSizeChanged`.
    private func installZoom() {
        for case let pinch as UIPinchGestureRecognizer in gestureRecognizers ?? [] {
            pinch.isEnabled = false
        }
        addGestureRecognizer(zoomGesture)
    }

    @objc private func handleHerdrZoomGesture(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            zoomBaseFontSize = appliedFontSize
        case .changed:
            guard let zoomBaseFontSize else { return }
            zoom(to: zoomBaseFontSize * Float(gesture.scale))
        case .ended, .cancelled, .failed:
            zoomBaseFontSize = nil
        default:
            break
        }
    }

    /// Combos already delivered this runloop turn, keyed by the physical key
    /// and its modifiers. See ``claimHardwareKeyDelivery(_:)``.
    private var claimedHardwareKeys: Set<TerminalHardwareKeyMapping.Key> = []
    private var hardwareKeyClaimResetIsScheduled = false
    /// Presses this view answered itself, held so their release can be kept
    /// from `super` too.
    private var interceptedPresses: Set<UIPress> = []
    /// The intercepted Option combos still in flight. UIKit echoes those
    /// through the text-input path as well, and the real bytes have already
    /// gone out. See ``isSuppressingAltEcho(forUsage:)``.
    private var claimedAltCombos: Set<TerminalHardwareKeyMapping.Key> = []

    /// Escape and Cmd+`.` as key commands. As a `UITextInput` first responder
    /// this view loses both to iPadOS's text machinery before `pressesBegan`
    /// runs, exactly as it loses Ctrl chords — which the vendored package
    /// already claims back with priority key commands. Take `super`'s list so
    /// those Ctrl commands survive, and add these two on the same terms.
    override var keyCommands: [UIKeyCommand]? {
        var commands = super.keyCommands ?? []
        commands.append(contentsOf: Self.escapeKeyCommands)
        return commands
    }

    private static let escapeKeyCommands: [UIKeyCommand] = {
        let entries: [(input: String, modifierFlags: UIKeyModifierFlags)] = [
            (UIKeyCommand.inputEscape, []),
            (".", .command),
        ]
        return entries.map { entry in
            let command = UIKeyCommand(
                input: entry.input,
                modifierFlags: entry.modifierFlags,
                action: #selector(handleEscapeKeyCommand(_:)))
            command.wantsPriorityOverSystemBehavior = true
            // Both spellings mean Escape, and this is the text the iPad's
            // ⌘-hold shortcut HUD lists them under.
            command.discoverabilityTitle = "Escape"
            return command
        }
    }()

    @objc private func handleEscapeKeyCommand(_ command: UIKeyCommand) {
        TerminalKeyTrace.log("escape key command input=\(command.input ?? "nil") mods=0x\(String(command.modifierFlags.rawValue, radix: 16))")
        let key =
            command.modifierFlags.contains(.command)
            ? TerminalHardwareKeyMapping.Key(
                usage: TerminalHardwareKeyMapping.Usage.period, command: true)
            : TerminalHardwareKeyMapping.Key(usage: TerminalHardwareKeyMapping.Usage.escape)
        sendHardwareKey(key)
    }

    /// ⌘+ / ⌘- would otherwise reach Ghostty's own font-size keybinds, which
    /// leaves the global setting stale. Handle them here and swallow both the
    /// press and its release so Ghostty never sees the shortcut.
    ///
    /// Every other ⌘ chord goes up the responder chain instead of to Ghostty,
    /// whose `pressesBegan` never calls super: a text-input first responder
    /// gets key presses before the scene's key commands, so a swallowed chord
    /// would leave every app shortcut dead while the terminal is focused.
    ///
    /// The same pass answers the combos ``TerminalHardwareKeyMapping`` owns:
    /// Ghostty's encoder would send the wrong bytes for them, so the app
    /// sends its own and keeps the press away from `super`.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let incoming = Set(presses.map(ObjectIdentifier.init))
        if let token = echoSuppression?.pressToken, !incoming.contains(token) {
            echoSuppression = nil
        }
        var forwarded: Set<UIPress> = []
        var sceneCommands: Set<UIPress> = []
        for press in presses {
            if let key = press.key {
                TerminalKeyTrace.log("pressesBegan code=0x\(String(key.keyCode.rawValue, radix: 16)) mods=0x\(String(key.modifierFlags.rawValue, radix: 16)) chars=\(key.charactersIgnoringModifiers.debugDescription) firstResponder=\(isFirstResponder)")
            } else {
                TerminalKeyTrace.log("pressesBegan type=\(press.type.rawValue) no key")
            }
            // ⌘C races UIKit's editing shortcut exactly as ⌘V does, and
            // whichever path runs first wins. Answer it here while the touch
            // selection still exists — the blanket clear below would
            // otherwise empty it before `copy(_:)` ever saw it — and swallow
            // both the press and its release so Ghostty never sees ⌘C it
            // would encode for the PTY.
            if Self.isCopyShortcut(press), touchSelectionOverlay.selection != nil {
                copyTouchSelection()
                interceptedPresses.insert(press)
                continue
            }
            // Typing replaces what is on the grid; a selection of cells does
            // not survive it.
            clearTouchSelection()
            // Kelpie: Ghostty ignores ⌘V, and the pasteboard is the one place
            // a hardware keyboard can hand this pane a photo or a file. It is
            // answered before the scene-command routing so the app's own drop
            // path gets it.
            if Self.isPasteShortcut(press) {
                paste(nil)
                continue
            }
            if press.key.map({ Self.hardwarePressRoute(for: $0) }) == .sceneCommand {
                pressesRoutedToSceneCommands.insert(ObjectIdentifier(press))
                sceneCommands.insert(press)
                continue
            }
            guard let step = Self.zoomShortcutStep(for: press) else {
                // Kelpie: the combos TerminalHardwareKeyMapping owns (Escape,
                // Cmd+., the Option word keys) are answered here, before the
                // armed-modifier path, so Ghostty never encodes them itself.
                guard !interceptHardwareKey(press) else { continue }
                if let key = press.key,
                    let physical = Self.physicalKey(
                        keyCode: key.keyCode,
                        characters: key.characters,
                        charactersIgnoringModifiers: key.charactersIgnoringModifiers,
                        modifierFlags: key.modifierFlags),
                    beginPhysicalKeyForArmedModifiers(
                        physical, token: ObjectIdentifier(press))
                {
                    pressesConsumedByArmedModifiers.insert(ObjectIdentifier(press))
                    continue
                }
                forwarded.insert(press)
                continue
            }
            zoom(to: appliedFontSize + step)
        }
        if !sceneCommands.isEmpty {
            next?.pressesBegan(sceneCommands, with: event)
        }
        guard !forwarded.isEmpty else { return }
        super.pressesBegan(forwarded, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let sceneCommands = presses.filter { forgetSceneCommandPress($0) }
        if !sceneCommands.isEmpty {
            next?.pressesEnded(sceneCommands, with: event)
        }
        let remaining = presses.subtracting(sceneCommands).filter { press in
            let consumed = forgetConsumedArmedModifierPress(press)
            endPhysicalKeyForArmedModifiers(token: ObjectIdentifier(press))
            return !consumed
        }
        // Kelpie: also releases the intercepted combos and their Option echo
        // claim; zoom presses are dropped here too.
        let forwarded = forwardablePresses(remaining)
        guard !forwarded.isEmpty else { return }
        super.pressesEnded(forwarded, with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let forwarded = forwardablePresses(presses)
        guard !forwarded.isEmpty else { return }
        super.pressesCancelled(forwarded, with: event)
    }

    /// Answers a press this view owns the bytes for. Returns whether it did,
    /// in which case `super` must see neither the press nor its release.
    private func interceptHardwareKey(_ press: UIPress) -> Bool {
        guard let key = Self.hardwareKey(for: press),
            TerminalHardwareKeyMapping.bytes(for: key) != nil
        else { return false }

        interceptedPresses.insert(press)
        if key.option {
            // An Option combo is the one case UIKit also echoes through the
            // text-input path; remember it so that echo can be swallowed.
            claimedAltCombos.insert(key)
            scheduleHardwareKeyClaimReset()
        }
        sendHardwareKey(key)
        return true
    }

    /// Drops the presses this view answered itself — `super` never saw them
    /// begin, so a release for one is a release for a press it has no record
    /// of — along with the zoom shortcuts it already swallowed.
    private func forwardablePresses(_ presses: Set<UIPress>) -> Set<UIPress> {
        var forwarded: Set<UIPress> = []
        for press in presses {
            if interceptedPresses.remove(press) != nil {
                if let key = Self.hardwareKey(for: press) {
                    claimedAltCombos.remove(key)
                }
                continue
            }
            guard Self.zoomShortcutStep(for: press) == nil else { continue }
            guard !Self.isPasteShortcut(press) else { continue }
            forwarded.insert(press)
        }
        return forwarded
    }

    /// Sends the app-owned bytes for `key` straight to the remote PTY, on the
    /// same raw route the mouse reports take.
    private func sendHardwareKey(_ key: TerminalHardwareKeyMapping.Key) {
        guard isLocalInputEnabled,
            let bytes = TerminalHardwareKeyMapping.bytes(for: key),
            claimHardwareKeyDelivery(key)
        else {
            TerminalKeyTrace.log("sendHardwareKey blocked usage=0x\(String(key.usage, radix: 16)) enabled=\(isLocalInputEnabled)")
            return
        }
        TerminalKeyTrace.log("sendHardwareKey usage=0x\(String(key.usage, radix: 16)) bytes=\(bytes.map { String($0, radix: 16) })")
        terminalSession.sendInput(bytes)
    }

    /// Whether this delivery path gets to send the combo. On some iPadOS
    /// versions one physical press arrives both as a key command and in
    /// `pressesBegan`; whichever runs first wins and the other stays silent.
    /// The package's `claimControlKeyDelivery` does the same for Ctrl chords,
    /// but it is internal to the package and not callable from here.
    private func claimHardwareKeyDelivery(_ key: TerminalHardwareKeyMapping.Key) -> Bool {
        let claim = Self.claimKey(for: key)
        guard !claimedHardwareKeys.contains(claim) else { return false }
        claimedHardwareKeys.insert(claim)
        scheduleHardwareKeyClaimReset()
        return true
    }

    /// Escape and Cmd+`.` send the same byte and iPadOS may spell either press
    /// as the other, so the two share one claim.
    private static func claimKey(
        for key: TerminalHardwareKeyMapping.Key
    ) -> TerminalHardwareKeyMapping.Key {
        guard key.usage == TerminalHardwareKeyMapping.Usage.period else { return key }
        return TerminalHardwareKeyMapping.Key(usage: TerminalHardwareKeyMapping.Usage.escape)
    }

    /// Claims expire at the end of the runloop turn, before a held key can
    /// physically repeat. The alt-echo set is not reset here: UIKit's
    /// `deleteBackward` for a hardware press can land a turn later (the
    /// text-input system round-trips the keyboard daemon), so that set is
    /// cleared per press, in `forwardablePresses`, exactly as the package
    /// keeps its own `keyHandled` flag alive until `pressesEnded`.
    private func scheduleHardwareKeyClaimReset() {
        guard !hardwareKeyClaimResetIsScheduled else { return }
        hardwareKeyClaimResetIsScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            hardwareKeyClaimResetIsScheduled = false
            claimedHardwareKeys.removeAll()
        }
    }

    /// Whether an intercepted Option combo on `usage` is still in flight, so
    /// its `UITextInput` echo has to be swallowed.
    private func isSuppressingAltEcho(forUsage usage: UInt16) -> Bool {
        claimedAltCombos.contains { $0.usage == usage }
    }

    private static func hardwareKey(for press: UIPress) -> TerminalHardwareKeyMapping.Key? {
        guard let key = press.key else { return nil }
        // iPadOS spells ⌘. as an Escape press: traced live on iPadOS 26, the
        // press keeps the period keycode, drops the Command modifier, and
        // carries `UIKeyInputEscape` as its characters. Match on the
        // characters, so both spellings of Escape land on the one row,
        // whatever keycode or modifiers the OS attached to them.
        if key.charactersIgnoringModifiers == UIKeyCommand.inputEscape
            || key.characters == UIKeyCommand.inputEscape
        {
            return TerminalHardwareKeyMapping.Key(usage: TerminalHardwareKeyMapping.Usage.escape)
        }
        let modifierFlags = key.modifierFlags
        return TerminalHardwareKeyMapping.Key(
            usage: UInt16(truncatingIfNeeded: key.keyCode.rawValue),
            control: modifierFlags.contains(.control),
            option: modifierFlags.contains(.alternate),
            shift: modifierFlags.contains(.shift),
            command: modifierFlags.contains(.command))
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        // Filter only presses this feature consumed. Zoom ⌘+/⌘− cancellations
        // must reach the superclass exactly as they did before this override.
        let sceneCommands = presses.filter { forgetSceneCommandPress($0) }
        if !sceneCommands.isEmpty {
            next?.pressesCancelled(sceneCommands, with: event)
        }
        var forwarded: Set<UIPress> = []
        for press in presses.subtracting(sceneCommands) {
            let consumed = forgetConsumedArmedModifierPress(press)
            cancelPhysicalKeyForArmedModifiers(token: ObjectIdentifier(press))
            if !consumed {
                forwarded.insert(press)
            }
        }
        guard !forwarded.isEmpty else { return }
        super.pressesCancelled(Set(forwarded), with: event)
    }

    /// Applies a one-shot ⌃/⌥/⇧, unioned with modifiers the physical key
    /// already held. Returns false when nothing is armed, or when encoding
    /// the key fails, so Ghostty still receives the original event. A failed
    /// send leaves the armed set in place for a later key the encoder can
    /// represent.
    @discardableResult
    func applyArmedModifiers(
        to key: AgentQuickKey,
        physicalModifiers: TerminalKeyModifiers = []
    ) -> Bool {
        guard let keyboardControl, !keyboardControl.pendingModifiers.isEmpty else {
            return false
        }
        return keyboardControl.sendQuickKey(key, combining: physicalModifiers)
    }

    /// The only consume path `pressesBegan` uses. Tests drive the same seam
    /// with `(key identity, physical modifier flags)` because `UIPress` cannot
    /// be constructed in the suite.
    @discardableResult
    func beginPhysicalKeyForArmedModifiers(
        _ key: ArmedModifierPhysicalKey,
        token: ObjectIdentifier
    ) -> Bool {
        guard applyArmedModifiers(to: key.key, physicalModifiers: key.physicalModifiers) else {
            return false
        }
        switch key.key {
        case .character(let character):
            echoSuppression = ArmedModifierEchoSuppression(
                pressToken: token, expectedInsert: character, expectBackspace: false)
        case .backspace:
            echoSuppression = ArmedModifierEchoSuppression(
                pressToken: token, expectedInsert: nil, expectBackspace: true)
        default:
            echoSuppression = ArmedModifierEchoSuppression(
                pressToken: token, expectedInsert: nil, expectBackspace: false)
        }
        return true
    }

    func endPhysicalKeyForArmedModifiers(token: ObjectIdentifier) {
        clearEchoSuppression(for: token)
    }

    func cancelPhysicalKeyForArmedModifiers(token: ObjectIdentifier) {
        clearEchoSuppression(for: token)
    }

    /// Maps a hardware `UIKey` to the press seam. ⌘ chords return nil so they
    /// are never intercepted. Printable identity prefers `characters` so
    /// Shift+c stays `"C"`. Characters the Ghostty US-key encoder cannot
    /// represent also return nil; `applyArmedModifiers` still refuses a
    /// failed send so an unmapped or unencodable press is forwarded.
    static func physicalKey(
        keyCode: UIKeyboardHIDUsage,
        characters: String,
        charactersIgnoringModifiers: String,
        modifierFlags: UIKeyModifierFlags
    ) -> ArmedModifierPhysicalKey? {
        guard !modifierFlags.contains(.command),
            let identity = quickKey(
                keyCode: keyCode,
                characters: characters,
                charactersIgnoringModifiers: charactersIgnoringModifiers)
        else { return nil }
        return ArmedModifierPhysicalKey(
            key: identity,
            physicalModifiers: physicalModifiers(from: modifierFlags))
    }

    private func applyArmedModifiers(toInsertedText text: String) -> Bool {
        if text == "\n" || text == "\r" {
            return applyArmedModifiers(to: .enter)
        }
        guard text.count == 1, let character = text.first else { return false }
        return applyArmedModifiers(to: .character(character))
    }

    private func consumeMatchingInsertEcho(_ text: String) -> Bool {
        guard let suppression = echoSuppression else { return false }
        if text.count == 1, text.first == suppression.expectedInsert {
            echoSuppression = nil
            return true
        }
        echoSuppression = nil
        return false
    }

    private func consumeMatchingBackspaceEcho() -> Bool {
        guard let suppression = echoSuppression else { return false }
        if suppression.expectBackspace {
            echoSuppression = nil
            return true
        }
        echoSuppression = nil
        return false
    }

    private func clearEchoSuppression(for pressToken: ObjectIdentifier) {
        if echoSuppression?.pressToken == pressToken {
            echoSuppression = nil
        }
    }

    private func forgetSceneCommandPress(_ press: UIPress) -> Bool {
        pressesRoutedToSceneCommands.remove(ObjectIdentifier(press)) != nil
    }

    private func forgetConsumedArmedModifierPress(_ press: UIPress) -> Bool {
        pressesConsumedByArmedModifiers.remove(ObjectIdentifier(press)) != nil
    }

    private static func physicalModifiers(
        from flags: UIKeyModifierFlags
    ) -> TerminalKeyModifiers {
        var modifiers = TerminalKeyModifiers()
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.alternate) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        return modifiers
    }

    private static func printableCharacter(_ string: String) -> Character? {
        guard string.count == 1, let character = string.first,
            !character.unicodeScalars.contains(where: {
                $0.properties.generalCategory == .control
            })
        else {
            return nil
        }
        return character
    }

    private static func quickKey(
        keyCode: UIKeyboardHIDUsage,
        characters: String,
        charactersIgnoringModifiers: String
    ) -> AgentQuickKey? {
        switch keyCode {
        case .keyboardEscape: return .escape
        case .keyboardTab: return .tab
        case .keyboardReturnOrEnter: return .enter
        case .keyboardDeleteOrBackspace: return .backspace
        case .keyboardDeleteForward: return .forwardDelete
        case .keyboardLeftArrow: return .left
        case .keyboardRightArrow: return .right
        case .keyboardUpArrow: return .up
        case .keyboardDownArrow: return .down
        case .keyboardHome: return .home
        case .keyboardEnd: return .end
        case .keyboardPageUp: return .pageUp
        case .keyboardPageDown: return .pageDown
        case .keyboardInsert: return .insert
        case .keyboardF1: return .function(.f1)
        case .keyboardF2: return .function(.f2)
        case .keyboardF3: return .function(.f3)
        case .keyboardF4: return .function(.f4)
        case .keyboardF5: return .function(.f5)
        case .keyboardF6: return .function(.f6)
        case .keyboardF7: return .function(.f7)
        case .keyboardF8: return .function(.f8)
        case .keyboardF9: return .function(.f9)
        case .keyboardF10: return .function(.f10)
        case .keyboardF11: return .function(.f11)
        case .keyboardF12: return .function(.f12)
        default:
            if let character = printableCharacter(characters)
                ?? printableCharacter(charactersIgnoringModifiers),
                TerminalKeyPress(typing: character) != nil
            {
                return .character(character)
            }
            return nil
        }
    }

    /// Bare ⌘V. Any other modifier is somebody else's shortcut.
    private static func isPasteShortcut(_ press: UIPress) -> Bool {
        isCommandShortcut(press, character: "v")
    }

    /// Bare ⌘C, on the same terms.
    private static func isCopyShortcut(_ press: UIPress) -> Bool {
        isCommandShortcut(press, character: "c")
    }

    private static func isCommandShortcut(_ press: UIPress, character: String) -> Bool {
        guard let key = press.key else { return false }
        let modifiers = key.modifierFlags
        guard modifiers.contains(.command),
            !modifiers.contains(.control),
            !modifiers.contains(.alternate),
            !modifiers.contains(.shift)
        else { return false }
        return key.charactersIgnoringModifiers.lowercased() == character
    }

    private static func zoomShortcutStep(for press: UIPress) -> Float? {
        guard let key = press.key,
            case .zoom(let step) = hardwarePressRoute(for: key)
        else { return nil }
        return step
    }

    private static func hardwarePressRoute(for key: UIKey) -> HardwarePressRoute {
        hardwarePressRoute(
            charactersIgnoringModifiers: key.charactersIgnoringModifiers,
            modifierFlags: key.modifierFlags)
    }

    /// Where a hardware press goes. ⌘+ / ⌘− step the zoom here, any other ⌘
    /// chord belongs to the scene's key commands, and everything else,
    /// including Ctrl, Esc, and arrows, reaches Ghostty unchanged.
    static func hardwarePressRoute(
        charactersIgnoringModifiers: String,
        modifierFlags: UIKeyModifierFlags
    ) -> HardwarePressRoute {
        guard modifierFlags.contains(.command) else { return .terminal }
        switch charactersIgnoringModifiers {
        case "+", "=": return .zoom(1)
        case "-", "_": return .zoom(-1)
        default: return .sceneCommand
        }
    }

    @objc private func handleHerdrTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended, !didReportRightClickForTouch else { return }
        // The first tap of a pair still clicks, exactly as today; the second
        // belongs to the double tap's word selection.
        guard directTouchTapCount < 2 else { return }
        handleTap(at: gesture.location(in: self))
    }

    /// A hold is the touch spelling of a right click — and, if the finger then
    /// moves, of a mouse drag.
    ///
    /// A trackpad can press a border and drag it; a finger had no way to say
    /// that, so herdr's sidebar and pane borders could not be resized by touch
    /// at all (ADR 0016 gave the hold to the right click alone). The hold now
    /// decides on movement: past half a cell it becomes a left-button press at
    /// the cell it started on, a motion report per cell crossed, and a release
    /// where the finger lifts — the same three things a trackpad drag sends.
    ///
    /// The trade is that a hold that does **not** move now sends its right
    /// click on release rather than on the press, so herdr's context menu
    /// appears when the finger lifts. Nothing else can tell the two apart: the
    /// right click has to be withheld until the hold is known not to be a drag.
    /// The haptic still fires on the press, so the hold itself is acknowledged
    /// at the moment it is recognized.
    @objc private func handleHerdrRightClickGesture(_ gesture: UILongPressGestureRecognizer) {
        let location = gesture.location(in: self)
        switch gesture.state {
        case .began:
            guard isLocalInputEnabled, modeTracker.tracksMouse,
                let cell = gridPointMapper.cell(at: location)
            else {
                TerminalKeyTrace.log(
                    "hold began ignored input=\(isLocalInputEnabled) tracksMouse=\(modeTracker.tracksMouse)")
                return
            }
            heldPointerDrag = HeldPointerDrag(
                origin: location, originCell: cell, lastCell: nil)
            TerminalKeyTrace.log("hold began col=\(cell.column) row=\(cell.row)")
            // Silent on an iPad, which is why the cue is drawn as well.
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            holdCue.show(at: location, in: self)
            // However this hold ends, its release is not a left click: herdr
            // would read that as picking a row out of the menu it just opened.
            didReportRightClickForTouch = true
        case .changed:
            holdCue.move(to: location)
            guard isLocalInputEnabled, var held = heldPointerDrag else { return }
            defer { heldPointerDrag = held }
            if held.lastCell == nil {
                guard Self.distance(location, held.origin) > pointerDragSlop,
                    let press = modeTracker.remoteLeftPressSequence(
                        column: held.originCell.column, row: held.originCell.row)
                else { return }
                terminalSession.sendInput(press)
                TerminalKeyTrace.log(
                    "drag press col=\(held.originCell.column) row=\(held.originCell.row)")
                held.lastCell = held.originCell
            }
            guard let cell = gridPointMapper.cell(at: location),
                let last = held.lastCell, cell != last,
                let motion = modeTracker.remoteLeftDragSequence(
                    column: cell.column, row: cell.row)
            else { return }
            terminalSession.sendInput(motion)
            TerminalKeyTrace.log("drag motion col=\(cell.column) row=\(cell.row)")
            held.lastCell = cell
        case .ended:
            holdCue.hide()
            guard let held = heldPointerDrag else { return }
            guard held.lastCell != nil else {
                heldPointerDrag = nil
                // The finger never moved: the hold was a right click after all.
                let reported = rightClickTouch(at: held.origin)
                TerminalKeyTrace.log(
                    "hold right click col=\(held.originCell.column) row=\(held.originCell.row) sent=\(reported)")
                return
            }
            releaseHeldPointerDrag(at: gridPointMapper.cell(at: location))
        case .cancelled, .failed:
            holdCue.hide()
            releaseHeldPointerDrag(at: nil)
        default:
            break
        }
    }

    /// Ends a hold, letting the left button up wherever it was last reported
    /// (or at `cell`, when the finger's final position is known). A button
    /// left down would leave herdr dragging for ever.
    private func releaseHeldPointerDrag(at cell: (column: Int, row: Int)?) {
        guard let held = heldPointerDrag else { return }
        heldPointerDrag = nil
        guard isLocalInputEnabled, let last = held.lastCell else { return }
        let target = cell ?? last
        guard let release = modeTracker.remoteLeftReleaseSequence(
            column: target.column, row: target.row)
        else { return }
        terminalSession.sendInput(release)
        TerminalKeyTrace.log("drag release col=\(target.column) row=\(target.row)")
    }

    /// How far a held finger has to travel before the hold is a drag rather
    /// than a right click.
    ///
    /// It has to clear the recognizer's own `allowableMovement` of 10 pt: a
    /// finger may drift that far during the half-second press without failing
    /// the hold, and a menu hold that drifts must not come out as a left drag
    /// of a cell or two. A row's height, and never less than 12 pt.
    private var pointerDragSlop: CGFloat {
        max(terminalCellSize.height, 12)
    }

    /// Two fingers reach text selection while one finger is spoken for.
    ///
    /// The hold now makes the same handle selection a double tap does. The
    /// read-only sheet stays as the fallback for a hold that lands on
    /// whitespace: there is no word to select there, and the sheet is the one
    /// way to reach the whole viewport when the grid has nothing under the
    /// fingers.
    @objc private func handleHerdrTextSelectionGesture(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }

        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        if selectWord(at: gesture.location(in: self)) { return }
        guard let text = terminalSession.readViewportText() else { return }
        TerminalTextSelectionPresenter.present(text: text, anchorRange: nil, from: self)
    }

    /// A double tap selects the word under the finger.
    ///
    /// The single-tap recognizer deliberately does **not** `require(toFail:)`
    /// this one. A terminal click has to land the moment the finger lifts, and
    /// waiting out the double-tap interval to find out whether a second tap is
    /// coming would put that delay on every tap herdr answers. So the first tap
    /// of the pair sends its click exactly as it does today, and that is
    /// accepted: it is a click at the cell the user was pointing at anyway.
    @objc private func handleHerdrDoubleTapGesture(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }
        guard selectWord(at: gesture.location(in: self)) else { return }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    /// The touch selection currently drawn over the grid, if any.
    var touchSelection: TerminalTouchSelection? {
        touchSelectionOverlay.selection
    }

    /// Selects the word under `point`, and returns whether there was one.
    /// A double tap on whitespace does nothing at all.
    @discardableResult
    private func selectWord(at point: CGPoint) -> Bool {
        guard let cell = gridPointMapper.cell(at: point) else { return false }
        let selection = TerminalTouchSelection.word(
            at: TerminalGridCell(column: cell.column, row: cell.row),
            in: viewportTextRows())
        guard let selection else { return false }
        show(selection)
        return true
    }

    private func show(_ selection: TerminalTouchSelection) {
        touchSelectionOverlay.selection = selection.normalized
        bringSubviewToFront(touchSelectionOverlay)
        presentSelectionEditMenu()
    }

    /// Drops the selection and its menu. Anything that moves the grid or takes
    /// input calls this: the selection names cells, and a cell that now holds
    /// something else was never what the user picked.
    func clearTouchSelection() {
        // A drag of a handle is the selection being used, not abandoned —
        // whoever asked (a stray recognizer of the edit menu's, a forwarded
        // touch) does not get to end it mid-gesture.
        guard !touchSelectionOverlay.isDraggingHandle else { return }
        guard touchSelectionOverlay.selection != nil else { return }
        touchSelectionOverlay.selection = nil
        selectionEditMenu.dismissMenu()
    }

    private func presentSelectionEditMenu() {
        guard touchSelectionOverlay.selection != nil else { return }
        let anchor = touchSelectionOverlay.lastSpanRect ?? bounds
        selectionEditMenu.dismissMenu()
        selectionEditMenu.presentEditMenu(
            with: UIEditMenuConfiguration(
                identifier: nil,
                sourcePoint: CGPoint(x: anchor.midX, y: anchor.maxY)))
    }

    /// The viewport as rows of text, the way the selection and the link
    /// detector both read it.
    private func viewportTextRows() -> [String] {
        guard let text = terminalSession.readViewportText() else { return [] }
        return text.components(separatedBy: "\n")
    }

    /// Copies the selected cells' current contents.
    ///
    /// The text is read now rather than remembered from when the selection was
    /// made: the grid repaints constantly, and the honest answer to "copy
    /// this" is whatever those cells hold at the moment Copy is tapped. No
    /// polling, and nothing to keep in sync.
    func copyTouchSelection() {
        guard let selection = touchSelectionOverlay.selection else { return }
        let text = selection.text(in: viewportTextRows())
        clearTouchSelection()
        guard !text.isEmpty else { return }
        UIPasteboard.general.string = text
    }

    /// Everything the viewport currently holds, from its first cell to the end
    /// of its last row with text on it.
    func selectAllTouchSelection() {
        guard let selection = TerminalTouchSelection.all(in: viewportTextRows()) else { return }
        show(selection)
    }

    #if !targetEnvironment(macCatalyst)
        @objc private func handleHerdrPointerScrollGesture(_ gesture: UIPanGestureRecognizer) {
            // A pointer with a touch down is dragging, which is Ghostty's own
            // indirect-pointer pan (selection or a remote drag).
            guard gesture.numberOfTouches == 0 else { return }
            switch gesture.state {
            case .began:
                stopTouchScrollMomentum()
                touchScrollAccumulator.reset()
            case .changed:
                _ = scrollTouch(translationY: gesture.translation(in: self).y)
                gesture.setTranslation(.zero, in: self)
            case .ended, .cancelled, .failed:
                touchScrollAccumulator.reset()
            default:
                break
            }
        }
    #endif

    func handleTap(at location: CGPoint) {
        // A URL takes the tap whole: no click for herdr to answer by opening
        // the link on the Mac, and no keyboard on the way out.
        if let match = linkMatch(at: location) {
            open(match)
            return
        }
        switch tapAction(at: location) {
        case .haltMomentum:
            stopTouchScrollMomentum()
            touchScrollAccumulator.reset()
        case .report(let raisesKeyboard):
            clickTouch(at: location)
            if raisesKeyboard {
                requestKeyboard()
            }
        }
    }

    /// What a tap means, given what the terminal is currently doing.
    ///
    /// In the normal buffer the keyboard follows the input row alone, so that a
    /// touch meant for native scrollback is never answered with a keyboard-driven
    /// viewport resize.
    ///
    /// The alternate screen reaches further, two ways. The caret band grows to
    /// three rows' worth, because an agent TUI parks its caret below the row
    /// the user reads as the prompt (Claude Code's visible `>` measured
    /// 16–40 pt above it, #90). And the bottom quarter always answers, because
    /// chat-style TUIs (Claude Code, Codex, Amp, Droid, …) pin their input box
    /// there while parking the caret in tool-specific spots the band cannot
    /// chase. Whole-screen activation was tried first (#92) and answered every
    /// output-area tap with the keyboard.
    func tapAction(at location: CGPoint) -> TerminalTapAction {
        if isTouchScrollMomentumRunning { return .haltMomentum }
        if keyboardActivationRegion.contains(location) {
            return .report(raisesKeyboard: true)
        }
        let inBottomBand = modeTracker.isAlternateScreen
            && TerminalKeyboardTapTarget.alternateScreenBottomRegion(in: bounds)
                .contains(location)
        return .report(raisesKeyboard: inBottomBand)
    }

    var isTouchScrollMomentumRunning: Bool {
        touchScrollMomentumDisplayLink != nil
    }

    @objc private func handleHerdrTouchScrollGesture(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            stopTouchScrollMomentum()
            touchScrollAccumulator.reset()
        case .changed:
            _ = scrollTouch(translationY: gesture.translation(in: self).y)
            gesture.setTranslation(.zero, in: self)
        case .ended:
            startTouchScrollMomentum(velocityY: gesture.velocity(in: self).y)
        case .cancelled, .failed:
            stopTouchScrollMomentum()
            touchScrollAccumulator.reset()
        default:
            break
        }
    }

    func startTouchScrollMomentum(velocityY: CGFloat) {
        guard abs(velocityY) >= 80 else {
            touchScrollAccumulator.reset()
            return
        }
        stopTouchScrollMomentum()
        touchScrollMomentumVelocityY = max(-4_000, min(4_000, velocityY))
        touchScrollMomentumTimestamp = 0
        let displayLink = CADisplayLink(
            target: self,
            selector: #selector(advanceTouchScrollMomentum(_:)))
        touchScrollMomentumDisplayLink = displayLink
        displayLink.add(to: .main, forMode: .common)
    }

    @objc private func advanceTouchScrollMomentum(_ displayLink: CADisplayLink) {
        guard abs(touchScrollMomentumVelocityY) >= 20 else {
            stopTouchScrollMomentum()
            touchScrollAccumulator.reset()
            return
        }
        guard touchScrollMomentumTimestamp > 0 else {
            touchScrollMomentumTimestamp = displayLink.timestamp
            return
        }

        let elapsed = min(1.0 / 30.0, displayLink.timestamp - touchScrollMomentumTimestamp)
        touchScrollMomentumTimestamp = displayLink.timestamp
        _ = scrollTouch(translationY: touchScrollMomentumVelocityY * elapsed)
        touchScrollMomentumVelocityY *= pow(0.998, elapsed * 1_000)
    }

    private func stopTouchScrollMomentum() {
        touchScrollMomentumDisplayLink?.invalidate()
        touchScrollMomentumDisplayLink = nil
        touchScrollMomentumVelocityY = 0
        touchScrollMomentumTimestamp = 0
    }

    private func reliableInputDidBegin() {
        stopTouchScrollMomentum()
        touchScrollAccumulator.reset()
    }

    /// Stops inertial remote scroll. App-owned Esc no longer goes through
    /// Ghostty `sendInput`, so it calls this instead of relying on that hook.
    func noteReliableInputBegan() {
        reliableInputDidBegin()
    }
}

extension HeelerTerminalView: TerminalSurfaceOpenURLDelegate,
    TerminalSurfaceTextSelectionRequestDelegate, TerminalSurfaceLifecycleDelegate,
    TerminalSurfaceGridResizeDelegate, TerminalSurfaceBellDelegate
{
    /// A bell the iPad can feel. There is no terminal audio here and a visual
    /// flash would fight the agent's own redraw, so BEL becomes a light impact
    /// — the same vocabulary the long-press right click already uses, one step
    /// softer. Throttled, because a TUI rejecting keystrokes rings per press.
    func terminalDidRingBell() {
        let now = CACurrentMediaTime()
        if let last = lastBellFeedbackTime,
            now - last < Self.bellFeedbackInterval
        {
            return
        }
        lastBellFeedbackTime = now
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    func terminalDidRequestOpenURL(_ url: String, kind _: TerminalOpenURLKind) {
        guard let url = TerminalLinkPolicy.url(for: url) else { return }
        onOpenLink?(url)
    }

    /// The one metrics source that still carries cell dimensions. Since
    /// GhosttyTerminal 1.4.0 the in-memory session's resize dispatches come
    /// from the engine's receive-resize callback, which reports the logical
    /// grid to the Host, while this delegate keeps `terminalCellSize` real so
    /// tap-to-cell mapping and touch-scroll row heights don't fall back to the
    /// 8×16 default.
    func terminalDidResize(_ size: TerminalGridMetrics) {
        // Every cell moves; the selection's coordinates no longer mean what
        // they meant when it was made.
        clearTouchSelection()
        terminalGridSize = (Int(size.columns), Int(size.rows))
        hasTerminalGridMetrics = true
        guard size.cellWidthPixels > 0, size.cellHeightPixels > 0 else { return }
        let scale = window?.screen.nativeScale ?? traitCollection.displayScale
        guard scale > 0 else { return }
        terminalCellSize = CGSize(
            width: CGFloat(size.cellWidthPixels) / scale,
            height: CGFloat(size.cellHeightPixels) / scale)
    }

    func terminalDidRequestTextSelection(_ request: TerminalTextSelectionRequest) {
        TerminalTextSelectionPresenter.present(request, from: self)
    }

    func terminalDidAttachSurface(_: TerminalSurface) {}

    func terminalDidDetachSurface() {
        removeOrphanedSurfaceLayers()
    }
}

/// The menu over a touch selection. Copy takes the cells' text to the
/// pasteboard; Select All grows the selection to the whole viewport. Neither
/// sends anything to the PTY — the selection is drawn by Kelpie and lives
/// entirely on this side of the wire.
extension HeelerTerminalView: @MainActor UIEditMenuInteractionDelegate {
    func editMenuInteraction(
        _: UIEditMenuInteraction,
        menuFor _: UIEditMenuConfiguration,
        suggestedActions _: [UIMenuElement]
    ) -> UIMenu? {
        UIMenu(children: [
            UIAction(title: "Copy") { [weak self] _ in
                self?.copyTouchSelection()
            },
            UIAction(title: "Select All") { [weak self] _ in
                self?.selectAllTouchSelection()
            },
        ])
    }
}

/// Photos and files dropped onto the terminal. A drop of plain text is
/// refused: it would race the text-input path for the same insertion, and
/// staging is the only thing this interaction adds.
extension HeelerTerminalView: UIDropInteractionDelegate {
    func dropInteraction(
        _: UIDropInteraction,
        canHandle session: any UIDropSession
    ) -> Bool {
        // A PDF, a text file or an archive from Files conforms to
        // `public.data`, never to `public.file-url`, so the narrower list
        // refused them before the proposal was ever made.
        isLocalInputEnabled
            && onStageItems != nil
            && session.hasItemsConforming(
                toTypeIdentifiers: MediaIntake.acceptedDropTypeIdentifiers)
            && session.items.contains { Self.isStageable($0.itemProvider) }
    }

    func dropInteraction(
        _: UIDropInteraction,
        sessionDidUpdate _: any UIDropSession
    ) -> UIDropProposal {
        UIDropProposal(operation: isLocalInputEnabled ? .copy : .cancel)
    }

    func dropInteraction(_: UIDropInteraction, performDrop session: any UIDropSession) {
        guard isLocalInputEnabled else { return }
        stageMedia(from: session.items.map(\.itemProvider))
    }
}
