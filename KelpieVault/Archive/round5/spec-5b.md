# Kelpie round 5B — multitasking, compact widths, notifications, Quick Look, windows

Project: /Users/anthonytopalides/Developer/Kelpie, branch `kelpie`, clean tree at `0df2239`. Swift 6 strict concurrency, no force unwraps / `try!` outside tests, iOS 18+. Read the Kelpie section of `CLAUDE.md` first. **Never edit `Packages/GhosttyTerminal`.**

**File ownership (another builder works in parallel — stay inside yours):** you own `project.yml`, `Sources/Heeler/Client/HerdrClientView.swift`, `HerdrClientRootView.swift`, `HerdrClientStore.swift`, `PrimaryHostStore.swift`, new files under `Sources/Heeler/Client/` and `Sources/Heeler/Files/`, `Sources/Heeler/Settings/**`, `Sources/Heeler/Notifications/**`, `Sources/Heeler/Transport/**`, `Packages/HeelerSSH/**`, `Sources/Heeler/HeelerApp.swift`, `ContentView.swift`, `Sources/Heeler/Terminal/TerminalLinkDetector.swift` (only this one file under Terminal/), and the tests for those. Do **not** touch any other file under `Sources/Heeler/Terminal/`, nor `MediaIntake.swift`, `HerdrMediaStagingStore.swift`, `KelpieVault/`, docs. You are the only one who runs `xcodegen generate` (do it after adding files; commit nothing). For `CHANGELOG.md`, append your lines at the **end** of the `[Unreleased]` → `### Added` section only (create `### Changed` lines only if needed, at the end of that section).

## 1. Let iPadOS resize the window (Split View, Slide Over, Stage Manager)

Observed: the window "keeps its shape", so side-by-side is near impossible. Cause: `project.yml:94` lists three orientations; iPadOS only allows multitasking and resizable windows when the iPad supports **all four**. Add `UIInterfaceOrientationPortraitUpsideDown` for the iPad (`INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad` alongside the existing key; keep the iPhone key as it is), and make sure `UIRequiresFullScreen` stays absent/false. Verify in the generated `Heeler.xcodeproj` build settings.

## 2. Width-aware default font size

`Sources/Heeler/Settings/TerminalZoomSettings.swift:42-44` keys the 12 pt iPad default off idiom. Make the *default* follow the window's width: ≥ 700 pt → 12, ≥ 500 pt → 11, below → 10, on iPad only (iPhone unchanged). The user's explicit zoom (⌘+/⌘-, pinch) stays an offset applied on top and is preserved across width changes; changing the window width must not wipe a chosen zoom. Feed the width from the client screen (`GeometryReader` or `UIWindowScene` size via the representable) into the settings through a small `windowWidthDidChange(_:)`; the screen already re-applies `fontSize` on change. Keep the change contained: one computed default, one input.

## 3. Compact chrome

`HerdrClientRootView.menuButton`: under 500 pt window width show the capsule icon-only (`server.rack` in the same material capsule, no host name), keep the accessibility label. Nothing else changes.

## 4. herdr's desktop notifications reach the iPad

herdr can ask the outer terminal for a desktop notification (`ui.toast.delivery = "terminal"`, OSC 9/777). The vendored view decodes it into `TerminalSurfaceDesktopNotificationDelegate.terminalDidRequestDesktopNotification(title:body:)` (`Packages/GhosttyTerminal/Sources/GhosttyTerminal/Surface/TerminalSurfaceViewDelegate.swift:147`, routed via `State/TerminalViewState+Delegate.swift:45`); nothing in the app adopts it. Find how the app receives view-state delegate callbacks (grep `TerminalViewState`, `delegate`, `TerminalController` in `Sources/Heeler/Terminal/TerminalScreenView.swift` — read-only for you; if adoption *must* live in that file, write the adopter as an extension in a new file under `Sources/Heeler/Client/` and expose a one-line hook the other builder can call; describe it in the report). Behaviour: app in foreground → the existing in-app banner (`AgentNotificationBannerStore`, see how the Console posts banners) with title/body; app in background → a local `UNNotificationRequest` (use the notification permission path the app already has in `Sources/Heeler/Notifications/`; if permission is undetermined, request it once). Tapping the local notification just brings the app forward.

