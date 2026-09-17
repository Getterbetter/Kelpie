import Observation
import SwiftUI
import UIKit

/// The composer: a real text field between the terminal and the key bar, so
/// the on-screen keyboard's autocorrect, predictions, dictation and
/// hold-to-accent apply to what is typed (Open item 30). The field mirrors
/// itself into the PTY as it changes, so the TUI shows the line as it is
/// typed and Claude Code's `/` and `@` menus still open; Return submits.
///
/// Stage 0 of the design — autocorrect traits on the terminal's own
/// `UITextInput` — was tried first and failed on the device: iOS corrects
/// against the terminal's one-line shadow document, and the corrections were
/// wrong ("teh went to yeh", Anthony 2026-09-15). A `UITextView` gives iOS a
/// real document to work with; that is the whole reason this exists.
///
/// Off by default, toggled from the leading key of ``TerminalKeyBar`` and
/// persisted (`kelpie.composer-enabled`). Design and decisions:
/// `KelpieVault/Design/Composer text field.md`.

// MARK: - The mirror

/// What the PTY has to be sent so its line matches the field. Pure, so the
/// diff can be tested without a view.
///
/// `committed` is what the PTY has received. Every change is expressed as
/// the common prefix kept, one DEL (`0x7F`, the byte Backspace sends) per
/// character of the old tail, and the new tail typed. An autocorrect
/// replacing "teh" with "the", a prediction tap, a dictation chunk landing,
/// a hold-to-accent pick: all are just diffs.
///
/// Characters are counted as grapheme clusters, which is what one DEL takes
/// off a line editor's buffer for every character the on-screen keyboard can
/// produce (`é` arrives precomposed). A flag emoji would count as one here
/// and two in a UTF-16 editor; accepted for v1.
struct TerminalComposerMirror: Equatable {
    static let deleteByte: UInt8 = 0x7F
    static let submitByte: UInt8 = 0x0D
    /// The escape Claude Code reads as "newline, do not send": a backslash
    /// immediately before the Return.
    static let softNewlineByte: UInt8 = 0x5C

    private(set) var committed = ""

    /// The bytes that bring the PTY's line from `committed` to `text`.
    mutating func update(to text: String) -> Data {
        let target = Self.sanitized(text)
        let old = Array(committed)
        let new = Array(target)
        var prefix = 0
        while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] {
            prefix += 1
        }
        var bytes = Data(repeating: Self.deleteByte, count: old.count - prefix)
        bytes.append(contentsOf: String(new[prefix...]).utf8)
        committed = target
        return bytes
    }

    /// Return: a carriage return, and the line starts over.
    mutating func submit() -> Data {
        committed = ""
        return Data([Self.submitByte])
    }

    /// A soft newline: `\` then Return, which Claude Code takes as a line
    /// break inside the prompt rather than a submission. Like ``submit()``
    /// the field's line is finished as far as this mirror is concerned — the
    /// remote line keeps growing, but the field starts empty again, so the
    /// next diff is typed in full.
    mutating func softNewline() -> Data {
        committed = ""
        return Data([Self.softNewlineByte, Self.submitByte])
    }

    /// The PTY's line is no longer the one this mirror described (a new
    /// pane after a reconnect): the next update retypes the whole field.
    mutating func reset() {
        committed = ""
    }

    /// The field never sends a control byte: a newline in a pasted block
    /// would press Enter, a tab would complete. Whitespace controls become a
    /// space; anything else below `0x20`, and DEL, is dropped.
    static func sanitized(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x09, 0x0A, 0x0D: scalars.append(" ")
            case ..<0x20, 0x7F: continue
            default: scalars.append(scalar)
            }
        }
        return String(scalars)
    }
}

// MARK: - The control

/// The composer's state, shared between the key bar's toggle, the terminal
/// and the field. Owned by the root screen; the terminal and the field hold
/// it weakly and are held weakly by it.
@MainActor
@Observable
final class TerminalComposerControl {
    static let defaultsKey = "kelpie.composer-enabled"

