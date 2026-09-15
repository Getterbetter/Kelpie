# Resume: Kelpie

Read this first in a new session started in `~/Developer/Kelpie`. It holds the current state only: rewritten in place at the close of every round, with an `## In progress` section at the top when a round is checkpointed part-way (one round per session, see `CLAUDE.md`). Every round's history is in `KelpieVault/Changelog.md` and `KelpieVault/Decisions.md`; this file as it stood before the 2026-09-13 trim is `KelpieVault/Archive/round14/resume-before-trim.md`. Full documentation lives in the Obsidian vault at `KelpieVault/` (start at `KelpieVault/Kelpie.md`), and open work is in `KelpieVault/Open items.md`.

## Where things stand (2026-09-15, after round 17)

- Kelpie is Anthony's iPadOS and iPhone fork of Heeler, an SSH client for herdr. Branch `kelpie` on `origin` (Getterbetter/Kelpie, public, push freely), rebased onto upstream Heeler v0.1.8 (`b384847`) on 2026-09-15 in round 16, 118 commits on top; `upstream` is Heeler. Every hash quoted in the vault from before round 16 resolves only through the tag `kelpie-pre-rebase-20260915`.
- Round 17 (2026-09-15, main session, commits `794fb65` to the close-out): Open items 34, 35 and 32, all confirmed by Anthony on the iPad in one install. The iPad's on-screen keyboard insets the terminal again: upstream's `4b697cb` (in the rebase) made `TerminalKeyboardInset` measure only against a window a view hands it, and `HerdrClientView` never did; one `.terminalKeyboardInsetWindow` fixes it. A return from the background keeps the last frame on screen until herdr redraws: `HerdrClientView` mounts its Ghostty surfaces through a `ForEach` keyed by surface id, so a pipeline swap keeps the outgoing surface mounted on top (input off, feed silent) until 150 ms after the new terminal reports live; the first try, a `snapshotView`, came back blank on the device (Metal), and is gone. The Connecting card waits a second before it appears. Hardware Shift+Tab reaches herdr as CSI Z through both a `TerminalHardwareKeyMapping` row and a priority `UIKeyCommand`, sharing one claim. Release build on the iPad and the iPhone; 29 unit tests on the iPad; TestFlight build 4 uploaded (`make bump` fixed on the way: it wrote 1 because upstream's new `CFBundleVersion` line matched first). Round 16's write-up is in `Changelog.md` and `Decisions.md`.

## Live services, accounts and gates

- **App Store**: 1.0 and three tips submitted 2026-09-12 02:20 UTC as **Kelpie for herdr** (record 6811004082), waiting for review at last check. Running state in `KelpieVault/App Store plan.md`. After approval, delete the review host below.
- **TestFlight public beta**: `https://testflight.apple.com/join/AkJxAbnJ`, build 4 uploaded 2026-09-15 (round 17; build 3 was 2026-09-13). `make upload` fails "Failed to Use Accounts" on this Mac: export with `scripts/ExportOptions-manual.plist` and upload with `xcrun altool --upload-app` and the API key. The Apple Distribution cert lives in the Thyme keychain (`~/Developer/maple-and-salt-agent/config/asc/thyme-dist.keychain-db`); unlock it before `-exportArchive`.
- **Push relay**: `kelpie-apns.getter-tilbury-0m.workers.dev` on Anthony's Cloudflare account, APNs key 7RJ68B8QX8 held as a Wrangler secret; the app and plugin defaults point at it.
- **App Review host**: Hetzner `kelpie-review` (5.78.158.22, about US$20 a month), password in `~/Developer/kelpie-review-host.secret`, runbook `docs/guides/app-review-host.md`. Delete after approval: `DELETE /v1/servers/165493403`, token in `~/Developer/hetzner-kelpie.token`.
- **Watches**: `com.kelpie.depwatch` daily at 05:45 with `--publish` (`KelpieVault/Dependency watch.md`; issue #3, the upstream rebase, is Open item 21). `com.kelpie.redditwatch` hourly, drafts in `~/.kelpie/redditwatch/drafts/`; mark a comment done with `scripts/redditwatch.py --answered <id>` (`KelpieVault/Reddit watch.md`).
- **Guards**: `make hooks` once per checkout enables the pre-push close-out check (`scripts/check-round-closeout.sh`). Never `git filter-repo` without re-parenting onto upstream afterwards (round 11b).
- **Vendored GhosttyTerminal** is libghostty-spm `7e45d27` (1.6.20260909) with no patches; `KELPIE-PATCHES.md` is gone and the "never edit the vendored package" rule has no exception. The re-vendor recipe is in `KelpieVault/Build and deploy.md`.

## What is next: the action plan (2026-09-15, close of round 17)

Work through these in order, one round per session:

1. **Open item 30, the composer, its own round**: design and decisions in `KelpieVault/Design/Composer text field.md` (mirror per keystroke, off by default with a persisted toggle, Stage 0 first, Return submits). Design done; build next. The keyboard inset it needs is fixed (item 34).
2. **Open item 22, if the Tailscale retry still stalls**: the trace again; residual holes in `KelpieVault/Archive/round14/tailscale-candidates.md`. When it holds, close 22 and 27 together.
3. **The device checklists that never got their session** (Open items 1, 1f, 1g, 1a, 1b, 2, 10, 11, 12, 13, 20, 28): most are believed working from later rounds; one session with the list open on the iPad would close the lot or turn them into real items.
4. **Open item 19, no notification while foregrounded**: read the round-12c behaviour again on the device now that the rebase moved the stores into `HeelerAppModel`.
5. **Community**: reply to every comment the Reddit watch surfaces within the day (drafts in `~/.kelpie/redditwatch/drafts/`, most on threads that are not Anthony's own; the r/ClaudeCode showcase watch surfaces every commenter, which needs a filter); r/ClaudeAI Showcase; r/iPad and r/iosapps his call; Show HN Tuesday US morning.
6. **After App Store approval**: delete the Hetzner review host (`DELETE /v1/servers/165493403`, token in `~/Developer/hetzner-kelpie.token`) and note it in the plan.
7. **Possible follow-ups, not scheduled**: the Connecting card's one-second delay has only been seen on the LAN (try it against a slow Host); the iPhone's keyboard inset after the rebase is unconfirmed; a socket-level SSH keepalive (none exists; app-level 30 s ping only); `kelpie.primary-host` is a literal in two files (`PairingSync.swift`, `PrimaryHostStore.swift`); the Reddit watch's r/ClaudeCode row counts every showcase comment as unanswered.

**Pending on the remote:** round 17's commits are local only; `git push origin kelpie` is a plain fast-forward (the pre-push close-out check runs). CI on the fork runs the suites on the next pull request.

## How to work on it

- Build, install and test on the iPad or iPhone, never the simulator, with the recipe in `KelpieVault/Build and deploy.md`; the rules are in `CLAUDE.md`.
- `KelpieVault/Device regression list.md` is the per-build device checklist.
- The device diagnostics that have settled every "it doesn't work" so far: the keystroke and mouse trace (`-kelpie.key-trace YES`) and the connection trace (`-kelpie.connection-trace YES`), both pulled with `devicectl device copy from` (the connection-trace command is in `KelpieVault/Testing status.md`, round 14).
- A rebase of this size is three Opus builders, not one: each stops at 80 tool calls, and a reviewer at 40, so brief them narrow. The dependency watch's "conflicting files" count is a floor (its dry run stops at the first conflict); read `git merge-tree` before sizing the round.

## Key facts to not rediscover

- Heeler's console still powers push notifications and Live Activities; that is why it was demoted, not removed. Since the v0.1.8 rebase its stores live in upstream's `HeelerAppModel`, which `ContentView` reads.
- herdr opens clicked URLs on the Mac with `open`; Kelpie intercepts URL taps client-side so they open on the iPad and never reach herdr as clicks.
- Ghostty on iOS has no "link at point" query; `TerminalLinkDetector` scans the viewport text instead, and `TerminalSurfaceLinkQuery` moves the core's mouse for OSC 8 links.
- A trackpad right-click is claimed entirely by `HeelerTerminalView` while the remote app tracks the mouse, because Ghostty otherwise shows an iPadOS copy menu instead of forwarding it.
- The root screen keeps a replaced Ghostty surface mounted on top until its replacement paints (`HerdrClientView`'s `ForEach` of mounted surfaces); UIKit's `snapshotView` of the Metal layer is blank, so never reach for it there. The keyboard inset only works for a view that calls `.terminalKeyboardInsetWindow`.
- Since 7e45d27 the vendored package owns the bare Escape key command and hardware keys go through Ghostty's `sendKey`; Kelpie's `interceptHardwareKey` runs first for the chords it maps (Escape, Cmd+., Option word keys, Cmd+arrows).
- Pairing: install the upstream Heeler plugin on the mini, `herdr plugin action invoke heeler.pair` opens a popup inside herdr's TUI; the QR was not recognised but pasting the Pairing Code via iCloud clipboard worked.
- MARKETING_VERSION is `1.0`, matching the ASC version; the unit-test target is universal (`TARGETED_DEVICE_FAMILY 1,2`), which is harmless and deliberate.
