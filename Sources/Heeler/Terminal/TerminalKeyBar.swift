import GhosttyTerminal
import UIKit

/// What a key press asks of the terminal behind the bar. The bar holds no
/// terminal of its own: an accessory view outlives nothing, and the surface it
/// types into is replaced whenever the pane is.
@MainActor
protocol TerminalKeyBarHandler: AnyObject {
    /// Esc, Tab and the arrows, on the raw control-key route.
    func keyBar(_ bar: TerminalKeyBar, didPress key: TerminalControlKey)
    /// The symbol keys, typed as text so a sticky modifier still applies.
    func keyBar(_ bar: TerminalKeyBar, didType text: String)
    func keyBar(_ bar: TerminalKeyBar, didToggleSticky modifier: TerminalPublicStickyModifier)
    func keyBar(
        _ bar: TerminalKeyBar, stickyActivationFor modifier: TerminalPublicStickyModifier
    ) -> TerminalPublicStickyActivation
    /// The trailing keyboard-dismiss button, pinned outside the scroll view.
    func keyBarDidRequestDismiss(_ bar: TerminalKeyBar)
    /// The composer toggle at the leading edge: nil hides the key (the
    /// Console has no composer here), otherwise whether the composer is on.
    func keyBarComposerState(_ bar: TerminalKeyBar) -> Bool?
    func keyBarDidToggleComposer(_ bar: TerminalKeyBar)
    /// The soft-newline key beside the toggle, shown only while the composer
    /// is on: it commits the field's line with a trailing `\` so Claude Code
    /// breaks the line instead of sending the prompt.
    func keyBarDidPressSoftNewline(_ bar: TerminalKeyBar)
}

extension TerminalKeyBarHandler {
    func keyBarComposerState(_ bar: TerminalKeyBar) -> Bool? { nil }
    func keyBarDidToggleComposer(_ bar: TerminalKeyBar) {}
    func keyBarDidPressSoftNewline(_ bar: TerminalKeyBar) {}
}

/// The key bar's sizes, derived from the reader's text size.
///
/// Before round 12 every one of these was a constant: 38 pt keys under the
/// 44 pt minimum target, 16 pt labels that ignored Dynamic Type entirely, and
/// a 46 pt bar that could not grow — on the one row of chrome an iPhone user
/// has for Esc, Tab, Ctrl and the arrows (finding 8). They scale now, and they
/// are capped, because the bar has to stay a single row above the keyboard.
///
/// Pure, so the floor and the ceiling can be tested without a view.
enum TerminalKeyBarMetrics {
    /// The unscaled label size, and the text style it scales with. `.body` is
    /// the style a keyboard key's caption reads as.
    static let baseTitleSize: CGFloat = 16
    static let textStyle = UIFont.TextStyle.body
    /// Past this a key's caption starts wrapping inside a one-row bar.
    static let maximumTitleSize: CGFloat = 24
    /// The HIG minimum touch target, which the old 38 pt keys were under.
    static let minimumKeyHeight: CGFloat = 44
    /// A third of an iPhone's landscape keyboard is as much as one row may
    /// take.
    static let maximumKeyHeight: CGFloat = 68
    /// The gap above and below the key row inside the bar.
    static let keyPadding: CGFloat = 4

    /// The label size at `traits`' content size category, scaled by
    /// `UIFontMetrics` exactly as `preferredFont(forTextStyle:)` would and
    /// then capped.
    static func titleSize(for traits: UITraitCollection) -> CGFloat {
        min(
            UIFontMetrics(forTextStyle: textStyle).scaledValue(
                for: baseTitleSize, compatibleWith: traits),
            maximumTitleSize)
    }

    /// The key height that fits a caption of `size`, never below the touch
    /// minimum and never above the one-row ceiling.
    static func keyHeight(forTitleSize size: CGFloat) -> CGFloat {
        let fitted = (size * 1.6).rounded(.up) + 16
        return min(max(minimumKeyHeight, fitted), maximumKeyHeight)
    }

    static func barHeight(forTitleSize size: CGFloat) -> CGFloat {
        keyHeight(forTitleSize: size) + 2 * keyPadding
    }
}

