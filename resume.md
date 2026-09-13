# Resume: Kelpie

Read this first in a new session started in `~/Developer/Kelpie`. It holds the current state only: rewritten in place at the close of every round, with an `## In progress` section at the top when a round is checkpointed part-way (one round per session, see `CLAUDE.md`). Every round's history is in `KelpieVault/Changelog.md` and `KelpieVault/Decisions.md`; this file as it stood before the 2026-09-13 trim is `KelpieVault/Archive/round14/resume-before-trim.md`. Full documentation lives in the Obsidian vault at `KelpieVault/` (start at `KelpieVault/Kelpie.md`), and open work is in `KelpieVault/Open items.md`.

## Where things stand (2026-09-13, after round 14b)

- Kelpie is Anthony's iPadOS and iPhone fork of Heeler, an SSH client for herdr. Branch `kelpie` on `origin` (Getterbetter/Kelpie, public, push freely), re-parented onto upstream Heeler `375267c` on 2026-09-12; `upstream` is Heeler.
- Round 14 (2026-09-13, `/delegate`, commit `f58cae8`): the action plan worked in order. Open item 24 built (tap-to-dismiss replaces scroll-to-dismiss, deferred past the double-tap window), reviewed, installed on both devices. Open item 22 got `ConnectionTrace` (launch with `-kelpie.connection-trace YES`; the iPad is running with it) after the three round-13 candidates were checked against the code — likeliest cause is a long-lived channel dying on the Tailscale path, which the trace will name. Items 26 and 27 surveyed and decided without code (Live Activity works from the root screen once the per-Host toggle is on; background lifetime stays at 20 s, no honest background mode). Item 25 re-vendor checked safe (78 upstream commits, no override breaks, new binary checksum). CLAUDE.md trimmed, `/delegate` made the default (reversed the same day after the token review, see `CLAUDE.md`). All in `KelpieVault/Decisions.md` (round 14) and `Archive/round14/`.
- Round 14b (2026-09-13 afternoon, commit `173b356`): Anthony confirmed Open items 24 and 26 and 20 (a), (h). The iPhone's connection trace named the Tailscale hang: at the path change the primary Host's session awaited a graceful channel close that waits on `SessionDriver.acquireOperation()`, an undeadlined mutex held by the attach and RPCs on the dead socket; a sibling Host with only the events channel reconnected in 3 s. Fixed with `EventsSession.endStreamPromptly` (2 s, then `SSHConnection.abandon`), reviewed, installed on both devices with the trace on; his off-Wi-Fi retry decides. New Open item 28 built: notification and Live Activity taps land on herdr's own screen. The HeelerSSH package suites cannot run on this Mac (device refuses tool-hosted tests, simulator wedges); CI runs them on push.

## Live services, accounts and gates

