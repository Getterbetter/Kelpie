---
note: Every Kelpie commit on branch `kelpie`, oldest first, grouped by round.
---

# Changelog

69 commits on branch `kelpie` on top of upstream Heeler `375267c`, as of 2026-09-12. Remotes are `origin` (public, `github.com/Getterbetter/Kelpie`, default branch `kelpie`) and `upstream` (Heeler). *Corrected 2026-09-12: the old count of 17 on `90e01a9`, and "nothing has ever been pushed", were both true only until round 7.* For the user-facing version of this, see the "Kelpie" section at the top of `CHANGELOG.md` in the repo.

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
| `bae86a9` | **docs: round 7** — reviewer nits taken, rebased on upstream, archive in `Archive/round7/`. |

## Round 7b — the App Store groundwork — 2026-09-11

| Commit | |
| --- | --- |
| `cc8e38a` | **chore(app-store): rebrand leftovers, NOTICE, Kelpie privacy policy, 1.0.0** — visible "Heeler" text becomes "Kelpie" (usage strings, extension display names, Settings, notifications, Live Activity copy) while Keychain names, the logger subsystem and every wire literal stay; `NOTICE` and an in-app Heeler credit under Apache 2.0; `PRIVACY.md` rewritten; repository / privacy / support links hoisted into `KelpieLinks`; local-network usage description; relay config on `TME.Kelpie` and team 8JQWBQKEXX; `publish.sh` takes `PUBLISH_REMOTE`/`PUBLISH_BRANCH`; all three targets reset to 1.0 (1). |
| `3948efd` | **docs: resume notes for round 7b and [[App Store plan]]** — eight decisions for Anthony, six gates in order. |

## Round 7c — his answers, built — 2026-09-11

| Commit | |
| --- | --- |
| `03e6936` | **docs: feedback log** — the App Store plan answers in his words. |
| `a42e62e` | **feat(app-store): tip jar and iPad-only target** — three consumables (`TME.Kelpie.tip.small/medium/large`) through StoreKit 2; `TipJarStore` owns products, purchase and the `Transaction.updates` listener and finishes every tip, including unverified ones; `TipJarView` is a form sheet from Settings and the Kelpie menu; `Kelpie.storekit` backs the scheme's run action and stays out of the bundle. All three targets are iPad-only and opt out of Designed-for-iPad on Mac and Vision. |
| `8da2db1` | **docs: App Store plan answers, round 7c, icon drafts archived.** |

## Round 8 — the App Store push — 2026-09-11 to 12

| Commit | |
| --- | --- |
| `2c13697` | **feat(notifications): Kelpie's own push relay on workers.dev** — `relay/` deployed as `kelpie-apns` on Anthony's Cloudflare account. The app's production endpoint and the plugin default point at it; Heeler's relay joins the legacy list so an existing install migrates on its next registration. |
| `5584d9c` | **feat(icon): Kelpie's own app icon** — front-facing kelpie head with a terminal prompt for eyes, draft 2 of the set archived in the vault. |
| `8904a93` | **docs: item 0 closed** — the repo is public on GitHub; plan answers updated. |
| `71e6da3` | **docs(app-review-host): App Review host runbook; relay key id** — Pairing Codes are single-use and live two minutes, so the guide falls back to a review-only password login for the review window. |
| `285bb4e` | **feat(tooling): XCUITest driver lane for the iPad** (`scripts/drive-ipad.sh`), the way to drive the device. |
| `ca1946c` | **chore(app-store): ASC metadata script, driver toggle/allow steps, version 1.0** — `scripts/asc-kelpie.py` plans and applies the App Store Connect metadata, dry-run by default. |
| `394723c` | **docs: App Store listing copy draft**; the ASC script tolerates a new IAP's missing schedule. |
| `4af8576` | **docs(app-review-host): Node 22 from NodeSource** — the distro's Node 18 is below the plugin's floor. |
| `9e400df` | **chore(app-store): listing copy into the version localization**; support link `r/KelpieConsole`. |
| `e47b377` | **chore(app-store): no `whatsNew` on a first release.** |
| `34c19d5` | **chore(app-store): a new IAP has no availability record yet.** |
| `94f0147` | **feat(app-store): 13-inch store panels**, the compositor, and the screenshot and IAP upload steps in `asc-kelpie`. |
| `baefed9` | **feat(app-store): attach build, review details, attachment and submission steps**; upright tip sheet; review clip. |
| `109ca7a` | **docs: round 8 close-out** — App Store push state, review host, relay, driver lane. |

## Round 9 — submitted — 2026-09-12

| Commit | |
| --- | --- |
| `1c918f0` | **docs: round 9** — `resume.md` and the vault reconciled against the repo, App Store Connect, the relay and the review host. No live state had drifted, only the docs. |
| `694774c` | **feat(app-store): 1.0 submitted for review as Kelpie for herdr** — submitted 02:20 UTC with the three tip consumables. Beyond the script it needed content rights, copyright, a free price schedule, App Privacy published by hand, and the tips added to the draft on the App Review page by hand (`reviewSubmissionItems` has no IAP relationship and a first consumable cannot use `inAppPurchaseSubmissions`). The IAP review screenshot was letterboxed to 2732x2048 after 2816x1940 was rejected. Subtitle is "Agent console for iPad". |

