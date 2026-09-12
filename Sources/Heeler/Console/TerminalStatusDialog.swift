import SwiftUI

/// A dialog drawn over the terminal, for the moments when the terminal itself
/// cannot answer: the session ended, or it has not started yet.
///
/// It carries its own background on purpose. The first version was a bare
/// `ContentUnavailableView`, which is transparent by design — over a live
/// terminal that left the copy competing with whatever glyphs happened to be
/// underneath it, and losing.
///
/// The background is the terminal's, not the system's: the theme owns the
/// whole screen (see `surfaceBackground(for:)`), and a `.regularMaterial` card
/// over a Solarized or Nord grid reads as a piece of some other app. The card
/// lifts off the terminal background rather than matching it, or it would be
/// invisible on the surface it sits on.
enum TerminalStatusGlyph {
    case symbol(String)
    /// For states the app is actively working through, where a still icon
    /// would read as "stuck".
    case progress
}

/// The status overlay Agent detail presents for one terminal state.
/// Keeping this mapping as a value lets hosted lifecycle tests observe the
/// actual presentation choice without snapshotting Ghostty's live Metal tree.
struct TerminalStatusPresentation: Equatable {
    enum Kind: Equatable {
        case connecting
        case ended
    }

    let kind: Kind
    let title: String
    let message: String?
    let dimsBackground: Bool
    /// Whether the overlay offers Reconnect. An `.ended` overlay always does;
    /// a `.connecting` one only when it is reporting a connection the user can
    /// act on rather than ordinary startup.
    let offersReconnect: Bool

    static let connecting = TerminalStatusPresentation(
        kind: .connecting,
        title: "Connecting…",
        message: nil,
        dimsBackground: false)

    /// The Client let go of the Host's Attach channel and never got it back
    /// (`HerdrClientStore` `.rejoinRequired`). Not a remote failure — nothing
    /// ended on the Host — so it says what it is and offers the one action
    /// that fixes it.
    static let rejoinRequired = TerminalStatusPresentation(
        kind: .ended,
        title: "Disconnected",
        message: "Kelpie let go of this Host's terminal. Reconnect to attach again.",
        dimsBackground: true)

    /// The Client's own ended state. Same dialog, plus the one fact the raw
    /// message cannot carry: which herdr session the attach asked for. A
    /// nonzero exit from `herdr --session "<name>"` is nearly always that name
    /// — a session that does not exist, or one this Host no longer runs — so
    /// the overlay says which one and waits for the user rather than
    /// reattaching into the same exit.
    static func clientEnded(
        message: String, sessionName: String?
    ) -> TerminalStatusPresentation {
        guard let sessionName else {
            return TerminalStatusPresentation(
                kind: .ended,
                title: "Session Ended",
                message: message + "\n\nherdr exited on the Host.",
                dimsBackground: true)
        }
        return TerminalStatusPresentation(
            kind: .ended,
            title: "Session Ended",
            message: message
                + "\n\nherdr exited on the Host, running session “\(sessionName)”."
                + " Check the session name for this Host if it no longer exists.",
            dimsBackground: true)
    }

    static func ended(message: String) -> TerminalStatusPresentation {
        TerminalStatusPresentation(
            kind: .ended,
            title: "Session Ended",
            message: message,
            dimsBackground: true)
    }

    /// What the Host's own events session is doing, for the surfaces whose
    /// attach cannot proceed until it recovers — the root Client, which parks
    /// on the session's Transport with nothing of its own to say.
    ///
    /// Only the two states the user can act on produce an overlay. A healthy,
    /// connecting or suspended session returns nil, leaving the terminal's own
    /// status in charge exactly as before. The reason text is the Console
    /// rows' (`ConsoleHostStatusPresentation`): a reconnecting Host shows the
    /// failure's summary, because automatic recovery is still running; a
    /// failed one shows the whole presentation, recovery suggestion included.
    init?(hostSessionStatus: EventsSessionStatus?) {
        switch hostSessionStatus {
        case .reconnecting(let attempt, _, let failure):
            self = TerminalStatusPresentation(
                kind: .connecting,
                title: attempt > 1 ? "Reconnecting… (attempt \(attempt))" : "Reconnecting…",
                message: failure.presentation.summary,
                dimsBackground: false,
                offersReconnect: true)
        case .failed(let failure):
            self = TerminalStatusPresentation(
                kind: .ended,
                title: "Disconnected",
                message: failure.presentation.message,
                dimsBackground: true,
                offersReconnect: true)
        case .connecting:
            // A first dial, or a Reconnect Request: work is under way and
            // there is no failure to name yet. Still worth claiming, because
            // an attach that ran out its own deadline waiting for this dial
            // would otherwise draw the "Session Ended" dialog over a Host
            // that is merely slow.
            self = .connecting
        case .connected, .suspended, .ended, nil:
            return nil
        }
    }

