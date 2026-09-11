---
source: "delegate-20260910-191536/r2-navmap/navmap.md — round 2 navigation/attach/host map, 2026-09-11 08:48"
---

# Kelpie (Heeler fork) navmap — herdr-TUI-as-main-screen task

## 1. Navigation flow
- Root: `Sources/Heeler/ContentView.swift:99` builds `ConsoleView` unconditionally (no separate "host picked" screen — Console shows Agents across all Hosts; Hosts are managed in a sheet).
- `Sources/Heeler/Console/ConsoleView.swift:6` `struct ConsoleView: View`.
  - `NavigationSplitView(columnVisibility: $columnVisibility)` at line 61; sidebar = `content` (Agent list, line 62-140ish), `detail:` closure at line 151-153 returns `detail` (line 228).
  - `@State private var columnVisibility` line 50 (added in b1c0fe4 per comment at line 46-50); driven by `preferredColumnVisibility` (line 196-199) and synced via `.onChange(of: preferredColumnVisibility, initial: true)` line 171-173.
  - Navigation "path" is NOT a `NavigationPath`; it's `notificationRouter.path` (`AgentNotificationRouter`, `@Bindable var notificationRouter` line 20), a `[ConsoleAgent.ID]` acting as a 0-or-1-element stack. `selectedAgent` binding (line 201-208) projects it to the sidebar `List` selection.
  - Host management: `HostListView` is a **sheet** (`.sheet(item: $hostSheet)`, line 121-131), not a pushed route — opened via toolbar "Hosts" button (`presentHosts()`). `Sources/Heeler/Hosts/HostListView.swift:66,102` — its own `NavigationStack(path: $path)`.
  - Detail column (`ConsoleView.swift:228-` `private var detail`): if `notificationRouter.path.last` resolves to a live `ConsoleAgent`, renders `AgentDetailView` (line 233-256), `.id(id)`.
  - `Sources/Heeler/Console/AgentDetailView.swift:6` `struct AgentDetailView`: body (line 98-137) is a `Group` that shows either `ShellTerminalView` (line 102, when `openTerminal.shell != nil`) or `AgentTerminalView` (line 114, default) — this Group/AgentDetailView is the natural insertion point for a herdr-TUI screen (add a third case).

## 2. Direct-shell-attach flow (ADR 0015) + remote command builder
- ADR docs: `docs/adr/0015-*.md` (direct shell attach), `docs/adr/0016-*.md` (Direct Input).
- `Sources/Heeler/Console/ShellTerminalStore.swift`, `Sources/Heeler/Console/ShellTerminalView.swift` (435 lines) implement the shell-tab UI; `AgentOpenTerminalStore` (`ShellTerminalStore.swift:60`) owns creation/remembering.
- **Command builder**: `Sources/Heeler/Transport/HeelerSSHTransport.swift:2141` `static func attachExecCommand(agentAttachCommand:terminalAttachCommand:request:socketPath:) throws -> String`. Builds:
  ```
  "/bin/sh -c '\(HerdrHostPath.pathExport); export HERDR_SOCKET_PATH=\"$2\"; printf \"<marker>\"; exec \(attachCommand) \"$1\"<--takeover>' attach '<target>' <socketPath>"
  ```
  (lines 2172-2179). `attachCommand` is chosen by `attachCommand(agentAttachCommand:terminalAttachCommand:target:)` (line 2189-2199): `.agentPane` → `herdr agent attach`, `.terminal` → `herdr terminal attach` (defaults at `Sources/Heeler/Transport/SSHTransportSettings.swift:10-12`).
  - Handshake marker: `AttachBootstrapHandshake` in `Sources/Heeler/Transport/TerminalAttach.swift:70-76` (`printf "\033_heeler-attach\033\134"`), gated client-side by `AttachBootstrapGate` (same file, lines 83-116) to hide pre-exec shell chatter.
  - `TerminalAttachTarget` enum (`TerminalAttach.swift:10-19`) and `TerminalAttachRequest` (line 24-50) carry `target`/`takeover`/`cols`/`rows`.
