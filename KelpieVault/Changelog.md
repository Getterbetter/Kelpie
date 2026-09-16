---
note: Every Kelpie commit on branch `kelpie`, oldest first, grouped by round.
---

# Changelog

124 commits on branch `kelpie` on top of upstream Heeler v0.1.8 `b384847`, as of 2026-09-15 (round 16 rebased the branch; hashes quoted for earlier rounds resolve through the tag `kelpie-pre-rebase-20260915`, and before round 7 through `kelpie-pre-rebase-20260911`). Remotes are `origin` (public, `github.com/Getterbetter/Kelpie`, default branch `kelpie`) and `upstream` (Heeler). *Corrected 2026-09-12: the old count of 17 on `90e01a9`, and "nothing has ever been pushed", were both true only until round 7.* For the user-facing version of this, see the "Kelpie" section at the top of `CHANGELOG.md` in the repo.

**On the hashes.** Round 7 rebased the whole branch onto upstream `375267c`, which rewrote every commit before it. The fork-and-rebrand, round 1 and round 2 rows below still carry the **pre-rebase** hashes; those objects live on tag `kelpie-pre-rebase-20260911`, not on `kelpie`. From round 3 down, each row gives the current hash from `git log kelpie` and, where other notes quote it, the pre-rebase one in brackets. Match by subject line if a hash will not resolve.

## Fork and rebrand — 2026-09-10

| Commit | |
| --- | --- |
| `9437b1f` | **rebrand: Kelpie identifiers** — team, bundle IDs under `TME.Kelpie`, `PRODUCT_NAME` Kelpie with an explicit `PRODUCT_MODULE_NAME` Heeler, app group `group.TME.Kelpie.shared` in all three entitlements and the one shared Swift constant, device family `"1,2"`, indirect input events on. No Swift logic changed. |
| `0058d3c` | **build: regenerate `Heeler.xcodeproj`** from the rebranded `project.yml`. The build itself could not be run — every `xcodebuild` invocation hung at "Resolve Package Graph". |
| `98cb6b6` | **build: vendor GhosttyTerminal** with a local libghostty binary. Pinned commit `356f730b` under `Packages/GhosttyTerminal`; `scripts/fetch-ghostty-artifact.sh` fetches and checksum-verifies the xcframework, which stays untracked. This is what unblocked the build. |

## Round 1 — iPad pointer, touch and layout — 2026-09-10

| Commit | |
| --- | --- |
| `bb1aece` | **feat(terminal): iPad pointer and touch input reach herdr** — right click from a trackpad or mouse (by nulling `selectionMenuPoint` while the remote tracks the mouse), one-finger long press encoding a button-2 report itself with its release suppressed, two-finger selection sheet, and a scroll-type pan giving trackpad and wheel scrolling. Plus `TerminalMouseReportingTests`. |
| `b1c0fe4` | **feat(console): an open terminal fills the iPad window** — split-view column visibility driven by the router's path; `.detailOnly` with a terminal open on regular width. iPhone unchanged. |
| `b81f3c8` | **docs: record the iPad pointer decisions** — ADR 0016, and the Kelpie section at the top of `CHANGELOG.md`. |
| `aab7149` | **build: point the unit-test host at `Kelpie.app`** — `TEST_HOST` in `project.yml`; XcodeGen derives it from the target name (Heeler) while the product is `Kelpie.app`. |
| `01a7923` | **fix(terminal): own the right-button pointer touch while herdr tracks the mouse** — review fix. Ghostty arms its copy menu on `.began` from a stale drag-selection rect *before* consulting `selectionMenuPoint`, so the click was swallowed entirely. Now the whole right-button sequence is claimed. Also gates the two-finger selection gesture on the remote owning the mouse. |

## Between rounds — 2026-09-11

| Commit | |
| --- | --- |
| `d7ba148` | **docs: Kelpie section in `CLAUDE.md`** — device-only runs and the build quirks. |
| `40c0682` | **build: scheme as Xcode rewrote it** after the first device run. |

## Round 2 — herdr's client is the screen — 2026-09-11

| Commit | |
| --- | --- |
| `454fee5` | **feat(client): attach herdr's own client to a Host** — a `.client(session:)` attach target running `exec herdr` (or `--session "<name>"`, never `--takeover`); `COLORTERM` and `LANG` exported on every attach; `HerdrClientStore` (generation replacement, suspension recovery, explicit leave/rejoin) and the full-screen `HerdrClientView`. |
| `7dba133` | **feat(client): herdr's client is the root screen** — `HerdrClientRootView`, the floating menu, `PrimaryHostStore`, the Agents `fullScreenCover`, notification deep links. Every store the console needs stays on `ContentView`, above the cover. |
| `69d4b32` | **feat(terminal): tapping a URL opens it on the iPad** — `TerminalLinkDetector` resolves the URL under a cell from the viewport text (libghostty has no link-at-point query on iOS), including one wrapped onto the next row; the tap and the primary-button pointer click both open it through `onOpenLink`. |
| `376aa92` | **feat(input): keyboard mode follows the hardware keyboard** — `HardwareKeyboardObserver` over GameController; an `automatic` agent-input preference as the new default; Direct Input also claims first responder while a keyboard is attached. |
| `00ce790` | **docs: record why herdr's client became the screen** — ADR 0017, plus `CHANGELOG.md` and `CLAUDE.md`. |
| `1c4747e` | **test: cover the client attach, link detection and the new defaults** — exact attach strings, `TerminalLinkDetectorTests`, `PrimaryHostStoreTests`, the automatic-mode resolution. |
| `58199a7` | **fix(client): review fixes for the herdr client screen** — six: the foreground banner is drawn at the new root; a wrapped URL is joined only when the match reaches the grid's last column; a pointer press that moves 8 pt is released back to Ghostty so a selection drag starting on a link works; the Agents cover is presented only after the client's channel has actually closed; the client leaves when its screen goes away; `project.yml` names the product Kelpie so a regenerated scheme stops pointing Run and Test at a `Heeler.app` that is never built. |

> Commit trailers name `Co-Authored-By: Claude Opus 5 (1M context)` rather than the specs' `Claude Fable 5.1`, on both rounds — the session's harness attribution instruction supersedes the spec's. `aab7149` is the one exception and carries the spec's line.

## Between rounds — the vault — 2026-09-11

| Commit | |
| --- | --- |
| `28300fd` [pre-rebase `26900b7`] | **docs: KelpieVault project documentation** — the Obsidian vault itself: what Kelpie is, every decision, the architecture, herdr's load-bearing facts, the build recipe, pairing, testing status, the open checklist, this changelog, and Anthony's feedback. `Archive/` carries every spec, review and scout report verbatim. |
| `6c6c45b` [pre-rebase `f36b033`] | **docs: resume.md handoff and CLAUDE.md pointer** — the "read this first" file at the repo root. |

