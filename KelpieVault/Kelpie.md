# Kelpie

Kelpie is Anthony's private iPadOS fork of [[Heeler upstream|Heeler]], an open-source iOS SSH client for [[herdr]] — the terminal multiplexer that runs his AI coding agents on the Mac mini. Kelpie's job is to put herdr's own TUI on an 11-inch iPad Pro, full-bleed, and make a trackpad, a Magic Keyboard and ten fingers all work against it.

Named for the Australian kelpie, a herding dog — a sibling to Heeler.

## Status — 2026-09-15

- Branch `kelpie`, 121 commits on top of upstream Heeler v0.1.8 `b384847` (rebased 2026-09-15 in round 16; before that on `375267c`, re-parented 2026-09-12 after the round-11 history purge detached it, round 11b). Hashes from before round 16 resolve through the tag `kelpie-pre-rebase-20260915`. Remotes `origin` (public github.com/Getterbetter/Kelpie, branch kelpie, pushed) and `upstream` (Heeler).
- Round 1 (evening of 2026-09-10): rebrand, iPad device family, trackpad/mouse right-click reaching herdr, touch long-press as right-click, trackpad and wheel scrolling, split-view collapse. Built, reviewed, two fixes applied.
- Round 2 (2026-09-11): herdr's own client became the root screen, Heeler's console demoted behind a floating menu, automatic keyboard mode, tappable URLs, 12 pt default font on iPad. Built, reviewed, six fixes applied (`58199a7`).
- Rounds 3 to 6 (2026-09-11): keys that reach herdr (Escape, Cmd+., Option word keys), Welcome screen and paste-first pairing, photos and files into a pane, all four orientations with a width-aware font, touch selection with handles and hold-then-drag. Round 7: rebase onto upstream `375267c`. Rounds 7b to 9: the App Store push (public repo, own push relay, tip jar, review host, 1.0 submitted 2026-09-12). The round-7c Release build (`540b8d6`) is installed on Anthony's iPad Pro and paired with the mini; the device checklist is in [[Open items]].
- Round 10 (2026-09-12): the [[Dependency watch]] runs daily at 05:45, opens one GitHub issue per moved dependency, and its first pass made CI real on the fork (PR #2: vendored libghostty fetched on the runner, iPad simulator, licence inventory and zoom tests fixed; 1648 tests green). The Mac mini's herdr version is watched through a dedicated key.
- Round 11 (2026-09-12): the iPhone. Kelpie goes universal — a 12 pt phone default with herdr's own mobile layout taking over at 64 columns or fewer, a herdr submenu in the Kelpie menu, the capsule moved bottom-trailing off herdr's mobile header ([[iPhone assessment]]) — plus a keyboard-styled key bar (`TerminalKeyBar`, one row in `UIInputView` keyboard style) replacing the chip and paste/newline rows, and **iCloud pairing sync** (ADR 0018: synchronizable Keychain items carry the device key and one record per Host, so a second device never pairs again; 22 unit tests pass on the iPad). TestFlight public beta approved and live, serving build 2. The trackpad right-click regression was fixed and device-confirmed, and [[Device regression list]] is now the per-build checklist. A public-repo sweep found the round-8 review clip leaking a lock screen; purged with `git filter-repo` and force-pushed.
- Round 12b/12c (2026-09-12 to 13): the [[Robustness review]] — four subsystem reviews, the ranked gap list, and every must-fix and should-fix built (APNs environment from the profile, foreground pushes never dropped, Host deletion retiring keys/entries/tombstones, fingerprints travelling with adopted addresses, a remote exit no longer read as transport death, a network path monitor, paths no longer a tap target). Also: double-space full stop, scroll-to-dismiss, push re-registration on launch, force push and Reddit watch loaded. Not device-confirmed at close.
- Round 21 (2026-09-15): Open item 40 closed — `make ghostty-override-diff NEW=<commit>` names every `UITerminalView` override point, collision, conformance and public API a libghostty-spm commit changes under Kelpie, derived from Kelpie's sources; replayed on round 16 it names all three of that round's collisions, and upstream `main` is clean today. The build-5 check found that builds 3, 4 and 5 were uploaded but never put in the TestFlight group, so every tester is on build 2: `make distribute` is now the last step of the recipe and build 5 went out on Anthony's yes and the public link serves it; both devices then re-registered as `production` (item 41 closed); the dead `sandbox` entries the switch leaves behind are Open item 42. Both devices green.
- Round 20 (2026-09-15): TestFlight build 5 uploaded after the round (the composer, the tap fix, the lease). The device suite became the gate (Open item 39). Anthony: the full `HeelerTests` on the iPad and the iPhone at the end of every change, one command (`make test-device`, waits for the device to be plugged in, prints the verdict). The 15 known device failures that had sat in every run since round 16 were fixed or turned into reasoned skips (`TestHostConditions`: six tests read the checkout's files, four need the software keyboard, one upstream test asserted the iPhone's resolution of `.automatic`), so green now means zero issues. The [[Device regression list]] gained its iPhone rows; the vendored override-point diff is Open item 40.
- Round 19 (2026-09-15): Open items 36, 37 and 38 built in one round — a finger tap reaches herdr once again (Ghostty's own tap click since the re-vendor had doubled it and closed herdr's mobile switcher on the phone), the Kelpie capsule sits in the bottom corner on the iPad too, and a foreground lease in `notifications.json` keeps Agent alerts off the other devices while one has Kelpie on screen. Installed on both devices; nothing device-confirmed yet, both were locked.
- Round 18 (2026-09-15): the composer (Open item 30) — a text field above the key bar for the on-screen keyboard, mirroring per keystroke so autocorrect, predictions, dictation and accents reach herdr and Claude Code's menus still open; off by default behind the pill's leading toggle, floating like the pill, hidden with a hardware keyboard. Stage 0 (autocorrect on the terminal itself) failed on the device first. Confirmed by Anthony on both devices; 16 tests on the iPad. Items 36, 37, 38 logged.
- Round 17 (2026-09-15): three root-screen fixes checked on the iPad in one install — the on-screen keyboard insets the terminal again (the inset was never handed its window after the rebase, Open item 34), a return from the background keeps the last frame on screen until herdr redraws and the Connecting card waits a second (the retired Ghostty surface stays mounted; a `snapshotView` came back blank, Open item 35), and hardware Shift+Tab reaches herdr (a mapping row plus a priority key command, Open item 32). All three confirmed by Anthony; installed on both devices; TestFlight build 4 uploaded.
- Round 16 (2026-09-15, `/delegate`): GhosttyTerminal re-vendored at libghostty-spm `7e45d27` with no patch left, then the branch rebased onto Heeler v0.1.8 (105 commits replayed, 14 files conflicted, three reviews, seven fixes; `HeelerAppModel` owns the stores, one window, taps still land on herdr's screen). The suite ran on the iPad (2058 tests, no regression) and Anthony's sixteen hand checks passed (item 33 closed); item 34, the iPad keyboard inset, logged for next time. The pending push went out, the Reddit watch was already running, the composer design (Open item 30) was written and decided, hardware Shift+Tab logged as item 32.
- Round 15 (2026-09-15, `/delegate`): the key bar became one floating capsule, Notion-style, and gained Shift+Tab and a hide-keyboard button (`88cd333`, Open items 29 and 31); Anthony: "looks good" on the iPad, installed on the iPhone too. Item 30, typing through a real text field, is next.
- Round 14b (2026-09-13 afternoon): Anthony confirmed tap-to-dismiss and the Live Activity; the iPhone's connection trace named the Tailscale hang (the channel close behind an undeadlined SSH mutex on the primary Host's busy connection), fixed with a bounded end that abandons the dead transport (`173b356`, Open item 22, his off-Wi-Fi retry pending); notification and Live Activity taps now land on herdr's own screen (Open item 28). Diagnosis and reviews in `Archive/round14/`.
- Round 14 (2026-09-13, `/delegate` from a fresh session): the keyboard now leaves on a tap on an agent's screen text, never on a scroll (Open item 24, built and installed on both devices, Anthony to confirm on the iPhone); the Tailscale hang gets a connection trace instead of another blind fix (Open item 22, the iPad relaunched with it on); Live Activity and background lifetime surveyed and decided without code (26: turn the Host toggle on and look; 27: 20 s is what iOS honestly gives); the re-vendor (25) checked safe for its own session; CLAUDE.md trimmed and `/delegate` made the default. Round-14 maps and reviews in `Archive/round14/`.
- Round 13 (2026-09-13 morning): the three held community posts went out on Anthony's yes (r/SideProject reply, r/ClaudeCode showcase comment, r/herdr reply under his own comment), the [[Reddit watch]] now follows both new threads, and the overnight watches were read: the Reddit watch ran hourly, the [[Dependency watch]] opened issue #3 (Heeler upstream 46 commits ahead, a `project.yml` conflict). Then, with the iPad unlocked: the full suite on the iPad found a tombstone gap (`f8201cc`), the Tailscale spin got a reconnecting state and Reconnect on the root screen (`cab2da6`, still hangs on "Reconnecting" — Open item 22 stays open), Claude Code's OSC 8 artifact links became tappable through one sanctioned edit to the vendored package (`8834b2a`, Open item 23), the r/herdr standalone post went out, `kelpie` was pushed to origin, TestFlight build 3 approved; the libghostty-spm PR turned out unnecessary (upstream already has the wrapper, Open item 25 is the re-vendor). New Open item 24: dismiss the iPhone keyboard on a tap, not a scroll.
- Round 12 (2026-09-12): the round-11b follow-through — a pre-push guard against detached history and unreconciled rounds, round 11 written up, stale hashes repaired, the Chrome allow rule, pairing sync carrying Host edits (built, not on a device), and the hourly [[Reddit watch]] (written, not loaded). Force push and launchd load wait on Anthony.
- Round 11b (2026-09-12): the history purge had left `kelpie` with no common commit with upstream; re-parented with `git rebase --onto`, 77 commits, no conflicts. Force push pending.
- Distribution: App Store 1.0 and the three tips Waiting for Review since 2026-09-12 02:20 UTC as **Kelpie for herdr**; TestFlight public beta live (build 5 uploaded 2026-09-15) at https://testflight.apple.com/join/AkJxAbnJ — see [[App Store plan]]. No pull request upstream for now.

## The notes

| Note | What's in it |
| --- | --- |
| [[Decisions]] | Every decision, with date and rationale |
| [[Architecture]] | The stack, root navigation, key files, how input flows |
| [[herdr]] | What herdr is and the facts about it Kelpie depends on |
| [[Heeler upstream]] | The fork's parent: author, licence, differences, rebase and push relay |
| [[App Store plan]] | The path to a free Kelpie on the App Store: decisions, gates, status |
| [[Build and deploy]] | The exact commands that work on this Mac, and the two quirks |
| [[Pairing and setup]] | Mini-side and iPad-side setup, the clipboard trick |
| [[Onboarding proposal]] | First-run Welcome screen (round 3, built) |
| [[Mac vs iPad gaps]] | What the iPad still lacks versus sitting at the Mac, ranked |
| [[Window size workshop]] | Split View / Slide Over / Stage Manager: facts, options, recommendation |
| [[Testing status]] | What is verified on the device, what CI covers, what nobody has seen run |
| [[Dependency watch]] | What Kelpie depends on, the daily watch, and what to do when something moves |
| [[Robustness review]] | The 2026-09-12 four-subsystem review: verdict, ranked gaps, what was built and what was set aside |
| [[Reddit watch]] | The hourly watch on the community posts: new comments, drafted replies, what it cannot see |
| [[iPhone assessment]] | Whether Kelpie's concept carries to the iPhone: herdr's mobile layout, measured live |
| [[Design/Composer text field]] | Open item 30's design and its round-18 result: Stage 0 failed, the composer shipped, one deviation recorded |
| [[Device regression list]] | The fixed per-build device checklist, run on every install |
| [[Open items]] | The checklist, including reviewer nits not yet taken |
| [[Changelog]] | Every Kelpie commit, by round |
| [[Feedback log]] | Anthony's feedback, verbatim, every round, with how it was read |

## Archive

Verbatim copies of every spec, review, scout report and build note the two rounds produced.

- Research: [[Archive/research/heeler-findings|Heeler architecture]] · [[Archive/research/herdr-findings|herdr]] · [[Archive/research/reddit-findings|the Reddit thread]] · [[Archive/research/inputmap|Heeler input map]] · [[Archive/research/navmap|round 2 navmap]] · [[Archive/research/ghostty-and-herdr-cli-findings|Ghostty and the herdr CLI]]
- Round 1: [[Archive/round1/SPEC|spec]] · [[Archive/round1/fork-notes|fork notes]] · [[Archive/round1/notes|build notes]] · [[Archive/round1/verify-notes|verification attempt]] · [[Archive/round1/review|review]]
- Round 16: [[Archive/round16/revendor-report|re-vendor]] · [[Archive/round16/rebase-report|rebase stops]] · [[Archive/round16/review-1|review 1]] · [[Archive/round16/review-2|review 2]] · [[Archive/round16/review-3|review 3]] · [[Archive/round16/fixes-report|fixes]] · [[Archive/round16/fixes2-report|key fixes]]
- Round 2: [[Archive/round2/SPEC2|spec]] · [[Archive/round2/notes|build notes]] · [[Archive/round2/review|review]]

## Identity

| | |
| --- | --- |
| Bundle ID | `TME.Kelpie` (extensions `.NotificationService`, `.Widgets`, tests `.tests`) |
| Team | `8JQWBQKEXX` |
| App group | `group.TME.Kelpie.shared` |
| Display name / product | Kelpie (`Kelpie.app`) |
| Swift module, targets, project, scheme | still **Heeler** — deliberately, see [[Decisions]] |
| Repo | `~/Developer/Kelpie`, branch `kelpie` |
| Device | 11-inch iPad Pro (M4), id `09D7738D-2173-55EF-8966-A9C3EA1D0514` |

Working files in the repo that mirror parts of this vault: `resume.md` (session start point), `CLAUDE.md` (Kelpie section at the top), `CHANGELOG.md` (Kelpie section), `docs/adr/0016-ipad-pointer-input.md`, `docs/adr/0017-herdr-client-is-the-screen.md`.