    /// The persisted toggle. Never reset by a reconnect or a Host switch.
    private(set) var isEnabled: Bool
    /// False while a hardware keyboard is attached: the composer is an
    /// on-screen-keyboard feature only.
    var isAvailable = true
    var isActive: Bool { isEnabled && isAvailable }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private(set) var mirror = TerminalComposerMirror()
    /// The live terminal, set by ``TerminalScreenView`` as the surface is
    /// made and updated. A new surface is a new PTY line.
    @ObservationIgnored weak var terminal: HeelerTerminalView? {
        didSet {
            guard terminal !== oldValue else { return }
            mirror.reset()
            // The field's accessory is the terminal's bar, and UIKit caches
            // it: a field that holds the keyboard across a pipeline
            // replacement would otherwise keep the retired terminal's dead
            // pill until the keyboard next came up.
            if field?.isFirstResponder == true { field?.reloadInputViews() }
        }
    }
    /// The mounted field, if the composer is on screen.
    @ObservationIgnored weak var field: TerminalComposerTextView?
    /// The root screen's keyboard inset, frozen across a responder handoff
    /// so the terminal reflows once, not twice.
    @ObservationIgnored weak var keyboardInset: TerminalKeyboardInset?
    /// Set when the composer is enabled while the terminal holds the
    /// keyboard: the field, once mounted, takes it over. Consumed by the
    /// field's representable.
    @ObservationIgnored private(set) var pendingKeyboardClaim = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: Self.defaultsKey)
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.defaultsKey)
    }

    /// The key bar's toggle. Turning the composer on while the terminal has
    /// the keyboard hands it to the field; turning it off while the field
    /// has it hands it back — both without the keyboard visibly leaving.
    func toggle() {
        let terminalHeldKeyboard = terminal?.isFirstResponder == true
        let fieldHeldKeyboard = field?.isFirstResponder == true
        setEnabled(!isEnabled)
        if isEnabled {
            pendingKeyboardClaim = terminalHeldKeyboard
        } else if fieldHeldKeyboard, let terminal {
            let id = beginKeyboardHandoff()
            if !terminal.requestKeyboardHandoff(id: id) {
                keyboardInset?.cancelResponderHandoff(id, currentHeight: currentKeyboardHeight)
            }
        }
    }

    /// Whether the field should take the keyboard as it mounts. One answer
    /// per claim.
    func consumeKeyboardClaim() -> Bool {
        defer { pendingKeyboardClaim = false }
        return pendingKeyboardClaim
    }

    /// Freezes the keyboard inset for a responder swap. Ends when the
    /// destination's keyboard frame settles, or on the inset's own fallback.
    func beginKeyboardHandoff() -> UUID {
        guard let keyboardInset else { return UUID() }
        return keyboardInset.beginResponderHandoff(currentHeight: currentKeyboardHeight)
    }

    func endKeyboardHandoff(_ id: UUID) {
        keyboardInset?.endResponderHandoff(id, currentHeight: currentKeyboardHeight)
    }

    private func currentKeyboardHeight() -> CGFloat? {
        guard let window = terminal?.window ?? field?.window else { return nil }
        return TerminalKeyboardInset.layoutGuideHeight(in: window)
    }

    // MARK: Routing

    /// Raises the keyboard on the field. The terminal's input-row tap comes
    /// here while the composer is active.
    @discardableResult
    func focusField() -> Bool {
        guard isActive, let field else { return false }
        return field.becomeFirstResponder()
    }

    /// Takes the keyboard down if the field holds it.
    @discardableResult
    func resignField() -> Bool {
        guard let field, field.isFirstResponder else { return false }
        return field.resignFirstResponder()
    }

    var fieldHoldsKeyboard: Bool { field?.isFirstResponder == true }

    /// A control key from the bar is about to go to the PTY. Esc and the
    /// Ctrl chords change or clear the remote line in ways the field cannot
    /// see (Ctrl-C empties Claude Code's input; Esc interrupts), so the field
    /// is cleared and the mirror starts over: whatever is typed next is
    /// appended to whatever the remote kept, which is right either way. Tab
    /// and the arrows leave both alone — a completion or a cursor move keeps
    /// the field's text on the remote line, and a later edit still applies.
    func controlKeyWillBeSent(_ key: TerminalControlKey) {
        guard isActive else { return }
        switch key {
        case .escape, .controlC, .controlD, .controlZ, .enter:
            mirror.reset()
            field?.text = ""
            field?.refreshPlaceholder()
        case .tab, .shiftTab, .home, .end, .pageUp, .pageDown, .up, .down, .left, .right,
            .backspace:
            break
        }
    }

    /// The key bar's symbol keys, typed into the field while it is active.
    /// Returns false when the composer is not the place for the text.
    @discardableResult
    func typeIntoField(_ text: String) -> Bool {
        guard isActive, let field else { return false }
        field.insertText(text)
        return true
    }

    /// The field changed: bring the PTY's line up to date.
    func fieldDidChange(_ text: String) {
        send(mirror.update(to: text))
    }

    /// Return: the PTY's line is brought up to date first, so a field that
    /// outlived a reconnect still sends what it shows, then submitted.
    func submit(_ text: String) {
        send(mirror.update(to: text))
        send(mirror.submit())
    }

    /// A soft newline: the PTY's line is brought up to date exactly as for
    /// ``submit(_:)``, then `\` and Return go out, which Claude Code reads as
    /// a line break in its prompt instead of a send.
    func softNewline(_ text: String) {
        send(mirror.update(to: text))
        send(mirror.softNewline())
    }

    /// The key bar's soft-newline key. Sends what the field holds as a
    /// committed line and clears the field, the way Return does.
    @discardableResult
    func softNewlineFromKeyBar() -> Bool {
        guard isActive, let field else { return false }
        softNewline(field.text)
        field.text = ""
        field.refreshPlaceholder()
        field.invalidateIntrinsicContentSize()
        return true
    }

    /// Backspace on an empty field takes a character off the remote line —
    /// one typed before the composer was turned on, or by a control key.
    func deleteBackwardOnEmptyField() {
        mirror.reset()
        send(Data([TerminalComposerMirror.deleteByte]))
    }

    private func send(_ bytes: Data) {
        guard !bytes.isEmpty else { return }
        terminal?.sendComposerBytes(bytes)
    }
}

