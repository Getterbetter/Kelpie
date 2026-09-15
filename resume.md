# Resume: Kelpie

Read this first in a new session started in `~/Developer/Kelpie`. It holds the current state only: rewritten in place at the close of every round, with an `## In progress` section at the top when a round is checkpointed part-way (one round per session, see `CLAUDE.md`). Every round's history is in `KelpieVault/Changelog.md` and `KelpieVault/Decisions.md`; this file as it stood before the 2026-09-13 trim is `KelpieVault/Archive/round14/resume-before-trim.md`. Full documentation lives in the Obsidian vault at `KelpieVault/` (start at `KelpieVault/Kelpie.md`), and open work is in `KelpieVault/Open items.md`.

## Where things stand (2026-09-15, after round 16)

- Kelpie is Anthony's iPadOS and iPhone fork of Heeler, an SSH client for herdr. Branch `kelpie` on `origin` (Getterbetter/Kelpie, public, push freely), **rebased onto upstream Heeler v0.1.8 (`b384847`) on 2026-09-15 in round 16**, 108 commits on top; `upstream` is Heeler. Every hash quoted in the vault from before round 16 resolves only through the tag `kelpie-pre-rebase-20260915` (the round-15 key bar `88cd333` is now `b3ffd30`, the Tailscale fix `173b356` is `12fe00d`, the iPhone build `4beeecd` is `d00a6c8`).
- Round 16 (2026-09-15, `/delegate`, commits `b063383` to `3aa4e6f`): Open items 25 and 21. GhosttyTerminal re-vendored at libghostty-spm `7e45d27` (1.6.20260909, binary `upstream.82938b633ba6`); the `sendMousePos` patch retired because upstream ships it, so the vendored package carries no patch. Then the rebase: 105 commits replayed, 14 files conflicted; upstream's `HeelerAppModel` now owns the stores, the app stays one window (`UIApplicationSupportsMultipleScenes` false), taps still land on herdr's screen, the key bar writes Kelpie's own byte table, Cmd+arrows and a single Escape command restored after review. Three reviewers, seven findings taken (`Archive/round16/`). Anthony ran the unit tests himself: passed. Release build installed on both devices; the full suite ran on the iPad (2058 tests, 15 issues, none a regression) and Anthony's sixteen hand checks passed (Open item 33 closed). Also this session: the pending push went out (item 16 closed, a plain fast-forward at the time), the Reddit watch was found already loaded since 2026-09-12 (item 17 closed), the composer design was written and its four decisions taken (`KelpieVault/Design/Composer text field.md`, Open item 30), and Open item 32 (hardware Shift+Tab) was logged.

## Live services, accounts and gates

- **App Store**: 1.0 and three tips submitted 2026-09-12 02:20 UTC as **Kelpie for herdr** (record 6811004082), waiting for review at last check. Running state in `KelpieVault/App Store plan.md`. After approval, delete the review host below.
- **TestFlight public beta**: `https://testflight.apple.com/join/AkJxAbnJ`, build 3 uploaded 2026-09-13. `make upload` fails "Failed to Use Accounts" on this Mac: export with `scripts/ExportOptions-manual.plist` and upload with `xcrun altool --upload-app` and the API key. The Apple Distribution cert lives in the Thyme keychain (`~/Developer/maple-and-salt-agent/config/asc/thyme-dist.keychain-db`); unlock it before `-exportArchive`.
- **Push relay**: `kelpie-apns.getter-tilbury-0m.workers.dev` on Anthony's Cloudflare account, APNs key 7RJ68B8QX8 held as a Wrangler secret; the app and plugin defaults point at it.
- **App Review host**: Hetzner `kelpie-review` (5.78.158.22, about US$20 a month), password in `~/Developer/kelpie-review-host.secret`, runbook `docs/guides/app-review-host.md`. Delete after approval: `DELETE /v1/servers/165493403`, token in `~/Developer/hetzner-kelpie.token`.
- **Watches**: `com.kelpie.depwatch` daily at 05:45 with `--publish` (`KelpieVault/Dependency watch.md`; issue #3, the upstream rebase, is Open item 21). `com.kelpie.community watch` hourly, drafts in `~/.kelpie/community watch/drafts/`; mark a comment done with `scripts/community watch.py --answered <id>` (`KelpieVault/Reddit watch.md`).
- **Guards**: `make hooks` once per checkout enables the pre-push close-out check (`scripts/check-round-closeout.sh`). Never `git filter-repo` without re-parenting onto upstream afterwards (round 11b).
- **Vendored GhosttyTerminal** is libghostty-spm `7e45d27` (1.6.20260909) with no patches; `KELPIE-PATCHES.md` is gone and the "never edit the vendored package" rule has no exception. The re-vendor recipe is in `KelpieVault/Build and deploy.md`.

## What is next: the action plan (2026-09-15, close of round 16)

Work through these in order, one round per session:

1. **Open item 34, the iPad terminal does not inset for the on-screen keyboard** (the iPhone does): start in `TerminalKeyboardInset.swift` and `HerdrClientRootView`; reproduce with the Magic Keyboard detached. Small, and item 30's composer needs the same inset, so it goes first.
2. **Open item 32, hardware Shift+Tab** (confirmed still not reaching herdr on 2026-09-15): key trace first (`-kelpie.key-trace YES`), then either a priority `UIKeyCommand` like Cmd+. or CSI Z in `interceptHardwareKey`.
3. **Open item 30, the composer, its own round**: design and decisions in `KelpieVault/Design/Composer text field.md` (mirror per keystroke, off by default with a persisted toggle, Stage 0 first, Return submits). Design done; build next.
4. **Open item 22, if the Tailscale retry still stalls**: the trace again; residual holes in `KelpieVault/Archive/round14/tailscale-candidates.md`. When it holds, close 22 and 27 together.
5. **Community**: reply to every comment the Reddit watch surfaces within the day (28 drafts are waiting in `~/.kelpie/community watch/drafts/`, most on threads that are not Anthony's own; the r/ClaudeCode showcase watch surfaces every commenter, which needs a filter); r/ClaudeAI Showcase; r/iPad and r/iosapps his call; Show HN Tuesday US morning.
6. **After App Store approval**: delete the Hetzner review host (`DELETE /v1/servers/165493403`, token in `~/Developer/hetzner-kelpie.token`) and note it in the plan.
7. **Possible follow-ups, not scheduled**: a socket-level SSH keepalive (none exists; app-level 30 s ping only); `kelpie.primary-host` is a literal in two files (`PairingSync.swift`, `PrimaryHostStore.swift`); the Reddit watch's r/ClaudeCode row counts every showcase comment as unanswered.

**Nothing pending on the remote.** `origin/kelpie` matches the local branch after the round-16 force push; CI on the fork runs the suites on the next pull request.

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
- Since 7e45d27 the vendored package owns the bare Escape key command and hardware keys go through Ghostty's `sendKey`; Kelpie's `interceptHardwareKey` runs first for the chords it maps (Escape, Cmd+., Option word keys, Cmd+arrows).
- Pairing: install the upstream Heeler plugin on the mini, `herdr plugin action invoke heeler.pair` opens a popup inside herdr's TUI; the QR was not recognised but pasting the Pairing Code via iCloud clipboard worked.
- MARKETING_VERSION is `1.0`, matching the ASC version; the unit-test target is universal (`TARGETED_DEVICE_FAMILY 1,2`), which is harmless and deliberate.
