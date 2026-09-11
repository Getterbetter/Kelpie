---
source: "delegate-20260910-191536/r2-build/SPEC2.md — round 2 build spec, 2026-09-11 08:52"
---

# Kelpie round 2 spec: herdr's own screen is the app

Project /Users/anthonytopalides/Developer/Kelpie, branch `kelpie`, clean at commit 40c0682. Round 1 (commits bb1aece..01a7923) added iPad pointer right-click, long-press right-click, trackpad scroll and the split-view collapse; keep all of it.

Anthony's verdict after using round 1 on his iPad with a Magic Keyboard: Heeler's native console (agent list, per-agent terminal, composer, bottom agent-switcher bar) is not what he wants as the main screen. He wants exactly what his Mac terminal shows: the full herdr TUI with its own workspaces/agents sidebar, tabs and panes, full-screen, and the iPad just makes interacting with it seamless. Heeler's native console stays reachable behind one button (it powers push and Live Activities). Decisions he made: (1) keep console behind a toolbar button, (2) keyboard mode is automatic from hardware-keyboard presence, (3) font sizing is my call, (4) URLs in the terminal must be tappable and open in the iPadOS default browser, no in-app browser.

Reference maps (read first, they carry file:line anchors):
- ../r2-navmap/navmap.md  (navigation, attach command builder, host model, input chrome, resume behaviour, tests)
- ../r2-ghostty/findings.md (Ghostty link delegates, hardware keyboard routing, herdr CLI facts)
- ../ipad/SPEC.md and ../ipad/notes.md (round 1, incl. the build recipe at the end; use that recipe, it is the only one that works on this Mac)

Established facts you can rely on:
- Full herdr client over SSH = bare `herdr`, plus `--session "<name>"` when Host.sessionName is non-empty; HERDR_SOCKET_PATH is already exported by HeelerSSHTransport.attachExecCommand (HeelerSSHTransport.swift:2141-2199) which also prefixes PATH via HerdrHostPath.pathExport and prints the AttachBootstrapHandshake marker. `herdr agent attach`/`herdr terminal attach` are single-pane attaches; the client is a different target.
- herdr uses SGR mouse, keeps its own scrollback, opens URLs it is clicked on with `open` ON THE MAC (src/client/shell_runtime.rs); we must intercept taps on URLs client-side so they open on the iPad and never reach herdr as clicks.
- Ghostty on iOS never opens links itself; it only calls TerminalSurfaceOpenURLDelegate.terminalDidRequestOpenURL (already wired by Heeler to SwiftUI openURL via HeelerTerminalView.onOpenLink, TerminalScreenView.swift:170,267,1974) and there is NO "link at point" query in ghostty.h. Viewport text is readable via the in-memory session's readViewportText() (used by round 1's two-finger selection).
- Hardware keys already reach the PTY through Ghostty (TerminalHardwareKeyRouter; Ctrl+letter via priority UIKeyCommands). No hardware-keyboard-presence state exists anywhere; add it with GameController's GCKeyboard.coalesced plus GCKeyboardDidConnect / GCKeyboardDidDisconnect notifications.
- ContentView.swift:99 builds ConsoleView as the root unconditionally; hosts are managed in a sheet (HostListView); AgentDetailView.swift:98-137 switches ShellTerminalView vs AgentTerminalView; ShellTerminalStore.didBecomeActive(afterPossibleSuspension:) re-attaches on resume (ShellTerminalStore.swift:343-365) and is the pattern to copy.
- Default terminal font is 8 (TerminalZoomSettings.swift), pinch zoom persists to UserDefaults.
- herdr's ui.mobile_width_threshold is 64 columns (single-column layout below it). Sidebar width 26 cols, toggled with prefix+b.

## Deliverables

### 1. HerdrClientView + HerdrClientStore (new, Sources/Heeler/Client/)
A full-screen terminal running the herdr client for one Host.
- New TerminalAttachTarget case (e.g. `.client(session: String?)`) and a matching branch in HeelerSSHTransport.attachCommand/attachExecCommand producing `exec herdr` or `exec herdr --session "<name>"` (quote safely, same style as the existing target quoting). Never `--takeover`. Add `export COLORTERM=truecolor; export LANG="${LANG:-en_US.UTF-8}";` to the sh -c preamble for ALL targets (herdr needs truecolor and UTF-8 for its box drawing; a non-login SSH exec often has neither). Keep the handshake marker.
- HerdrClientStore mirrors ShellTerminalStore: owns the attach session for a Host, exposes the terminal store the TerminalScreenView needs (AttachTerminalStore or whatever ShellTerminalView uses), re-attaches after possible suspension, surfaces connection errors the way ShellTerminalView does, and reconnects with a visible "Reconnect" affordance on failure.
- HerdrClientView: TerminalScreenView filling the whole screen (ignores safe area horizontally, respects the bottom keyboard inset), navigation bar hidden, status bar visible. No agent switcher bar, no composer, no message-jump control. Software keyboard rises when the terminal is tapped and there is no hardware keyboard, exactly like ShellTerminalView.
- Font: on a regular-width (iPad) window default the terminal font size to 12 when the user has never zoomed; iPhone keeps 8. Implement in TerminalZoomSettings as an idiom/size-class-aware default without changing the persisted-value semantics. Pinch zoom still persists.
- Initial and resize cols/rows come from the terminal grid exactly as for shell terminals.