/// One row of keys riding the software keyboard, drawn as keyboard keys.
///
/// This is a `UIInputView` in `.keyboard` style, so the bar's background *is*
/// the keyboard's — the same material, the same seam. Inside it the keys sit
/// in one floating pill, the shape Notion's iOS toolbar uses: plain glyphs on
/// a capsule with a soft shadow, rather than a second row of key caps.
///
/// Nothing here is a subview of the terminal, so the full-bounds-container
/// quirk `TerminalHoldCueView` documents does not apply: the accessory is
/// UIKit's, and the vendored surface never lays it out.
@MainActor
final class TerminalKeyBar: UIInputView, UIInputViewAudioFeedback {
    private static let minimumKeyWidth: CGFloat = 44
    private static let keySpacing: CGFloat = 6
    private static let sideInset: CGFloat = 8
    /// The gap from the bar's edges to the floating pill. Shared with the
    /// composer field so the two float in one column.
    static let pillMargin: CGFloat = 12
    /// The pill is the key row plus a little air above and below.
    private static let pillPadding: CGFloat = 8
    /// The hairline between the scrolling keys and the dismiss button.
    private static let dividerHeightRatio: CGFloat = 0.6

    private var titleSize: CGFloat { TerminalKeyBarMetrics.titleSize(for: traitCollection) }
    private var keyHeight: CGFloat { TerminalKeyBarMetrics.keyHeight(forTitleSize: titleSize) }
    private var barHeight: CGFloat { TerminalKeyBarMetrics.barHeight(forTitleSize: titleSize) }

