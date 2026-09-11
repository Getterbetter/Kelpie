# Media/attachment scout map

## 1. Upload mechanism (Attachments/Files, Transport, HeelerSSH)
- `Sources/Heeler/Attachments/AttachmentStaging.swift:22-63` — `StagedImage`/`StagedFile` wrap a validated absolute Host path (`StagedHostPath.isValid`, line 56); `AttachmentStagingError` enum lines 65-86.
- `Sources/Heeler/Attachments/ComposerStagingStore.swift` — orchestrates prepare→stage→outcome for `.photo`/`.file` sources (`Source` enum lines 9-19, `State`/`Medium` lines 28-63); `copyPath()` (lines 273-282) puts the finished Host path on `UIPasteboard` via `AttachmentClipboard`, it is **not** typed into the pane automatically — the user must paste it themselves.
- `Sources/Heeler/Files/FilePreparer.swift:53-139` — copies a document-picker URL into app-owned protected temp storage (`HeelerPreparedFiles`, line 56), 64 MB cap (line 54), random UUID filename, `.complete` file protection + backup-exclusion.
- `Sources/Heeler/Images/ImagePreparer.swift` — re-encodes: PNG if alpha else JPEG (line 156), iterates `jpegQualities` (line 91) and downsamples (line 349) to fit `maximumEncodedByteCount` (line 160/271).
- Transport is **SFTP**, per ADR: `docs/adr/0006-stage-images-over-sftp.md`, `docs/adr/0005-keep-staged-image-cleanup-outside-mobile.md`.
- `Sources/Heeler/Transport/HeelerSSHTransport.swift:1319-1331` `createStageParentDirectory()` runs `SSHTransportSettings.defaultStageDirectoryCommand` (`Sources/Heeler/Transport/SSHTransportSettings.swift:6-9`) — `mktemp -d "${TMPDIR:-/tmp}/heeler.XXXXXXXX"`.
- `HeelerSSHTransport.swift:1345-1420` `performStage`: opens SFTP (line 1352), writes under `<parentDirectory>/stage-<uuid>/<remoteFilename>.part` (lines 1364-1365/1367), permission-locks dirs 0700 (1369/1374) and file 0600 (1393/1463), atomic `renameFileAtomically` to final path (1396), verifies byte count + perms again (1401-1411), cleans up `.part` on any failure (1416-1417).
- No `agent.prompt`/`pane.send_text` call anywhere in the staging path — delivery into the pane is left to the human pasting the copied path.

## 2. Paste / drop on the terminal
- `Sources/Heeler/Terminal/TerminalScreenView.swift:921` — `pasteConfiguration = UIPasteConfiguration(forAccepting: String.self)` — **text only**.
- Lines 1267-1296: `paste(itemProviders:)` (1267) filters `provider.canLoadObject(ofClass: NSString.self)` (1269); `canPaste(_:)` (1280) same NSString gate; `canPerformAction` (1287) delegates to `super`. Non-text pasteboard items (images, file URLs) never reach the app through this path.
- `onPaste` callback plumbing: `TerminalScreenView.swift:129,166,198,214,229,325,359,366,502,881,893,949,955` fires only with a `String`; consumed at `Sources/Heeler/Client/HerdrClientView.swift:33-34` (`store.requestPaste`), `Sources/Heeler/Console/AgentTerminalView.swift:334-335`, `Sources/Heeler/Console/ShellTerminalView.swift:39-40` — all forward plain text into `HerdrClientStore`/`AgentAttachStore`/`ShellTerminalStore.requestPaste`, which writes it to the PTY (`TerminalInputController.requestPaste`, `TerminalScreenView.swift:1165`).
- No `UIDropInteraction`, `onDrop`, or `.dropDestination` anywhere in `Sources/Heeler/` or the vendored `Packages/GhosttyTerminal/` — grep returned zero hits. Drag-and-drop is entirely unimplemented.
- Vendored view (`Packages/GhosttyTerminal/Sources/GhosttyTerminal/Platform/UIKit/UITerminalView+Interaction.swift:364-384`) also gates paste on `UIPasteboard.general.hasStrings`/`.string` only.
- Hardware-keyboard Cmd+V is not separately routed; it goes through the same UIKit responder-chain `paste(itemProviders:)`/`canPerformAction`, so it inherits the text-only restriction.

## 3. Photos/Files pickers already present
- `Sources/Heeler/Images/PhotosPickerImageSelection.swift` — wraps `PhotosPicker`/`PhotosPickerItem` as the `ImageSelection` protocol feeding `ComposerStagingStore.Source.photo`.
- `Sources/Heeler/Console/AgentTerminalView.swift` — hosts both the Photos picker and a document picker (`fileImporter`/`UIDocumentPickerViewController`) trigger UI (line ~1426 handles `.copyPath` command) that drives `ComposerStagingStore`.

## 4. Design intent (CHANGELOG / ADRs / vault)
- `CHANGELOG.md:584` — "Cancelling an image upload on a slow connection no longer kills the Host" — only attachment-related CHANGELOG line found.
- ADR 0006 chose SFTP for staging (not exec `cat >`, not base64); ADR 0005 chose to leave completed staged files on the Host rather than clean them up from the app, because the point is the resulting path outlives the app session for the agent to use later.
- No GitHub issue references (`refs #`) found in `Attachments/`, `Files/`, or `Images/`.
- `KelpieVault/` hits for attachment/media/photo/paste/drag are all in `Feedback log.md`, `Testing status.md`, `Architecture.md`, `Changelog.md`, `Onboarding proposal.md`, `Pairing and setup.md`, `Open items.md`, `Build and deploy.md`, `Decisions.md`, and several `Archive/` research/round files — did not open bodies (out of scope for this pass); flagging paths only per brief's citation-only instruction was not requested here, but content was not read to keep within the literal grep-and-map scope given.

Output file: `/private/tmp/claude-501/-Users-anthonytopalides-Developer-Kelpie/2beb8609-5f8f-488c-8847-4514dad12a4b/scratchpad/delegate-20260911/scout-media/media-map.md`