- **herdr binary path**: no field on `Host`; resolved purely via PATH-fixup, not a pairing payload. `Sources/Heeler/Transport/HerdrHostPath.swift`: `extraPATH` (line 37) is a fixed list of well-known install prefixes appended to `$PATH`; `pathExport` (line 45-49) builds `PATH="$PATH:<extraPATH>"`; `missingBinaryError` (line 76-81) maps exit 127 of a still-bare `herdr` word to `TransportError.herdrBinaryNotFound`.
- **TERM/env**: no TERM/COLORTERM setting in `Sources/Heeler`; the SSH package sets it. `Packages/HeelerSSH/Sources/HeelerSSH/SSHConnection.swift:161-171` `func openPTY(command:terminal: String = "xterm-256color", columns:rows:timeout:)` — default TERM is `xterm-256color`, no COLORTERM. Call site: `HeelerSSHTransport.swift:2096-2099` `connection.openPTY(command:columns: request.cols, rows: request.rows, timeout:)`.
- **cols/rows**: initial from `TerminalAttachRequest.cols/rows` (set by caller, ultimately the terminal grid). Resize: `TerminalAttachInputQueue.resize(cols:rows:)` (`TerminalAttach.swift:202-204`) enqueues `.resize`; consumed and sent over the channel in `HeelerSSHTransport.swift` `runAttachPumps` (line 2284-2304), via `channel.resize(columns:rows:timeout:)`.
- **Reconnect/restoration**: `Sources/Heeler/Console/ShellTerminalStore.swift:343-365` `func didBecomeActive(afterPossibleSuspension:)` — if `afterPossibleSuspension` is true it calls `replaceTerminal()` (re-attaches using the remembered `ShellTerminalIdentity`, targeting `.terminal(id)` via the same `attachExecCommand`), i.e. **yes, a shell session IS restored (re-attached) when the app returns from background**, gated by `isOnStage()` and `lifecycleState`. Trigger: `ShellTerminalView.swift:191-194` `.onChange(of: activity.activationCount, initial: true) { store.didBecomeActive(afterPossibleSuspension: activity.lastAbsenceMayHaveSuspended) }`. The remembered identity itself is kept in `ConsoleStore` (`rememberShellTerminal`/`recallShellTerminal`/`shellTerminalStillExists`, referenced from `AgentDetailView.swift:82-92`).

## 3. Host model
- `Sources/Heeler/Hosts/Host.swift:7-41` `struct Host: Identifiable, Codable, Hashable, Sendable`. Fields: `id`, `name`, `address`, `port`, `username`, `authMethod` (`.deviceKey`/`.password`, line 10-13), `sessionName`, `jumpAddress`, `jumpPort`, `jumpUsername`. No herdr-path field; no secrets (password lives in Keychain, device key in `DeviceKeyStore`, comment lines 3-6).
- Storage: `Sources/Heeler/Hosts/HostStore.swift:15-18` `@Observable final class HostStore`; persists `PersistedCatalog` (versioned) to `UserDefaults` key `"hosts"` (line 17-18, 34-58); passwords go to injected `SecretStore` (`KeychainSecretStore(service: "dev.bybee.heeler.ssh")`, init default line 32).
- Transport factory: `Sources/Heeler/Console/ConsoleStore.swift:606-625` `static func sshSessionFactory(connector:knownHosts:credentials:) -> @Sendable (Host, [EventSubscription]) -> EventsSession`. Resolves `SSHCredentials` via `HostCredentialsProvider`, builds `HostKeyPolicy`, calls `connector.connect(settings: SSHTransportSettings(host:credentials:hostKeyPolicy:))` (`SSHTransportConnector`, default in factory param).

