# Kelpie — media into herdr (paste, drop, pickers) build spec

Project: /Users/anthonytopalides/Developer/Kelpie, branch `kelpie`, clean tree. Swift 6 strict concurrency, no force unwraps / `try!` outside tests, iOS 18+. Read the Kelpie section of `CLAUDE.md` first. **Never edit `Packages/GhosttyTerminal`**; override its `open` members from `HeelerTerminalView` (`Sources/Heeler/Terminal/TerminalScreenView.swift`). Do not touch `KelpieVault/`, `resume.md`, docs. Do not edit `Sources/Heeler/Terminal/TerminalKeyTrace.swift` or the Escape/Option key code in `TerminalScreenView.swift` (the `pressesBegan`/`keyCommands`/`TerminalHardwareKeyMapping` parts); you may add to that file.

## Why and what

The user wants to bring photos and files from the iPad into a herdr pane so an agent (Claude Code) can use them. herdr's own `--remote` client does this by copying the image to a temp file on the server and typing the path into the pane; Claude Code reads an image or file whose path appears in the prompt. Heeler already has the upload half: `ComposerStagingStore` (`Sources/Heeler/Attachments/ComposerStagingStore.swift`) prepares an image (`Sources/Heeler/Images/ImagePreparer.swift`, HEIC→JPEG/PNG under a byte cap) or a file (`Sources/Heeler/Files/FilePreparer.swift`), stages it over SFTP into a private temp dir on the Host (`HeelerSSHTransport.stageImage/stageFile`, ADR 0006), and on success calls `composer.insertIntoDraft("\(staged.path) ")` on its `ComposerDraftOperations`. `ConsoleStore.imageStager(for:)` / `fileStager(for:)` (`Sources/Heeler/Console/ConsoleStore.swift:220-240`) hand out late-bound stagers per Host. The Agent terminal in the console (`Sources/Heeler/Console/AgentTerminalView.swift`, around line 282) already wires a `ComposerStagingStore` with `PhotosPicker` and `fileImporter`; read it first and mirror its patterns (security-scoped URL handling, the staging UI it shows, its state machine) rather than inventing new ones.

