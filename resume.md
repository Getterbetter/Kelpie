# Resume: Kelpie

Read this first in a new session started in `~/Developer/Kelpie`. It holds the current state only: rewritten in place at the close of every round, with an `## In progress` section at the top when a round is checkpointed part-way (one round per session, see `CLAUDE.md`). Every round's history is in `KelpieVault/Changelog.md` and `KelpieVault/Decisions.md`; this file as it stood before the 2026-09-13 trim is `KelpieVault/Archive/round14/resume-before-trim.md`. Full documentation lives in the Obsidian vault at `KelpieVault/` (start at `KelpieVault/Kelpie.md`), and open work is in `KelpieVault/Open items.md`.

## In progress: round 33 (2026-09-25)

Batch (Anthony: "both but keep a to do list and update it as you go"): Open item 55, then 49, 53 and 52. This list is ticked as each step lands. Specs and worker reports: `KelpieVault/Archive/round33/`.

- [ ] A. SSH group cherry-picked (`Packages/HeelerSSH`, plus 3b7ddf64's Tailscale-SSH pairing refusal)
- [ ] B. Transport and terminal group cherry-picked (`EventsSession` dead-transport series, never-autocorrect, replaced-surface keyboard)
- [ ] C. Plugin and build group cherry-picked; `npm test` green; `depwatch.py`'s `heeler-upstream` check reports unreviewed upstream fixes instead of a rebase
- [ ] D. Items 49 (banner lost on a reconnect), 53 (`agent_launch_pending` message), 52 (temp-file sweep)
- [ ] E. Integrated on `kelpie`, builds at the fixed path
- [ ] F. Review of A to D
- [ ] G. `make test-device` green on the iPad and the iPhone, plus the four keyboard tests on the iPad with the Magic Keyboard detached
- [ ] H. HeelerSSH package suites through CI (a pull request on the fork; they cannot run on a device)
- [ ] I. Plugin re-installed on the mini; Device regression list on both devices
- [ ] J. Close-out: vault reconciled, pushed, scratchpad empty

## Where things stand (2026-09-23, after round 32)

- Kelpie is Anthony's iPadOS and iPhone fork of Heeler, an SSH client for herdr. Branch `kelpie` on `origin` (Getterbetter/Kelpie, public, push freely), rebased onto upstream Heeler v0.1.8 (`b384847`) on 2026-09-15 in round 16, 125 commits on top; `upstream` is Heeler. Every hash quoted in the vault from before **2026-09-16** resolves only through the bundle `~/Developer/kelpie-pre-social-purge-20260916.bundle`: round 26's purge rewrote every commit, the surviving tags included, so no tag in this repo reaches the old objects. The bundle is local and is never pushed.
- Round 32 (2026-09-23, docs only): **herdr 0.9.1 on the mini, verified live.** Anthony restarted the mini onto 0.9.1 after round 31; its schema equals the snapshot, and CLAUDE.md's load-bearing facts re-ran in a throwaway workspace and hold, with three 0.9.1 notes added (Open items 47 and 14 closed; `KelpieVault/Archive/round32/herdr-0.9.1-live.md`). Anthony then decided Kelpie is a **hard fork**: no more rebases, upstream fixes by cherry-pick (Open item 55). On Anthony's yes, the mini's two stale `production` push entries (item 51, closed) and 15 orphaned temp files (item 52's by-hand half) were removed; the three facts not re-tested are item 54, and the app has no message yet for 0.9.1's `agent_launch_pending` rename refusal (53).
- Round 31 (2026-09-17, vault only): triage; the device checklists and item 50 closed on Anthony's word. Round 30 (same day): item 19 closed, the composer's soft newline, TCP keepalive. Rounds 26 to 29: the social tooling left the repo and the history was purged; item 42; the 0.9.1 snapshot. History in `KelpieVault/Changelog.md`.
## Live services, accounts and gates