    /// The pill's fill: white on light, a grey lighter than the keyboard's own
    /// background on dark, so the pill reads as floating above it either way.
    /// Shared with the composer field, which floats the same way (round 18).
    static let pillBackgroundColor = UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(white: 0.30, alpha: 1)
            : .systemBackground
    }

    private weak var handler: (any TerminalKeyBarHandler)?
    private let stack = UIStackView()
    private let scroll = UIScrollView()
    private let pill = TerminalKeyBarPillView()
    private let divider = UIView()
    /// The composer toggle and its hairline, pinned at the leading edge the
    /// way the dismiss key is pinned at the trailing one. Hidden, with the
    /// scroll view pulled back to the pill's edge, when the handler offers no
    /// composer (Open item 30).
    private var composerKey: UIButton?
    /// The soft-newline key, pinned beside the toggle and shown only while
    /// the composer is on.
    private var softNewlineKey: UIButton?
    private let leadingDivider = UIView()
    private var scrollLeadingWithComposer: NSLayoutConstraint?
    private var scrollLeadingWithoutComposer: NSLayoutConstraint?
    private var leadingDividerAfterSoftNewline: NSLayoutConstraint?
    private var leadingDividerAfterComposer: NSLayoutConstraint?
    private var pillHeightConstraint: NSLayoutConstraint?
    private var dividerHeightConstraints: [NSLayoutConstraint] = []
    private var stickyKeys:
        [(modifier: TerminalPublicStickyModifier, key: UIButton, caption: String)] = []
    /// Every constraint pinned to the key height, so one text-size change can
    /// move them all together.
    private var keyHeightConstraints: [NSLayoutConstraint] = []
    /// The symbol keys and their SF Symbol names: an image is drawn at a point
    /// size, so it has to be remade when the text size moves.
    private var symbolKeys: [(button: UIButton, symbol: String)] = []

    @objc var enableInputClicksWhenVisible: Bool { true }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: barHeight)
    }

    /// - Parameter pasteTarget: the responder whose `pasteConfiguration` and
    ///   `paste(itemProviders:)` the system Paste button drives. Named rather
    ///   than left to the responder chain, because an accessory view's chain
    ///   runs up the keyboard window, not the terminal.
    init(
        handler: any TerminalKeyBarHandler,
        pasteTarget: (any UIPasteConfigurationSupporting)?
    ) {
        self.handler = handler
        // A real starting frame plus flexible width: an accessory sized only by
        // its intrinsic height is the classic zero-height bar.
        super.init(
            frame: CGRect(
                x: 0, y: 0, width: 320,
                height: TerminalKeyBarMetrics.barHeight(
                    forTitleSize: TerminalKeyBarMetrics.titleSize(for: .current))),
            inputViewStyle: .keyboard)
        autoresizingMask = [.flexibleWidth]
        configureKeys(pasteTarget: pasteTarget)
        applyTextSizeMetrics()
        refreshStickyKeys()
        refreshComposerKey()
        // One row of chrome is all an iPhone has for Esc, Tab, Ctrl and the
        // arrows, so it follows the reader's text size — capped, because the
        // bar has to stay one row (round 12, finding 8).
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) {
            (bar: TerminalKeyBar, _) in
            bar.applyTextSizeMetrics()
        }
    }

    /// Re-derives every size that follows the text size, and tells UIKit the
    /// accessory wants a different height.
    private func applyTextSizeMetrics() {
        let keyHeight = self.keyHeight
        for constraint in keyHeightConstraints { constraint.constant = keyHeight }
        pillHeightConstraint?.constant = keyHeight + Self.pillPadding
        for constraint in dividerHeightConstraints {
            constraint.constant = (keyHeight * Self.dividerHeightRatio).rounded()
        }
        let verticalInset = Self.pillPadding / 2
        scroll.contentInset = UIEdgeInsets(
            top: verticalInset, left: Self.sideInset,
            bottom: verticalInset, right: Self.sideInset)
        for entry in symbolKeys {
            entry.button.configuration?.image = Self.symbolImage(
                entry.symbol, pointSize: titleSize)
            entry.button.setNeedsUpdateConfiguration()
        }
        refreshStickyKeys()
        invalidateIntrinsicContentSize()
        frame.size.height = barHeight
    }

    private static func symbolImage(_ name: String, pointSize: CGFloat) -> UIImage? {
        UIImage(
            systemName: name,
            withConfiguration: UIImage.SymbolConfiguration(
                pointSize: pointSize, weight: .regular))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    /// Redraws the Ctrl and Alt keys from the terminal's sticky state, which
    /// changes both from these keys and from every keystroke that consumes an
    /// armed modifier.
    func refreshStickyKeys() {
        guard let handler else { return }
        for entry in stickyKeys {
            apply(
                handler.keyBar(self, stickyActivationFor: entry.modifier),
                to: entry.key,
                caption: entry.caption)
        }
    }

    /// Redraws the composer toggle from the handler: absent, off, or on
    /// (tinted, as an armed sticky key is).
    func refreshComposerKey() {
        guard let composerKey else { return }
        let state = handler?.keyBarComposerState(self)
        let offered = state != nil
        composerKey.isHidden = !offered
        leadingDivider.isHidden = !offered
        // The soft newline only means anything while the field is there.
        softNewlineKey?.isHidden = state != true
        leadingDividerAfterSoftNewline?.isActive = false
        leadingDividerAfterComposer?.isActive = false
        (state == true ? leadingDividerAfterSoftNewline : leadingDividerAfterComposer)?
            .isActive = true
        scrollLeadingWithComposer?.isActive = false
        scrollLeadingWithoutComposer?.isActive = false
        (offered ? scrollLeadingWithComposer : scrollLeadingWithoutComposer)?.isActive = true
        composerKey.configuration?.baseForegroundColor = state == true ? .tintColor : .label
        composerKey.accessibilityValue = state == true ? "On" : "Off"
        composerKey.setNeedsUpdateConfiguration()
    }

    // MARK: - Layout

    private func configureKeys(pasteTarget: (any UIPasteConfigurationSupporting)?) {
        // One floating pill on the keyboard's own background, the shape
        // Notion's iOS toolbar uses: the keys inside it lose their key caps,
        // so the row reads as a single object rather than a second keyboard.
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.backgroundColor = Self.pillBackgroundColor
        addSubview(pill)

        // A scroll view so a phone can reach the right-hand keys. On an iPad
        // the row fits and stretches instead (see the width constraint below).
        // Its vertical inset is what centres the key row in the pill;
        // a centre constraint would fight the scroll view's content offset.
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.showsHorizontalScrollIndicator = false
        pill.addSubview(scroll)

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = Self.keySpacing
        // Even spacing when the row fits, the fixed gap plus scrolling when it
        // does not — the stack's own width settles which, below.
        stack.distribution = .equalSpacing
        scroll.addSubview(stack)

        let controls: [(TerminalControlKey, String?, String?)] = [
            (.escape, "esc", nil),
            (.tab, "tab", nil),
            (.shiftTab, "⇧tab", nil),
        ]
        for (key, title, symbol) in controls {
            stack.addArrangedSubview(controlKey(key, title: title, symbol: symbol))
        }

        for modifier in [TerminalPublicStickyModifier.ctrl, .alt] {
            let key = stickyKey(modifier)
            stickyKeys.append((modifier, key, modifier.rawValue))
            stack.addArrangedSubview(key)
        }

        let arrows: [(TerminalControlKey, String)] = [
            (.left, "arrow.left"),
            (.up, "arrow.up"),
            (.down, "arrow.down"),
            (.right, "arrow.right"),
        ]
        for (key, symbol) in arrows {
            stack.addArrangedSubview(controlKey(key, title: nil, symbol: symbol))
        }

        for text in ["|", "~", "/", "-", "_", "`"] {
            stack.addArrangedSubview(symbolKey(text))
        }

        if let pasteTarget {
            stack.addArrangedSubview(pasteKey(target: pasteTarget))
        }

        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.backgroundColor = .separator
        pill.addSubview(divider)

        let dismiss = dismissKey()
        pill.addSubview(dismiss)

        let composer = composerToggleKey()
        composerKey = composer
        pill.addSubview(composer)
        let softNewline = softNewlineToggleKey()
        softNewlineKey = softNewline
        pill.addSubview(softNewline)
        leadingDivider.translatesAutoresizingMaskIntoConstraints = false
        leadingDivider.backgroundColor = .separator
        pill.addSubview(leadingDivider)

        let pillHeight = pill.heightAnchor.constraint(
            equalToConstant: keyHeight + Self.pillPadding)
        pillHeightConstraint = pillHeight
        let dividerHeight = divider.heightAnchor.constraint(
            equalToConstant: (keyHeight * Self.dividerHeightRatio).rounded())
        let leadingDividerHeight = leadingDivider.heightAnchor.constraint(
            equalToConstant: (keyHeight * Self.dividerHeightRatio).rounded())
        dividerHeightConstraints = [dividerHeight, leadingDividerHeight]
        // One of the two is active at a time; `refreshComposerKey` picks.
        scrollLeadingWithComposer = scroll.leadingAnchor.constraint(
            equalTo: leadingDivider.trailingAnchor)
        scrollLeadingWithoutComposer = scroll.leadingAnchor.constraint(
            equalTo: pill.leadingAnchor)
        // The soft-newline key sits between the toggle and the hairline while
        // the composer is on; with it hidden the hairline closes up against
        // the toggle. One of the two is active at a time.
        leadingDividerAfterSoftNewline = leadingDivider.leadingAnchor.constraint(
            equalTo: softNewline.trailingAnchor, constant: Self.keySpacing)
        leadingDividerAfterComposer = leadingDivider.leadingAnchor.constraint(
            equalTo: composer.trailingAnchor, constant: Self.keySpacing)

        NSLayoutConstraint.activate([
            pill.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.pillMargin),
            pill.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.pillMargin),
            pill.centerYAnchor.constraint(equalTo: centerYAnchor),
            pillHeight,

            composer.leadingAnchor.constraint(
                equalTo: pill.leadingAnchor, constant: Self.sideInset),
            composer.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
            softNewline.leadingAnchor.constraint(
                equalTo: composer.trailingAnchor, constant: Self.keySpacing),
            softNewline.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
            leadingDivider.widthAnchor.constraint(equalToConstant: 1),
            leadingDivider.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
            leadingDividerHeight,

            scroll.topAnchor.constraint(equalTo: pill.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: pill.bottomAnchor),
            scroll.trailingAnchor.constraint(equalTo: divider.leadingAnchor),

            divider.widthAnchor.constraint(equalToConstant: 1),
            divider.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
            dividerHeight,
            divider.trailingAnchor.constraint(
                equalTo: dismiss.leadingAnchor, constant: -Self.keySpacing),

            dismiss.trailingAnchor.constraint(
                equalTo: pill.trailingAnchor, constant: -Self.sideInset),
            dismiss.centerYAnchor.constraint(equalTo: pill.centerYAnchor),

            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
        ])
        // Low priority, so a row too wide to fit keeps its natural width and
        // scrolls; when it fits, this stretches the stack across the pill and
        // `.equalSpacing` distributes the keys evenly (the iPad case).
        let stretch = stack.widthAnchor.constraint(
            equalTo: scroll.frameLayoutGuide.widthAnchor,
            constant: -2 * Self.sideInset)
        stretch.priority = .defaultLow
        stretch.isActive = true

        let stackHeight = stack.heightAnchor.constraint(equalToConstant: keyHeight)
        stackHeight.isActive = true
        keyHeightConstraints.append(stackHeight)
    }

    // MARK: - Keys

    private func controlKey(
        _ key: TerminalControlKey, title: String?, symbol: String?
    ) -> UIButton {
        let button = makeKey(title: title, symbol: symbol, monospaced: false)
        button.accessibilityLabel = key.accessibilityLabel
        button.addAction(
            UIAction { [weak self] _ in
                guard let self else { return }
                UIDevice.current.playInputClick()
                handler?.keyBar(self, didPress: key)
            }, for: .touchUpInside)
        return button
    }

    private func symbolKey(_ text: String) -> UIButton {
        let button = makeKey(title: text, symbol: nil, monospaced: true)
        button.accessibilityLabel = text
        button.addAction(
            UIAction { [weak self] _ in
                guard let self else { return }
                UIDevice.current.playInputClick()
                handler?.keyBar(self, didType: text)
            }, for: .touchUpInside)
        return button
    }

    private func stickyKey(_ modifier: TerminalPublicStickyModifier) -> UIButton {
        let button = makeKey(title: modifier.rawValue, symbol: nil, monospaced: false)
        button.accessibilityLabel = modifier == .ctrl ? "Control" : "Option"
        button.addAction(
            UIAction { [weak self] _ in
                guard let self else { return }
                UIDevice.current.playInputClick()
                handler?.keyBar(self, didToggleSticky: modifier)
                refreshStickyKeys()
            }, for: .touchUpInside)
        return button
    }

    /// Always visible, outside the scroll view: on an iPhone the scrolling
    /// keys can be anywhere, and the way down must not be one of the things
    /// that scrolls away.
    private func dismissKey() -> UIButton {
        let button = makeKey(
            title: nil, symbol: "keyboard.chevron.compact.down", monospaced: false)
        button.accessibilityLabel = "Hide Keyboard"
        button.addAction(
            UIAction { [weak self] _ in
                guard let self else { return }
                UIDevice.current.playInputClick()
                handler?.keyBarDidRequestDismiss(self)
            }, for: .touchUpInside)
        return button
    }

    /// The composer toggle (Open item 30): a text-box glyph at the leading
    /// edge, tinted while the composer is on. Pinned outside the scroll view
    /// for the same reason the dismiss key is.
    private func composerToggleKey() -> UIButton {
        let button = makeKey(title: nil, symbol: "character.textbox", monospaced: false)
        button.accessibilityLabel = "Text Field"
        button.addAction(
            UIAction { [weak self] _ in
                guard let self else { return }
                UIDevice.current.playInputClick()
                handler?.keyBarDidToggleComposer(self)
                refreshComposerKey()
            }, for: .touchUpInside)
        return button
    }

    /// The soft-newline key: `\` then Return, so Claude Code breaks the line
    /// in its prompt instead of sending it. Pinned beside the composer
    /// toggle, outside the scroll view, and only on while the composer is.
    /// A sticky Ctrl or Alt does not apply — this is not typed text.
    private func softNewlineToggleKey() -> UIButton {
        let button = makeKey(title: nil, symbol: "return.left", monospaced: false)
        button.accessibilityLabel = "Soft newline"
        button.accessibilityHint = "Starts a new line in the prompt without sending"
        button.addAction(
            UIAction { [weak self] _ in
                guard let self else { return }
                UIDevice.current.playInputClick()
                handler?.keyBarDidPressSoftNewline(self)
            }, for: .touchUpInside)
        return button
    }

    /// UIKit's own Paste button: it reads the pasteboard under the system's
    /// authority, so no "Allow Paste?" prompt appears, and the terminal's
    /// `paste(itemProviders:)` handles text, images and files alike.
    private func pasteKey(target: any UIPasteConfigurationSupporting) -> UIView {
        let configuration = UIPasteControl.Configuration()
        configuration.displayMode = .iconOnly
        configuration.cornerStyle = .capsule
        configuration.baseBackgroundColor = .clear
        configuration.baseForegroundColor = .label
        let control = UIPasteControl(configuration: configuration)
        control.target = target
        control.translatesAutoresizingMaskIntoConstraints = false
        let height = control.heightAnchor.constraint(equalToConstant: keyHeight)
        keyHeightConstraints.append(height)
        NSLayoutConstraint.activate([
            height,
            control.widthAnchor.constraint(
                greaterThanOrEqualToConstant: Self.minimumKeyWidth),
        ])
        return control
    }

    private func makeKey(title: String?, symbol: String?, monospaced: Bool) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.title = title
        configuration.image = symbol.flatMap { Self.symbolImage($0, pointSize: titleSize) }
        configuration.baseForegroundColor = .label
        configuration.background.backgroundColor = .clear
        configuration.contentInsets = NSDirectionalEdgeInsets(
            top: 0, leading: 8, bottom: 0, trailing: 8)
        configuration.titleTextAttributesTransformer =
            UIConfigurationTextAttributesTransformer { [weak self] incoming in
                var outgoing = incoming
                let size =
                    self?.titleSize
                    ?? TerminalKeyBarMetrics.titleSize(for: .current)
                outgoing.font =
                    monospaced
                    ? .monospacedSystemFont(ofSize: size, weight: .regular)
                    : .systemFont(ofSize: size)
                return outgoing
            }

        let button = UIButton(configuration: configuration, primaryAction: nil)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.showsMenuAsPrimaryAction = false
        button.isPointerInteractionEnabled = true
        let height = button.heightAnchor.constraint(equalToConstant: keyHeight)
        keyHeightConstraints.append(height)
        NSLayoutConstraint.activate([
            height,
            button.widthAnchor.constraint(
                greaterThanOrEqualToConstant: Self.minimumKeyWidth),
        ])
        if let symbol { symbolKeys.append((button, symbol)) }
        return button
    }

    /// Armed is the tinted key; locked is the same key with its caption
    /// underlined, so a glance tells a one-shot modifier from a held one.
    private func apply(
        _ activation: TerminalPublicStickyActivation,
        to key: UIButton,
        caption: String
    ) {
        guard var configuration = key.configuration else { return }
        var title = AttributedString(caption)
        title.font = .systemFont(ofSize: titleSize)
        // Without a key cap to fill, the tint moves into the caption itself:
        // armed is tinted, locked is tinted and underlined.
        switch activation {
        case .inactive:
            title.foregroundColor = .label
        case .armed:
            title.foregroundColor = .tintColor
        case .locked:
            title.foregroundColor = .tintColor
            title.underlineStyle = .single
        }
        configuration.title = nil
        configuration.attributedTitle = title
        key.configuration = configuration
    }
}

