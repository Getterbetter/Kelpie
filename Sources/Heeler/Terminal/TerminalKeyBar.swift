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
    static let barHeight: CGFloat = 46
    private static let keyHeight: CGFloat = 38
    private static let minimumKeyWidth: CGFloat = 44
    fileprivate static let keyCornerRadius: CGFloat = 6
    private static let keySpacing: CGFloat = 6
    private static let groupSpacing: CGFloat = 12
    private static let sideInset: CGFloat = 8
    private static let titleSize: CGFloat = 16

    /// White on light, the keyboard's own grey on dark — the colour an iPadOS
    /// key is, which no semantic colour reproduces on both sides.
    private static let keyBackgroundColor = UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(white: 0.42, alpha: 1)
            : .systemBackground
    }

    private weak var handler: (any TerminalKeyBarHandler)?
    private let stack = UIStackView()
    private var stickyKeys:
        [(modifier: TerminalPublicStickyModifier, key: UIButton, caption: String)] = []

    @objc var enableInputClicksWhenVisible: Bool { true }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: Self.barHeight)
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
            frame: CGRect(x: 0, y: 0, width: 320, height: Self.barHeight),
            inputViewStyle: .keyboard)
        autoresizingMask = [.flexibleWidth]
        configureKeys(pasteTarget: pasteTarget)
        refreshStickyKeys()
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
        // the row fits and never scrolls.
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.showsHorizontalScrollIndicator = false
        // The vertical inset is what centres a 38 pt key in the 46 pt bar;
        // a centre constraint would fight the scroll view's content offset.
        let verticalInset = (Self.barHeight - Self.keyHeight) / 2
        scroll.contentInset = UIEdgeInsets(
            top: verticalInset, left: Self.sideInset,
            bottom: verticalInset, right: Self.sideInset)
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
            stack.heightAnchor.constraint(equalToConstant: Self.keyHeight),
        ])
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
        NSLayoutConstraint.activate([
            control.heightAnchor.constraint(equalToConstant: Self.keyHeight),
            control.widthAnchor.constraint(
                greaterThanOrEqualToConstant: Self.minimumKeyWidth),
        ])
        return control
    }

    private func makeKey(title: String?, symbol: String?, monospaced: Bool) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.title = title
        configuration.image = symbol.flatMap {
            UIImage(
                systemName: $0,
                withConfiguration: UIImage.SymbolConfiguration(
                    pointSize: Self.titleSize, weight: .regular))
        }
        configuration.baseForegroundColor = .label
        configuration.background.backgroundColor = Self.keyBackgroundColor
        configuration.background.cornerRadius = Self.keyCornerRadius
        configuration.contentInsets = NSDirectionalEdgeInsets(
            top: 0, leading: 8, bottom: 0, trailing: 8)
        configuration.titleTextAttributesTransformer =
            UIConfigurationTextAttributesTransformer { incoming in
                var outgoing = incoming
                outgoing.font =
                    monospaced
                    ? .monospacedSystemFont(ofSize: Self.titleSize, weight: .regular)
                    : .systemFont(ofSize: Self.titleSize)
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
        NSLayoutConstraint.activate([
            button.heightAnchor.constraint(equalToConstant: Self.keyHeight),
            button.widthAnchor.constraint(
                greaterThanOrEqualToConstant: Self.minimumKeyWidth),
        ])
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
        title.font = .systemFont(ofSize: Self.titleSize)
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
