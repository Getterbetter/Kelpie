# Kelpie — Welcome screen (onboarding) build spec

Project: /Users/anthonytopalides/Developer/Kelpie, branch `kelpie`. Swift 6 strict concurrency, no force unwraps / `try!` outside tests, iOS 18+, SwiftUI. Read the Kelpie section of `CLAUDE.md` first. Never edit `Packages/GhosttyTerminal`. Do not touch `Sources/Heeler/Terminal/` (another change is in flight there) and do not touch `KelpieVault/`, `resume.md` or docs.

Background: with zero Hosts, `HerdrClientRootView` (`Sources/Heeler/Client/HerdrClientRootView.swift`, `body` around line 47) shows Heeler's `ConsoleView`, whose "No Hosts" empty state has one "Add Host" button. Nothing in the app tells a new user what to run on their Mac. Every flow needed already exists: `HostListView` (`Sources/Heeler/Hosts/HostListView.swift`) with its Scan to Pair / Add Manually empty state, `PairingScanView` (`Sources/Heeler/Pairing/PairingScanView.swift`) with camera scan plus a paste button, `HostFormView`, and the per-Host preflight (`HostOnboardingView`) that `HostListView` pushes after a Host is added or paired. The decisions below are final: lead with the plugin and pairing; manual SSH is a secondary option; pasting the code is the primary action because it is the route that works reliably (iCloud universal clipboard); typing the code by hand and scanning the QR are the fallbacks.

## 1. `Sources/Heeler/Client/WelcomeView.swift` (new)

`struct WelcomeView: View` with `let hosts: HostStore`, `let presentation: Presentation` (`enum Presentation { case root, sheet }`), and a callback `let onAction: (Action) -> Void` where `enum Action { case pasteCode, scanCode, addManually }`. The view is content only; presenting the flows is the root's job (section 3).

Layout: a `ScrollView` whose content is centred with `frame(maxWidth: 560)` and 24 pt side padding, generous vertical spacing, background `Color(.systemGroupedBackground)`. In `.sheet` presentation wrap in a `NavigationStack` with title "Setup Guide" and a trailing "Done" button that dismisses via `@Environment(\.dismiss)`; in `.root` presentation no navigation bar.

Content, top to bottom, exact copy:

1. `Image(systemName: "ipad.landscape.and.iphone")`-style hero is NOT wanted; use the app's `server.rack` symbol at `.largeTitle` weight, then **Title** "Kelpie" (`.largeTitle.bold()`), then one line `.title3`: "herdr on your Mac, full screen on your iPad."
2. A short paragraph, `.body`, secondary colour: "You need a Mac with herdr running and Remote Login turned on. Kelpie connects over SSH, opens herdr's own screen, and keeps it there."
3. **Section "On your Mac"** — a `GroupBox`-styled card (use `.background(.background, in: RoundedRectangle(cornerRadius: 16))` with 20 pt padding) containing three numbered steps. Each step: a number in a circle, a `.headline` title, a `.subheadline` secondary description, and for steps 2 and 3 a command row: monospaced text (`.system(.footnote, design: .monospaced)`, selectable via `.textSelection(.enabled)`) in a rounded `.quaternary` background, with a trailing "Copy" button (`doc.on.doc`) that writes the command to `UIPasteboard.general.string` and swaps its label to "Copied" for 1.5 s.
   - Step 1 title "Turn on Remote Login". Description: "System Settings → General → Sharing → Remote Login. The Pairing Code pins this Mac's SSH host key, so this must be on before you make a code."
   - Step 2 title "Install the pairing plugin". Description: "Run this once in any terminal on the Mac." Command: `herdr plugin install ZingerLittleBee/Heeler/plugin --ref main --yes`
   - Step 3 title "Make a Pairing Code". Description: "The popup opens inside herdr's own window, not in the shell. Press Return to make a code, then press C to copy it. With iCloud clipboard on, it is already on this iPad." Command: `herdr plugin action invoke heeler.pair`
4. **Section "On this iPad"** — same card style. A `.subheadline` secondary line: "Pair with the code you just copied, or add the Mac over SSH yourself." Then three buttons stacked full-width:
   - "Paste Pairing Code" — `.borderedProminent`, `.controlSize(.large)`, systemImage `doc.on.clipboard` → `onAction(.pasteCode)`.
   - "Scan QR Code" — `.bordered`, `.controlSize(.large)`, systemImage `qrcode.viewfinder` → `onAction(.scanCode)`.
   - "Add manually over SSH" — `.borderless` plain text button → `onAction(.addManually)`.
5. A closing `.footnote` secondary line: "Notifications need the same plugin; nothing else is required on the Mac."

Dynamic Type must work (no fixed heights); phone width must not overflow (commands wrap or scroll horizontally inside their row via `ScrollView(.horizontal)`).