Three more round-9 commits landed from the parallel session while round 10 was running, so they sit out of order in `git log`:

| Commit | |
| --- | --- |
| `2eb612c` | **feat(keyboard): chip row above the software keyboard on the herdr screen** — the accessory bar (Esc, Tab, sticky Ctrl/Alt, arrows, symbols) rides the keyboard on the root screen instead of the separate Keys pad, and is absent while a hardware keyboard is attached. [[Open items]] 9, from his round-9 feedback. |
| `31b8082` | **docs(app-store): TestFlight public beta submitted** alongside the 1.0 review. |
| `18651c5` | **fix(terminal): trackpad right-click reaches herdr again** — round 6's touch-selection `UIEditMenuInteraction` answered every trackpad secondary click itself and cancelled the touch before the right click was reported. It is now installed only while a touch selection is on screen. Confirmed on the iPad by Anthony the same day. Brings a per-build device regression list and the iPhone assessment with it. |

## Round 10 — the dependency watch — 2026-09-12

Anthony's ask: a recurring routine that checks what Kelpie depends on and feeds the work back into development quickly, without a fix breaking something else. Built by an Opus builder, reviewed (six should-fixes applied), then switched on with his yes.

| Commit | |
| --- | --- |
| `ab73f1a` | **feat(depwatch): scheduled dependency watch** — `scripts/depwatch.py` (stdlib, `/usr/bin/python3`) runs ten checks: herdr releases and API schema drift, herdr on the mini, Heeler upstream with a dry-run rebase, libghostty-spm, the libssh2/OpenSSL pins and advisories, npm audit, the Xcode toolchain, CI on the fork, the push relay, the review host. State and reports go to `~/.kelpie/depwatch/`, a section to [[Dependency watch]] and a handoff to the morning brief. `--publish` keeps one GitHub issue per check; `--prepare` builds and compile-checks the herdr wire-type refresh on a branch in a temporary worktree; `scripts/depwatch-analyse.sh` writes a headless-Claude brief for new high manual findings. Ships with `scripts/depwatch.sh` (the launchd wrapper and its lock), the `com.kelpie.depwatch` plist at 05:45 **unloaded**, tests, `docs/guides/dependency-watch.md` and `make depwatch`. |
| `5faf719` | **docs: depwatch schedule loaded, first live run** — `com.kelpie.depwatch` bootstrapped with Anthony's yes, `--publish` on. The first live run opened **issue #1** (`ci-fork`: GitHub Actions had never run on the fork). |

Then PR #2, the first pull request into `kelpie`, merged by rebase. It exists because opening it is what makes CI run on the fork at all, and it made CI real there for the first time: **1648 tests** green.

| Commit | |
| --- | --- |
| `976edac` | **fix(depwatch): quote compile paths and give npm audit the network timeout** — two nits from the depwatch review, and the PR's reason to exist. |
| `3da2a82` | **ci: fetch the vendored libghostty artifact before the simulator build** — the fork's first CI run failed at package resolution because `GhosttyKit.xcframework` is gitignored and only `make generate` fetched it. |
| `81d8829` | **ci: boot an iPad simulator, Kelpie is iPad-only** — `TARGETED_DEVICE_FAMILY` is 2, so the iPhone 17 the gate booted is not a valid destination. The model is `HEELER_CI_SIM_MODEL`, default `iPad Air 11-inch (M4)`, which the macos-26 runners have. |
| `436044f` | **test: cover Kelpie's iPad defaults in the licence inventory and zoom tests** — libghostty-spm no longer appears in `Package.resolved` since GhosttyTerminal is vendored, so its coverage moves to `projectPackages.GhosttyTerminal`; the zoom tests pin the phone idiom and add the iPad 12 pt default. |

Five CI attempts to green. Two were the real fixes above; three were transient real-SSH fixture failures, a different test each time, and upstream's own PR runs show the same. So **a red real-SSH run is re-run once before it counts as a regression.**

| Commit | |
| --- | --- |
| `7af1acd` | **depwatch: accurate `ci-fork` summary once CI is green; `resume.md` round 10 close-out.** Issue #1 closed; `ci-fork` drops to info. |
| `599bc26` | **depwatch: `herdr-mini` finds herdr on the mini's non-interactive PATH; document the key setup** — the check extends `PATH` with `~/.local/bin`, Homebrew and Cargo, because a non-interactive login has none of them. |

Remaining low findings after the first runs: libghostty-spm has a newer release, and OpenSSL 3.6.4 is out.

## Round 11 — iPhone, key bar, pairing sync, TestFlight — 2026-09-12

Not yet written up here; see `resume.md` round 11 and [[Open items]] 10 to 13. Its hashes (`9799147`, `baefed9` and later) were rewritten twice (purge, then round 11b).

## Round 11b — re-parenting after the purge — 2026-09-12

No code change. `kelpie` rebased with `--onto` back onto upstream `375267c` after the round-11 `filter-repo` detached it (see [[Decisions]]). 77 commits replayed, no conflicts, tree identical. Old tip: tag `kelpie-pre-rerebase-20260912`. One docs commit follows (this vault and `resume.md`).

Related: [[Kelpie]] · [[Decisions]] · [[Architecture]] · [[Testing status]]