// MARK: - The field

/// The composer's `UITextView`. It rides the same ``TerminalKeyBar`` the
/// terminal does, so the pill survives the responder swap, and it settles a
/// keyboard handoff the way the Console's Composer does: by watching for its
/// own keyboard frame to match the window's keyboard layout guide.
final class TerminalComposerTextView: UITextView {
    weak var control: TerminalComposerControl?
    var onKeyboardHandoffSettled: ((UUID) -> Void)?
    private var activeKeyboardHandoffID: UUID?
    private let placeholder = UILabel()

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        // The design's traits (decision 6): autocorrect, spell check and
        // predictions on; capitalisation off (shell commands and paths);
        // smart quotes and dashes off (they corrupt code).
        autocorrectionType = .default
        spellCheckingType = .default
        autocapitalizationType = .none
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
        keyboardType = .default
        returnKeyType = .send
        enablesReturnKeyAutomatically = false
        backgroundColor = .clear
        font = .preferredFont(forTextStyle: .body)
        adjustsFontForContentSizeCategory = true
        textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        self.textContainer.lineFragmentPadding = 0
        accessibilityLabel = "Composer"
        placeholder.text = "Type here. Return sends."
        placeholder.font = font
        placeholder.adjustsFontForContentSizeCategory = true
        placeholder.textColor = .placeholderText
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        placeholder.isAccessibilityElement = false
        addSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholder.leadingAnchor.constraint(equalTo: leadingAnchor),
            placeholder.topAnchor.constraint(equalTo: topAnchor, constant: textContainerInset.top),
        ])
        for name: Notification.Name in [
            UIResponder.keyboardDidShowNotification,
            UIResponder.keyboardDidChangeFrameNotification,
        ] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(keyboardFrameDidSettle(_:)), name: name, object: nil)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    /// The terminal's own bar, shared rather than copied, so the sticky
    /// Ctrl and Alt state it shows stays the terminal's.
    override var inputAccessoryView: UIView? {
        get { control?.terminal?.sharedKeyBar }
        set {}
    }

    func refreshPlaceholder() {
        placeholder.isHidden = !text.isEmpty
    }

    /// An armed sticky Ctrl or Alt makes the next key a chord, and a chord
    /// is the terminal's: `c` after Ctrl is an interrupt, not a letter in the
    /// field. The terminal's own `insertText` applies and consumes it.
    override func insertText(_ text: String) {
        if let terminal = control?.terminal, terminal.hasActiveStickyModifiers,
            text.count == 1, markedTextRange == nil
        {
            terminal.insertText(text)
            return
        }
        super.insertText(text)
    }

    /// Backspace with nothing in the field reaches the remote line.
    override func deleteBackward() {
        if text.isEmpty, markedTextRange == nil {
            control?.deleteBackwardOnEmptyField()
            return
        }
        super.deleteBackward()
    }

    @discardableResult
    func requestKeyboardHandoff(id: UUID) -> Bool {
        guard window != nil else { return false }
        activeKeyboardHandoffID = id
        let accepted = becomeFirstResponder()
        if !accepted { activeKeyboardHandoffID = nil }
        return accepted
    }

    @objc private func keyboardFrameDidSettle(_ notification: Notification) {
        guard let activeKeyboardHandoffID, isFirstResponder,
            let window, window.isKeyWindow,
            let endFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey]
                as? CGRect,
            let guideFrame = TerminalKeyboardInset.keyboardLayoutGuideFrame(in: window)
        else { return }
        let frameInWindow = window.convert(endFrame, from: window.screen.coordinateSpace)
        guard TerminalKeyboardInset.keyboardFrame(frameInWindow, matches: guideFrame, in: window)
        else { return }
        self.activeKeyboardHandoffID = nil
        onKeyboardHandoffSettled?(activeKeyboardHandoffID)
    }
}