## 5. View a file the agent made on the Host (Quick Look / share)

Tapping an absolute path in the terminal should open it on the iPad. Extend `TerminalLinkDetector` (`Sources/Heeler/Terminal/TerminalLinkDetector.swift`, which scans viewport text for URLs; read its tests) to also detect **absolute Unix paths** with a file-ish last component (`/…/name.ext`, also `~/…`), returning a distinct `.hostPath(String)` match kind next to URLs; keep URL precedence. On a tap of a path (the existing tap route that opens URLs — it is invoked from the terminal view through a callback; add a sibling callback `onHostPathTap: ((String) -> Void)?` in the representable-facing API **only if** it lives in a file you own; otherwise ask via the report and implement the rest). Then: `HostFileViewer` (new, `Sources/Heeler/Files/HostFileViewer.swift` + a store): downloads the file over **SFTP** through the Host's transport — add `downloadFile(remotePath:progress:) async throws -> URL` to the `Transport` protocol (`Sources/Heeler/Transport/Transport.swift`) and `HeelerSSHTransport` using the same SFTP session code the staging upload uses (`performStage`, ~line 1345), with a **64 MB cap** (refuse larger with a clear message), into `tmp/kelpie-downloads/<uuid>/<name>`; expose it from `ConsoleStore` as `fileDownloader(for:)` beside `imageStager(for:)`. Present with `QLPreviewController` in a sheet, with a share button (`UIActivityViewController`/`ShareLink`) so it can be saved to Files; delete the download when the sheet closes. Errors (not a file, permission, too large) go to an alert. Also add a menu item "Open File on Host…" (after Attach File) that asks for a path in an alert text field and runs the same viewer. Expand `~` using the Host's home (the transport already resolves `$HOME`; grep `homeDirectory`).
If `Packages/HeelerSSH` needs a new SFTP read primitive, add it there with a unit test in its package tests and run `scripts/run-heelerssh-package-tests.sh` (read the script first; if it needs a simulator, note that it could not run).

## 6. Stage Manager: multiple windows, one Host per window

Assess first, then implement only if the stores allow it. Read `HeelerApp.swift` and `ContentView.swift`: are `HostStore`, `ConsoleStore` and the other long-lived stores created once for the app (in `HeelerApp` as `@State`/singletons) or per scene inside `ContentView`? If **per app**: set `UIApplicationSupportsMultipleScenes` (`INFOPLIST_KEY_UIApplicationSupportsMultipleScenes: YES` in `project.yml`), make the primary Host **per window** (`@SceneStorage("kelpie.primary-host")` seeded from the app-level default in `PrimaryHostStore`), and make "Switch Host" in a window change only that window; the first window keeps today's behaviour. A Transport serves one Attach at a time per Host, so two windows on the **same** Host must not both attach: if a second window picks a Host already attached elsewhere, show a plain message in that window ("Already open in another window") with a button to take it over (which leaves the other window's attach the way the Console cover does — see `HerdrClientCommands.prepareForConsole`). If the stores are **per scene**, do not restructure: leave item 6 undone and say exactly what would have to move.

## 7. Build and return

```
S=/private/tmp/claude-501/-Users-anthonytopalides-Developer-Kelpie/2beb8609-5f8f-488c-8847-4514dad12a4b/scratchpad/build-5b
mkdir -p $S
xcodebuild build -project Heeler.xcodeproj -scheme Heeler -configuration Release \
  -destination 'platform=iOS,id=09D7738D-2173-55EF-8966-A9C3EA1D0514' \
  -clonedSourcePackagesDirPath $S/kelpie-spm -derivedDataPath $S/kelpie-dd -allowProvisioningUpdates \
  > $S/build.log 2>&1
```
Never the simulator. Fix any error in your files; if a build error is in a file you do not own, report it instead of editing. Do NOT install and do NOT commit. Write `report.md` in your folder as you go. Return at most 350 words: per item what changed (paths), the build tail line, item 6's assessment, anything skipped and why.