### 2. Root navigation (ContentView.swift)
- Root becomes HerdrClientRootView: if the HostStore has no hosts, show whatever ConsoleView shows today for the no-host / onboarding case (mirror it; do not redesign). Otherwise show HerdrClientView for the "primary" host: a persisted Host.ID in UserDefaults ("kelpie.primary-host"), defaulting to the first host and healing itself if that host was deleted.
- A floating circular button, top-right, 36pt, `ellipsis.circle` symbol, 55% opacity resting, full opacity on hover/press, 12pt inset from the safe area, over the terminal (it sits over the empty right end of herdr's tab strip; keep it small). It opens a Menu: "Agents" (present ConsoleView in a fullScreenCover, keeping all of its own behaviour), "Hosts" (HostListView sheet, as ConsoleView presents it), "Switch host" submenu listing hosts (sets primary), "Settings" (SettingsView sheet), "Reconnect".
- Notification deep links: ConsoleView relies on notificationRouter.path. When the app is opened from a notification (path becomes non-empty) present the Agents cover automatically so the existing routing lands on the agent; when the cover is dismissed, clear the path. Live Activities and push keep working because ConsoleStore stays alive; check that whatever ConsoleView needs alive at root (ConsoleStore, activity driver in ContentView .task) is still created at root even when the cover is not shown, and say in notes where that happens.
- The round-1 columnVisibility logic in ConsoleView stays as is (it now only applies inside the Agents cover).

### 3. Automatic keyboard mode
- New `HardwareKeyboardObserver` (@Observable, @MainActor): `isConnected` from GCKeyboard.coalesced != nil at init, updated by the two GameController notifications. Inject via environment.
- HerdrClientView: when connected, no on-screen control pad and the terminal becomes first responder on appear (hardware keys flow; no software keyboard appears). When not connected, show TerminalControlPadView (Esc, Tab, arrows, Ctrl, the existing pad) above the software keyboard, as the shell terminal does today. React live to connect/disconnect.
- Agents console (AgentInputModeSettings): add `.automatic` as the default for installs with no stored choice; it resolves to `.direct` when a hardware keyboard is connected and `.composer` otherwise. An explicit user choice in Settings still wins and persists as before. Update the Settings picker to offer Automatic / Composer / Keyboard. Update AgentInputModeSettingsTests accordingly.
- Two bugs Anthony hit in the console with a hardware keyboard attached: (a) the composer appeared centred on screen with no software keyboard, (b) in Keyboard (direct) mode, pressing Return on the hardware keyboard did not submit. With .automatic (a) no longer occurs by default; for (b) read AgentDirectInputChrome / the direct-input text field and make hardware Return submit (onSubmit or the UIKit equivalent). If (b) needs more than ~30 lines, note it and skip.

### 4. Tappable links (open in the iPadOS default browser)
- New `TerminalLinkDetector` (pure, testable): given the viewport text (rows split on newline) and a 1-based (column, row), returns the http/https URL whose span covers that column on that row, or nil. Match `https?://[^\s<>"'`]+`, strip trailing `.,;:!?)]}'"` , and when a match runs to the end of a row and the next row starts with non-space, join the two rows for that match (wrapped URLs). Apply TerminalLinkPolicy.url(for:) to the result.
- In HeelerTerminalView:
  a. Direct touch tap (tapAction/handleTap path): before sending a remote left click or raising the keyboard, run the detector on session.readViewportText() at the tapped cell; if it yields a URL call onOpenLink(url) and stop (no click to herdr, no keyboard raise). Applies regardless of tracksMouse.
  b. Indirect pointer primary button: in touchesBegan, if the began location's cell has a URL, own the touch sequence exactly like round 1's right-click ownership (don't forward began/moved/ended to super), and on touchesEnded open the URL if the ended cell still resolves to the same URL, else drop it. Other primary-button touches are untouched.
  c. Keep terminalDidRequestOpenURL as is.
- Make sure the sh -c/herdr side is not asked to open: nothing to change on the Mac; we simply never send the click.

### 5. Tests (Tests/HeelerTests, existing style)
- attachExecCommand for the client target with and without a session name (exact string), and that COLORTERM/LANG exports are present for all targets (update existing TerminalAttachTests / transport tests that assert the command string).
- TerminalLinkDetector: URL at column inside/at edges, trailing punctuation stripped, wrapped URL joined, non-URL cell returns nil, ftp:// ignored.
- AgentInputModeSettings .automatic resolution with a stubbed keyboard-connected flag.
- Primary host selection: default first host, persisted choice, healing after deletion.
- Run the unit tests on 'platform=iOS Simulator,name=iPhone 17' (the iPad simulator does not work on this Mac). Build the app for the iPad simulator with the round-1 recipe. Both must pass before you finish.

### 6. Docs and commits
- docs/adr/0017-herdr-client-is-the-screen.md (decision, why the console is demoted not removed, link interception rationale, automatic keyboard mode). CHANGELOG "Kelpie" section: add entries.
- Update CLAUDE.md's Kelpie section with one paragraph on the new root flow.
- New Swift files require `xcodegen generate`; commit the regenerated Heeler.xcodeproj with them. Logical commits on `kelpie`, ending each message with:
Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01UCKuKzzfLucRJEGyMbdvrR
- Never push, never add a remote, never edit Packages/GhosttyTerminal or Packages/HeelerSSH.

Swift 6 strict concurrency. Match the existing code and comment style. Concise code, no feature flags, no speculative options. Keep the diff focused on the six items above.