/// The field, mounted by the root screen between the terminal and the key
/// bar whenever the composer is active. Grows to five lines, then scrolls.
struct TerminalComposerView: UIViewRepresentable {
    let control: TerminalComposerControl

    func makeCoordinator() -> Coordinator {
        Coordinator(control: control)
    }

    func makeUIView(context: Context) -> TerminalComposerTextView {
        let field = TerminalComposerTextView()
        field.control = control
        field.delegate = context.coordinator
        field.refreshPlaceholder()
        control.field = field
        let control = control
        field.onKeyboardHandoffSettled = { id in control.endKeyboardHandoff(id) }
        // Enabled from the pill while the terminal held the keyboard: take
        // it over once this view is in a window, under an inset freeze so
        // the terminal does not reflow for the swap.
        if control.consumeKeyboardClaim() {
            DispatchQueue.main.async { [weak field] in
                guard let field, field.window != nil else { return }
                let id = control.beginKeyboardHandoff()
                if !field.requestKeyboardHandoff(id: id) {
                    control.keyboardInset?.cancelResponderHandoff(id)
                }
            }
        }
        return field
    }

    func updateUIView(_ field: TerminalComposerTextView, context: Context) {
        field.control = control
        if control.field !== field { control.field = field }
    }

    static func dismantleUIView(_ field: TerminalComposerTextView, coordinator: Coordinator) {
        if coordinator.control.field === field { coordinator.control.field = nil }
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize, uiView: TerminalComposerTextView, context: Context
    ) -> CGSize? {
        guard let width = proposal.width else { return nil }
        let measured = uiView.sizeThatFits(
            CGSize(width: width, height: .greatestFiniteMagnitude))
        let lineHeight = uiView.font?.lineHeight ?? 20
        let maximumHeight =
            lineHeight * 5 + uiView.textContainerInset.top + uiView.textContainerInset.bottom
        let height = min(max(36, measured.height), maximumHeight)
        uiView.isScrollEnabled = measured.height > maximumHeight
        return CGSize(width: width, height: height)
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        let control: TerminalComposerControl

        init(control: TerminalComposerControl) {
            self.control = control
        }

        /// Return submits. A newline inside a paste becomes a space through
        /// the mirror; a soft newline is the key bar's own key, never a
        /// newline in the field itself (the field stays one line).
        func textView(
            _ textView: UITextView, shouldChangeTextIn range: NSRange,
            replacementText text: String
        ) -> Bool {
            guard text == "\n" else { return true }
            // Return over an inline prediction accepts it first.
            if textView.markedTextRange != nil { textView.unmarkText() }
            submit(textView)
            return false
        }

        func textViewDidChange(_ textView: UITextView) {
            (textView as? TerminalComposerTextView)?.refreshPlaceholder()
            textView.invalidateIntrinsicContentSize()
            // Marked text is a composition in flight — an inline prediction,
            // a dictation chunk, an IME candidate — and is not typed until
            // it is committed.
            guard textView.markedTextRange == nil else { return }
            control.fieldDidChange(textView.text)
        }

        private func submit(_ textView: UITextView) {
            control.submit(textView.text)
            textView.text = ""
            (textView as? TerminalComposerTextView)?.refreshPlaceholder()
            textView.invalidateIntrinsicContentSize()
        }
    }
}