## Round 3 — Escape, word keys and a labelled menu — 2026-09-11

From the round-2 feedback in [[Feedback log]].

| Commit | |
| --- | --- |
| `46dc1c2` [pre-rebase `77cabda`] | **feat(client): Escape and Option word keys reach herdr; labelled host menu** — Escape and Cmd+. claimed as priority `UIKeyCommand`s on `HeelerTerminalView`, the way the vendored view already claims Ctrl chords, because iPadOS's text-input system ate them before `pressesBegan`. Option+Backspace, Option+Left/Right and Option+ForwardDelete send ESC DEL / ESC b / ESC f / ESC d raw, with the UIKit echo suppressed per press (`TerminalHardwareKeyMapping`, a pure value type with unit tests). The dim ellipsis becomes a material capsule naming the primary Host, Switch Host and Hosts first. |
| `122f270` [pre-rebase `98b899d`] | **docs: round-3 feedback, onboarding proposal, spec and review archive** — [[Onboarding proposal]] written, not built. |

## Round 3b — Cmd+. for real, and onboarding — 2026-09-11

| Commit | |
| --- | --- |
| `b54a6c3` [pre-rebase `5afab42`] | **fix(client): Cmd+. reaches herdr as Escape on iPadOS 26** — traced live: iPadOS delivers Cmd+. to `pressesBegan` as a press carrying the period keycode, the Command modifier stripped and `UIKeyInputEscape` as its characters, and never performs the registered key command. Anthony's Magic Keyboard has no Escape key, so Cmd+. is his only Escape. Adds `TerminalKeyTrace`, the keystroke trace to `Documents/key-trace.log`, off unless launched with `-kelpie.key-trace YES`; it is how this was found. |
| `e23bab5` [pre-rebase `a2d66a2`] | **feat(onboarding): Welcome screen, paste-first pairing, QR fixes** — with no Host the root is a Welcome screen: the Mac-side steps with copyable commands, then Paste Pairing Code as the primary way in, typing the code and scanning the QR as fallbacks, manual SSH secondary. Setup Guide in the Kelpie menu opens the same screen. The clipboard is read only on a tap, never on appear. The plugin's pairing popup no longer slices into the QR matrix in a short pane. |
| `e0b7567` [pre-rebase `043b66f`] | **docs: round 3b** — Escape confirmed, onboarding built, the QR investigation archived. |
| `397ba28` [pre-rebase `38c099e`] | **docs: round-3b feedback** — Welcome ok, QR untested by choice, media wanted next. |

## Round 4 — media into a herdr pane — 2026-09-11

| Commit | |
| --- | --- |
| `64863ad` [pre-rebase `44529b3`] | **feat(client): photos and files from the iPad into a herdr pane** — four ways in, one pipeline: paste (edit menu and hardware Cmd+V) when the pasteboard holds an image or file, drag and drop onto the terminal, and Attach Photo / Attach File in the Kelpie menu. Items go over SFTP through Heeler's existing staging into a private temp dir on the Host, and the path is typed into the focused pane by the bracketed-paste route. `HerdrMediaStagingStore` queues and stages one at a time; `MediaIntake` is the pure classifier with unit tests; intake copies are deleted when their operation ends and leftovers swept after an hour. |
| `57fc13b` [pre-rebase `0df2239`] | **docs: round 4** — media intake, plus [[Mac vs iPad gaps]] and [[Window size workshop]] written but not built. |

## Round 5 — the Mac-vs-iPad gaps, implemented — 2026-09-11

| Commit | |
| --- | --- |
| `4480834` [pre-rebase `e860ea4`] | **feat: close the Mac-vs-iPad gaps** — all four iPad orientations declared, which is what made Split View, Slide Over and resizable Stage Manager windows work (the app kept its shape before); resize reports coalesced during a divider drag; the default font follows window width on iPad (12/11/10 pt) with the user's zoom kept as an offset, and the host capsule goes icon-only under 500 pt; drop from Files fixed (provider loads start inside `performDrop`, and data/content types qualify); Cmd+arrows send Home/End/PageUp/PageDown; the terminal bell is a haptic; herdr's OSC 9/777 desktop notifications become an in-app banner or a local notification (needs `ui.toast.delivery = "terminal"` on the Host); tapping an absolute path, or Open File on Host, downloads it over SFTP into Quick Look with a share button. |
| `67e5ba0` [pre-rebase `447ef31`] | **docs: round 5** — gaps closed, window-size status, the round-6 queue. |

## Round 6 — touch selection and hold-drag — 2026-09-11

| Commit | |
| --- | --- |
| `bcb27b4` [pre-rebase `a2de274`] | **feat(terminal): touch text selection with handles; hold-then-drag as a mouse drag** — double tap (or two-finger hold) selects the word under the finger in a Kelpie-drawn overlay with iPadOS-style handles; drag a handle to extend, then Copy or Cmd+C. The selection is computed from the viewport text and never touches Ghostty's own selection, which is internal to the vendored package. A one-finger hold that then moves sends a left-button press, per-cell motion reports and a release, so herdr's sidebar edge and pane borders resize by touch; a hold that never moves still sends the right click on release. A translucent ring under the finger signals the hold, since iPads have no Taptic Engine. |
| `edeffa1` [pre-rebase `bddc5c1`] | **docs: round 6** — touch selection and hold-drag, feedback, archive. |

## Round 6b — two device fixes — 2026-09-11

| Commit | |
| --- | --- |
| `7606635` [pre-rebase `1539995`] | **fix(terminal): hold cue sized as a disc; touch selection bounded to the pane** — the vendored `UITerminalView` stamps its bounds onto every sublayer of its layer, including a subview's backing layer, so the 44 pt hold cue became a screen-sized rounded rectangle. The cue is now a transparent full-bounds container with the disc as an inner subview. A multi-row selection also ran over herdr's sidebar; it now finds the vertical box-drawing borders either side of the anchor and clamps every row's span, the handles and the copied text to those columns. |
| `373029f` [pre-rebase `4c147b9`] | **docs: round 6b** — hold cue and pane-bounded selection; new-session notes in `resume.md`. |

## Round 6c — the ring, and the disk — 2026-09-11

| Commit | |
| --- | --- |
| `b29db34` [pre-rebase `53c6821`] | **fix(terminal): 64 pt hold ring** so it shows around the fingertip. Anthony: "the ring is good." |
| `de46873` [pre-rebase `0a0b61c`] | **docs: close-out for a new session** — git remote as item 0, the disk note (the mini hit 97% because parallel builders each kept a derived-data tree), device status. |

## Round 7 — reviewer nits, then the rebase — 2026-09-11

