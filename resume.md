# Resume: Kelpie

Read this first in a new session started in `~/Developer/Kelpie`. Full documentation lives in the Obsidian vault at `KelpieVault/` (start at `KelpieVault/Kelpie.md`). Project rules for Claude are in `CLAUDE.md` (Kelpie section at the top).

## Where things stand (2026-09-12)

- Kelpie is a private iPadOS fork of Heeler, an SSH client for herdr. Branch `kelpie`, 56 commits on top of upstream Heeler `375267c` (36 at the round-7 rebase) (including the vault), remotes `origin` (Getterbetter/Kelpie, public) and `upstream` (Heeler).
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
- Round 7 (2026-09-11, `/delegate`): the eight round-2 reviewer nits taken (`98187d3`; one reviewer must-fix applied: the floating capsule is a `Menu`, which only routes a `ButtonStyle` to its label under `.menuStyle(.button)`), then `kelpie` rebased onto Heeler upstream `375267c` (herdr 0.9.0 wire types, muse agent kind, PR #307 paste key cap in the console keyboard). Two `CHANGELOG.md` conflicts, nothing else; Release build clean; installed on the iPad. **Every commit hash quoted above this line is pre-rebase** — they live on tag `kelpie-pre-rebase-20260911`; `git log kelpie` has the rewritten ones. Specs, reviews and the rebase plan are in `KelpieVault/Archive/round7/`. Disk is back to ~31 GB free.
- Round 7b (2026-09-11): Anthony's next ask is the App Store (free, no TestFlight testing, a subreddit for support, donate later). Two recon passes (repo and Apple's 2026 rules) and one builder: visible Heeler text → Kelpie, `NOTICE` + in-app Heeler credit, `PRIVACY.md` for Kelpie, `KelpieLinks`, local-network usage string, relay config on `TME.Kelpie`/8JQWBQKEXX, `publish.sh` env-driven remote/branch, version 1.0 (1). Commit `cc8e38a`. **Read `KelpieVault/App Store plan.md`**: eight decisions for Anthony (iPad-only?, public repo?, reviewer access, own relay, name/subtitle, icon, subreddit name, donate later) and six gates in order.
- Round 7c (2026-09-11): Anthony's answers to the plan recorded in the Feedback log. Built and reviewed: iPad-only target, StoreKit 2 tip jar (`a42e62e`). Icon drafts in `KelpieVault/Archive/round7/icons/` (draft 2 recommended). Waiting on him: public-vs-private repo, the reviewer VPS yes, `wrangler login` in Terminal.app plus an APNs `.p8`, the icon pick. `KelpieVault/App Store plan.md` has the running state.
- Round 8 (2026-09-11 → 12, App Store push, all `/delegate`): repo public at `github.com/Getterbetter/Kelpie` (origin/kelpie); Kelpie's push relay deployed on Anthony's Cloudflare account (`kelpie-apns.getter-tilbury-0m.workers.dev`, APNs key 7RJ68B8QX8 as a Wrangler secret, app + plugin defaults point at it; the plugin pipeline verified end to end with a hand-run hook); icon 2 in the Icon Composer bundle; iPad-only; StoreKit tip jar; App Store Connect record 6811004082 "Kelpie Console" (SKU kelpie, 1.0) fully filled by `scripts/asc-kelpie.py` (categories, subtitle, URLs, age rating, copy, three consumable tips with USD prices); build 1 of 1.0 uploaded and VALID (App Store profiles created via the API, Apple Distribution cert lives in the Thyme keychain `~/Developer/maple-and-salt-agent/config/asc/thyme-dist.keychain-db`, unlock it before `-exportArchive`); App Review host on Hetzner (`kelpie-review`, 5.78.158.22, cpx11 Hillsboro ≈ US$20/month — delete after approval; password in `~/Developer/kelpie-review-host.secret`; staged demo workspaces tidepool/infra/notes; runbook `docs/guides/app-review-host.md`); XCUITest driver lane `scripts/drive-ipad.sh` (the way to drive the iPad, see `docs/guides/driving-the-ipad.md`); 13-inch store panels in `KelpieVault/Design/Store Screenshots/final-13in/`. Pending at close: Anthony runs the three `--apply` uploads (screenshots, IAP screenshots, attach build + review details + attachment) then `--submit` with his word; device checks he will do later (on-screen keyboard Return in a shell pane — a reviewer's only keyboard; whether a notification landed at 20:27 on 2026-09-11; whether the tip sheet lists all three tips — the capture showed Medium and Large only).
- Round 9 (2026-09-12, `/delegate`): resume.md and the vault reconciled against the repo, ASC, the relay and the review host; no live state had drifted, only the docs.
- The latest Release build (round 7c, `a42e62e`) is installed on the iPad and everything in rounds 3–6 has been confirmed on the device except (round 7's nit fixes are also unverified by hand — press-lift on the capsule, padding taps not opening links): Cmd+arrows as Home/End/Page keys, the bell haptic, the Quick Look file viewer, desktop notifications (gated on the mini config), and the Welcome root with zero Hosts. Not yet seen on the device: drag-and-drop from Files onto the terminal, and paste-first pairing. The Welcome screen, media paste and Attach, and clipboard-out are confirmed (Feedback log rounds 3b and 4).

## What is next

- His three `--apply` runs then `--submit`:
  ```
  python3 scripts/asc-kelpie.py --apply --screenshots "KelpieVault/Design/Store Screenshots/final-13in"
  python3 scripts/asc-kelpie.py --apply --iap-screenshots
  python3 scripts/asc-kelpie.py --apply --attach-build --review-details --contact-first … --contact-last … --contact-phone … --contact-email … --review-attachment <file>
  python3 scripts/asc-kelpie.py --apply --submit
  ```
- The device checks he said he would do: on-screen keyboard Return in a shell pane, whether the 20:27 notification on 2026-09-11 landed, whether the tip sheet lists all three tips.
- Record his feedback in `KelpieVault/Feedback log.md` before acting on it.

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

0. ~~Git remote and push~~ **Done 2026-09-11**: public `github.com/Getterbetter/Kelpie`, `origin/kelpie`. Push freely from now on. (Original note kept below.)
0-old. **Git remote and push.** Anthony (2026-09-11): "not sure if we're using git for this project but we should." We are: every round is a commit on `kelpie` (36 commits ahead of upstream `main` after the round-7 rebase, all local). Nothing is pushed because the only remote is `upstream` (Heeler). Next session: ask him for the destination — a private GitHub repo under his account (`gh repo create TME/Kelpie --private --source . --remote origin --push`, or his own name) — and push `kelpie` with his explicit yes. Until then, `git log` on this Mac is the only copy.

1. Remaining device checks (list in `KelpieVault/Open items.md`, items 1a, 1b, 1c, 1f, 1g; 1d and 1e are done), then the two gates below.
2. Return-to-submit in the console's Keyboard mode (partial fix, needs device confirmation).
3. **App Store submission**: `KelpieVault/App Store plan.md` is the checklist; the three `--apply` uploads (screenshots, IAP screenshots, attach build + review details + attachment) and the final `--submit` remain. After approval: delete the Hetzner server (`DELETE /v1/servers/165493403`, token in `~/Developer/hetzner-kelpie.token`) and note it in the plan.
3a. ~~Own push relay: deploy `relay/` as a Cloudflare Worker with Anthony's APNs key and point the app at it. Outward-facing, needs his explicit yes. Required for any App Store build.~~ **Done 2026-09-11**: deployed and keyed on Anthony's Cloudflare account (`kelpie-apns.getter-tilbury-0m.workers.dev`), app and plugin defaults point at it — see round 8 above.
4. ~~TestFlight upload (needs his yes; `scripts/ExportOptions.plist` already carries team 8JQWBQKEXX).~~ **Done 2026-09-12**: build 1 of 1.0 uploaded, VALID.
5. Rebase on Heeler upstream periodically; it moves daily. Done once on 2026-09-11 (round 7) — the recipe that worked: `git tag kelpie-pre-rebase-<date>`, `GIT_EDITOR=true git rebase upstream/main`, resolve `CHANGELOG.md` by keeping both `### Added` lists, `xcodegen generate`, device build. Consider a PR upstream for the iPad work (his call).
6. Reviewer nits: the round-2 set was taken in round 7; the round-1 leftovers in `KelpieVault/Open items.md` are device checks or deliberate.

## Key facts to not rediscover

- Heeler's console still powers push notifications and Live Activities; that is why it was demoted, not removed.
- herdr opens clicked URLs on the Mac with `open`; Kelpie intercepts URL taps client-side so they open on the iPad and never reach herdr as clicks.
- Ghostty on iOS has no "link at point" query; `TerminalLinkDetector` scans the viewport text instead.
- A trackpad right-click is claimed entirely by `HeelerTerminalView` while the remote app tracks the mouse, because Ghostty otherwise shows an iPadOS copy menu instead of forwarding it.
- Pairing: install the upstream Heeler plugin on the mini, `herdr plugin action invoke heeler.pair` opens a popup inside herdr's TUI; the QR was not recognised but pasting the Pairing Code via iCloud clipboard worked.
- MARKETING_VERSION is `1.0`, matching the ASC version; the unit-test target is still universal (`TARGETED_DEVICE_FAMILY 1,2`), which is harmless and deliberate.
