# Builder 4b — round 5B

Repo: /Users/anthonytopalides/Developer/Kelpie (branch `kelpie`). Nothing committed,
nothing installed.

## 1. iPadOS window resizing
- `project.yml`: added `INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad` with all
  four orientations; the generic (three-orientation) key is left as the iPhone's.
  `UIRequiresFullScreen` still absent. Verified in the regenerated
  `Heeler.xcodeproj/project.pbxproj` (lines 2118-2119 Debug, 2284-2285 Release).

## 2. Width-aware default font size
- `Sources/Heeler/Settings/TerminalZoomSettings.swift` now persists an **offset**
  (`terminal-font-size-offset`), migrated from the old absolute `terminal-font-size`
  (still mirrored on write). `defaultFontSize(forWindowWidth:idiom:)`: iPad >=700 -> 12,
  >=500 -> 11, else 10; iPhone unchanged at 8. `windowWidthDidChange(_:)` moves only the
  base, so ⌘+/⌘−/pinch survive every resize. Existing TerminalZoomSettingsTests
  expectations still hold.
- Width fed from `Sources/Heeler/Client/HerdrClientRootView.swift` via a
  `.background { GeometryReader … onChange(of: proxy.size.width, initial: true) }`
  into one method, `windowDidResize(to:)`.

## 3. Compact chrome
- Same file: `menuLabel` uses `.labelStyle(.iconOnly)` under 500 pt (`isCompactWidth`).
  Same capsule, same `server.rack`, accessibility label/hint untouched.

## 4. herdr desktop notifications
- New `Sources/Heeler/Notifications/TerminalDesktopNotificationRelay.swift`:
  `TerminalDesktopNotification.normalized(title:body:)` (OSC 9 usually has body only),
  a `LocalNotificationScheduling` seam, and the relay — foreground → in-app banner,
  otherwise a `UNNotificationRequest` with no `userInfo` (tap only foregrounds the app);
  permission requested at most once per launch when `notDetermined`.
- New `Sources/Heeler/Client/HerdrTerminalDesktopNotifications.swift`: the
  `TerminalSurfaceDesktopNotificationDelegate` conformance as an extension on
  `HeelerTerminalView`. **No edit to TerminalScreenView.swift was needed** — the view is
  already its own surface delegate and the vendored bridge dispatches via
  `(delegate as? any …DesktopNotificationDelegate)?`
  (`Packages/GhosttyTerminal/…/InMemory/TerminalCallbackBridge.swift:100`), so a
  conformance in another file of the same module is found at runtime. Nothing is
  required from the other builder for item 4.
- `Sources/Heeler/Notifications/AgentNotificationBannerStore.swift`: `banner.target` is
  now optional; new `present(_:)` posts a terminal toast past the Agent gates. Both tap
  sites already pass it to `AgentNotificationRouter.open(_:)`, which takes an optional,
  so `ConsoleView` needed no change.
- `Sources/Heeler/ContentView.swift`: one `.task` connecting relay → bannerStore.
- `Tests/HeelerTests/AgentNotificationBannerStoreTests.swift`: two assertions updated to
  `banner?.target?.paneID`.

## 5. Host file Quick Look / share
- `Sources/Heeler/Terminal/TerminalLinkDetector.swift` (the one Terminal/ file I own),
  rewritten around a token scan: new `Match` enum (`.url` / `.hostPath`) and
  `match(inViewport:…)` / `match(in:…)`; `url(…)` kept with identical behaviour as a
  filter over it. A path matches when the token — after stripping wrapping
  brackets/quotes and trailing sentence punctuation — starts `/` or `~/`, has no `://`,
  does not start `//`, and its last component carries a short alphanumeric extension.
  URL precedence is explicit; row-wrap joining is shared.
- `Sources/Heeler/Transport/Transport.swift`: `downloadFile(remotePath:progress:)` on the
  protocol + a default impl throwing `HostFileDownloadError.unsupported` (keeps every
  fake compiling) + the `HostFileDownloadError` enum (64 MB cap, user-facing messages).
- `Sources/Heeler/Transport/HeelerSSHTransport.swift`: `downloadFile`,
  `resolvedHostFilePath` (`~` via the cached `remoteHomeDirectory()`), `performDownload`
  over the same `connection.openSFTP` path `performStage` uses, SFTP status mapping
  (2 not found / 3 permission denied / 4 not readable), destination
  `tmp/kelpie-downloads/<uuid>/<name>` at 0700, 300 s download timeout. The SFTP client
  is tracked in `imageStageClients` so `close()` tears it down.