## 4. Input chrome
- `Sources/Heeler/Console/AgentDirectInputChrome.swift:8` `struct AgentDirectInputChromeContext`, `:41` `struct AgentDirectInputChrome: View` — the Direct-Input (ADR 0016) keyboard-attached chrome, shown when `AgentInputModeSettings.mode == .direct` (see `AgentTerminalView.swift:868-889` `inputChrome`: `if isDirectInput ... directInputChrome else composerChrome`/handoff `ZStack`).
- `Sources/Heeler/Console/AgentDirectInputPresentation.swift:12` `struct AgentDirectInputPresentation` — presentation state (status/telemetry/theme) for that chrome.
- `Sources/Heeler/Console/AgentComposerView.swift` / `AgentComposerStore.swift` — the default Composer chrome (authored-delivery input, ADR 0013 default); embeds `TerminalAgentSwitcherRow` (line 244-245) fed by `switcher: TerminalAgentSwitcher` (line 94).
- `Sources/Heeler/Terminal/TerminalKeyboard.swift` — `TerminalControlPadView`/keyboard-frame settle logic (`keyboardFrameDidSettle` used from `TerminalScreenView.swift:1500`; frame math at `TerminalKeyboard.swift:452-471` reading `UIResponder.keyboardFrameEndUserInfoKey`).
- `Sources/Heeler/Console/MessageJumpControl.swift` — jump-to-latest-output control, referenced from `AgentTerminalView.swift` `messageJumpChrome` overlay (line 791-793).
- Mode selection/storage: `Sources/Heeler/Settings/AgentInputModeSettings.swift:23-46` `@Observable final class AgentInputModeSettings` — app-wide, persisted to `UserDefaults` key `"agent-input-mode"` (line 28, 33-36, 41-45), values `.composer`/`.direct` (enum `AgentInputMode`, line 7-20). User-driven only (Settings toggle) — **no hardware-keyboard auto-detection found anywhere in the tree**: no `GCKeyboard`, no "keyboard height == 0" heuristic, no `UIKeyboard`-connected notification. `grep -rn "GCKeyboard|isKeyboardConnected|hardwareKeyboard"` over `Sources/Heeler` returns nothing. The nearest related mechanism is `TerminalKeyboardInset` (`Sources/Heeler/Terminal/TerminalKeyboardInset.swift:22-40`), which only measures the *software* keyboard's frame via `UIResponder.keyboardFrameEndUserInfoKey` (`TerminalKeyboardInset.swift:66`, `TerminalKeyboard.swift:467-471`) for layout/inset purposes, not to infer hardware-keyboard presence.

## 5. Bottom "active agents" status bar
- Drawn by `TerminalAgentSwitcherRow` (type referenced `Sources/Heeler/Console/AgentComposerView.swift:244-245`), fed by `TerminalAgentSwitcher` built in `Sources/Heeler/Console/AgentTerminalView.swift:669-680` `private var agentSwitcher: TerminalAgentSwitcher`.
- Inserted into the terminal screen via `.safeAreaInset(edge: .bottom, spacing: 0) { inputChrome }` at `AgentTerminalView.swift:806-808` (composer chrome, which contains the switcher row, is the default of `inputChrome`, `AgentTerminalView.swift:868-889`). A separate staging/upload bar (`AttachmentStatusBar`, `AgentTerminalView.swift:1391-1401`, type at line 1529) is a different, upload-status strip via its own `.safeAreaInset(edge:.bottom)` at line 798-800 — not the "active agents" bar.

## 6. Toolbar ownership
- `ConsoleView.swift:65-113` owns the sidebar column's toolbar (Filter/Presentation/Hosts/Settings/New Agent buttons) — this is the Console list screen, not the terminal.
- `AgentTerminalView.swift:826-852`: the Attach/terminal screen deliberately **hides** its navigation-bar content (`.navigationTitle("")`, comment lines 826-828 "navigation bar remains present only as the owner of the status bar appearance… content stays hidden") but keeps `.toolbar(.visible, for: .navigationBar)` (line 852) and sets `.toolbarBackground(Color.clear, ...)` (line 850-851) — i.e. today's terminal screen has no visible toolbar buttons of its own; a new toolbar button for "Heeler's native console" would need a `ToolbarItem` added here (or wherever the new herdr-TUI screen replaces this body) since this is the file/view that owns the terminal screen's nav bar.
- `ShellTerminalView.swift:137-149`: separate `.toolbar { ToolbarItem(.navigationBarLeading) ...; ToolbarItem(.navigationBarTrailing) ... }` for the shell-terminal screen (Close Terminal / Back-to-Agent controls) — the other candidate location if the herdr TUI reuses the shell-attach surface.

## 7. Terminal font size / pinch zoom persistence
- `Sources/Heeler/Settings/TerminalZoomSettings.swift:9-46` `@Observable final class TerminalZoomSettings`. `defaultFontSize: Float = 8` (line 9... actually line 9 class, `defaultFontSize` line 9-ish/`:9`), `range: 4...32` (line 15), persisted to `UserDefaults` key `"terminal-font-size"` (line 17, `setFontSize` line 29-33). `adjust(by:)` (line 36-38) used by pinch/keyboard-shortcut zoom; `clamped(_:)` (line 41-45) is the single shared clamp.
- Pinch handling & apply: `Sources/Heeler/Terminal/TerminalScreenView.swift:998` `private func zoom(to fontSize:)` calls `applyFontSize` (line 957-961, applies `TerminalConfiguration().fontSize(clamped)` to `terminalController`); comment at line 1757 notes Ghostty's own pinch handler is intentionally not used (Heeler drives zoom itself).

