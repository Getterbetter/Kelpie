# Resume: Kelpie

Read this first in a new session started in `~/Developer/Kelpie`. Full documentation lives in the Obsidian vault at `KelpieVault/` (start at `KelpieVault/Kelpie.md`). Project rules for Claude are in `CLAUDE.md` (Kelpie section at the top).

## Where things stand (2026-09-11)

- Kelpie is a private iPadOS fork of Heeler, an SSH client for herdr. Branch `kelpie`, 18 commits on top of upstream Heeler (including the vault), remote `upstream` only, nothing pushed anywhere.
- Round 1 (2026-09-10): rebrand, iPad target, trackpad right-click → herdr's menu, touch long-press → right-click, two-finger long-press → selection sheet, trackpad/mouse-wheel scrolling, sidebar collapse. Reviewed, two fixes applied.
- Round 2 (2026-09-11): herdr's own TUI is the root screen (full-screen terminal running `herdr` over SSH), Heeler's console demoted behind a floating `ellipsis.circle` menu (Agents, Hosts, Switch host, Settings, Reconnect), automatic keyboard mode from hardware-keyboard presence, tappable URLs opening in the default browser, 12pt default font on iPad. Reviewed, six fixes applied (commit `58199a7`).
- Round 3 (2026-09-11, commit `77cabda`): from round-2 feedback. Escape and Cmd+. now reach herdr (claimed as priority `UIKeyCommand`s on `HeelerTerminalView`; iPadOS's text-input system consumed them), Option+Backspace / Option+arrows / Option+Fn+Delete send ESC-prefixed word keys (`TerminalHardwareKeyMapping`, unit-tested), and the floating menu is a labelled host capsule with Switch Host and Hosts first. Reviewed, three fixes applied. Onboarding is a proposal in `KelpieVault/Onboarding proposal.md`, not built.
- Round 3b (2026-09-11, same day): Cmd+. fixed for real (`5afab42`) — his Magic Keyboard has no Escape key, and iPadOS delivers Cmd+. as a press with `UIKeyInputEscape` characters; confirmed on the device. `TerminalKeyTrace` (off unless launched with `-kelpie.key-trace YES`) is the keystroke trace that found it; pull it with `devicectl device copy from`. Welcome screen + paste-first pairing + QR fixes built and reviewed (five fixes applied), commit after `5afab42`. Option+Backspace and the host capsule confirmed working by Anthony.
- Round 4 (2026-09-11): photos and files into a herdr pane — paste incl. Cmd+V, drop, Attach Photo/File in the menu → SFTP staging (upstream's) → path typed into the pane. Reviewed, six fixes applied. Also written, not built: `KelpieVault/Mac vs iPad gaps.md` (ranked gap list) and `KelpieVault/Window size workshop.md` (Split View / Slide Over / Stage Manager options; two questions for Anthony).
- Round 5 (2026-09-11): the Mac-vs-iPad gap list, implemented: all four iPad orientations (the cause of the window keeping its shape — Split View now works, confirmed), resize coalescing, width-aware font, icon-only capsule under 500 pt, drop-from-Files fix, Cmd+arrows as Home/End/Page keys, bell haptic, herdr desktop notifications (needs `ui.toast.delivery = "terminal"` on the mini — gated), host file viewer (tap a path or the menu → SFTP → Quick Look + share). Two builders in parallel with file ownership, one reviewer, six fixes. Not done: Stage Manager multi-window (stores per scene), finger drag as mouse drag.
- Round 6 (2026-09-11): touch text selection with handles (Kelpie-drawn overlay over the grid, copied from viewport text — Ghostty's selection is internal to the vendored package) and one-finger hold-then-drag as a left-button mouse drag (sidebar/pane resize by touch), with a visual ring since iPads have no haptics. Sidebar *taps* always worked; the ask was resizing. Two reviews, all findings applied. ADR 0016 amended. The trace facility (`-kelpie.key-trace YES`) now logs mouse reports too — launch with `xcrun devicectl device process launch --device <id> --terminate-existing TME.Kelpie -- -kelpie.key-trace YES`.
- Since round 4, builds and installs are run by sonnet-runner sub-agents at Anthony's request ("we hit a safeguard, use a sub agent").
- Round 6b (2026-09-11): two device fixes — the hold cue was stretched to the whole screen because the vendored `UITerminalView` sets every sublayer's frame to its bounds (any subview added to `HeelerTerminalView` must be a full-bounds container with the real content as an inner subview — a load-bearing quirk, see `TerminalHoldCueView`); touch selection is now clamped to the pane's box-drawing borders around the anchor so it no longer spans the sidebar.
- Round 6c: hold ring enlarged to 64 pt ("the ring is good"); pane-bounded selection confirmed. The mini's data volume hit 97% mid-build (the parallel builds each kept a derived-data tree); this session's scratch trees were deleted and Anthony has a separate session handling disk space. **Use one derived-data path per session from now on** (`<scratchpad>/build/kelpie-dd`), not one per builder.
- The latest Release build (round 6c, commit `53c6821`) is installed on the iPad and everything in rounds 3–6 has been confirmed on the device except: Cmd+arrows as Home/End/Page keys, the bell haptic, the Quick Look file viewer, desktop notifications (gated on the mini config), and the Welcome root with zero Hosts. Not yet seen on the device: media intake, the Welcome screen (via Setup Guide), paste-first pairing, and whether copying text in herdr reaches the iPad clipboard.

## What Anthony will bring

Feedback from using round 2 on the iPad with a Magic Keyboard. Things to ask about if he doesn't mention them:
trackpad two-finger scroll inside a pane, trackpad right-click opening herdr's menu, one-finger long-press, tapping a URL, keyboard pad appearing when the Magic Keyboard is detached, Ctrl+B prefix working, the floating menu, the Agents cover, whether Return submits in the old console's Keyboard mode (partial fix only).

Record his feedback in `KelpieVault/Feedback log.md` under "Round 2 feedback" before acting on it.

## How to work on it

- Never use the iOS simulator on this Mac (it wedges). Build and run on the iPad:
  ```
  S=<a scratch dir>
  xcodebuild build -project Heeler.xcodeproj -scheme Heeler -configuration Release \
    -destination 'platform=iOS,id=09D7738D-2173-55EF-8966-A9C3EA1D0514' \
    -clonedSourcePackagesDirPath $S/kelpie-spm -derivedDataPath $S/kelpie-dd -allowProvisioningUpdates
  xcrun devicectl device install app --device 09D7738D-2173-55EF-8966-A9C3EA1D0514 $S/kelpie-dd/Build/Products/Release-iphoneos/Kelpie.app
  xcrun devicectl device process launch --device 09D7738D-2173-55EF-8966-A9C3EA1D0514 TME.Kelpie
  ```
  Run xcodebuild in the background with output to a log file and read only the tail. Always pass both path flags; two builds sharing a derived-data path lock each other out.
- New Swift files need `xcodegen generate`; commit the regenerated `Heeler.xcodeproj`. `make generate` also fetches the vendored libghostty binary if missing.
- `Packages/GhosttyTerminal` is vendored; never edit it, override its `open` members from `HeelerTerminalView` (see `docs/adr/0016-ipad-pointer-input.md`).
- Unit tests compile but could not be executed this round (simulator). If a simulator ever boots, the test recipe is the build recipe with `test` and an iPhone destination.
- Working pattern that suited this project: `/delegate` with Sonnet scouts for code maps, an Opus builder given a complete spec, an Opus reviewer in a fresh context, then a Fable-written spec and triage. Specs and reviews from both rounds are archived in `KelpieVault/Archive/`.

## If starting a new session

Context in the long session that did rounds 3–6 was at ~45% when this was written; a new session loses nothing. Read this file, then `KelpieVault/Open items.md` (item 1g is the device checklist for round 6), `KelpieVault/Feedback log.md` (every round's verbatim feedback), and `KelpieVault/Mac vs iPad gaps.md`. Working pattern that held up: `/delegate` with Opus builders given a complete spec and strict file ownership when two run in parallel, an Opus reviewer in a fresh context, Fable triage; builds and device installs go through sonnet-runner sub-agents (Anthony asked for that after a permission safeguard). The keystroke/mouse trace (`-kelpie.key-trace YES`, pulled with `devicectl device copy from`) is the device diagnostic that has settled every "it doesn't work" so far.

## Open items, in priority order

0. **Git remote and push.** Anthony (2026-09-11): "not sure if we're using git for this project but we should." We are: every round is a commit on `kelpie` (32 commits ahead of upstream `main`, all local). Nothing is pushed because the only remote is `upstream` (Heeler). Next session: ask him for the destination — a private GitHub repo under his account (`gh repo create TME/Kelpie --private --source . --remote origin --push`, or his own name) — and push `kelpie` with his explicit yes. Until then, `git log` on this Mac is the only copy.

1. Remaining device checks (list in `KelpieVault/Open items.md`, items 1a–1g), then the two gates below.
2. Return-to-submit in the console's Keyboard mode (partial fix, needs device confirmation).
3. Own push relay: deploy `relay/` as a Cloudflare Worker with Anthony's APNs key and point the app at it. Outward-facing, needs his explicit yes. Required for any App Store build.
4. TestFlight upload (needs his yes; `scripts/ExportOptions.plist` already carries team 8JQWBQKEXX).
5. Rebase on Heeler upstream periodically; it moves daily. Consider a PR upstream for the iPad work (his call).
6. Reviewer nits not yet taken: listed in `KelpieVault/Open items.md`.

## Key facts to not rediscover

- Heeler's console still powers push notifications and Live Activities; that is why it was demoted, not removed.
- herdr opens clicked URLs on the Mac with `open`; Kelpie intercepts URL taps client-side so they open on the iPad and never reach herdr as clicks.
- Ghostty on iOS has no "link at point" query; `TerminalLinkDetector` scans the viewport text instead.
- A trackpad right-click is claimed entirely by `HeelerTerminalView` while the remote app tracks the mouse, because Ghostty otherwise shows an iPadOS copy menu instead of forwarding it.
- Pairing: install the upstream Heeler plugin on the mini, `herdr plugin action invoke heeler.pair` opens a popup inside herdr's TUI; the QR was not recognised but pasting the Pairing Code via iCloud clipboard worked.
