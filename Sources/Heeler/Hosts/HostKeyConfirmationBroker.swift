import Observation
import SwiftUI

/// The first-connect trust decision, asked from wherever the app is (#1
/// robustness review, ADR 0018 amendment).
///
/// Preflight owns its own confirmation because it drives one connection at a
/// time and has a screen to put the question on. The Console has neither: it
/// connects Hosts in the background, so its policy used to decline every
/// unknown key outright. That was correct while the only unpinned Host was one
/// the user had never confirmed anywhere — and wrong once a Host can arrive
/// from a sibling device, or move to an address this device has no pin for.
/// Such a Host is unreachable until the user finds Edit Host → preflight.
///
/// So the Console asks here instead, and whichever screen is up answers by
/// applying `hostKeyConfirmation()`. A mismatch is still a hard failure that
/// never reaches this type: this is a first connect, exactly as preflight's is.
@MainActor
@Observable
final class HostKeyConfirmationBroker {
    /// The app-wide broker. The host-key policy is built inside a session
    /// factory that takes no UI of its own, so the two meet here rather than
    /// through a parameter threaded down from the root view.
    static let shared = HostKeyConfirmationBroker()

    /// The candidate awaiting an answer; the UI renders it as the fingerprint
    /// confirmation alert.
    private(set) var pending: HostKeyCandidate?

    @ObservationIgnored private var decision: CheckedContinuation<Bool, Never>?
    @ObservationIgnored private var timeoutTask: Task<Void, Never>?
    /// How many presenters are mounted. With none there is nobody to answer,
    /// so a request is declined at once rather than hanging for the timeout.
    @ObservationIgnored private var presenters = 0
    @ObservationIgnored private let timeout: Duration

    init(timeout: Duration = .seconds(60)) {
        self.timeout = timeout
    }

    /// Whether a screen is mounted that can ask the question.
    var canAsk: Bool { presenters > 0 }

    func addPresenter() {
        presenters += 1
    }

    func removePresenter() {
        presenters = max(0, presenters - 1)
        // The screen that was going to answer is gone; nobody else will.
        if presenters == 0 {
            resolve(false)
        }
    }

    /// The `HostKeyPolicy.confirmFirstConnect` implementation: shows the
    /// candidate and waits. A second candidate arriving while one is pending
    /// is declined rather than queued — the answer is about one specific key,
    /// and stacking two questions on one alert would risk answering the wrong
    /// one. The declined connection retries on the user's next attempt.
    func confirmFirstConnect(_ candidate: HostKeyCandidate) async -> Bool {
        guard presenters > 0, decision == nil else { return false }
        pending = candidate
        return await withCheckedContinuation { continuation in
            decision = continuation
            timeoutTask = Task { [timeout] in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled else { return }
                self.resolve(false)
            }
        }
    }

    /// The user's verdict on the pending candidate.
    func confirm(trusted: Bool) {
        resolve(trusted)
    }

    private func resolve(_ trusted: Bool) {
        guard let continuation = decision else { return }
        decision = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        pending = nil
        continuation.resume(returning: trusted)
    }
}

extension View {
    /// Answers the app's first-connect host key questions from this screen.
    /// Apply it once, high up: the alert is the same one preflight shows, and
    /// without it the Console declines unknown keys exactly as it used to.
    func hostKeyConfirmation(
        _ broker: HostKeyConfirmationBroker = .shared
    ) -> some View {
        modifier(HostKeyConfirmationModifier(broker: broker))
    }
}

private struct HostKeyConfirmationModifier: ViewModifier {
    let broker: HostKeyConfirmationBroker

    func body(content: Content) -> some View {
        content
            .onAppear { broker.addPresenter() }
            .onDisappear { broker.removePresenter() }
            .alert(
                "Trust this Host?",
                isPresented: presented,
                presenting: broker.pending
            ) { _ in
                Button("Trust") { broker.confirm(trusted: true) }
                Button("Don't Trust", role: .cancel) { broker.confirm(trusted: false) }
            } message: { candidate in
                Text(HostKeyConfirmationCopy.message(for: candidate))
            }
    }

    /// Presentation tracks the pending candidate; dismissal is decided by the
    /// buttons (or the broker's timeout), never by the binding, so a
    /// dismiss-then-answer race cannot double-resolve the decision.
    private var presented: Binding<Bool> {
        Binding(get: { broker.pending != nil }, set: { _ in })
    }
}

/// The confirmation's words, in one place so preflight's alert and the
/// Console's cannot drift apart.
enum HostKeyConfirmationCopy {
    static func message(for candidate: HostKeyCandidate) -> String {
        "First connection to \(candidate.host):\(String(candidate.port)).\n\n"
            + "Key fingerprint:\n\(candidate.fingerprint.displayString)\n\n"
            + "Verify it matches the Host's key before trusting."
    }
}