- `Sources/Heeler/Console/HostConsoleProjection.swift`: `fileDownloader()`.
  `Sources/Heeler/Console/ConsoleStore.swift`: `fileDownloader(for:)` beside
  `imageStager(for:)`, late-bound like the stagers.
- New `Sources/Heeler/Files/HostFileViewer.swift`: `HostFileDownloader`, `HostFile`,
  `HostFileViewerStore` (task, progress, error, deletes the per-download directory on
  dismiss, `cleanupRemnants()`), `HostFileQuickLookView` (QLPreviewController),
  `HostFilePreviewSheet` (Done + `ShareLink` → Files), `HostFilePathPrompt`, and the two
  view modifiers.
- `HerdrClientRootView`: store created per Host in `HerdrClientHostView` from
  `console.fileDownloader(for: host.id)`, exposed on `HerdrClientCommands.files` /
  `openHostFile(_:)`, presented with `.hostFileViewer(files)`; menu gains
  "Open File on Host…" right after "Attach File…".
- `Sources/Heeler/HeelerApp.swift`: one line, `HostFileViewerStore.cleanupRemnants()`.
- No new HeelerSSH primitive was needed (`SSHSFTPClient.readFileIfPresent` reads a whole
  file), so `scripts/run-heelerssh-package-tests.sh` was not run.

### OPEN — needs the other builder (tap route)
`Sources/Heeler/Terminal/TerminalScreenView.swift` (not mine) owns `handleTap(at:)`
(~2235), `linkURL(at:)` (~1765) and `onOpenLink` (~560, assigned ~181/~279). To wire path
taps it needs: (1) `var onHostPathTap: ((String) -> Void)?` on `HeelerTerminalView` and on
the representable, assigned in both `makeUIView` sites; (2) `handleTap`'s URL branch
switched to `TerminalLinkDetector.match(inViewport:column:row:width:)` with `.url` →
`onOpenLink` and `.hostPath` → `onHostPathTap`, using the `gridPointMapper` cell/width it
already computes. Then one line in `HerdrClientView` (mine):
`screen.onHostPathTap = { commands.openHostFile($0) }`. Everything downstream exists and
is reachable today through the menu item.

## 6. Multiple windows — NOT DONE (per-scene stores)
`HeelerApp.swift` owns only the `@UIApplicationDelegateAdaptor`; its `WindowGroup` builds
`ContentView`, and `ContentView` declares `hostStore`, `console`,
`notificationPreferences`, the three terminal settings stores, `snippets`, `appearance`,
`inputMode`, `relaySettings`, `bannerStore`, `liveActivities`, `activity` and
`hardwareKeyboard` as its own `@State`. A second scene would build a second `ConsoleStore`
with its own SSH sessions, a second `HostStore`, a second Live Activity coordinator and a
second activity driver. So per the spec I did not restructure, and
`INFOPLIST_KEY_UIApplicationSupportsMultipleScenes` was **not** set.

Would have to move first:
1. Every `@State` store in `ContentView` up into `HeelerApp` (or one app-scoped container)
   and injected down, so all scenes share one of each.
2. The singleton `.task`s — `console.resume()`, `ConsoleActivityDriver.run()`,
   `liveActivities.start()`, `pushRegistration.refresh()`, the Notification Key mirror —
   must run once per app, not once per scene.
3. `PrimaryHostStore` becomes per window: `@SceneStorage("kelpie.primary-host")` seeded
   from the app-level persisted default.
4. Attach arbitration: an owner registry keyed by Host, so a second window on an attached
   Host shows "Already open in another window" + takeover, reusing
   `HerdrClientCommands.prepareForConsole()`'s leave-then-join.
5. A target-window rule for `AgentNotificationRouter` deep links.

## 7. Build
Spec's exact Release build on the physical iPad Pro `09D7738D-2173-55EF-8966-A9C3EA1D0514`
(never the simulator), logged to
`/private/tmp/claude-501/-Users-anthonytopalides-Developer-Kelpie/2beb8609-5f8f-488c-8847-4514dad12a4b/scratchpad/build-5b/build.log`:
tail is `** BUILD SUCCEEDED **`, exit 0, zero `error:` lines. Not installed, not committed.
One error of mine was fixed en route (a second weak `self` capture in `HostFileViewer`).