On the herdr client screen (`Sources/Heeler/Client/HerdrClientView.swift`, `HerdrClientRootView.swift`, `HerdrClientStore.swift`) the "draft" is the live PTY: inserting the path means pasting it as text through the same route a text paste takes (`HerdrClientStore.requestPaste(_:bracketedPaste:)`, fed today by `screen.onPaste = { text, bracketed in … }` where `bracketed` comes from the terminal's mode tracker).

Build four intake surfaces feeding one staging pipeline.

## 1. `Sources/Heeler/Client/HerdrMediaStagingStore.swift` (new)

`@MainActor @Observable final class HerdrMediaStagingStore: ComposerDraftOperations`:
- `init(stageImage: @escaping ImageStager, stageFile: @escaping FileStager, insert: @escaping @MainActor (String) -> Void)`; owns a `ComposerStagingStore(stageImage:stageFile:composer: self)`. `insertIntoDraft(_ text:)` calls `insert(text)`; `replaceDraft(with:)` also calls `insert` (staging never calls it, but implement it honestly).
- `func stage(_ items: [MediaIntakeItem])` — queues items and stages them **one at a time in order** through the wrapped store (it handles one operation at a time; wait for each outcome before starting the next; on a failure stop the queue and surface the error, keep the already-inserted paths).
- Exposes whatever the staging UI needs (progress, error, cancel) by forwarding the wrapped store's observable state; keep it thin.

## 2. `Sources/Heeler/Client/MediaIntake.swift` (new) — pure, testable

```swift
enum MediaIntakeItem: Sendable { case image(Data, suggestedName: String?), file(URL) }
enum MediaIntakeClassification: Equatable { case text, image, file, unsupported }
enum MediaIntake {
    /// Classifies by registered type identifiers, preferring text, then image, then a file URL.
    static func classify(typeIdentifiers: [String]) -> MediaIntakeClassification
    /// Loads providers into items: images via `loadDataRepresentation(forTypeIdentifier:)` for the first image-conforming identifier (keep the original bytes; ImagePreparer re-encodes), files via `loadFileRepresentation` copied to a fresh file under `FileManager.default.temporaryDirectory/kelpie-intake/<uuid>/<original name>` before the closure returns (the provided URL dies with the closure). Text providers are not this function's business.
    static func loadItems(from providers: [NSItemProvider]) async -> [MediaIntakeItem]
    /// A path for a bracketed paste into a shell or an agent prompt: single-quoted only if it contains whitespace or a quote, always followed by one space.
    static func pasteText(forStagedPath path: String) -> String
}
```
`classify` rules: any identifier conforming to `UTType.plainText`/`.text`/`.url` (non-file) → `.text`; else any conforming to `UTType.image` → `.image`; else any conforming to `UTType.fileURL` or `.item` with a file representation → `.file`; else `.unsupported`. Use `UTType(identifier)?.conforms(to:)`.

Tests in `Tests/HeelerTests/MediaIntakeTests.swift` (same framework as neighbouring tests): `classify` for `public.utf8-plain-text`, `public.jpeg`, `public.heic`, `public.png`, `public.file-url`, `com.adobe.pdf`, an unknown identifier, and text winning over image when both present; `pasteText` for a plain path, a path with a space, a path with a single quote.

## 3. Intake surfaces on `HeelerTerminalView` (`TerminalScreenView.swift`)

Add `var onStageItems: (([NSItemProvider]) -> Void)?` to the UIKit view and plumb it through the `TerminalScreenView` representable exactly the way `onPaste` is plumbed (find every place `onPaste` is declared, stored, and updated — including `updateUIView` — and add `onStageItems` beside it).

a. **Paste.** Today `paste(itemProviders:)`, `canPaste(_:)`, `canPerformAction(paste)` and the `UIPasteConfiguration` (grep `UIPasteConfiguration` in the file, around line 921) are text-only. Extend: acceptable type identifiers gain `UTType.image.identifier` and `UTType.fileURL.identifier`; `canPaste` is true when `MediaIntake.classify` of any provider's `registeredTypeIdentifiers` is `.text`, `.image` or `.file`; `paste(itemProviders:)` keeps the text branch first and otherwise calls `onStageItems(providers)` with the image/file providers; `canPerformAction(paste)` becomes `isLocalInputEnabled && (clipboard.hasStrings() || UIPasteboard.general.hasImages || UIPasteboard.general.hasURLs)` — note `hasImages`/`hasURLs` do not trigger the paste banner, only reading contents does; `paste(_:)` (edit-menu Paste): if the pasteboard has strings keep today's behaviour, else hand `UIPasteboard.general.itemProviders` to `onStageItems`.
   Hardware **Cmd+V**: the key-trace showed Cmd+letter presses reach `pressesBegan` and go to Ghostty, which ignores them. In the existing `pressesBegan` override, alongside `zoomShortcutStep`, intercept a press with `.command` and `charactersIgnoringModifiers == "v"` (no other modifiers): call `paste(nil)` and swallow the press and its release (the same bookkeeping the mapping interception uses via `forwardablePresses`; do not edit the mapping code itself — add a separate check).
b. **Drop.** Add a `UIDropInteraction` to the view (install where the other interactions are installed; grep `addInteraction`). `canHandle` when the session has objects conforming to image or file URL (`session.hasItemsConforming(toTypeIdentifiers: [UTType.image.identifier, UTType.fileURL.identifier])`) and `isLocalInputEnabled`; `sessionDidUpdate` returns `.copy`; `performDrop` calls `onStageItems(session.items.map(\.itemProvider))`. Text-only drops are ignored (return `.cancel`), keep it to media.
c. **Pickers** in the Kelpie menu (`HerdrClientRootView.menuButton`): after "Setup Guide" add a `Divider()` then `Button("Attach Photo…", systemImage: "photo")` and `Button("Attach File…", systemImage: "doc")`. Photo: `PhotosPicker` bound to a `@State` `PhotosPickerItem?` (use the existing `PhotosPickerImageSelection` in `Sources/Heeler/Images/`), producing `.image` intake through `ImageSelection` — extend `MediaIntakeItem` with a case `photo(any ImageSelection)` if that is cleaner than loading data eagerly; File: `.fileImporter(allowedContentTypes: [.item], allowsMultipleSelection: true)`, copying each security-scoped URL the way `AgentTerminalView` does before handing `.file(url)` on.

## 4. Wiring in `HerdrClientView` / `HerdrClientRootView`

- `HerdrClientRootView` builds one `HerdrMediaStagingStore` per client instance (next to where `HerdrClientStore` is built, ~line 334) with `console.imageStager(for: host.id)`, `console.fileStager(for: host.id)`, and `insert: { text in store.requestPaste(text, bracketedPaste: <current>) }`. For `<current>`: find how the view computes `bracketed` for `onPaste` and expose the same value (a small control object like `TerminalKeyboardControl`, or an `onBracketedPasteModeChanged` callback kept in `@State`). If that is disproportionate, always pass `true` and say so in the report.
- `HerdrClientView`: `screen.onStageItems = { providers in Task { media.stage(await MediaIntake.loadItems(from: providers)) } }`.
- Staging UI: reuse the staging status/progress/error component the Agent terminal uses with its `ComposerStagingStore` (find it in `AgentTerminalView.swift`; if it is a self-contained view, place it as a bottom overlay on the client screen above the keyboard inset; if it is entangled with the composer, build a compact capsule: "Uploading photo… 42%" with a Cancel button, an error line with Dismiss, auto-hides 2 s after success).

## 5. Housekeeping

- `xcodegen generate`; regenerated `Heeler.xcodeproj` is part of the change.
- `Info.plist`/entitlements: check whether Photos picker needs anything (`PhotosPicker` needs no usage string). If `fileImporter` needs the `UISupportsDocumentBrowser`-style keys it does not; leave `project.yml` alone unless the build says otherwise.
- `CHANGELOG.md` `[Unreleased]` → Added: "Photos and files reach herdr from the iPad: paste (including Cmd+V), drop, or Attach Photo / Attach File in the Kelpie menu. Each is uploaded over SFTP to a private temp folder on the Host and its path is typed into the focused pane, the way herdr's own remote image paste works. (Kelpie)".
- Build for the device in the background, log to a file, read only the tail:
  ```
  S=/private/tmp/claude-501/-Users-anthonytopalides-Developer-Kelpie/2beb8609-5f8f-488c-8847-4514dad12a4b/scratchpad/build-media
  mkdir -p $S
  xcodebuild build -project Heeler.xcodeproj -scheme Heeler -configuration Release \
    -destination 'platform=iOS,id=09D7738D-2173-55EF-8966-A9C3EA1D0514' \
    -clonedSourcePackagesDirPath $S/kelpie-spm -derivedDataPath $S/kelpie-dd -allowProvisioningUpdates \
    > $S/build.log 2>&1
  ```
  Never the simulator. Fix any error. Do NOT install and do NOT commit.

## Return

At most 300 words: files changed with paths, the build's tail line, how `bracketed` is sourced, which staging UI you reused, anything not done and why. Also write it to `<your folder>/report.md`.
