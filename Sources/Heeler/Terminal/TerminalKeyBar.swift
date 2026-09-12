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
/// The vendored accessory bar draws round buttons on its own blurred gradient,
/// which reads as a floating pill sitting on the keyboard rather than as part
/// of it. This is a `UIInputView` in `.keyboard` style, so its background *is*
/// the keyboard's — the same material, the same seam — and the keys are
/// rounded rectangles with the one-point bottom shadow iPadOS gives its own.
///
/// Nothing here is a subview of the terminal, so the full-bounds-container
/// quirk `TerminalHoldCueView` documents does not apply: the accessory is
/// UIKit's, and the vendored surface never lays it out.
@MainActor
final class TerminalKeyBar: UIInputView, UIInputViewAudioFeedback {
    private static let minimumKeyWidth: CGFloat = 44
    fileprivate static let keyCornerRadius: CGFloat = 6
    private static let keySpacing: CGFloat = 6
    private static let groupSpacing: CGFloat = 12
    private static let sideInset: CGFloat = 8

    private var titleSize: CGFloat { TerminalKeyBarMetrics.titleSize(for: traitCollection) }
    private var keyHeight: CGFloat { TerminalKeyBarMetrics.keyHeight(forTitleSize: titleSize) }
    private var barHeight: CGFloat { TerminalKeyBarMetrics.barHeight(forTitleSize: titleSize) }

    /// White on light, the keyboard's own grey on dark — the colour an iPadOS
    /// key is, which no semantic colour reproduces on both sides.
    private static let keyBackgroundColor = UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(white: 0.42, alpha: 1)
            : .systemBackground
    }

    private weak var handler: (any TerminalKeyBarHandler)?
    private let stack = UIStackView()
    private let scroll = UIScrollView()
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
        let verticalInset = (barHeight - keyHeight) / 2
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

    // MARK: - Layout

    private func configureKeys(pasteTarget: (any UIPasteConfigurationSupporting)?) {
        // A scroll view so a phone can reach the right-hand keys. On an iPad
        // the row fits and never scrolls. Its vertical inset is what centres
        // the key row in the bar (``applyTextSizeMetrics`` sets it); a centre
        // constraint would fight the scroll view's content offset.
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.showsHorizontalScrollIndicator = false
        addSubview(scroll)

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = Self.keySpacing
        scroll.addSubview(stack)

        let controls: [(TerminalControlKey, String?, String?)] = [
            (.escape, "esc", nil),
            (.tab, "tab", nil),
        ]
        for (key, title, symbol) in controls {
            stack.addArrangedSubview(controlKey(key, title: title, symbol: symbol))
        }

        for modifier in [TerminalPublicStickyModifier.ctrl, .alt] {
            let key = stickyKey(modifier)
            stickyKeys.append((modifier, key, modifier.rawValue))
            stack.addArrangedSubview(key)
        }
        endGroup()

        let arrows: [(TerminalControlKey, String)] = [
            (.left, "arrow.left"),
            (.up, "arrow.up"),
            (.down, "arrow.down"),
            (.right, "arrow.right"),
        ]
        for (key, symbol) in arrows {
            stack.addArrangedSubview(controlKey(key, title: nil, symbol: symbol))
        }
        endGroup()

        for text in ["|", "~", "/", "-", "_", "`"] {
            stack.addArrangedSubview(symbolKey(text))
        }

        if let pasteTarget {
            endGroup()
            stack.addArrangedSubview(pasteKey(target: pasteTarget))
        }

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
        ])
        let stackHeight = stack.heightAnchor.constraint(equalToConstant: keyHeight)
        stackHeight.isActive = true
        keyHeightConstraints.append(stackHeight)
    }

    /// Widens the gap after the key just added, so the groups read apart.
    private func endGroup() {
        guard let last = stack.arrangedSubviews.last else { return }
        stack.setCustomSpacing(Self.groupSpacing, after: last)
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

    /// UIKit's own Paste button: it reads the pasteboard under the system's
    /// authority, so no "Allow Paste?" prompt appears, and the terminal's
    /// `paste(itemProviders:)` handles text, images and files alike.
    private func pasteKey(target: any UIPasteConfigurationSupporting) -> UIView {
        let configuration = UIPasteControl.Configuration()
        configuration.displayMode = .iconOnly
        configuration.cornerStyle = .medium
        configuration.baseBackgroundColor = Self.keyBackgroundColor
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
        configuration.background.backgroundColor = Self.keyBackgroundColor
        configuration.background.cornerRadius = Self.keyCornerRadius
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

        let button = TerminalKeyBarButton(configuration: configuration, primaryAction: nil)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.showsMenuAsPrimaryAction = false
        button.isPointerInteractionEnabled = true
        button.layer.shadowColor = UIColor.black.cgColor
        button.layer.shadowOpacity = 0.35
        button.layer.shadowOffset = CGSize(width: 0, height: 1)
        button.layer.shadowRadius = 0
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
        switch activation {
        case .inactive:
            configuration.background.backgroundColor = Self.keyBackgroundColor
            title.foregroundColor = .label
        case .armed:
            configuration.background.backgroundColor = .tintColor
            title.foregroundColor = .white
        case .locked:
            configuration.background.backgroundColor = .tintColor
            title.foregroundColor = .white
            title.underlineStyle = .single
        }
        configuration.title = nil
        configuration.attributedTitle = title
        key.configuration = configuration
    }
}

/// A key whose shadow follows its rounded rect. Without an explicit path UIKit
/// composites the shadow from the layer tree on every frame, and the button's
/// own layer is transparent — the rounded background lives one layer down.
private final class TerminalKeyBarButton: UIButton {
    override func layoutSubviews() {
        super.layoutSubviews()
        layer.shadowPath = UIBezierPath(
            roundedRect: bounds, cornerRadius: TerminalKeyBar.keyCornerRadius).cgPath
    }
}

/// The terminal answers its own key bar. Every route here is one the keyboard
/// and the hardware keys already take: control keys go out as raw bytes, and
/// the symbol keys are typed, so an armed sticky modifier applies to them the
/// way it applies to anything else the user types.
extension HeelerTerminalView: TerminalKeyBarHandler {
    func keyBar(_ bar: TerminalKeyBar, didPress key: TerminalControlKey) {
        sendControlKey(key)
    }

    func keyBar(_ bar: TerminalKeyBar, didType text: String) {
        guard isLocalInputEnabled else { return }
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
}