`xcodebuild build-for-testing` on the device compiled `HeelerTests` far enough to prove
the API changes do not break the suite; it then stops on a pre-existing unrelated failure
— `Tests/HeelerTests/SidebarConsoleIntegrationTests.swift:14` uses
`DemoScreenshotComposition`, which `Sources/Heeler/Demo/DemoScreenshotMode.swift` guards
with `#if DEBUG && targetEnvironment(simulator)` — so the suite cannot build for a
physical device at all. Unit suites therefore not run (the simulator is unusable on this
Mac per CLAUDE.md).

## Changelog
Three entries appended at the END of `[Unreleased]` → `### Added` in `CHANGELOG.md`
(resizing + width-aware default + compact menu; herdr desktop notifications;
Open File on Host). No `### Changed` lines needed.

## Files touched
project.yml; Heeler.xcodeproj/project.pbxproj (xcodegen);
Sources/Heeler/Settings/TerminalZoomSettings.swift;
Sources/Heeler/Client/HerdrClientRootView.swift;
Sources/Heeler/Client/HerdrTerminalDesktopNotifications.swift (new);
Sources/Heeler/Notifications/TerminalDesktopNotificationRelay.swift (new);
Sources/Heeler/Notifications/AgentNotificationBannerStore.swift;
Sources/Heeler/ContentView.swift; Sources/Heeler/HeelerApp.swift;
Sources/Heeler/Terminal/TerminalLinkDetector.swift;
Sources/Heeler/Transport/Transport.swift; Sources/Heeler/Transport/HeelerSSHTransport.swift;
Sources/Heeler/Console/ConsoleStore.swift; Sources/Heeler/Console/HostConsoleProjection.swift
(outside the explicit ownership list, but item 5 names `ConsoleStore.fileDownloader(for:)`
directly and the other builder is in Terminal/ + the two media files);
Sources/Heeler/Files/HostFileViewer.swift (new);
Tests/HeelerTests/AgentNotificationBannerStoreTests.swift; CHANGELOG.md.

Untouched: the rest of Sources/Heeler/Terminal/, MediaIntake.swift,
HerdrMediaStagingStore.swift, KelpieVault/, docs/, Packages/GhosttyTerminal.

## Review round (reviewer4 items 2, 3, 4)

- **2 — mid-run URLs restored.** `Sources/Heeler/Terminal/TerminalLinkDetector.swift`:
  `match(...)` now runs the original scheme-anchored `span(covering:)` search first
  (`urlMatch`), so `](https://…)`, `url=https://…` and `see:https://…` resolve exactly as
  before, wrap-join and trailing-punctuation stripping included. Only when that finds
  nothing does the token-based `.hostPath` rule run, which is also what keeps URL
  precedence explicit. Added `strippingSourceLocation` so `/a/b.swift:12:3` matches the
  path (a trailing all-digit `:n` or `:n:m` only).
- **3 — detector tests.** `Tests/HeelerTests/TerminalLinkDetectorTests.swift`: three
  mid-run URL shapes, `/a/b/c.txt`, `~/x/y.md`, `:12:3`/`:12` suffixes, punctuation
  wrappers (`(…)`, trailing `.`, `"…",`), extensionless paths not matched (`/dev/null`,
  `/usr/local/bin`, `/Users/anthony`), URL precedence over a URL's own path, and
  `//comment/x.txt` / bare `/` / relative `a/b/c.txt` not matched.
- **4 — bounded download.** `Packages/HeelerSSH/.../SSHSFTPClient.swift` and
  `SessionDriver.swift`: `readFileIfPresent` takes an optional `maximumByteCount`
  (defaulted, so existing callers are unchanged) and throws
  `SSHError.responseTooLarge(limit:)` from inside the chunk loop as a running byte count.
  `HeelerSSHTransport.performDownload` now refuses a nil `attributes.size` (and a zero
  size with no permissions) as `.notReadable` — "not a file that can be opened" — checks
  the cap against the stat, and passes the same 64 MB budget into the read, mapping
  `responseTooLarge` to `.tooLarge`. A lying stat or a FIFO now costs one cap, not a
  300 s unbounded read.
- Not done: no new HeelerSSH package test. `scripts/run-heelerssh-package-tests.sh`
  defaults to an iPhone 17 **Simulator** destination, which is unusable on this Mac
  (CLAUDE.md), and the package's only suite is `SessionDriverE2ETests` against a live
  sshd — an unrunnable new E2E case would ship unverified. The change is a defaulted
  parameter; the enforcement is asserted app-side.
