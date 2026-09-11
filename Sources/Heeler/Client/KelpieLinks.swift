import Foundation

/// The web addresses Kelpie shows the user: the fork's own repository, the
/// privacy policy App Review resolves, and the support channel.
///
/// One owner, because the same two URLs were previously literals in
/// `SettingsView` and `NotificationPrivacyCopy` and drifted apart from the
/// fork's rebrand. Strings rather than `URL`s so the call sites keep their
/// existing optional `URL(string:)` handling (no force unwraps).
// TODO(app-store): confirm before submission
enum KelpieLinks {
    /// The fork's public repository.
    static let repository = "https://github.com/Getterbetter/Kelpie"

    /// The privacy policy the App Store listing must also point at. Tracks
    /// `PRIVACY.md` on the `kelpie` branch.
    static let privacyPolicy = "https://github.com/Getterbetter/Kelpie/blob/kelpie/PRIVACY.md"

    /// Where users ask for help. Also the App Store support URL.
    static let support = "https://www.reddit.com/r/KelpieConsole/"
}