## 2. Paste-first pairing: `PairingScanView` gets a mode

In `Sources/Heeler/Pairing/PairingScanView.swift` add `enum Entry { case camera, paste }` and an `entry: Entry = .camera` init parameter (default keeps every existing caller unchanged). In `.paste` mode the body's non-ceremony state shows, instead of the camera, a `PairingCodeEntryView` (new file `Sources/Heeler/Pairing/PairingCodeEntryView.swift`):
- Title "Paste the Pairing Code". Copy: "Press C in herdr's pairing popup on the Mac to copy it. With iCloud clipboard on it is already here."
- A prominent "Paste" button that reads `UIPasteboard.general.string`, trims whitespace, and hands it to the same submit path the existing paste button uses in `PairingScanStore` (find that method and reuse it; do not duplicate parsing). On a parse failure show the store's existing error presentation, or if there is none, an inline red `.footnote` "That is not a Pairing Code. It starts with HERDR-PAIR:".
- Below it a `TextField("Or type it here", text:, axis: .vertical)` monospaced, `.autocorrectionDisabled()`, `.textInputAutocapitalization(.never)`, with a "Continue" button enabled when non-empty, submitting through the same path.
- A "Scan QR Code instead" `.borderless` button that switches the view's entry to `.camera` (make `entry` `@State`, seeded from the init parameter).
On first appearance in `.paste` mode, if the clipboard already holds a string that parses as a Pairing Code, submit it immediately without a tap (this is the "already on this iPad" promise) — reuse the existing parse to check, only auto-submit on success.

Do not change the camera path, the ceremony view, or `onPaired`/`onAddManually` semantics.

## 3. `HostListView` initial action and root wiring

`HostListView` currently starts on its list or empty state and has `isScanningToPair` / `isAddingHost` state. Add `enum InitialAction { case scan, paste, addManually }` and an `initialAction: InitialAction? = nil` init parameter that, on first appearance (`.task` or `.onAppear` guarded by a `@State` flag), sets the matching state so the corresponding sheet opens. For `.paste`, present `PairingScanView(catalog:entry: .paste, …)`; carry the entry through the existing `isScanningToPair` sheet by storing the chosen entry in a `@State`. Keep all existing behaviour (a paired or added Host still pushes its preflight, the manual fallback ordering still holds).

`HerdrClientRootView`:
- `body`: when `primaryHost.host(in:)` is nil show `WelcomeView(hosts:, presentation: .root) { action in … }` instead of `consoleScreen(onClose: nil)`. The action handler sets `hostSheet = HostSheet(hostID: nil, initialAction: …)` — extend `HostSheet` with `let initialAction: HostListView.InitialAction?` (default nil) and pass it into `HostListView` in the `.sheet(item:)` at line ~83. Delete the now-wrong comment about "Onboarding is the Console's own empty state, unchanged".
- Menu (the capsule `Menu` in `menuButton`): add `Button("Setup Guide", systemImage: "questionmark.circle")` after "Settings", presenting a new `@State private var isShowingSetupGuide = false` `.sheet` with `WelcomeView(hosts:, presentation: .sheet)` whose actions dismiss the guide and then open the Host sheet with the matching initial action (use the sheet's `onDismiss` to open the second sheet, the same pattern `HostListView` uses so two sheets never overlap).
- The Console's own "No Hosts" state stays as it is for the Agents cover.

## 4. Housekeeping

- Two new files → `xcodegen generate`; the regenerated `Heeler.xcodeproj` is part of the change.
- `CHANGELOG.md` `[Unreleased]` → Added: "A Welcome screen with the Mac-side setup steps replaces the empty "No Hosts" panel, and the Kelpie menu gains Setup Guide. Pasting the Pairing Code is the primary way in; typing it and scanning the QR are the fallbacks. (Kelpie)".
- Build for the device in the background, log to a file, read only the tail:
  ```
  S=/private/tmp/claude-501/-Users-anthonytopalides-Developer-Kelpie/2beb8609-5f8f-488c-8847-4514dad12a4b/scratchpad/build-welcome
  mkdir -p $S
  xcodebuild build -project Heeler.xcodeproj -scheme Heeler -configuration Release \
    -destination 'platform=iOS,id=09D7738D-2173-55EF-8966-A9C3EA1D0514' \
    -clonedSourcePackagesDirPath $S/kelpie-spm -derivedDataPath $S/kelpie-dd -allowProvisioningUpdates \
    > $S/build.log 2>&1
  ```
  Use exactly that derived-data path (another build uses a different one). Never the simulator. Fix any error. Do NOT install to the device and do NOT commit.

## Return

At most 300 words: files changed with paths, the build's tail line, anything you could not do and why. Also write it to `<your folder>/report.md`.