| Commit | |
| --- | --- |
| `98187d3` [pre-rebase `76ed711`] | **refactor(terminal, client): take the round-2 reviewer nits** — one viewport read per link tap (the resolved match rides in the claim state, whose `UITouch` is now weak), padding taps no longer clamp to an edge cell on the link path, the dead `HardwareKeyboardObserver` environment injection is gone, the console cover's router reset lives on the cover only, the floating capsule lifts on press as well as hover (a `Menu` only routes a `ButtonStyle` to its label under `.menuStyle(.button)`), and the detector's doc comment states the grapheme-vs-cell limitation. The idiom font default stays: round 5's width ladder already settles it per window. |
| *(no commit)* | **The rebase.** `git tag kelpie-pre-rebase-20260911`, then 36 commits replayed onto upstream `375267c` (herdr 0.9.0 wire types, the muse agent kind, PR #307's paste key cap). Two `CHANGELOG.md` conflicts, resolved by keeping both `### Added` lists; nothing else. Release build clean, installed on the iPad. **Every hash before this line was rewritten**; the originals are on the tag. |
| `395eace` | **docs: round 7** — reviewer nits taken, rebased on upstream, archive in `Archive/round7/`. |

## Round 7b — the App Store groundwork — 2026-09-11

| Commit | |
| --- | --- |
| `8158e25` | **chore(app-store): rebrand leftovers, NOTICE, Kelpie privacy policy, 1.0.0** — visible "Heeler" text becomes "Kelpie" (usage strings, extension display names, Settings, notifications, Live Activity copy) while Keychain names, the logger subsystem and every wire literal stay; `NOTICE` and an in-app Heeler credit under Apache 2.0; `PRIVACY.md` rewritten; repository / privacy / support links hoisted into `KelpieLinks`; local-network usage description; relay config on `TME.Kelpie` and team 8JQWBQKEXX; `publish.sh` takes `PUBLISH_REMOTE`/`PUBLISH_BRANCH`; all three targets reset to 1.0 (1). |
| `820932f` | **docs: resume notes for round 7b and [[App Store plan]]** — eight decisions for Anthony, six gates in order. |

## Round 7c — his answers, built — 2026-09-11

| Commit | |
| --- | --- |
| `6839ac0` | **docs: feedback log** — the App Store plan answers in his words. |
| `540b8d6` | **feat(app-store): tip jar and iPad-only target** — three consumables (`TME.Kelpie.tip.small/medium/large`) through StoreKit 2; `TipJarStore` owns products, purchase and the `Transaction.updates` listener and finishes every tip, including unverified ones; `TipJarView` is a form sheet from Settings and the Kelpie menu; `Kelpie.storekit` backs the scheme's run action and stays out of the bundle. All three targets are iPad-only and opt out of Designed-for-iPad on Mac and Vision. |
| `152fab3` | **docs: App Store plan answers, round 7c, icon drafts archived.** |

## Round 8 — the App Store push — 2026-09-11 to 12

| Commit | |
| --- | --- |
| `3811432` | **feat(notifications): Kelpie's own push relay on workers.dev** — `relay/` deployed as `kelpie-apns` on Anthony's Cloudflare account. The app's production endpoint and the plugin default point at it; Heeler's relay joins the legacy list so an existing install migrates on its next registration. |
| `ea19e7c` | **feat(icon): Kelpie's own app icon** — front-facing kelpie head with a terminal prompt for eyes, draft 2 of the set archived in the vault. |
| `4caabed` | **docs: item 0 closed** — the repo is public on GitHub; plan answers updated. |
| `2016f23` | **docs(app-review-host): App Review host runbook; relay key id** — Pairing Codes are single-use and live two minutes, so the guide falls back to a review-only password login for the review window. |
| `396d885` | **feat(tooling): XCUITest driver lane for the iPad** (`scripts/drive-ipad.sh`), the way to drive the device. |
| `c000019` | **chore(app-store): ASC metadata script, driver toggle/allow steps, version 1.0** — `scripts/asc-kelpie.py` plans and applies the App Store Connect metadata, dry-run by default. |
| `f13134c` | **docs: App Store listing copy draft**; the ASC script tolerates a new IAP's missing schedule. |
| `d2b71e2` | **docs(app-review-host): Node 22 from NodeSource** — the distro's Node 18 is below the plugin's floor. |
| `d8897fe` | **chore(app-store): listing copy into the version localization**; support link `r/KelpieConsole`. |
| `f72cfb5` | **chore(app-store): no `whatsNew` on a first release.** |
| `45064ad` | **chore(app-store): a new IAP has no availability record yet.** |
| `c664672` | **feat(app-store): 13-inch store panels**, the compositor, and the screenshot and IAP upload steps in `asc-kelpie`. |
| `cf45aea` | **feat(app-store): attach build, review details, attachment and submission steps**; upright tip sheet; review clip. |
| `8211508` | **docs: round 8 close-out** — App Store push state, review host, relay, driver lane. |

## Round 9 — submitted — 2026-09-12

| Commit | |
| --- | --- |
| `265f8b0` | **docs: round 9** — `resume.md` and the vault reconciled against the repo, App Store Connect, the relay and the review host. No live state had drifted, only the docs. |
| `61f6546` | **feat(app-store): 1.0 submitted for review as Kelpie for herdr** — submitted 02:20 UTC with the three tip consumables. Beyond the script it needed content rights, copyright, a free price schedule, App Privacy published by hand, and the tips added to the draft on the App Review page by hand (`reviewSubmissionItems` has no IAP relationship and a first consumable cannot use `inAppPurchaseSubmissions`). The IAP review screenshot was letterboxed to 2732x2048 after 2816x1940 was rejected. Subtitle is "Agent console for iPad". |

Three more round-9 commits landed from the parallel session while round 10 was running, so they sit out of order in `git log`:

| Commit | |
| --- | --- |
| `a756361` | **feat(keyboard): chip row above the software keyboard on the herdr screen** — the accessory bar (Esc, Tab, sticky Ctrl/Alt, arrows, symbols) rides the keyboard on the root screen instead of the separate Keys pad, and is absent while a hardware keyboard is attached. [[Open items]] 9, from his round-9 feedback. |
| `5a3ee9e` | **docs(app-store): TestFlight public beta submitted** alongside the 1.0 review. |
| `c23b766` | **fix(terminal): trackpad right-click reaches herdr again** — round 6's touch-selection `UIEditMenuInteraction` answered every trackpad secondary click itself and cancelled the touch before the right click was reported. It is now installed only while a touch selection is on screen. Confirmed on the iPad by Anthony the same day. Brings a per-build device regression list and the iPhone assessment with it. |

## Round 10 — the dependency watch — 2026-09-12

Anthony's ask: a recurring routine that checks what Kelpie depends on and feeds the work back into development quickly, without a fix breaking something else. Built by an Opus builder, reviewed (six should-fixes applied), then switched on with his yes.

| Commit | |
| --- | --- |
| `bef44c7` | **feat(depwatch): scheduled dependency watch** — `scripts/depwatch.py` (stdlib, `/usr/bin/python3`) runs ten checks: herdr releases and API schema drift, herdr on the mini, Heeler upstream with a dry-run rebase, libghostty-spm, the libssh2/OpenSSL pins and advisories, npm audit, the Xcode toolchain, CI on the fork, the push relay, the review host. State and reports go to `~/.kelpie/depwatch/`, a section to [[Dependency watch]] and a handoff to the morning brief. `--publish` keeps one GitHub issue per check; `--prepare` builds and compile-checks the herdr wire-type refresh on a branch in a temporary worktree; `scripts/depwatch-analyse.sh` writes a headless-Claude brief for new high manual findings. Ships with `scripts/depwatch.sh` (the launchd wrapper and its lock), the `com.kelpie.depwatch` plist at 05:45 **unloaded**, tests, `docs/guides/dependency-watch.md` and `make depwatch`. |
| `222b855` | **docs: depwatch schedule loaded, first live run** — `com.kelpie.depwatch` bootstrapped with Anthony's yes, `--publish` on. The first live run opened **issue #1** (`ci-fork`: GitHub Actions had never run on the fork). |

Then PR #2, the first pull request into `kelpie`, merged by rebase. It exists because opening it is what makes CI run on the fork at all, and it made CI real there for the first time: **1648 tests** green.

| Commit | |
| --- | --- |
| `3d28072` | **fix(depwatch): quote compile paths and give npm audit the network timeout** — two nits from the depwatch review, and the PR's reason to exist. |
| `84587b2` | **ci: fetch the vendored libghostty artifact before the simulator build** — the fork's first CI run failed at package resolution because `GhosttyKit.xcframework` is gitignored and only `make generate` fetched it. |
| `e157a21` | **ci: boot an iPad simulator, Kelpie is iPad-only** — `TARGETED_DEVICE_FAMILY` is 2, so the iPhone 17 the gate booted is not a valid destination. The model is `HEELER_CI_SIM_MODEL`, default `iPad Air 11-inch (M4)`, which the macos-26 runners have. |
| `203acd0` | **test: cover Kelpie's iPad defaults in the licence inventory and zoom tests** — libghostty-spm no longer appears in `Package.resolved` since GhosttyTerminal is vendored, so its coverage moves to `projectPackages.GhosttyTerminal`; the zoom tests pin the phone idiom and add the iPad 12 pt default. |

Five CI attempts to green. Two were the real fixes above; three were transient real-SSH fixture failures, a different test each time, and upstream's own PR runs show the same. So **a red real-SSH run is re-run once before it counts as a regression.**

| Commit | |
| --- | --- |
| `0e6dc43` | **depwatch: accurate `ci-fork` summary once CI is green; `resume.md` round 10 close-out.** Issue #1 closed; `ci-fork` drops to info. |
| `0347cb8` | **depwatch: `herdr-mini` finds herdr on the mini's non-interactive PATH; document the key setup** — the check extends `PATH` with `~/.local/bin`, Homebrew and Cargo, because a non-interactive login has none of them. |

Remaining low findings after the first runs: libghostty-spm has a newer release, and OpenSSL 3.6.4 is out.

## Round 11 — iPhone, key bar, pairing sync, TestFlight — 2026-09-12

Anthony's ask was an iPhone assessment ("being able to pick it up on the phone would be so nice"), and it turned into a build: the same concept — herdr's own TUI on the screen — carried onto the phone, with the key bar and iCloud pairing sync built alongside it. Same-day: the TestFlight public beta was approved, build 2 went up, and a sweep of the now-public repo found a leak.

| Commit | |
| --- | --- |
| `4beeecd` | **feat: iPhone build, keyboard-styled key bar, iCloud pairing sync** — three pieces in one commit. *iPhone*: universal device family, a 12 pt phone default with herdr's own mobile layout taking over at 64 columns or fewer, a herdr submenu in the Kelpie menu (Next/Previous Tab, Toggle Sidebar, Zoom Pane) and Welcome copy for both devices. *Key bar*: `TerminalKeyBar`, one keyboard-styled row (`UIInputView` in keyboard style) above the software keyboard on the herdr screen — esc, tab, sticky ctrl and alt, arrows, symbols, a `UIPasteControl` — replacing the vendored chip bar and the paste/newline row. *Pairing sync*: `Sources/Heeler/Pairing/` (`PairingSync`, `PairingSyncRecord`) carries the device SSH key and one synchronizable record per Host — host, fingerprints, notification key, pending and authorized public keys — through iCloud Keychain, with a Settings toggle; fresh devices adopt, siblings enrol each other's keys into `authorized_keys`, and an adopted Host registers its APNs token on first connect. ADR 0018. **22 unit tests pass on the iPad**; the simulator-only integration suite is gated so the test target still builds for a device. |
| `44bbb8f` | **docs: open items for the iPhone, pairing sync and key bar checks** — [[Open items]] 10, 11 and 12: the phone device check and a 1.1 listing, the two-device sync check, and the key bar's look plus sticky ctrl and Paste. |
| `68bc332` | **fix(client): the Kelpie capsule sits in the bottom corner on phones** — from his screenshot ("our button slightly overlaps the menu button in herdr"): at compact width the icon-only capsule sat on herdr's own mobile-header switch button, so it moves bottom-trailing, off the header. |
| `e56d2cd` | **chore: build 2 (1.0) for TestFlight** — `CURRENT_PROJECT_VERSION` 2 in `project.yml` and the regenerated project, app and extensions in lockstep; the store copy note renamed to **Kelpie for herdr** to match the submitted listing. |
| `d292e37` | **chore: review clip purged from history; vault media ignored; sweep recorded** — the public-repo sweep's outcome: `.gitignore` stops vault media entering the repo again, and the sweep is recorded in [[App Store plan]] and [[Device regression list]]. |
| `8637df1` | **docs: open item 13** — pairing sync should carry Host *edits*, not only unknown Hosts, so the Tailscale address (`100.65.54.52`) is set once instead of on both devices. |
| `439e752` | **docs: round 11 close-out** — `resume.md`: TestFlight build 2, the iPhone build, the key bar, iCloud pairing sync, the repo purge and the community push state. |

**TestFlight build 2.** The public beta cleared Beta App Review and is live at `https://testflight.apple.com/join/AkJxAbnJ`, now serving build 2 of 1.0. The upload went through `xcrun altool --upload-app` with the App Store Connect API key, not `make upload`, which fails "Failed to Use Accounts" on this Mac — see [[Build and deploy]].

**The purge.** Before publicising the beta, Anthony asked for "a sweep of the github repo to make sure there's nothing in there that shouldn't be since it's public". It found the round-8 App Review clip (added in `cf45aea`) showing a lock screen. `git filter-repo` removed it and the branch was force-pushed; the clip now lives outside the repo at `~/Developer/kelpie-private/`. **Every hash after `cf45aea` changed** — and because `filter-repo` rewrote the shared history too, the branch lost its common commit with upstream, which is what round 11b below repaired (so those hashes changed a second time; the table above carries the current ones).

## Round 11b — re-parenting after the purge — 2026-09-12

No code change. `kelpie` rebased with `--onto` back onto upstream `375267c` after the round-11 `filter-repo` detached it (see [[Decisions]]). 77 commits replayed, no conflicts, tree identical. Old tip: tag `kelpie-pre-rerebase-20260912`. One docs commit follows (this vault and `resume.md`).

## Round 12 — guards, round-11 write-up, hash repair, pairing edits, Reddit watch — 2026-09-12

| Commit | |
| --- | --- |
| `a9fcba0` (+ `docs` hash fix) | **round 12**: `scripts/check-round-closeout.sh` + `.githooks/pre-push` + `make hooks`/`closeout-check`; round 11 in the vault; 35 stale hashes repaired; pairing sync carries Host edits (`PairingSync.swift`, `ContentView.swift`, 7 tests, ADR 0018 amendment); `scripts/community watch.py`, `scripts/community watch-analyse.sh`, `scripts/launchd/com.kelpie.community watch.plist`, `docs/guides/reddit-watch.md`, [[Reddit watch]]. |

Reviewed twice (fresh-context Opus); every must-fix and should-fix applied. Not on a device; the launchd job not loaded; force push pending.

## Round 12b — gates, device run, double-space, push re-registration — 2026-09-12

Force push done (`68e471e` on origin), `com.kelpie.community watch` loaded, the Chrome allow rule written (took effect only after a restart). 171 tests in 7 suites passed on the iPad over Wi-Fi. Built: the iOS double-space full stop (the vendored `replace(_:withText:)` ignored its range; the override sends one DEL per replaced character), one-finger scroll dismissing the software keyboard, and push re-registration on launch when the (token, environment) pair changed — found because the mini held a single sandbox entry from 11 Sep while the iPad ran the TestFlight build. Reviewed, no must-fix.

## Round 12c — the robustness review, built — 2026-09-12 to 13

| Commit | |
| --- | --- |
| `39ced10` | **round 12b + 12c**: four reviews → [[Robustness review]] → four builders (notifications, identity, client/transport, screen) → integration → two reviews → fixes. New: `NetworkPathObserver`, `HostKeyConfirmationBroker`, `HerdrClientNotices`, tombstones in `PairingSync`, `APNSEnvironment` from the provisioning profile, `RegistrationFailureRecording`, `TerminalShadowInput`/`TerminalShadowDeleteEchoes`, `TerminalKeyBarMetrics`; ~90 new tests. |

Every must-fix and should-fix from the reviews applied; the set-aside items are listed in [[Robustness review]]. Compiled for a generic iOS device; not run on a device at close (both devices were locked).

Related: [[Kelpie]] · [[Decisions]] · [[Architecture]] · [[Testing status]]

## Round 15 — the key bar as one pill, Shift+Tab, hide keyboard — 2026-09-15

| Commit | |
| --- | --- |
| `171e57c` | **docs: Open items 29–31** — Anthony's three keyboard asks logged at session open (Shift+Tab and collapse, a real text field for autocorrect, Notion-style toolbar) with his Notion screenshot at `Design/notion-keyboard-toolbar.png`. |
| `88cd333` | **Key bar: Shift+Tab, a hide-keyboard button, and one floating pill instead of key caps** — Open items 29 and 31. `TerminalControlKey.shiftTab` (CSI Z, off the Console pad's `rows`; the two coverage tests exclude it, plus a bytes test). `TerminalKeyBar`: keys lose their caps and shadows and sit in `TerminalKeyBarPillView`, a capsule with a soft shadow on the keyboard-style background, 12 pt margins, key height + 8; `.equalSpacing` with a low-priority width tie so the iPad spreads and the phone scrolls; sticky armed/locked shown in the caption; `UIPasteControl` capsule and clear; a `keyboard.chevron.compact.down` button pinned outside the scroll view behind a `.separator` hairline, through `keyBarDidRequestDismiss` → `dismissKeyboard()`. One Opus builder (report in `Archive/round15/`), diff read by the manager, test target compiled for the iPad, Release build installed on the iPad ("looks good") and the iPhone. |
| `872d125` | **docs: round 15 close-out** — this write-up, `resume.md`, Open items 29 and 31 ticked, item 12's verdict, `CHANGELOG.md` entry. |

## Round 16 — re-vendor GhosttyTerminal, rebase onto Heeler v0.1.8 — 2026-09-15

| Commit | |
| --- | --- |
| `b063383` | **Re-vendor GhosttyTerminal at 7e45d27 (1.6.20260909)** — Open item 25. The vendored tree replaced from libghostty-spm `7e45d27`; `scripts/fetch-ghostty-artifact.sh` fetches and verifies `upstream.82938b633ba6`; `KELPIE-PATCHES.md` deleted because `sendMousePos(x:y:modifiers:)` is public upstream. Three compile-forced Kelpie edits in `TerminalScreenView.swift`: `heelerEscapeKeyCommand` (upstream declared the old selector privately), `HeelerTerminalDropDelegate` (upstream's view now conforms to `UIDropInteractionDelegate` with non-open members; Kelpie removes upstream's drop interaction and installs its own), `HeelerPointerScrollGestureDelegate` (same for `shouldRecognizeSimultaneouslyWith`). One Opus builder; Release and test-target compiles clean. |
| (rebase) | **105 commits replayed onto `b384847`** — Open item 21, issue #3. Fourteen files conflicted; two Opus builders (the first stopped at its turn limit after 65 commits). Judgement calls: `HeelerAppModel` adopted as the store owner with one plain `WindowGroup`; Kelpie's `23c4a30` skipped for upstream's split presentation; `TerminalControlKey` reinstated beside upstream's `AgentQuickKey`; two tests of the removed `TerminalControlPadView` dropped; pairing sync, notification registration, the network path observer and the desktop-notification relay moved into `HeelerAppModel`; taps still land through `AgentSceneDirectory.land(onHostID:)` with a `pendingLanding` for a killed app. Stop log in `Archive/round16/rebase-report.md`. |
| `38c9f3d` | **Rebase onto Heeler v0.1.8: compile fixes** — `TerminalKeyboard.swift` (the escape-sequence table restored, `sendControlKey`), one `pressesCancelled`, `project.pbxproj` regenerated. |
| `f31c4a1` | **Rebase review fixes** — from review 1: `UIApplicationSupportsMultipleScenes` false (a dead "Open in New Window" item and a row drag that would open a second herdr client); `ConsoleSplitPresentation` picks `.detailOnly` in landscape too when an Agent is open (two tests); `restoreRoute()` no longer seeds the router path at launch (a restored path suppressed that Agent's pushes); `sendControlKey` writes `TerminalControlKey.bytes` again; the CI script's "iPad-only" comment reworded. |
| `55b8951` | **Hardware keys after the rebase** — from review 2: `interceptHardwareKey` runs before upstream's `.sceneCommand` route for the chords Kelpie maps, so Cmd+←/→/↑/↓ (Home/End/PageUp/PageDown) and the Cmd+. press backstop work again; Kelpie's bare-Escape `UIKeyCommand` dropped now the package registers its own (with IME withholding), Cmd+. kept and sharing `claimHardwareKeyDelivery`. |
| `3aa4e6f` | **Makefile: `make install` falls back to any physical device** — from review 3: upstream made it iPhone-only. |
| (this commit) | **docs: round 16 close-out** — this write-up, `resume.md`, `Decisions`, `Testing status`, Open items 16, 17, 21, 25 ticked and 32, 33 added, the composer design for item 30 with Anthony's four decisions, CLAUDE.md and ADR 0017 naming `HeelerAppModel`, the Reddit watch note corrected (the job has run hourly since 2026-09-12), `CHANGELOG.md` entry. |

## Round 17 — the keyboard inset, the reconnect flash, Shift+Tab — 2026-09-15

| Commit | |
| --- | --- |
| `794fb65` | **Root screen: keyboard inset gets its window, the last frame bridges a reconnect, hardware Shift+Tab** — Open items 34, 35, 32. `.terminalKeyboardInsetWindow(keyboardInset)` on `HerdrClientView` (upstream's `4b697cb` made the inset measure against a handed window and nothing else). A `TerminalLastFrame` snapshot over the reconnect and a 1 s delay on the Connecting card. `TerminalHardwareKeyMapping` gains Tab (0x2B) + Shift → CSI Z and `TerminalScreenView` a priority `UIKeyCommand` for the chord; five mapping tests. |
| `11cb5d1` | **docs: round 17 checkpoint** — `resume.md` In progress, Decisions, Open item 35 with Anthony's pick. |
| `9d17158` | **Root screen: the retired surface stays mounted over a reconnect; the snapshot bridge is gone** — the `snapshotView` came back blank on the iPad (Metal). `HerdrClientView` mounts its surfaces through a `ForEach` keyed by surface id; a pipeline swap moves the outgoing surface to a retired slot on top (input off, feed silent, last frame held) and releases it 150 ms after the new terminal reports live. `TerminalLastFrame.swift` removed. |
| (bump) | **build 4** — `CURRENT_PROJECT_VERSION` 3 → 4, archived with the fixed build path and uploaded to TestFlight with `scripts/ExportOptions-manual.plist` and `altool`, delivery id `634bfd55-78b6-454b-b068-80ca78556bee`. `make bump` fixed: its `awk` matched upstream's new `CFBundleVersion: $(CURRENT_PROJECT_VERSION)` line first and wrote 1. |
| (this commit) | **docs: round 17 close-out** — this write-up, `resume.md`, Decisions, Testing status, Open items 32, 34, 35 ticked, Kelpie status, Build and deploy. |

## Side task — disk cleanup and the fixed build path — 2026-09-15

| Commit | |
| --- | --- |
| (this commit) | **docs: builds go to one fixed path** — This was done alongside round 17, and no code changed. The disk had 3.2 GiB free. Deleted 81 stale derived-data, SPM and result-bundle folders across 9 finished sessions' scratchpads (19 GiB), plus the repo's `build/HeelerSSHDerivedData` and Xcode's `DerivedData/Heeler-*`, and erased every simulator (about 2 GiB more), leaving 25 GiB free. `CLAUDE.md` and `Build and deploy.md` now give every session one fixed build path, `~/Library/Caches/kelpie-build`. Scratchpad builds (worktrees, workers, concurrent builds) delete their own output, and the round definition of done checks that none is left. |

## Round 22 — Kelpie Chat: the roadmap and the spike (Open item 43) — 2026-09-16

| Commit | |
| --- | --- |
| (this commit) | **docs: round 22 — Kelpie Chat, the roadmap and the spike (Open item 43)** — no code changed. Anthony's ask for a native iPhone surface (a chat like the Claude app, tappable artifacts, a workspaces-and-agents panel, richer notifications, a [+] for attachments), scoped iPhone-first with an off switch. The live spike on the mini (`Archive/round22/`: `rpc.py`, `watch.py`, `perm.py`, three logs, the transcript shape) proved that a herdr pane maps exactly to Claude Code's transcript file through `pane.process_info` and `~/.claude/sessions/<pid>.json`, that tool calls land in the file within a second and the reply within a second of herdr's `done`, that a permission prompt is `blocked` plus a dangling tool_use and `agent.send_keys` answers it, and that images the agent reads are inline in the transcript. New [[Kelpie Chat]] (findings, architecture, six build rounds 43a–43f, rejected routes), ADR 0019, Open item 43, Decisions, Testing status, `herdr.md` (`pane.process_info` on 0.8.2), [[iPhone assessment]] pointer, Kelpie.md, `resume.md`, the Feedback log. |

## Round 21 — the override-point diff, and build 5 to the testers (Open items 40, 41) — 2026-09-15

| Commit | |
| --- | --- |
| `81022a1` | **scripts: ghostty-override-diff names what a re-vendor changes under Kelpie (Open item 40)** — `scripts/ghostty-override-diff.py` (stdlib) indexes the vendored GhosttyTerminal on two sides (the checkout, a Kelpie commit, or any libghostty-spm ref from a bare clone at `~/Library/Caches/kelpie-build/libghostty-spm.git`) and reads Kelpie's `UITerminalView` subclasses to report override points removed, closed, re-signed or re-bodied, new upstream members or `@objc` selectors colliding with Kelpie's own, new upstream conformances Kelpie already declares, and moved public API; exit 1 on findings. `scripts/test-ghostty-override-diff.sh` replays round 16 from tag `kelpie-pre-rebase-20260915` and asserts its three collisions are named and HEAD-against-itself is clean. `make ghostty-override-diff [NEW=<ref>]`; the dependency watch's libghostty remediation points at it. Fixes `depwatch_test.py`, red since round 16 moved the pin. |
| `23d1d5c` | **asc: --distribute-build puts an uploaded build in front of the TestFlight testers** — an `altool` upload stops at `READY_FOR_BETA_SUBMISSION`; builds 3, 4 and 5 were never added to the external group, so all 16 testers stayed on build 2. The new mode adds the newest VALID build (or `--build N`) to "Kelpie public beta", fills the empty en-US what-to-test text from `--notes`, creates the beta review submission; idempotent, dry run unless `--apply`. `make distribute [APPLY=1 BUILD=<n> NOTES="..."]`. CLAUDE.md and the dependency-watch guide point the re-vendor recipe at `make ghostty-override-diff`. |
| (this commit) | **docs: round 21 close-out** — Decisions, Testing status, Open items 40 closed and 41 opened, Build and deploy (the diff first in the re-vendor recipe; uploading is not distributing), the App Store plan's TestFlight state, `Archive/round21/override-diff-round16-replay.md`, Kelpie.md, `resume.md`. |

## Round 20 — the device suite is the gate (Open item 39) — 2026-09-15

| Commit | |
| --- | --- |
| `4daeb41` | **Tests: the device suite reads green on both devices, and one command runs it** — `TestHostConditions` (new): `readsRepository` skips the six checkout-reading tests on a device host, `presentsSoftwareKeyboard` skips the four keyboard-layout-guide tests when a hardware keyboard is attached to a physical device (the simulator is exempt, so CI keeps them); `ConsoleSplitPresentationTests.automaticReportReadsAsThePlatformsResolution` replaces upstream's iPhone-only assertion with both platform branches; `scripts/device-tests.sh` and `make test-device` / `test-device-ipad` / `test-device-iphone` wait for the device, run the suite in the fixed path, delete the `.xcresult` and print the verdict. Run at this commit: iPad 2086 tests, 0 issues; iPhone 2086 tests, 0 issues. |
| (bump) | **build 5** — `make bump` (4 → 5), archived Release, exported with `scripts/ExportOptions-manual.plist`, uploaded with `altool` (delivery `a6aa2408-ec32-4f99-b348-d39a1e458589`); carries the composer (round 18), the single tap click (round 19) and the foreground lease (round 19). |
| (this commit) | **docs: round 20 close-out** — the rule in CLAUDE.md's definition of done, Decisions, Testing status, Open items 39 closed and 40 opened, the [[Device regression list]]'s iPhone rows, Build and deploy's test recipe, Kelpie.md, `resume.md`. |

## Round 19 — Open items 36, 37, 38 — 2026-09-15

| Commit | |
| --- | --- |
| `472665f` | **Root screen: the menu button sits in the bottom corner at every width (Open item 37)** — one overlay alignment (`.bottomTrailing`), the composer-height padding at every width; the top-trailing placement from round 2 sat over the right end of herdr's tab strip, which is herdr's. |
| `f6b642f` | **Terminal: a finger tap reaches herdr once (Open item 38)** — since the re-vendor at `7e45d27` Ghostty's `touchesEnded` sends its own click for a short direct touch, doubling Kelpie's `handleTap` click; herdr's mobile switcher's close button shares the header's switch button's cells, so the second click closed it. `HeelerTerminalView.touchesEnded` now forwards direct touches to `super.touchesCancelled` (which only disarms Ghostty's tap candidate) and pointer touches to `super.touchesEnded`; `clickTouch` logs `tap click col= row=` to the key trace. |
| `c913786` | **Notifications: a foreground lease keeps alerts off the other devices (Open item 36)** — `foreground_until` on the device's entry in `notifications.json`, written on `didBecomeActive` and every 60 s (180 s lease), removed on `didEnterBackground` inside a background-task assertion (`NotificationPreferencesStore`, `NotificationRegistrationCeremony.setForegroundLease`, `NotificationRegistrationFile.settingForegroundUntil`); the notify hook's `readEligibleDevices` sends only to lease holders while any device holds a live lease. Plugin: 5 tests, 318 green. App: 11 tests written, not yet run (both devices locked). README and `CHANGELOG.md` updated. |
| `b0239dc` | **docs: round 19 close-out** — the write-up, `resume.md`, Decisions, Testing status, Open items 36–38 annotated, Kelpie.md, the spec and builder reports under `Archive/round19/`. |
| (this commit) | **docs: round 19 after the report** — 37, 38 and 1c closed, the iPad unit run (106 tests), Kelpie's plugin installed on the mini from the pushed branch, Open item 39 (the guard against upstream regressions) logged. |

## Round 18 — the composer text field — 2026-09-15

| Commit | |
| --- | --- |
| `a90ee7d` | **Root screen: assisted typing on the on-screen keyboard (Open item 30, Stage 0)** — a `TerminalTextInputStyle.assisted` (autocorrect, spell check, predictions on; capitalisation, smart quotes and dashes off) on the root screen's terminal; installed on the iPad and the iPhone. Failed the device check ("teh went to yeh") and was removed by the next commit. |
| `dabbc0f` | **Root screen: a composer text field for the on-screen keyboard (Open item 30)** — new `TerminalComposer.swift`: `TerminalComposerMirror` (the prefix diff: DELs plus the new tail, CR on submit, controls sanitised), `TerminalComposerControl` (the persisted toggle `kelpie.composer-enabled`, availability, routing, the inset handoff) and `TerminalComposerTextView`/`TerminalComposerView` (a `UITextView` riding the terminal's own key bar as its accessory). `TerminalKeyBar` gains the leading toggle key and two handler methods with defaults; `HeelerTerminalView` gains `composerControl`, `sharedKeyBar`, `sendComposerBytes`, refuses first responder while the composer is active and redirects `requestKeyboard` to the field; `HerdrClientView` mounts the field under the terminal. 14 tests in `TerminalComposerTests`. `CHANGELOG.md` entry. |
| `dd7fc0d` | **Composer: control keys start the line over, the field re-reads its bar after a reconnect** — the round's `opus-reviewer` findings (`Archive/round18/composer-review.md`): Esc and the Ctrl chords clear the field and reset the mirror; the field reloads its input views when the control's terminal changes; a late `composerControl` refreshes the toggle; a retired screen drops `onKeyboardHandoffEnded`; an armed sticky modifier turns a field keystroke into the terminal's chord; Return over an inline prediction accepts it first. Two tests replace the trivial claim test (16 in the file). Decisions, Changelog, Open items 36 and 37. |
| `98f90fb` | **docs: round 18 checkpoint** — `resume.md` In progress, Testing status, the review archived. |
| `7fd4afa` | **Composer: the field floats like the pill** — the pill's fill (`TerminalKeyBar.pillBackgroundColor`, now internal), side margins, a 24 pt continuous corner and the same shadow, on the terminal's background, instead of an edge-to-edge strip (Anthony's screenshot). |
| `bb430cc` | **Root screen: the phone's menu button rides above the composer field** — `HerdrComposerBarHeightKey` reports the bar's height; `HerdrClientRootView` pads the bottom-corner button by it. |
| (this commit) | **docs: round 18 close-out** — this write-up, `resume.md`, Decisions, Testing status, Open item 30 ticked, 38 added, Kelpie.md, the design note. |

## Side task — no standing push toward `/delegate` — 2026-09-15

| Commit | |
| --- | --- |
| (this commit) | **docs: drop the push toward `/delegate`** — alongside round 17, on Anthony's request. `CLAUDE.md` loses its when-to-delegate line (the build rule now says "a subagent"); the dependency watch's upstream-rebase brief (`scripts/depwatch.py`) and `docs/guides/dependency-watch.md` call a large rebase a round of its own instead of a `/delegate` round. |

## Round 14b — the Tailscale hang, taps on herdr's screen — 2026-09-13

| Commit | |
| --- | --- |
| `173b356` | **abandon a dead transport instead of waiting on its close; taps land on herdr's screen** — Open item 22 from the iPhone connection trace: the primary Host's session sat in `stream.end()` because the channel close waits on `SessionDriver.acquireOperation()`, an undeadlined mutex held by the attach and RPCs on the dead socket. `EventsSession.endStreamPromptly` bounds it at 2 s and abandons the transport (`HerdrEventStream.abandon` → `SSHConnection.abandon`), unconditionally; graceful ends kept for subscription changes and suspend. Package test `abandonReturnsWhileTheOperationMutexIsHeld` (fixture-gated, unexecuted locally). Open item 28: notification and Live Activity taps land on the root screen, switching the primary Host if needed and lowering the cover; a tap during the Console hand-off puts the client back on stage; `requestsConsole` removed. Two Opus builders, two Opus reviewers (one must-fix and three should-fixes taken), 1809 tests on the iPad (seven issues: six known source-reading tests, one activity-driver poll that passes alone), Release 1.0 (3) on both devices, both relaunched with the trace on. |

## Round 14 — the action plan through `/delegate` — 2026-09-13

| Commit | |
| --- | --- |
| `f58cae8` | **tap-to-dismiss, connection trace, CLAUDE.md trimmed** — Open item 24: a tap on an agent's screen text outside the input band sends its click to herdr and then drops the software keyboard after a 350 ms grace that any further touch cancels (`TerminalTapKeyboardDismiss`; the round-12b scroll path and its state removed; the double tap keeps its unresized viewport). Open item 22: `ConnectionTrace` records every `EventsSession` attempt, outcome, retry decision, path change, suspect marking, wind-down and attach hand-off to `Documents/connection-trace.log` under `-kelpie.connection-trace YES` or the key-trace flag, file sink on its own serial queue, zero cost off; the three round-13 candidates checked against the code (`Archive/round14/tailscale-candidates.md`). CLAUDE.md's Kelpie section points at the vault for the build recipe, ADR 0017 and the dependency watch, and names `/delegate` as the session default. Six scout maps and two reviews archived under `Archive/round14/`. Two Opus builders, two Opus reviewers (no must-fix; two and four should-fixes taken), 1798 tests on the iPad (the eight issues all known), 134 in the four affected suites on the final tree, Release 1.0 (3) on both devices, the iPad relaunched with the trace on. |

## Round 13 — the three posts out, watches checked — 2026-09-13

| Commit | |
| --- | --- |
| (bump) | **build 3** — `make bump` (2 → 3), archived and uploaded to TestFlight with `xcrun altool` and the API key; `scripts/ExportOptions-manual.plist` added because the automatic-signing plist fails "Failed to Use Accounts" on this Mac. Carries 12c, the tombstone fix, the reconnect surfacing and the OSC 8 link tap. |
| `8834b2a` | **OSC 8 links open on a tap** — Claude Code's pinned artifact links are OSC 8 hyperlinks with title text, invisible to `TerminalLinkDetector`'s viewport scan. New `TerminalSurfaceLinkQuery`: text scan first; when it finds nothing, the tap moves the core's mouse to the cell with shift+super (under `?1003h` the core zeroes the mods, shift restores the hit test; super alone for untracked screens) through a new public `sendMousePos(x:y:modifiers:)` on the vendored `TerminalSurface`, takes the URL from `MOUSE_OVER_LINK`, opens it on the iPad through the existing route, parks the mouse off-grid, and suppresses the probe's own motion report so herdr sees nothing. The vendored edit is the one sanctioned exception, written up in `Packages/GhosttyTerminal/KELPIE-PATCHES.md` and `CLAUDE.md`; forgetting it on a re-vendor fails the build. 61 tests in four suites on the iPad. Open item 23. |
| `cab2da6` | **root screen: the session's reconnecting state, a bounded attach, Reconnect retries the Host** — Anthony's Tailscale check: Host settings connected, the root screen spun at "Connecting" until Wi-Fi returned. Diagnosed read-only (`Archive/round13/tailscale-diagnosis.md`): the attach parked in `EventsSession.awaitTerminalTransport` with no deadline and waiters resumed only on success or a non-retryable failure. Now `HerdrClientStore` takes the Host's session status and presents reconnecting/failed with the reason and a Reconnect button (which also calls `ConsoleStore.retryHost`), rebuilds the attach when the session recovers on its own, waiters get `terminalAcquisitionTimeout` and fail on retryable errors, and `networkPathDidChange` marks the transport suspect even while suspended. Built by an Opus builder, reviewed fresh (no must-fix; two should-fixes and a nit taken, three nits set aside). 21 tests in the two suites pass on the iPad. |
| `f8201cc` | **pairing sync: retire a defeated tombstone; device-run test fixes** — the first full `HeelerTests` run on the iPad after 12c (1776 tests, 13 issues) found `applyTombstones` skipping a tombstone older than the local edit stamp but leaving it in the synced store, so `publish` refused the re-paired Host for the tombstone's month. Now removed from the store and the pass (`retireTombstone`). Test harness for the device: the detached-client rejoin waits for the replacement surface, the software-keyboard test stands down behind a Magic Keyboard, `activateControl` falls back to the probe on iOS 27, the status-dialog pixel tests use a tolerance and stand down on a black snapshot. 91 tests in the six suites pass on the iPad. Also: the r/herdr standalone post (`1wepr2j`), Release build installed on iPad and iPhone with the key trace. |
| `8d9234c` | **docs: round 13** — no code changed. The three held community posts went out through Chrome on Anthony's yes (r/SideProject reply on photo handling `p9fko9n`, r/ClaudeCode weekly showcase comment `p9fl0ga`, r/herdr reply under his own comment `p9fl8gi`), logged in the embed plan; the Reddit watch marked `t1_p9bp6zo` answered and now watches r/herdr and the r/ClaudeCode showcase thread. Overnight watches read: the Reddit watch ran hourly to 07:24, the dependency watch's 05:45 run opened issue #3 (Heeler upstream 46 commits ahead, `project.yml` conflict from PR #298). The mini's Heeler plugin still holds one `sandbox` registration only (Open item 19/20f), so the round-12c re-registration has not yet been exercised by a Release install. |

Related: [[Kelpie]] · [[Decisions]] · [[Testing status]] · [[Open items]]
