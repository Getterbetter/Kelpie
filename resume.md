# Resume: Kelpie

Read this first in a new session started in `~/Developer/Kelpie`. It holds the current state only: rewritten in place at the close of every round, with an `## In progress` section at the top when a round is checkpointed part-way (one round per session, see `CLAUDE.md`). Every round's history is in `KelpieVault/Changelog.md` and `KelpieVault/Decisions.md`; this file as it stood before the 2026-09-13 trim is `KelpieVault/Archive/round14/resume-before-trim.md`. Full documentation lives in the Obsidian vault at `KelpieVault/` (start at `KelpieVault/Kelpie.md`), and open work is in `KelpieVault/Open items.md`.

## Where things stand (2026-09-15, after round 19)

- Kelpie is Anthony's iPadOS and iPhone fork of Heeler, an SSH client for herdr. Branch `kelpie` on `origin` (Getterbetter/Kelpie, public, push freely), rebased onto upstream Heeler v0.1.8 (`b384847`) on 2026-09-15 in round 16, 121 commits on top; `upstream` is Heeler. Every hash quoted in the vault from before round 16 resolves only through the tag `kelpie-pre-rebase-20260915`.
- Round 19 (2026-09-15, main session, `472665f` to the close-out): Open items 36, 37 and 38 built, installed on both devices, **none device-confirmed** (both devices were locked all session). 38 was a regression from the round-16 re-vendor: Ghostty's `touchesEnded` now sends its own click for a finger tap, doubling Kelpie's, and herdr's mobile switcher's close button shares the header's switch button's cells; direct touches now end for Ghostty as a cancel (`f6b642f`). 37: the Kelpie capsule is bottom-trailing at every width (`472665f`). 36: a `foreground_until` lease on the device's entry in the Host's `notifications.json`, written while active and cleared on background, honoured by the notify hook (`c913786`; plugin 318 tests green; 11 app tests written, unrun). Rounds 17 and 18 are in `Changelog.md` and `Decisions.md`.

## Live services, accounts and gates

- **App Store**: 1.0 and three tips submitted 2026-09-12 02:20 UTC as **Kelpie for herdr** (record 6811004082), waiting for review at last check. Running state in `KelpieVault/App Store plan.md`. After approval, delete the review host below.
- **TestFlight public beta**: `https://testflight.apple.com/join/AkJxAbnJ`, build 4 uploaded 2026-09-15 (round 17; build 3 was 2026-09-13). `make upload` fails "Failed to Use Accounts" on this Mac: export with `scripts/ExportOptions-manual.plist` and upload with `xcrun altool --upload-app` and the API key. The Apple Distribution cert lives in the Thyme keychain (`~/Developer/maple-and-salt-agent/config/asc/thyme-dist.keychain-db`); unlock it before `-exportArchive`.
- **Push relay**: `kelpie-apns.getter-tilbury-0m.workers.dev` on Anthony's Cloudflare account, APNs key 7RJ68B8QX8 held as a Wrangler secret; the app and plugin defaults point at it.
- **App Review host**: Hetzner `kelpie-review` (5.78.158.22, about US$20 a month), password in `~/Developer/kelpie-review-host.secret`, runbook `docs/guides/app-review-host.md`. Delete after approval: `DELETE /v1/servers/165493403`, token in `~/Developer/hetzner-kelpie.token`.
- **Watches**: `com.kelpie.depwatch` daily at 05:45 with `--publish` (`KelpieVault/Dependency watch.md`; issue #3, the upstream rebase, is Open item 21). `com.kelpie.community watch` hourly, drafts in `~/.kelpie/community watch/drafts/`; mark a comment done with `scripts/community watch.py --answered <id>` (`KelpieVault/Reddit watch.md`).
- **Guards**: `make hooks` once per checkout enables the pre-push close-out check (`scripts/check-round-closeout.sh`). Never `git filter-repo` without re-parenting onto upstream afterwards (round 11b).
- **Vendored GhosttyTerminal** is libghostty-spm `7e45d27` (1.6.20260909) with no patches; `KELPIE-PATCHES.md` is gone and the "never edit the vendored package" rule has no exception. The re-vendor recipe is in `KelpieVault/Build and deploy.md`.

## What is next: the action plan (2026-09-15, close of round 19)

Work through these in order, one round per session:

1. **Round 19's device checks** (Testing status, round 19): the iPhone's "switch" button holding its switcher (38), the iPad capsule in the bottom corner (37), and the lease — iPad open, iPhone silent; iPad backgrounded, iPhone buzzes (36). Run the three notification suites on an unlocked device (the command is in Testing status). If 38 still closes, pull the key trace: one `tap click` line per tap is the fix holding; two is a third click source.
2. **Open item 19, no in-app banner on the foregrounded device**: unchanged by 36 (the foregrounded device still gets its push and `willPresent` routes it); the recipe is in the item.
3. **Open item 22, if the Tailscale retry still stalls**: the trace again; residual holes in `KelpieVault/Archive/round14/tailscale-candidates.md`. When it holds, close 22 and 27 together.
4. **The device checklists that never got their session** (Open items 1, 1f, 1g, 1a, 1b, 2, 10, 11, 12, 13, 20, 28): one session with the list open on the iPad would close the lot or turn them into real items.
5. **Community**: reply to every comment the Reddit watch surfaces within the day (drafts in `~/.kelpie/community watch/drafts/`; the r/ClaudeCode showcase watch surfaces every commenter, which needs a filter); r/ClaudeAI Showcase; r/iPad and r/iosapps his call; Show HN Tuesday US morning.
6. **After App Store approval**: delete the Hetzner review host (`DELETE /v1/servers/165493403`, token in `~/Developer/hetzner-kelpie.token`) and note it in the plan.
7. **TestFlight build 5** carrying the composer, the tap fix and the lease once round 19's checks pass (the plugin on the mini needs the new `notify-hook.js` too: the lease is read there).
8. **Composer follow-ups, not scheduled**: a soft newline (Claude Code wants `\` then Return); the responder flows have no unit coverage; older: the Connecting card's delay seen only on the LAN; a socket-level SSH keepalive; `kelpie.primary-host` is a literal in two files.

**Pending on the remote:** rounds 17, 18 and 19 are local only; `git push origin kelpie` is a plain fast-forward (the pre-push close-out check runs). CI on the fork runs the suites on the next pull request.

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
- The composer (Open item 30) is a `UITextView` riding the terminal's own key bar; the terminal refuses first responder while it is active, its input-row tap focuses the field, and the field's bytes go through `sendComposerBytes` (raw, no bracketed paste). Autocorrect on the terminal's own `UITextInput` was tried and corrects badly: do not try it again.
- The root screen keeps a replaced Ghostty surface mounted on top until its replacement paints (`HerdrClientView`'s `ForEach` of mounted surfaces); UIKit's `snapshotView` of the Metal layer is blank, so never reach for it there. The keyboard inset only works for a view that calls `.terminalKeyboardInsetWindow`.
- Since 7e45d27 the vendored package owns the bare Escape key command and hardware keys go through Ghostty's `sendKey`; Kelpie's `interceptHardwareKey` runs first for the chords it maps (Escape, Cmd+., Option word keys, Cmd+arrows).
- Pairing: install the upstream Heeler plugin on the mini, `herdr plugin action invoke heeler.pair` opens a popup inside herdr's TUI; the QR was not recognised but pasting the Pairing Code via iCloud clipboard worked.
- MARKETING_VERSION is `1.0`, matching the ASC version; the unit-test target is universal (`TARGETED_DEVICE_FAMILY 1,2`), which is harmless and deliberate.