/// The floating pill the keys sit in. Its corner radius follows its height, so
/// a Dynamic Type change keeps the capsule a capsule, and its shadow is given
/// an explicit path — without one UIKit composites the shadow from the layer
/// tree on every frame.
private final class TerminalKeyBarPillView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.12
        layer.shadowOffset = CGSize(width: 0, height: 1)
        layer.shadowRadius = 3
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let radius = bounds.height / 2
        layer.cornerRadius = radius
        layer.shadowPath = UIBezierPath(
            roundedRect: bounds, cornerRadius: radius).cgPath
    }
}

/// The terminal answers its own key bar. Every route here is one the keyboard
/// and the hardware keys already take: control keys go out as raw bytes, and
/// the symbol keys are typed, so an armed sticky modifier applies to them the
/// way it applies to anything else the user types.
extension HeelerTerminalView: TerminalKeyBarHandler {
    func keyBar(_ bar: TerminalKeyBar, didPress key: TerminalControlKey) {
        composerControl?.controlKeyWillBeSent(key)
        sendControlKey(key)
    }

    /// While the composer is active a symbol key types into the field, so
    /// the field and the PTY stay one line. An armed Ctrl or Alt makes the
    /// key a chord instead, and a chord is the terminal's.
    func keyBar(_ bar: TerminalKeyBar, didType text: String) {
        guard isLocalInputEnabled else { return }
        if !hasActiveStickyModifiers, composerControl?.typeIntoField(text) == true {
            return
        }
        insertText(text)
    }

    func keyBar(_ bar: TerminalKeyBar, didToggleSticky modifier: TerminalPublicStickyModifier) {
        toggleStickyModifier(modifier)
    }

    func keyBar(
        _ bar: TerminalKeyBar, stickyActivationFor modifier: TerminalPublicStickyModifier
    ) -> TerminalPublicStickyActivation {
        stickyActivation(for: modifier)
    }

    /// The one sanctioned way down: a bare `resignFirstResponder()` is
    /// something UIKit does on its own and the terminal restores.
    func keyBarDidRequestDismiss(_ bar: TerminalKeyBar) {
        // The field may be the one holding the keyboard; the terminal's own
        // intent is cleared either way, so nothing raises it back.
        composerControl?.resignField()
        _ = dismissKeyboard()
    }

    func keyBarComposerState(_ bar: TerminalKeyBar) -> Bool? {
        composerControl?.isEnabled
    }

    func keyBarDidToggleComposer(_ bar: TerminalKeyBar) {
        composerControl?.toggle()
    }

    func keyBarDidPressSoftNewline(_ bar: TerminalKeyBar) {
        guard isLocalInputEnabled else { return }
        composerControl?.softNewlineFromKeyBar()
    }
}
