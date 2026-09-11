---
source: "delegate-20260910-191536/heeler/findings.md — scout report on Heeler's architecture, 2026-09-10 19:18"
---

# Heeler architecture findings

Repo cloned (depth 1) to .../heeler/repo. HEAD commit at clone time:
2026-09-10 01:11:23 +0800, "docs(readme): download buttons, Trendshift badge, App Store status (#296)".
GitHub API: 290 stars, 31 open issues, license Apache-2.0, pushed_at 2026-09-09T17:23:19Z.

## 1. Framework / project / iPad support
- SwiftUI, Swift 6 (strict concurrency). README.md "## Stack": "SwiftUI, iOS 18+, iPhone today (iPad planned)".
- Project generated via XcodeGen from project.yml (root) into Heeler.xcodeproj/project.pbxproj. SPM packages: local Packages/HeelerSSH, remote GhosttyTerminal (github.com/lakr233/libghostty-spm, pinned revision).
- Min deployment target: iOS 18.0 (project.yml line ~5 deploymentTarget.iOS: "18.0"; Heeler.xcodeproj/project.pbxproj IPHONEOS_DEPLOYMENT_TARGET = 18.0).
- iPad NOT a supported destination for the main app: project.yml line 81 TARGETED_DEVICE_FAMILY: "1" with comment "iPhone only. App Store Connect derives device support from the build."; same in Heeler.xcodeproj/project.pbxproj (both Debug/Release configs of the Heeler target, e.g. line 2013, 2039 = "1"). HeelerNotificationService extension target is also "1" (project.yml ~line 135, comment "Match the containing app's iPhone-only device family"). Two configs at project.pbxproj lines 2157/2174 = "1,2" belong to the HeelerWidgets extension (WidgetKit/Live Activity), not the app itself.
- INFOPLIST_KEY_UISupportedInterfaceOrientations = Portrait + LandscapeLeft + LandscapeRight (project.yml line 84, project.pbxproj line 2031/2193) - no UIRequiresFullScreen key found.
- Some @Environment(\.horizontalSizeClass) == .regular branches already exist (Sources/Heeler/Console/AgentDirectInputChrome.swift:85, Sources/Heeler/Console/AgentTerminalView.swift:953) - adaptive layout code for wide/regular width already present, a plausible starting point for iPad but not iPad enablement itself.

## 2. SSH layer
- Custom local Swift package Packages/HeelerSSH wrapping libssh2 + OpenSSL (checked-in prebuilt xcframeworks: Packages/HeelerSSH/Artifacts/CLibSSH2.xcframework, COpenSSL.xcframework). README: "The repository-local Packages/HeelerSSH (libssh2 + OpenSSL) for SSH". Not NMSSH/Citadel/SwiftNIO SSH.
- Core driver: Packages/HeelerSSH/Sources/HeelerSSH/SessionDriver.swift; public API in SSHConnection.swift.
- Auth: both password and public-key -
  - SSHConnection.swift:108 authenticate(username:password:timeout:)
  - SSHConnection.swift:119 authenticate(username:publicKey:signer:timeout:) (signer closure; device-generated key + external signing, matches README "keys are generated on device").
- PTY / shell: SessionDriver.swift configurePTY(...) calls libssh2_channel_request_pty_ex (~line 3172); interactive terminal runs `herdr agent attach --takeover` on that PTY (Sources/Heeler/Transport/HeelerSSHTransport.swift:2171 builds the takeover flag; Sources/Heeler/Transport/SSHTransportSettings.swift:11 defaultAttachCommand = "herdr agent attach").
- Window resize / SIGWINCH: SSHPTYChannel.swift:36 resize(columns:rows:timeout:) -> SessionDriver.swift:624 resizePTY(...) -> libssh2_channel_request_pty_size_ex (SessionDriver.swift:647). This is libssh2's PTY-size request channel message, not a raw SIGWINCH signal.
- JSON API to herdr is separate from the PTY path - SSHConnection.swift:176/199 open "direct-streamlocal" channels via libssh2_channel_direct_streamlocal_ex (SessionDriver.swift:3082) onto herdr's Unix socket. See section 4.