    init?(status: AttachTerminalStore.Status) {
        switch status {
        case .waitingForSize, .connecting:
            self = .connecting
        case .ended(let message):
            self = .ended(message: message)
        case .live, .stopped:
            return nil
        }
    }

    private init(
        kind: Kind,
        title: String,
        message: String?,
        dimsBackground: Bool,
        offersReconnect: Bool = false
    ) {
        self.kind = kind
        self.title = title
        self.message = message
        self.dimsBackground = dimsBackground
        self.offersReconnect = offersReconnect
    }
}

struct TerminalStatusDialog<Actions: View>: View {
    let glyph: TerminalStatusGlyph
    let title: String
    var message: String?
    /// The active terminal theme's colours. Defaults to the system palette so
    /// previews and pixel tests need not carry a theme.
    var palette: TerminalThemePalette = .system
    /// Dims the terminal behind the dialog. Off for transient states, where a
    /// full-screen dim would flash on every reconnect.
    var dimsBackground = true
    @ViewBuilder let actions: () -> Actions

    private static var cornerRadius: CGFloat { 20 }

    var body: some View {
        ZStack {
            if dimsBackground {
                Rectangle()
                    .fill(.black.opacity(0.45))
                    .ignoresSafeArea()
            }

            VStack(spacing: 12) {
                switch glyph {
                case .symbol(let name):
                    Image(systemName: name)
                        .font(.system(size: 34))
                        .foregroundStyle(palette.foreground.opacity(0.7))
                case .progress:
                    ProgressView()
                        .controlSize(.large)
                        .tint(palette.accent)
                }
                Text(title)
                    .font(.headline)
                    .foregroundStyle(palette.foreground)
                if let message {
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(palette.foreground.opacity(0.7))
                        .multilineTextAlignment(.center)
                }
                actions()
                    .tint(palette.accent)
                    .padding(.top, 4)
            }
            .padding(24)
            .frame(maxWidth: 320)
            .background(cardBackground, in: .rect(cornerRadius: Self.cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: Self.cornerRadius)
                    .strokeBorder(palette.foreground.opacity(0.12))
            }
            .shadow(color: .black.opacity(0.25), radius: 20, y: 8)
            .padding(24)
        }
        .accessibilityElement(children: .contain)
    }

    /// The terminal's background, lifted toward its foreground just enough to
    /// separate the card from the grid it sits on — the same trick a TUI uses
    /// for a popup, and it works for a light theme and a dark one alike.
    private var cardBackground: Color {
        palette.background.mix(with: palette.foreground, by: 0.08)
    }
}

extension TerminalStatusDialog where Actions == EmptyView {
    init(
        glyph: TerminalStatusGlyph,
        title: String,
        message: String? = nil,
        palette: TerminalThemePalette = .system,
        dimsBackground: Bool = true
    ) {
        self.init(
            glyph: glyph, title: title, message: message, palette: palette,
            dimsBackground: dimsBackground, actions: { EmptyView() })
    }
}

#Preview("Ended") {
    let palette = TerminalThemeOption.solarized.palette(for: .dark)
    ZStack {
        palette.background
        TerminalStatusDialog(
            glyph: .symbol("cable.connector.slash"),
            title: "Session Ended",
            message: "The session ended.",
            palette: palette
        ) {
            Button("Reattach") {}
                .buttonStyle(.borderedProminent)
        }
    }
}

#Preview("Connecting") {
    let palette = TerminalThemeOption.solarized.palette(for: .dark)
    ZStack {
        palette.background
        TerminalStatusDialog(
            glyph: .progress, title: "Connecting…", palette: palette, dimsBackground: false)
    }
}