- **App Store**: 1.0 and three tips submitted 2026-09-12 02:20 UTC as **Kelpie for herdr** (record 6811004082), waiting for review at last check. Running state in `KelpieVault/App Store plan.md`. After approval, delete the review host below.
- **TestFlight public beta**: `https://testflight.apple.com/join/AkJxAbnJ`, group "Kelpie public beta", 16 testers, **serving build 5** since 2026-09-15 (`IN_BETA_TESTING`, distributed with `make distribute APPLY=1` in round 21; builds 3 and 4 were never added and are superseded). Uploading is not distributing; the recipe ends with that step now. `make upload` fails "Failed to Use Accounts" on this Mac: export with `scripts/ExportOptions-manual.plist` and upload with `xcrun altool --upload-app` and the API key. The Apple Distribution cert lives in the Thyme keychain (`~/Developer/maple-and-salt-agent/config/asc/thyme-dist.keychain-db`); unlock it before `-exportArchive`.
- **Push relay**: `kelpie-apns.getter-tilbury-0m.workers.dev` on Anthony's Cloudflare account, APNs key 7RJ68B8QX8 held as a Wrangler secret; the app and plugin defaults point at it.
- **App Review host**: Hetzner `kelpie-review` (5.78.158.22, about US$20 a month), password in `~/Developer/kelpie-review-host.secret`, runbook `docs/guides/app-review-host.md`. Delete after approval: `DELETE /v1/servers/165493403`, token in `~/Developer/hetzner-kelpie.token`.
- **The mini's herdr plugin** is Kelpie's own since 2026-09-15: `github:Getterbetter/Kelpie/plugin@kelpie` (installed with `herdr plugin install Getterbetter/Kelpie/plugin --ref kelpie --yes`; re-run it after any `plugin/` change is pushed). Config dir `~/.config/herdr/plugins/config/heeler/` is unchanged. The mini runs herdr 0.9.1 (protocol 22) since 2026-09-17 and its live schema equals the snapshot; the facts in `CLAUDE.md` were re-verified on it in round 32. **This Mac is the mini**: `ssh mac-mini` is loopback.
- **Watches**: `com.kelpie.depwatch` daily at 05:45 with `--publish` (`KelpieVault/Dependency watch.md`; issue #3; Kelpie is a hard fork since 2026-09-23 and takes upstream fixes by cherry-pick, Open item 55). `make review-state` snapshots App Store review state to `~/.kelpie/asc/review-state.json`. Anthony's community watch, posting probe and, since 2026-09-17 09:24, the **armed** posting lane run under launchd from his private `kelpie-social` checkout; they are not part of this repo (round 26). Its handover is that checkout's `notes/next-session.md`.
- **Guards**: `make hooks` once per checkout enables the pre-push close-out check (`scripts/check-round-closeout.sh`). Never `git filter-repo` without re-parenting onto upstream afterwards (round 11b).
- **Vendored GhosttyTerminal** is libghostty-spm `7e45d27` (1.6.20260909) with no patches; `KELPIE-PATCHES.md` is gone and the "never edit the vendored package" rule has no exception. The re-vendor recipe is in `KelpieVault/Build and deploy.md`.

## What is next: the action plan (2026-09-23, close of round 32)

Work through these in order, one round per session. **Every change ends with `make test-device` green on the iPad and the iPhone** (Anthony plugs them in when it is time, and the phone stays untouched for the run); a rebase or re-vendor round also runs `make ghostty-override-diff` first and `KelpieVault/Device regression list.md` on both devices after.

1. **Open item 55, the hard fork: cherry-pick upstream Heeler's fixes** (Anthony, 2026-09-23: Kelpie stops rebasing). The commit list, grouped SSH, transport, terminal, plugin and build, and the test for each group are in the item; then change the dependency watch's `heeler-upstream` check to report unreviewed upstream fixes instead of a rebase. Delegate it by group (Opus builders, one reviewer); `make test-device` on both devices and the Device regression list at the end, and re-install the plugin on the mini.
2. **Open item 49, a reconnect inside the banner's 3 s hold loses the banner**: the fix is sketched in `KelpieVault/Archive/round30/item19-diagnosis.md`. Pair it with the Connecting card's delay seen only on the LAN (item 8 below) and the small item 53 (a message for `agent_launch_pending`) for one delegated round.
3. **Open item 22, if the Tailscale retry still stalls**: needs Anthony off Wi-Fi with a traced build; the trace again, residual holes in `KelpieVault/Archive/round14/tailscale-candidates.md`. When it holds, close 22 and 27 together.
4. **Kelpie Chat (Open item 43) is paused** (Anthony, 2026-09-16). When he picks it up, start from the *Paused* section at the top of `KelpieVault/Kelpie Chat.md`.
5. **Item 36, notifications on the other device**: ticks on Anthony's word. Nothing to build.
6. **Community and distribution**: tracked in Anthony's private `kelpie-social` checkout. Open item 48 holds the App Store link for the two pinned posts on approval; 44 to 46 are pointers only. Waiting on Anthony there: storing the long-lived Claude token.
7. **After App Store approval**: delete the Hetzner review host (`DELETE /v1/servers/165493403`, token in `~/Developer/hetzner-kelpie.token`), note it in `KelpieVault/App Store plan.md`, then the 1.1 listing with iPhone screenshots. Also left from the composer follow-ups: the Connecting card's delay seen only on the LAN, undiagnosed, goes with item 49.

**Remote:** `origin/kelpie` was at round 22 (`74c0eb5`) until round 26 force-pushed the purged branch over it, carrying rounds 23 to 26. The purge rewrote every hash, so anything quoted from before 2026-09-16 resolves only through the bundle `~/Developer/kelpie-pre-social-purge-20260916.bundle` — **which must never be pushed or unpacked into a shared repo**, because it holds exactly what the purge removed. CI on the fork runs the suites on the next pull request.

## How to work on it

- Build, install and test on the iPad or iPhone, never the simulator, with the recipe in `KelpieVault/Build and deploy.md`; the rules are in `CLAUDE.md`. `make test-device` is the unit gate on both devices (round 20); a red run is read before the next change, never filed under "known issues". Before a re-vendor, `make ghostty-override-diff NEW=<commit>` (round 21). A TestFlight build reaches nobody until `make distribute APPLY=1` (round 21).
- `KelpieVault/Device regression list.md` is the per-build device checklist.
- The device diagnostics that have settled every "it doesn't work" so far: the keystroke and mouse trace (`-kelpie.key-trace YES`) and the connection trace (`-kelpie.connection-trace YES`), both pulled with `devicectl device copy from` (the connection-trace command is in `KelpieVault/Testing status.md`, round 14).
- Talking to the mini's herdr from a script: `KelpieVault/Archive/round22/rpc.py` (one request per connection on `~/.config/herdr/herdr.sock`) and `watch.py` (1 Hz transcript, Claude status and herdr status), used by the round-22 spike.
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
- A chat for the iPhone cannot come from herdr's API (no conversation data; ADR 0012) and does come from Claude Code's transcript file on the host (ADR 0019, `KelpieVault/Kelpie Chat.md`): pane → `pane.process_info` pid → `~/.claude/sessions/<pid>.json` → `~/.claude/projects/<cwd, non-alphanumerics to '-'>/<sessionId>.jsonl`. The file appears with the first prompt, not at launch; `attachment` lines are context, skip them.