- **App Store**: 1.0 and three tips submitted 2026-09-12 02:20 UTC as **Kelpie for herdr** (record 6811004082), waiting for review at last check. Running state in `KelpieVault/App Store plan.md`. After approval, delete the review host below.
- **TestFlight public beta**: `https://testflight.apple.com/join/AkJxAbnJ`, build 3 uploaded 2026-09-13. `make upload` fails "Failed to Use Accounts" on this Mac: export with `scripts/ExportOptions-manual.plist` and upload with `xcrun altool --upload-app` and the API key. The Apple Distribution cert lives in the Thyme keychain (`~/Developer/maple-and-salt-agent/config/asc/thyme-dist.keychain-db`); unlock it before `-exportArchive`.
- **Push relay**: `kelpie-apns.getter-tilbury-0m.workers.dev` on Anthony's Cloudflare account, APNs key 7RJ68B8QX8 held as a Wrangler secret; the app and plugin defaults point at it.
- **App Review host**: Hetzner `kelpie-review` (5.78.158.22, about US$20 a month), password in `~/Developer/kelpie-review-host.secret`, runbook `docs/guides/app-review-host.md`. Delete after approval: `DELETE /v1/servers/165493403`, token in `~/Developer/hetzner-kelpie.token`.
- **Watches**: `com.kelpie.depwatch` daily at 05:45 with `--publish` (`KelpieVault/Dependency watch.md`; issue #3, the upstream rebase, is Open item 21). `com.kelpie.community watch` hourly, drafts in `~/.kelpie/community watch/drafts/`; mark a comment done with `scripts/community watch.py --answered <id>` (`KelpieVault/Reddit watch.md`).
- **Guards**: `make hooks` once per checkout enables the pre-push close-out check (`scripts/check-round-closeout.sh`). Never `git filter-repo` without re-parenting onto upstream afterwards (round 11b).
- **Vendored GhosttyTerminal** carries one sanctioned patch (`Packages/GhosttyTerminal/KELPIE-PATCHES.md`, for OSC 8 links); Open item 25's re-vendor retires it. No libghostty-spm PR is needed: upstream has had the same wrapper since `eb4107b`.

## What is next: the action plan (2026-09-13, close of round 14b)

Work through these in order, one round per session:

1. **Anthony's device checks first, they gate the rest**: (a) iPhone off Wi-Fi over Tailscale, Open item 22 on `173b356` — the app is running with the trace; if it still stalls, pull `Documents/connection-trace.log` (command in `KelpieVault/Testing status.md`, round 14) and read the primary Host's last lines; (b) Open item 28 — a notification tap and a Live Activity tap land on herdr's screen, Agents from the menu still opens the Console; (c) 20 (g): in a shell pane `echo ~/Developer/Kelpie/resume.md`, a single tap only clicks, a double tap selects the path and the menu shows Open on Host; (d) 20 (f): install build 3 from the TestFlight app on one device and check the mini's entry shows `production` (the Xcode-signed build registers `sandbox` by design); (e) item 23 in a fresh Claude Code session with a newly pinned artifact link; (f) 20 (e) the finished-turn banner.
2. **Open item 22, if the retry still stalls**: the trace again; the residual holes (`windDown` clearing the suspicion, a path that moves and moves back while frozen, `windDown`'s own unbounded end under the 8 s suspend deadline) are in `KelpieVault/Archive/round14/tailscale-candidates.md` and `tailscale-hang-diagnosis.md`. When it holds, close 22 and 27 together.
3. **Open item 25, re-vendor GhosttyTerminal**, own session: recipe and checksum in `KelpieVault/Archive/round14/ghostty-upstream-diff.md` (pin `701d3a5` → `7e45d27`, binary `upstream.82938b633ba6`, drop `KELPIE-PATCHES.md`, note the extra shell-integration resources). Then **Open item 21, rebase onto Heeler upstream** (issue #3, `project.yml` conflict). Round-7 recipe, `xcodegen generate`, device build after.
4. **Community**: reply to every comment the Reddit watch surfaces within the day; r/ClaudeAI Showcase after a few days of commenting there; r/iPad General Discussion comment when he says; r/iosapps his call; Show HN Tuesday US morning.
5. **After App Store approval**: delete the Hetzner review host (`DELETE /v1/servers/165493403`, token in `~/Developer/hetzner-kelpie.token`) and note it in the plan.
6. **Possible follow-ups, not scheduled**: a socket-level SSH keepalive (none exists; app-level 30 s ping only); `kelpie.primary-host` is a literal in two files (`PairingSync.swift`, `PrimaryHostStore.swift`).

Gates cleared on 2026-09-13: `kelpie` pushed to origin, TestFlight build 3 uploaded, the libghostty-spm PR found unnecessary (see above).

## How to work on it

- Build, install and test on the iPad or iPhone, never the simulator, with the recipe in `KelpieVault/Build and deploy.md`; the rules are in `CLAUDE.md`.
- `KelpieVault/Device regression list.md` is the per-build device checklist.
- The device diagnostics that have settled every "it doesn't work" so far: the keystroke and mouse trace (`-kelpie.key-trace YES`) and the connection trace (`-kelpie.connection-trace YES`), both pulled with `devicectl device copy from` (the connection-trace command is in `KelpieVault/Testing status.md`, round 14).

## Key facts to not rediscover

- Heeler's console still powers push notifications and Live Activities; that is why it was demoted, not removed.
- herdr opens clicked URLs on the Mac with `open`; Kelpie intercepts URL taps client-side so they open on the iPad and never reach herdr as clicks.
- Ghostty on iOS has no "link at point" query; `TerminalLinkDetector` scans the viewport text instead.
- A trackpad right-click is claimed entirely by `HeelerTerminalView` while the remote app tracks the mouse, because Ghostty otherwise shows an iPadOS copy menu instead of forwarding it.
- Pairing: install the upstream Heeler plugin on the mini, `herdr plugin action invoke heeler.pair` opens a popup inside herdr's TUI; the QR was not recognised but pasting the Pairing Code via iCloud clipboard worked.
- MARKETING_VERSION is `1.0`, matching the ASC version; the unit-test target is still universal (`TARGETED_DEVICE_FAMILY 1,2`), which is harmless and deliberate.