## 8. Ghostty surface configuration
- `Sources/Heeler/Terminal/TerminalScreenView.swift:912`: `configuration = TerminalSurfaceOptions(backend: .inMemory(terminalSession))` — the surface's data backend.
- Font config: `fontConfiguration(size:family:)` (`TerminalScreenView.swift:984-990ish`) builds `TerminalConfiguration().fontSize(size)` (+family); applied at init (line 259 `view.applyFontSize(fontSize)`) and on zoom (line 960-961).
- Theme: `Sources/Heeler/Settings/TerminalThemeSettings.swift` and `TerminalThemePreview.swift:43,73` also build `TerminalConfiguration`/`.withFontSize`/`.fontSize` for theme preview swatches.
- No explicit scrollback/link/mouse config strings found set from Heeler code beyond the above — mouse-reporting is read from the remote app's requests (`TerminalScreenView.swift:1020` comment) rather than configured by Heeler; link handling is Heeler's own `TerminalLink.url(for:)` (`TerminalScreenView.swift:9-10`), not a Ghostty config string.

## 9. Background/foreground behaviour
- `Sources/Heeler/Support/AppActivityCoordinator.swift`: `AppActivityPhase` (`.active`/`.suspended`, line 14-17) and `AppActivityEvent` (`.activated`/`.suspended`, line 35-38). Backgrounding opens a UIKit background-execution grace period (comment lines 7-13); connections are torn down only once the grace period elapses (ADR 0011 "deliberate teardown"), driven by `BackgroundExecutionGranting`/`UIKitBackgroundExecutionGranter` (line 46-80, `beginBackgroundTask`).
- `Sources/Heeler/Support/ConsoleActivityDriver.swift` consumes activity events to resume/suspend Host connections (driven from `ContentView.swift` `.task` per its own doc comment).
- Per-screen reaction: `AgentTerminalView.swift:1228` `attach.didBecomeActive(afterPossibleSuspension:)`; `ShellTerminalView.swift:191-194` same pattern for shell terminals (see §2 "Reconnect/restoration" above for the shell-specific re-attach logic).

## 10. Tests touching the above
- Navigation/Console: `Tests/HeelerTests/ConsoleDetailPresentationTests.swift`, `ConsoleStoreTests.swift`, `SidebarConsoleIntegrationTests.swift`, `ConsoleHostSectionHeaderPresentationTests.swift`, `ConsoleHostStatusPresentationTests.swift`, `ConsoleListPresentationStoreTests.swift`.
- Shell/attach/command-building: `Tests/HeelerTests/ShellTerminalStoreTests.swift`, `TerminalAttachTests.swift`, `HeelerSSHTransportBehaviorE2ETests.swift`, `HeelerSSHDirectStreamLocalE2ETests.swift`, `HeelerSSHJumpHostGateE2ETests.swift`, `HeelerSSHErrorMappingTests.swift`, `HerdrHostPathTests.swift`, `WakeCommandTests.swift`, `SSHSourcePolicyTests.swift`.
- Host model/store: `Tests/HeelerTests/HostStoreTests.swift`, `HostDraftTests.swift`, `HostOnboardingStoreTests.swift`.
- Input chrome/keyboard: `Tests/HeelerTests/AgentDirectInputTests.swift`, `AgentInputModeSettingsTests.swift`, `TerminalKeysKeyboardTests.swift`, `MessageJumpControlTests.swift`.
- Font/zoom: `Tests/HeelerTests/TerminalZoomSettingsTests.swift`.
- Background/resume: `Tests/HeelerTests/AppActivityCoordinatorTests.swift`, `AppForegroundRecoveryTests.swift`, `ContentViewActivityDriverTests.swift`, `AgentSurfaceReplacementTests.swift`, `WeakNetworkE2ETests.swift`.
- Misc adjacent: `SettingsViewTests.swift` (font/theme/zoom settings UI), `TransportErrorPresentationTests.swift`, `PinnedAgentsStoreTests.swift`, `StartAgentStoreTests.swift`, `NotificationPreferencesStoreTests.swift`, `NotificationKeyStoreTests.swift`, `AgentNotificationRendererTests.swift`, `GeneratedWireTypesTests.swift`, `ImageStagingE2ETests.swift`.

Scope covered: whole `Sources/Heeler` tree per the brief (Demo/, Console/, Hosts/, Transport/, Terminal/, Settings/, Support/, Notifications/, ContentView.swift). `Packages/HeelerSSH` and `Packages/GhosttyTerminal` consulted only where Sources/Heeler code calls into them (openPTY/TerminalConfiguration signatures) — they are separate packages, not part of Sources/Heeler.