## 3. Terminal emulation
- libghostty (Ghostty's terminal engine) via the GhosttyTerminal SPM package (github.com/lakr233/libghostty-spm, pinned commit 356f730bec03281fc7b83666a129b0246137ea26, project.yml packages block). README: "libghostty-spm for terminal emulation and Metal rendering".
- Embedded/wrapped throughout Sources/Heeler/Terminal/ (e.g. TerminalScreenView.swift, TerminalByteFeed.swift, TerminalOrphanSurfaceLayers.swift, TerminalMouseReporting.swift all reference Ghostty's UIKit surface, e.g. comment in TerminalMouseReporting.swift:5-7 "Ghostty's UIKit layer only turns indirect pointers ... into mouse events"). Rendering is Metal-based; native scrollback provided by libghostty itself (not xterm.js/WKWebView).

## 4. herdr-specific integration
- Two distinct paths, both over the one SSH connection:
  1. JSON API: Sources/Heeler/Transport/Transport.swift - direct-streamlocal channels to ~/.config/herdr/herdr.sock (default) or ~/.config/herdr/sessions/<name>/herdr.sock (named session), lines ~662-677. One long-lived channel carries an event stream (Sources/Heeler/Transport/EventsSession.swift, HerdrEvents.swift). Wire/type layer: Sources/Heeler/Transport/HerdrWire.swift, generated types in Sources/Heeler/Transport/Generated/HerdrAPITypes.swift.
  2. Interactive attach: runs `herdr agent attach --takeover` (or `herdr terminal attach`, per TerminalScrollControl.swift comment) directly as the remote command on an SSH PTY (SSHTransportSettings.swift:11, HeelerSSHTransport.swift:2171) - herdr is exec'd as a normal shell command over the PTY channel, raw bytes both ways (Transport.swift:147 comment).
- No separate herdr binary protocol beyond the JSON API framed over the streamlocal channel; Sources/Heeler/Hosts/Preflight.swift checks socket presence and gives user-facing errors if herdr isn't running (lines 12, 92, 97, 102).
- Onboarding installs a herdr plugin (plugin/ dir, README: `herdr plugin install ZingerLittleBee/Heeler/plugin`) for QR pairing and encrypted push notifications.

## 5. Input handling
- Touch/scroll: Sources/Heeler/Terminal/TerminalTouchScroll.swift and TerminalScrollControl.swift. Context-sensitive:
  - On the primary screen, local libghostty scrollback is used (native momentum scroll) - no wire traffic (TerminalScrollControl.swift comment: "remote wheel reports would be the wrong tool" on primary screen; isAlternateScreen mirrors DECSET 1049/47/1047).
  - On the alternate screen (TUIs - herdr attach always alternate-screen), touch scroll is translated into terminal mouse-wheel escape sequences via Sources/Heeler/Terminal/TerminalMouseReporting.swift (TerminalMouseEncoding: legacy DECSET 1000 ESC[M... and SGR DECSET 1006 ESC[<b;col;rowM/m, wheelUp/wheelDown button codes), falling back to cursor-key sequences if the remote app didn't request mouse tracking.
  - Grid coordinate mapping for touches uses TerminalGridPointMapper (same file), reverse-engineered against libghostty's fixed padding constants.
- Long-press / selection: Sources/Heeler/Terminal/TerminalTextSelectionPresenter.swift (text selection UI over the terminal surface); tap-target logic for raising the keyboard is in TerminalTouchScroll.swift (TerminalKeyboardTapTarget, alternate-screen caret-band heuristics).
- Keyboard: custom "tools keyboard" with tabs - Controls/Skills/Snippets/Appearance - in Sources/Heeler/Terminal/TerminalKeysKeyboard.swift and TerminalKeyboard.swift; a separate Composer for drafting (full iOS keyboard w/ autocorrect/IME/dictation per README) then "Send once".
- No hardware-keyboard-specific code found: no UIKeyCommand, GCKeyboard, or "hardwareKeyboard" hits anywhere under Sources/ (full-tree grep) - external keyboard shortcut handling appears absent or minimal.
- No explicit contextMenu/long-press-menu SwiftUI modifiers found beyond the custom text-selection presenter; grep for contextMenu/UILongPressGestureRecognizer hit only unrelated files (Snippets/Skills pickers, agent switcher, console list) - no terminal-specific native context menu found.

## 6. Connection storage
- Host records (hostname, port, username, session name, etc. - no secrets) stored in UserDefaults (Sources/Heeler/Hosts/HostStore.swift:13-14,29,33-34, comment: "...to UserDefaults (no secrets in them); passwords go straight to the injected SecretStore (the Keychain in the app), keyed by Host id.").
- Passwords and the device SSH key stored in Keychain, generic-password items, ThisDeviceOnly accessibility (no iCloud Keychain sync) - Sources/Heeler/Transport/SecretStore.swift (KeychainSecretStore, comment ~42-50), Sources/Heeler/Transport/DeviceKeyStore.swift, DeviceKey.swift. Keychain service string dev.bybee.heeler.ssh (HostStore.swift:34). Notification Service Extension shares Notification Keys via Keychain access group group.dev.bybee.heeler.shared (project.yml entitlements block for HeelerNotificationService).
- No SwiftData usage found for Hosts (grep for @Model/SwiftData in Hosts/Settings returned nothing).

## 7. License / stars / last commit / README claims
- License: Apache License 2.0 (repo/LICENSE; GitHub API spdx_id Apache-2.0).
- Stars: 290 (GitHub API stargazers_count, checked live via gh api).
- Last commit (this clone's HEAD, depth 1): 2026-09-10 01:11:23 +0800 (git log -1); GitHub API pushed_at: 2026-09-09T17:23:19Z.
- README.md explicitly states current scope/limits: "SwiftUI, iOS 18+, iPhone today (iPad planned)" - maintainer already flags iPad as future work, not yet shipped. README also documents prerequisites: herdr running on target machine, SSH server with stream-local forwarding enabled (OpenSSH default), Node >= 20, herdr >= 0.7.5.
- README "How it connects" section is the authoritative description of the SSH/herdr wiring and matches the code (section 4 above).

## 8. iPad-hostile signals
- Hard block: TARGETED_DEVICE_FAMILY = "1" on the main app target (both project.yml and generated project.pbxproj) - App Store Connect will not offer iPad installs regardless of code readiness (see section 1).
- No UIRequiresFullScreen found, and orientations already include landscape, which is iPad-friendly once the device family flag is changed.
- Partial adaptive-layout groundwork exists (horizontalSizeClass == .regular branches in AgentDirectInputChrome.swift and AgentTerminalView.swift) suggesting some regular-width handling already, but exercised today only via large-iPhone landscape/multitasking, not verified against iPad's typical size classes.
- No UIDevice.current.userInterfaceIdiom checks found anywhere (only UIDevice.current.playInputClick() calls for haptics in TerminalKeyboard.swift:290, AgentDirectInputChrome.swift:145, ShellTerminalView.swift:102) - the iPhone-only restriction is purely the build-setting device family, not scattered idiom checks in code.
- Terminal touch/mouse-reporting math (TerminalMouseReporting.swift, TerminalGridPointMapper) is calibrated against libghostty's fixed constants, not against screen size - should scale to iPad screens, but untested (no iPad build/target exists to verify).
- File inventory suggests a single-pane navigation flow for host list + agent console (Sources/Heeler/Console/, Sources/Heeler/Hosts/HostListView.swift), not NavigationSplitView - flagged as a likely (not fully verified) iPad UX gap; not read line-by-line for this claim.
