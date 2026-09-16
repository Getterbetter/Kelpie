---
note: Every Kelpie decision, with who decided it, when, and why.
---

# Decisions

Anthony's decisions are marked **A**; the rest were delegated to the build ("our call") and are recorded because they are load-bearing. See [[Kelpie]] for the current state.

## 2026-09-10 — starting out

**A — Fork Heeler rather than write a herdr client from scratch.** Heeler already solves the expensive parts: libssh2 transport, direct-streamlocal onto herdr's socket, a libghostty terminal surface, key handling in the Keychain, an encrypted push path. Writing an iPad herdr client from zero means rebuilding all of it. The fork is private; the alternatives (herdr's own "Herdr Connect" is LAN-only TestFlight, Moshi and ShadowTerm are generic terminals) do not do what he wants. See [[Heeler upstream]].

**A — Private fork, no pull request upstream for now.** The iPad work is opinionated and reshapes the app's root screen; upstream Heeler is iPhone-first and moves daily. Revisit later ([[Open items]]).

**A — Name it Kelpie.** An Australian herding dog, a sibling to Heeler. Bundle `TME.Kelpie`, team `8JQWBQKEXX`, display name Kelpie.

**Keep the Swift module, targets, `Heeler.xcodeproj` and the `Heeler` scheme named Heeler.** Only the product, bundle IDs, team, app group and device family are rebranded. Renaming the target would rename the project file and scheme, churn every import, and make an upstream rebase far harder for no user-visible gain. `PRODUCT_NAME: Kelpie` with an explicit `PRODUCT_MODULE_NAME: Heeler` gets the fork's name on the app without touching the code. Details in [[Archive/round1/fork-notes|the fork notes]].

**Vendor the GhosttyTerminal package.** Xcode's downloader hangs indefinitely on remote `binaryTarget` zips on this Mac while plain `curl` fetches the same file in seconds. The pinned libghostty-spm commit `356f730b` is copied under `Packages/GhosttyTerminal`, and `scripts/fetch-ghostty-artifact.sh` downloads and SHA-256-verifies `GhosttyKit.xcframework` (gitignored). See [[Build and deploy]].

**Never edit the vendored package.** Everything Kelpie needs from Ghostty is reachable by overriding `open` members from `HeelerTerminalView`. That keeps the package swappable for a newer libghostty-spm pin.

## 2026-09-10 — round 1: iPad input

**A — Right-click must cover trackpad, mouse and touch long-press.** herdr's context menu opens on an SGR right-button press at a cell, and a Magic Keyboard trackpad is the primary pointing device. A finger has to reach the same menu, so a one-finger long press encodes the right-button report itself.

**Take the whole right-button pointer touch sequence rather than only nulling `selectionMenuPoint`.** Ghostty arms its iPadOS copy menu on `.began` from a stale pointer drag-selection rect *before* consulting `selectionMenuPoint(at:)`, so right-clicking inside a previous selection produced neither the menu nor an SGR report. Found by the [[Archive/round1/review|round 1 review]], fixed in `01a7923`.

**Long-press-to-select moves to two fingers while a remote app owns the mouse.** A hold is what a right click means on iPadOS, and herdr's own menu is the destination; the selection sheet gets the two-finger gesture instead. In a plain shell the one-finger hold still selects, unchanged.

**An open terminal fills the iPad window.** `NavigationSplitView` column visibility follows the router: `.detailOnly` with a terminal open on regular width, `.automatic` otherwise. Applied on change, not bound continuously, so a manual sidebar toggle is not fought. iPhone is untouched.

## 2026-09-11 — round 2: herdr's TUI is the app

This round is the response to [[Feedback log|Anthony's round-1 feedback]] — above all that the UI deviated from herdr's.

**A — The main screen must be herdr's own TUI, exactly as on the Mac, full-bleed.** Not Heeler's agent list and per-agent terminal. The iPad's job is to make interacting with herdr seamless, not to reinterpret it. Implemented as a full-screen Attach running `exec herdr` (plus `--session "<name>"` when the Host names one).

**A — Keep every Heeler quality-of-life feature, demoted behind one floating menu button.** Push, Live Activities, the agent console, hosts, settings. The console is not decoration: it owns push registration, notification preferences, the Live Activity coordinator, the foreground banner, agent start/close/rename, file staging, and the notification router. So it stays whole, in a `fullScreenCover` behind a 36 pt `ellipsis.circle` at the top right. ADR 0017.

**A — Keyboard mode automatic from hardware-keyboard presence.** Asking the user to track it in Settings produced both round-1 keyboard bugs. `HardwareKeyboardObserver` reads `GCKeyboard.coalesced` live — UIKit only ever reports the *software* keyboard's frame, which is zero either way, so GameController is the only honest signal. Automatic is the new default preference; an explicit Composer or Keyboard choice still wins and still persists.

**A — Font sizing is our call.** 12 pt default on iPad, 8 pt on iPhone. Pinch-to-zoom still persists, and a size already chosen is kept.

**A — URLs tappable, opened in the iPadOS default browser, no in-app browser.** herdr hit-tests URL clicks itself and opens them with `open` **on the Mac** — the wrong machine entirely. So a click must never reach herdr for a cell holding a URL.

**Detect links by scanning the viewport text, not by asking libghostty.** Ghostty on iOS has no "link at point" query; its only link surface is the pushed `GHOSTTY_ACTION_OPEN_URL` action, fired by a cmd-click iPadOS never produces. `TerminalLinkDetector` reads the same viewport text the selection sheet already reads.

**Export `COLORTERM=truecolor` and a `LANG` default on every attach.** A non-login `ssh` exec inherits neither, and herdr needs truecolor for its palette and UTF-8 for its box drawing.

**The client leaves its Attach channel while the Agents cover is up.** One Transport serves one Attach channel; the agent attach inside the cover needs it. herdr keeps its own scrollback on the Host, so the reattach loses nothing.

## 2026-09-11 — round 3: the keys that were being eaten

**Escape and Cmd+. are claimed as priority key commands, not handled in `pressesBegan`.** iPadOS's text-input system consumes both before the press ever reaches the terminal view, exactly as it does Ctrl chords, which the vendored view already claims. Claiming them the same way is the only route that works. Anthony's round-2 report was "Escape does not reach herdr", and Escape is how you leave anything in a TUI.

**A — Cmd+. is Escape, and it is the only Escape he has.** His Magic Keyboard has no Escape key. The first round-3 build still failed because iPadOS delivers Cmd+. to `pressesBegan` as a press carrying the period keycode, the Command modifier stripped and `UIKeyInputEscape` as its characters, and never performs the registered key command. Matching on those characters put both spellings on one mapping row. Found with `TerminalKeyTrace`, which exists because XCUITest cannot synthesise hardware keys and device logs need root.

**Option word keys are sent as raw ESC sequences with the UIKit echo suppressed.** Option+Backspace, Option+Left/Right and Option+ForwardDelete send ESC DEL / ESC b / ESC f / ESC d. The mapping is a pure value type so it can be unit-tested without a device. Anthony: "Option+Backspace has never deleted the whole word in terminal sessions for me, on any build."

**The floating ellipsis becomes a labelled host capsule.** He could not find his way to Hosts from inside the full-screen herdr view. The menu always had Hosts in it; a dim glyph with no label simply was not discoverable without a pointer resting on it. Switch Host and Hosts go first.

## 2026-09-11 — round 3b: pairing by paste

**A — Lead with the plugin and the Pairing Code; manual SSH is the thing you can dive into.** His words on the onboarding proposal: "happy with the scope. Lead with the plugin and pairing, manual SSH as an option they can dive into. Fix the QR if possible."

**Paste Pairing Code is the primary way in, not the QR.** Pairing the iPad by pasting the code through the iCloud clipboard is what actually worked on the device; the QR was never recognised. Typing the code and scanning the QR stay as fallbacks. The clipboard is read only when the button is tapped, never on appear, so the app does not trip iPadOS's paste banner unasked.

**A — He will not test the QR himself.** "It is a free app, someone else will test it." So putting the fixed plugin on the mini stays a low-priority item in [[Open items]] rather than a gate.

## 2026-09-11 — round 4: media into a pane

**A — Bringing photos and files in from the iPad is the next feature.** The zero-code route, copying a photo on the iPad and pasting it into Claude Code over Universal Clipboard, did not work for him. "Hence the ask."

**Media goes over SFTP through Heeler's existing staging, and only the path is typed into the pane.** `ImagePreparer`, `FilePreparer` and `HeelerSSHTransport.stageImage/stageFile` already upload into a private temp dir on the Host for the console's composer; the herdr pane reuses them and then types the resulting path through the bracketed-paste route, which is how herdr's own remote image paste works. Nothing about the image travels through the terminal itself.

**Four ways in, one pipeline.** Paste (edit menu and hardware Cmd+V), drag and drop, Attach Photo and Attach File all queue onto `HerdrMediaStagingStore`, which stages one item at a time. One pipeline means one place for the upload capsule, the error path and the cleanup. Intake copies are deleted when their operation ends and leftovers are swept after an hour.

## 2026-09-11 — round 5: the iPad as a window

**A — "The Mac vs iPad gaps: implement all of them."** The ranked gap list in [[Mac vs iPad gaps]] was written in round 4 as a proposal; he took the whole list.

**Declare all four iPad orientations.** This was the actual cause of the complaint that "resizing keeps its shape so a side by side view is near impossible". An app that declares only landscape cannot be given an arbitrary Split View width. One plist change made Split View, Slide Over and resizable Stage Manager windows work; he confirmed it the same day.

**The default font follows window width, not the device idiom.** 12 pt full width, 11 pt narrower, 10 pt narrower still, with the user's own zoom kept as an offset rather than overwritten. This supersedes round 2's "12 pt on iPad" and it is why the round-2 reviewer's idiom-default finding was closed as superseded rather than changed: the width ladder runs on first layout, so a Slide Over launch settles at 10 pt by itself. The host capsule goes icon-only under 500 pt for the same reason.

**Stage Manager multi-window was left out.** It needs per-scene stores, which is a structural change, not a gap fix.

## 2026-09-11 — round 6: selection and drag by finger

**A — iPadOS-style selection handles.** A double tap selected one word with no way to extend it. Highlighting with the trackpad or mouse was already fine; the ask is touch.

**Kelpie draws the selection itself rather than driving Ghostty's.** Ghostty's selection is internal to the vendored package and, while mouse tracking is on, its drags are forwarded to the PTY instead. Since the package must never be edited, the overlay is computed from the same viewport text the selection sheet already reads, and Copy and Cmd+C take the text from there. Handles consume their own touches so the terminal's clear-on-touch cannot swallow a drag.

**A — The ask on the sidebar was resizing, not tapping.** "herdr's sidebar is either impossible to touch with a tap or not moveable with a tap." Diagnosed: workspace and agent taps work fine; dragging the pane divider is what only worked with a mouse.

**A one-finger hold that then moves becomes a left-button drag.** Press, per-cell motion reports, release, so herdr's sidebar edge and pane borders resize by touch. A hold that never moves still sends the right click on release, so the existing gesture is not lost. Slop is a cell height, above the recogniser's own 10 pt allowance.

**A — The hold needs a visible signal, because an iPad has no Taptic Engine.** "There is no tap because there's no haptic on an iPad; might need another way to signal." Hence a translucent ring under the finger.

## 2026-09-11 — round 6b: a quirk of the vendored view

**Any subview added to `HeelerTerminalView` must be a full-bounds container with the real content as an inner subview.** The vendored `UITerminalView` stamps its own bounds onto every sublayer of its layer, a subview's backing layer included, so the 44 pt hold cue was drawn as a screen-sized rounded rectangle. Anthony saw "a huge blue box covering most of the screen". This is load-bearing for anything drawn over the terminal from now on; `TerminalHoldCueView` is the pattern to copy, and ADR 0016 was amended to say so.

**Touch selection is clamped to the pane's box-drawing borders.** A multi-row selection spanned the whole grid and ran over herdr's sidebar, which herdr's own selection never does. The selection now finds the vertical box-drawing borders either side of the anchor on its row and clamps every row's span, the handles and the copied text to those columns.

## 2026-09-11 — round 6c: one derived-data path per session

**One derived-data path per session, `<scratchpad>/build/kelpie-dd`, not one per builder.** Two parallel builders each kept their own derived-data tree and the Mac mini's data volume hit 97% mid-build. Two builds sharing a path also lock each other out, which is why the per-builder split existed; running builders in sequence within a session is the cheaper trade. Recorded in [[Build and deploy]].

## 2026-09-11 — round 7: rebasing onto a fork that moves daily

**Tag before every rebase, and treat the tag as the only copy of the old hashes.** `git tag kelpie-pre-rebase-<date>`, then `GIT_EDITOR=true git rebase upstream/main`, resolve `CHANGELOG.md` by keeping both `### Added` lists, `xcodegen generate`, then a device build. Round 7 replayed 36 commits onto upstream `375267c` with two `CHANGELOG.md` conflicts and nothing else. Every hash quoted in the vault and in `resume.md` from before that point now resolves only through `kelpie-pre-rebase-20260911`, which is why [[Changelog]] labels them.

**Rebase is a recurring item, not a one-off.** Upstream Heeler moves daily and the longer the gap the worse the collisions. From round 10 the dependency watch rehearses the rebase in a detached worktree every morning, so the finding already knows whether it conflicts and where.

## 2026-09-11 to 12 — rounds 7b to 9: the App Store

**A — Ship Kelpie to the App Store as a free app.** His words after round 7: "It's going to be a free app, potentially with a donate to the dev option at some point. No internal or external testing - I'll start a reddit page for it and people can post there." So no tester groups, and `r/KelpieConsole` becomes the support channel.

**A — iPad-only for 1.0.** The root screen is herdr's full TUI, which is unusable at phone width, and universal would mean iPhone screenshots and a layout nobody had run. All three targets are device family 2 and opt out of Designed-for-iPad on Mac and Vision. The iPhone question came back on 2026-09-12 as an assessment, not a build ([[iPhone assessment]]).

**A — The repo goes public.** "Make it public." The privacy policy URL has to be a publicly reachable page, and the in-app links already pointed at `github.com/Getterbetter/Kelpie`. A public Apache-2.0 fork also satisfies the licence's "state your changes" expectation through the commit history. Done 2026-09-11.

**A — A StoreKit tip jar in 1.0, not a later version.** "I'm fine with in app purchase tip if it means less piping of infra to take payments, can be in v1.0." Outside the US storefront an in-app donation must be an In-App Purchase anyway (3.1.1), and external Ko-fi or Sponsors links are US-only. Three consumables through StoreKit 2.

**A — Kelpie gets its own push relay on his Cloudflare account.** Heeler's hosted relay signs for bundle `dev.bybee.heeler`, so it can never deliver to `TME.Kelpie`. The alternative, shipping 1.0 with notifications off, throws away the reason Heeler's console was kept at all. He ran `wrangler login` in his own Terminal.app (the session shell's two-minute cap killed the first OAuth callback) and reused the APNs key from his Weights app, since one auth key serves every app on the team.

**A — A real herdr host for App Review, not a fake demo mode.** Kelpie does nothing without a Mac running herdr, and the compiled-out demo mode fakes Heeler's console rather than the herdr TUI that is Kelpie's root screen. Building a demo path was costed at about a week of work for something untrue. A small Hetzner box (`kelpie-review`, cpx11, roughly US$20 a month) plus a screen-recorded walkthrough was the cheaper honest answer. It gets deleted after approval, and it must outlive the TestFlight beta review too.

**A — The name is "Kelpie for herdr".** Apple's 4.1(c) means someone else's mark does not belong in the app name, but Heeler itself ships as "Heeler for herdr" and Moshi carries the mark as well, so the form is established. Subtitle: "Agent console for iPad".

**Internal identifiers were deliberately left alone.** Keychain service names and access groups (changing them orphans the keys already on the iPad), the logger subsystem, and the module, target and scheme names. Only the user-visible surface was rebranded.

## 2026-09-12 — round 10: watching the dependencies

**A — A scheduled watcher, not ad-hoc checks.** His ask: "Kelpie has dependencies and could break if things change. I'm looking for a routine that runs on a recurring basis to check for these dependencies and feed the pipeline of development needed to respond to changes quickly. the goal would be to optimise for automation to respond to change quickly where fixes dont then break something else." `com.kelpie.depwatch` runs at 05:45 daily, twenty minutes before the morning brief is built, on the launchd pattern the rest of his fleet uses.

**GitHub issues are the work feed, one open issue per check.** A finding has to become work, not a line in a log nobody opens. `--publish` keeps one issue per check, labelled `depwatch`; a new fingerprint on a check that already has an issue is a comment and a title edit rather than a second issue, and a finding that falls back to info closes its issue with a note. That is what stops a daily watcher from becoming a daily interruption.

**It notices; it does not fix.** The single exception is herdr's API schema, where the change is mechanical: copy the snapshot, regenerate the wire types, prove there is no drift. Everything else hands a person the commands already written out, because the expensive half of a herdr release is re-verifying the load-bearing facts in `CLAUDE.md` against a live server, which no script can do.

**Every fix climbs the same ladder: drift check, compile, CI, device build, merge.** The compile is a generic iOS build with its own derived-data path; CI means a pull request into `kelpie`, because `ci.yml`'s `pull_request` trigger has no branch filter while its `push` trigger is `main`-only; the device build is the real iPad plus the checklist in [[Open items]], since the simulator is not an option on this Mac.

**A fix touching `Sources/` never merges on the compile alone.** A compile proves the Swift type-checks. It says nothing about whether herdr still answers the way the app expects, and every expensive herdr fact was learned from a live server.

**A red real-SSH CI run is re-run once before it counts as a regression.** Getting PR #2 green took five attempts: two were real fixes, three were transient real-SSH fixture failures with a different test failing each time, and upstream's own PR runs show the same pattern. Treating the first red as a regression would mean chasing fixtures instead of dependencies.

**CI boots an iPad simulator.** `TARGETED_DEVICE_FAMILY` is 2 since round 7c, so the iPhone 17 the upstream gate booted is not a valid destination for Kelpie at all. The model is `HEELER_CI_SIM_MODEL`, default `iPad Air 11-inch (M4)`, which the macos-26 runners carry.

**The mini is watched through a dedicated key.** `~/.ssh/kelpie-depwatch`, passphrase-less, installed once from Terminal.app because the session runner cannot answer a password prompt, with a `Host mac-mini` block over Tailscale. The check also extends `PATH` with `~/.local/bin`, Homebrew and Cargo, because a non-interactive login has none of them. Until a key is in place the check reports info, never error, so an unconfigured Mac does not produce a permanent false alarm.

## 2026-09-12 — round 11: iPhone, key bar, pairing sync

**A — The iPhone gets the same concept, not a second design.** His ask: "how much of what we've built could be made available on the iPhone? … I wondered whether we could maintain the herdr UI more (same concept as Kelpie) to minimize changes to adapt to herdr updates." So Kelpie becomes a universal app (device family 1,2) rather than growing a phone-specific layout: the phone gets a 12 pt default and **herdr's own mobile layout takes over at 64 columns or fewer**, which is herdr's decision to make, not Kelpie's. The Kelpie menu grows a herdr submenu — Next/Previous Tab, Toggle Sidebar, Zoom Pane — as the fallback navigation he asked for, because a phone has no room for the sidebar and no Magic Keyboard to drive it. Keeping the surface this thin is what keeps the fork cheap to hold in step with herdr.

**The Kelpie capsule sits bottom-trailing on phones.** At compact width the icon-only capsule overlapped herdr's *own* mobile-header switch button — Anthony, from a screenshot: "ios version works, but our button slightly overlaps the menu button in herdr". Moving it to the bottom corner keeps Kelpie's one piece of chrome off herdr's chrome, which is the same rule the root screen has followed since round 2: the screen belongs to herdr.

**The key bar is one keyboard-styled row, not a section of the screen.** From his round-9 feedback: "the 'keys section' should be a row of chips sitting above the keyboard instead of separate section." Round 9's chip row was the first pass; round 11 replaces both it and the paste/newline row with `TerminalKeyBar`, a single row in `UIInputView`'s **keyboard style** so it reads as part of the software keyboard rather than as app furniture — esc, tab, sticky ctrl and alt, arrows, symbols, and a `UIPasteControl` (the system control, so pasting a photo needs no clipboard-read prompt). It is absent while a hardware keyboard is attached, as the chip row was.

**Pairings ride iCloud Keychain; the Device Key is shared.** ADR 0018. Pairing is a physical ceremony at the Mac, and with an iPad *and* an iPhone every Host would have to be paired twice — a Host added on the road simply would not exist on the other device. Everything a sibling needs is either public (coordinates, host-key fingerprints, a public key line) or a secret the Host already holds (the Notification Key), so the carrier is `kSecAttrSynchronizable` generic-password items through the existing `KeychainSecretStore`: **no iCloud container, no CloudKit, no new entitlement, no Kelpie-operated storage**. A fresh device adopts the shared device key and the Host records; a device that already minted its own key is not overwritten (that would revoke it everywhere) — its public key goes into the record's `pendingPublicKeys` and whichever sibling can already reach the Host appends it to `authorized_keys` on its next connection. An adopted Host still registers its own APNs token, because the shared Notification Key is not a token. A Settings toggle withdraws this device's records without revoking anything, and a saved Host password is deliberately never synced. The cost, accepted: two devices present one SSH identity, so revoking that key on a Host revokes both.

**Build 2 was uploaded with `xcrun altool`, not `make upload`.** `make upload` (and `xcodebuild -exportArchive` with the upload option) fails on this Mac with "Failed to Use Accounts"; `xcrun altool --upload-app` with the App Store Connect API key works and needs no Xcode account state at all. That is the TestFlight recipe from now on — see [[Build and deploy]]. Interim builds still go out as `make bump` first, because App Store Connect rejects a reused build number.

**The leaked review clip was purged from history, and vault media is gitignored.** Anthony, before the community posts: "do we need to do a sweep of the github repo to make sure there's nothing in there that shouldn't be since it's public?" The sweep found the round-8 App Review clip (`cf45aea`) showing a lock screen. Deleting the file would have left it served by hash, so history was rewritten with `git filter-repo` and the branch force-pushed; the clip lives outside the repo at `~/Developer/kelpie-private/`, and `.gitignore` now refuses vault media so it cannot recur. GitHub still serves the old blobs by hash until Support purges them — that ask is in [[Open items]]. **The cost was not free**: `filter-repo` rewrote the shared history too, which detached the branch from upstream and forced the second rewrite in round 11b below. Never purge without re-parenting afterwards.

## 2026-09-12 — round 11b: re-parenting after the purge

**A history purge must be followed by a re-parent onto upstream.** Round 11's `git filter-repo` rewrote every commit back to 2026-07-18, not only the ones after the leaked clip, so `kelpie` shared no object with `upstream/main` and `git rev-list upstream/main..kelpie` reported 1252. The dependency watch's rebase rehearsal would have replayed upstream's own commits. The fix was `git tag kelpie-pre-rerebase-20260912`, then `git rebase --onto 375267c <rewritten twin> kelpie` — the twin found by subject, confirmed by identical tree hash — 77 commits, no conflicts, working tree unchanged. The cost is a second hash rewrite for rounds 8 to 11 and a force push. Rule going forward: after any `filter-repo`, check `git merge-base --is-ancestor <upstream base> kelpie` before pushing.

## 2026-09-12 — round 12: guards, and the watch on the posts

**The close-out is enforced by a pre-push hook, not by memory.** `scripts/check-round-closeout.sh` runs from `.githooks/pre-push` (`make hooks` sets `core.hooksPath` once per checkout). It checks three things that each went wrong once: the pinned upstream base `375267c` must be an ancestor of every pushed commit and the branch may not be more than 400 commits ahead of `upstream/main` (a `filter-repo` purge produced 1252; a healthy branch is under 100), every round in `resume.md` must have a Changelog and a Decisions heading, and Open items may not repeat a number. The base is pinned rather than the tip of `upstream/main` because any future upstream tip descends from the pin, so the pin never goes stale, while the tip fails every push the day upstream moves.

**Host edits sync by a per-Host edit stamp, not a model change.** `Host` has no last-modified field and the builder was scoped away from it, so `PairingSync` keeps a digest of the three synced coordinates (address, port, username) plus when this device first saw that shape. A changed digest is a local edit stamped now; adoption stamps the record's own `updatedAt`. The digest deliberately excludes the name, session and jump host, because a rename must not block or revert an address fix. The cost is that an edit is dated at the next reconcile, which rounds in favour of the local edit. Fingerprints are not synced with the coordinates, so the second device meets a TOFU prompt on a new address.

**The Reddit watch reads Atom feeds and never posts.** Reddit's `.json` view returns 403 to a signed-out request from this Mac whatever the User-Agent; the post's `.rss` feed answers with a browser User-Agent, at roughly one request per short window per IP, so the hourly run paces its requests 20 s apart. The feed carries no depth, parent or score; those are recorded as null. Replies are drafted by a time-boxed headless Claude with comment bodies fenced as data and only two read paths allowed; every reply is posted by hand. Unanswered comments stay in the morning-brief handoff until `--answered <id>`, because an hourly job that only reports "this run's new" hands the 06:05 brief an empty list.

**Browser posting is allowed at the settings level, gated at the conversation level.** `mcp__claude-in-chrome` is in `permissions.allow` and the auto-mode classifier has an allow rule for approved community posts. The rule that each post text gets Anthony's yes on screen is the delegate skill's, and stays.

## 2026-09-12 — round 12b: the double-space, the keyboard, the missing push

**The iOS double-space shortcut is fixed by honouring `replace(_:withText:)`, not by a trait.** Every autocorrection trait was already `.no`; the vendored view simply ignored the range iOS asked it to replace. The override sends one DEL per replaced character and refuses whenever it cannot be honest: marked text, a hardware keyboard, a range that is not the line's suffix, non-printable or wide text, or a caret away from the end of the shadow line.

**A one-finger scroll drops the software keyboard on every idiom.** The iPad's keyboard has a dismiss key and the iPhone's does not; the gesture never fires with a hardware keyboard attached, and never for selection, hold-then-drag or trackpad scroll.

**The push entry on the Host is revalidated on launch.** The mini held one sandbox entry from 11 Sep while the iPad ran the TestFlight build and the iPhone had adopted the Host by sync; nothing re-registered because registration only ran from two Settings toggles. Each Host now records the (token, environment) pair it last registered and re-registers when the pair changes; the sibling path re-runs when the token arrives.

**Swift Testing suites are named by their struct in `-only-testing`.** The first device run executed zero tests because the filter named the file; the XCTest "Executed N tests" line does not count Swift Testing.

## 2026-09-12 — round 12c: the robustness review

**"Captured once, never revalidated" is the bug class, and the cure is a habit.** Four fresh-context reviews (notifications, identity, transport, screen) independently found the hard parts sound and the same weakness at every lifecycle edge; see [[Robustness review]]. The rule from now on: any fact about the outside world (a token, an environment, a keyboard, a session name, a fingerprint, a network path) is re-read on launch and foreground, travels with the record it belongs to, is retired with that record, and gets a visible state when its neighbour is unhealthy.

**The APNs environment comes from the provisioning profile, not `#if DEBUG`.** `embedded.mobileprovision` carries `aps-environment`; a Release build on a development profile is sandbox, TestFlight and the App Store are production, and a build with no profile is production. `#if DEBUG` is only the fallback when the profile cannot be read.

**A push in the foreground is never dropped.** `willPresent` hands the envelope to the in-app banner store; when the store cannot show it (no live list, unknown triggers) the system banner shows instead; only the Agent actually on screen stays silent. One de-dupe key covers both pipelines.

**Deleting a Host retires everything it owned.** The Notification Key (Keychain and app-group mirror), this device's entry on the Host (withdrawn over SSH with retries, then a visible note if it never lands), and a synced tombstone so a sibling deletes too and never resurrects it. A re-pair after deletion advances the edit stamp so it out-dates the tombstone.

**Adopted coordinates travel with their fingerprints, and an unpinned Host asks.** `adoptCoordinates` imports the record's pins for endpoints with no local pin; `HostKeyConfirmationBroker` turns the Console's blanket-reject policy into a first-connect question wherever a presenter is mounted, and declines as before when none is.

**A remote exit is never transport death.** Only channel-open failure, an unreachable SSH host and timeouts mark the transport suspect; a nonzero herdr exit (a bad `--session` name, now user-editable) shows the exit and the session name and waits for the user, because treating it as death looped forever.

**A network path change is a first-class event.** `NetworkPathObserver` (NWPathMonitor behind a protocol) marks connected Hosts reconnecting synchronously, repairs with a capped policy, coalesces a flap storm to one repair plus one follow-up, and reports settled only when every Host reconnected on a newer transport generation.

**Paths in the terminal are no longer a tap target.** A tap always reaches herdr as a click; "Open <file>" lives in the selection menu. The path matcher was swallowing ordinary agent output.

**The double-space rewrite runs in alternate-screen mode on purpose.** herdr's client is always `?1049h` plus mouse tracking, and the input boxes of claude, codex and grok read DEL as Backspace; the honest gates are the shadow caret at end of line, the echo leash and the printable-ASCII rule, not the screen mode.

## 2026-09-13 — round 14: the action plan through `/delegate`

**A — A tap on an agent's screen text takes the keyboard down; a scroll never does.** Anthony (Open item 24): scroll-to-dismiss fought scrolling through Claude's actions while answering each. The round-12b scroll path is gone. A tap outside the input band, with the software keyboard up and no hardware keyboard, still sends its click to herdr first (round 12 finding 5 stands) and then drops the keyboard after a 350 ms grace, cancelled by any further touch, so a double tap to select never lands on a resized viewport. Accepted limit: in a plain shell's normal buffer the terminal keeps its taps, so there the key bar is the way down; the root screen is herdr's TUI, which always claims them. Set aside from the review: the cancel in `requestKeyboard` sits behind the local-input guard, no teardown cancel (weak self, harmless).

**A — Get the Tailscale reason from a trace, not from Anthony's eyes.** Open item 22 has now survived two rounds of fixing without anyone seeing the failure. `ConnectionTrace` (on with `-kelpie.connection-trace YES`, also with the key-trace flag) writes every session attempt, outcome, retry decision, path change, suspect marking and attach hand-off to `Documents/connection-trace.log`, pulled with `devicectl device copy from`. Zero cost off. The builder's code check of the three round-13 candidates: the reusable-socket hole is fixed by `cab2da6` (two residual holes: `windDown` clears the suspicion again, and a path that moves and moves back while the app is frozen leaves no change to record); the host-key presenter is mounted on the root screen and a decline is non-retryable anyway; the timeouts are identical. So Preflight proves only the short-lived path; the likeliest failure is something only the session does (the long-lived subscribe or the attach PTY channel) dying on the Tailscale path. The trace is how the next off-Wi-Fi run answers that. Review's four should-fixes taken (the sink writes on its own serial queue, an attempt-begins line, a wind-down line, autoclosures on the path note).

**A — Live Activity: no code change; the pipeline is root-screen and iPhone capable as built.** It starts from `ContentView` above the cover, updates locally and by push from the plugin, and shows agent counts and up to five agents on the lock screen and the Dynamic Island. The per-Host toggle defaults off (fail closed, like notify), which is the likeliest reason nothing has shown. Anthony turns it on in the Host's settings on both devices and looks. Tap-through opens the Console cover, which already shows the agent's pane; a jump into herdr's own TUI pane is not possible from outside herdr and is not pursued.

**A — Background lifetime: keep the 20 s grace; no background mode.** iOS grants about 30 s on a background-task assertion, and the app already spends 20 s of it keeping the SSH session live and 8 s tearing it down cleanly (`AppActivityCoordinator.defaultGracePeriod`, `ConsoleStore.suspendTimeout`); stretching it races the expiry handler. Audio, VoIP and location modes would be dishonest for SSH and App Review would say so. The honest gain is on return: it is already silent for a switch under 20 s (the session was never suspended) and shows the reconnecting state otherwise; making that return fast over Tailscale is Open item 22's fix, not a separate one. No socket-level keepalive exists (app-level 30 s ping only), noted as a possible follow-up, not a lifetime extender.

**A — CLAUDE.md: trim the Kelpie section only, keep the Heeler section verbatim.** The review found nothing stale; the savings are pointers (the build recipe lives in `Build and deploy.md`, the root-screen reasons in ADR 0017, the depwatch in `Dependency watch.md`). The inherited Heeler section is left word-for-word so the next rebase does not conflict on it, and `herdr.md` explicitly defers the load-bearing herdr facts to CLAUDE.md, so they stay. `/delegate` is now the stated default for every session.

**A — Re-vendor (Open item 25) is safe and can go ahead in its own session.** Upstream libghostty-spm is 78 commits past the pin (`701d3a5`, the real `release: 1.4.0`; `356f730b` in `project.yml` no longer exists upstream), head `7e45d27` tagged `1.6.20260909`. Every Kelpie override is signature-identical at head (some moved to a new `UITerminalView+Clipboard.swift` by a file split), none is duplicated by upstream's `UIPointerInteraction` work, the public `sendMousePos` matches the patch exactly (upstream adds a default). The binary target moved to `upstream.82938b633ba6`, checksum `2d9a26e8…`, so `scripts/fetch-ghostty-artifact.sh` changes too. Kelpie's copy also carries extra shell-integration resources not in the pin, unexplained.

## 2026-09-13 — round 14b: the Tailscale hang named and fixed, taps land on herdr

**A — The hang was the graceful close behind an undeadlined mutex, not the network path.** The iPhone trace (`Archive/round14/iphone-connection-trace.log`): at the Wi-Fi→cellular change every session marked its transport suspect and asked its events stream to end; a Host with only the events channel ended in 1.6 s and reconnected over cellular in 3 s; the primary Host, whose connection also carries the root screen's attach writes and the Console's RPCs, never logged another line. `HeelerSSHTransport`'s ender awaits the reader, whose tail runs `channel.close(timeout: 2 s)` → `SessionDriver.closeStreamLocal` → `acquireOperation()`, a FIFO mutex with no deadline; the 2 s starts only once held, and on a silently dead path the holders never finish. Fix: `EventsSession.endStreamPromptly` bounds the end at 2 s and then abandons the transport (`SSHConnection.abandon`: invalidate the driver, abort the byte transport, no mutex), on the path-change, keepalive-failure and terminal-failure paths; `updateSubscriptions` and `windDown` keep the graceful end (the suspend is already bounded by `ConsoleStore`'s 8 s deadline). The abandon is unconditional, because a graceful `close()` that wins the actor turn parks on the same mutex first. Killing the iPad first ruled out a second-client cause. Set aside: none; the reviewer's package test was added. Device confirmation off Wi-Fi is Anthony's.

**A — Notifications and the Live Activity open herdr's own screen (Open item 28).** Anthony: "the direct UI rather than the abstracted version that heeler came with". A tap lands on the root screen, makes the link's Host primary through the same `select` Switch Host uses, and lowers the Console cover; nothing presents the cover any more except the menu. The pane id stays in the link but is unused: herdr's client takes no pane from outside. The in-app banner at the root lands the same way (follows from the ask). Review must-fix taken: a tap during the ≤4 s Console hand-off used to leave the client off stage and unrejoinable; it now goes back on stage. The dead `requestsConsole` flag and its docs were removed.

**A — Device runs: a 5 s poll in `ContentViewActivityDriverTests` can miss under full-suite load.** It failed once in 1809 and passed alone (36 tests in three suites). Treat a lone failure there as the race until it repeats alone.

**Overtaken — the HeelerSSH package suites cannot run on this Mac.** "Tool-hosted testing is unavailable on device destinations", and the simulator wedged at the test bundle. CI's `run-ci-ios-tests.sh` runs them with a disposable sshd; the new `abandonReturnsWhileTheOperationMutexIsHeld` is unexecuted until a push.

## 2026-09-15 — round 15: the key bar as one pill

**A — The key bar is one floating capsule, not a row of key caps (Open item 31).** Anthony: "The buttons above the keyboard may need better styling - Notion does a good job (see screenshot) of this but open to input." Our call on the shape, taken from his screenshot (`Design/notion-keyboard-toolbar.png`): the bar stays a `UIInputView` in keyboard style so its background is the keyboard's, and inside it one capsule (`systemBackground` in light, a grey lighter than the keyboard in dark, soft shadow with an explicit path) holds plain `.label` glyphs with no caps and no per-key shadow. On a bar wide enough to fit, the keys spread evenly (`.equalSpacing` with a low-priority width tie to the scroll frame); on a phone the same row scrolls. Sticky ctrl and alt lose their tinted cap: armed is a tinted caption, locked is tinted and underlined. The round-11 key-cap look was the alternative and is gone; the group gaps went with it, the only separator now being the hairline before the dismiss button.

**A — Shift+Tab and a hide-keyboard button on the bar (Open item 29).** Anthony: "should also have a shift+tab button to alternate Claude models. Should also have a button the collapse the keyboard". `TerminalControlKey.shiftTab` sends CSI Z (`ESC [ Z`, the bytes `AgentQuickKey.shiftTab` already used) in both cursor modes and stays off the Console pad's `rows`; the two tests that assert the pad covers every case now exclude it. The dismiss button (`keyboard.chevron.compact.down`, "Hide Keyboard") is pinned outside the scroll view so a phone can always reach it, and calls `dismissKeyboard()`, the one route that takes the keyboard down for good (a bare resign is restored by the responder gate).

**Delegation shape.** One Opus builder for the two items in one file area, the diff read by the manager rather than a reviewer (UI only, no transport), the builder's generic-destination product installed on both devices. Item 30 (a composing text field) was kept out: it is a design change, not a bar change.

## 2026-09-13 — round 13: posts and watches

**A — Post with a yes in the same conversation, never on a carried-over approval.** The r/SideProject and r/ClaudeCode texts had a yes on 2026-09-12 and the r/herdr reply none; all three were shown again verbatim and posted only after "all of them". The Chrome allow rule in `~/.claude/settings.json` says the same: the gate is the delegate skill, not the classifier.

**A — The Reddit watch follows every thread Kelpie has posted in, not only the launch posts.** r/herdr (the Heeler author's thread) and the r/ClaudeCode showcase thread were added with `--add` the moment the comments went up, so replies there are caught by the hourly run.

**A — Trust the watch logs in UTC.** A scout read the Reddit watch's last run (`21:24Z`) as an evening stop and reported that launchd had slept through the night; it was 07:24 local. Timestamps under `~/.kelpie/` are UTC; the mini is UTC+10.

**A — A tombstone that loses to a newer local edit is retired, not skipped.** Round 12c's tombstones suppressed a deleted Host for a month; the device run showed that suppression also blocked republishing a Host re-paired after the deletion, so the sibling that deleted it never got it back. The defeated tombstone is now deleted from the synced store on the reconcile that defeats it. Found only because the suite finally ran on a device: six of the thirteen device failures were tests that read repo files from the Mac path and cannot run on hardware (CI's job), five were harness assumptions (a software keyboard, a foreground scene, an iOS 27 accessibility path), one was a test race, one was this.

**A — The root screen shows the session's state, never a bare spinner.** Round 12c gave the Console cover a reconnecting row with a reason; the root client still folded every not-live state into "Connecting" and waited on the session without a deadline. Off Wi-Fi that read as a hang. The root client now presents what the Console would, with Reconnect, and a parked attach fails at the acquisition deadline like `acquireTerminal` already did. Set aside from the review: waiters registered while suspended can be failed by the next activation's first retryable failure (they re-register), the two retry guards are duplicated but never reachable together, a Host edit can draw the outgoing session's status for a frame.

**A — One sanctioned edit to the vendored GhosttyTerminal package.** Anthony, after the trade-off was laid out ("proceed on your recommendation"): libghostty hit-tests links only when the mouse position carries the link modifier, the package kept `sendMousePos` internal, and no `open` member reaches it. A public mods-carrying wrapper is added, recorded in `KELPIE-PATCHES.md`, and a pull request to `Lakr233/libghostty-spm` was prepared — then found unnecessary: upstream `main` has carried the identical public `sendMousePos(x:y:modifiers:)` since `eb4107b` (2026-09-02, "feat(uikit): add first-class pointer input"). The exception therefore lasts only until the vendored package is bumped past that commit (Open item 25); the depwatch's "libghostty-spm newer" finding is now worth acting on. The never-edit rule otherwise stands.

**Overtaken — the depwatch upstream check is now high.** Issue #3: 46 upstream commits, one conflicting file. The next rebase (Open item 5) is due, not optional; it waits for a session with the device unlocked so the rebased build can be confirmed.

## 2026-09-13: how sessions run

**Decided: one round per session, and `/delegate` only when a round splits.** A token review of 11 to 13 Sep (`~/MemoryOS/_watcher/skills/delegate/research/burn-scan/`) priced this project's Claude use at about US$590 at API list rates (a proxy; plan weights are not published): Opus builders 42%, the Fable orchestrator 38%, Opus reviewers 12%, Sonnet workers 6%. The orchestrator sessions ran all day with contexts of 250k to 490k tokens, re-read on every turn, and ten messages into sessions idle past the one-hour cache rewrote the whole context, about $50 of it. The round-14 line making `/delegate` the default for every session is replaced in `CLAUDE.md`: a fix, install and feedback chain stays in the main session, and work outside the round goes to [[Open items]] for the next session. Anthony's words are in [[Feedback log]].

**Decided: `resume.md` holds the current state only.** It had grown to 32 KB of round history that every session reads first. The full file as it stood is `Archive/round14/resume-before-trim.md`; the round history already lives in [[Changelog]] and here. The pre-push check still reads the latest `- Round N` bullets.

**Kept: the Heeler section of `CLAUDE.md` stays verbatim.** The review suggested moving the load-bearing herdr facts (about 5.5k tokens loaded into every worker, roughly 2% of the spend) into a linked note. The round-14 reason wins: the section is upstream's text and stays verbatim so rebases merge cleanly. Anthony: "whatever you recommend".

**Decided: checkpoints, logged ideas and a mid-round restart.** Anthony works from herdr and cannot edit the vault himself, and a session closed before `resume.md` is updated would leave a round in limbo. So "checkpoint" writes an `## In progress` section to `resume.md`, "log:" or "next session:" adds an idea to [[Open items]] in one edit, and a new session that finds an In progress section, commits after the last close-out or a dirty tree reconstructs the round before carrying on.

## Distribution

**A — Xcode sideload now, TestFlight later, App Store possibly.** *(Overtaken 2026-09-11 to 12: the App Store became the plan. `scripts/ExportOptions.plist` carries team `8JQWBQKEXX`; build 1 of 1.0 was uploaded 2026-09-12 and version 1.0 plus the three tips were submitted for review at 02:20 UTC that day as **Kelpie for herdr**. A TestFlight public beta went in alongside it. See [[App Store plan]].)*

**Push notifications were knowingly broken in Kelpie until 2026-09-11.** Heeler's hosted relay signs for bundle `dev.bybee.heeler` with the upstream developer's APNs key, so Apple rejected any push aimed at `TME.Kelpie`. **Fixed 2026-09-11**: `relay/` is deployed on Anthony's own Cloudflare account at `kelpie-apns.getter-tilbury-0m.workers.dev`, APNs key 7RJ68B8QX8 held as a Wrangler secret, and the app and plugin defaults both point at it. Heeler's old relay is on the legacy list so an existing install migrates on its next registration. The pipeline was verified end to end with a hand-run hook; a real delivery to the iPad is still to be seen by Anthony. See [[Heeler upstream]] and [[Open items]].

## 2026-09-15 — round 16: the re-vendor and the rebase onto Heeler v0.1.8

**Decided: `HeelerAppModel` owns the stores, and the app stays one window.** Upstream v0.1.8 made the iPad multi-window (`WindowGroup(for: AgentRoute.self)`) with a `HeelerAppModel` composition root creating every store once. Kelpie adopts the model (less to re-resolve on every rebase; the review confirmed all 34 wirings moved intact, once each) but keeps a single plain `WindowGroup` showing `HerdrClientRootView`, and declares `UIApplicationSupportsMultipleScenes` false: a second window would build a second herdr client competing for the one Attach channel, and upstream's own gating then hides "Open in New Window" and the row drag. CLAUDE.md and ADR 0017 say so.

**Decided: Kelpie's `23c4a30` gives way to upstream's `ConsoleSplitPresentation`, with landscape added.** Upstream ships a fuller version of "an open terminal fills the iPad window", but only in portrait; Kelpie's version fired in both orientations, so the policy now picks `.detailOnly` whenever an Agent is open at regular width.

**Decided: no route restoration at launch.** Upstream restores the Console's Agent route from `@SceneStorage`. On Kelpie the cover is down at launch, so a restored path made the scene directory think that Agent was on screen and `willPresent` silently dropped its pushes. Removed.

**Decided: the key bar writes Kelpie's own byte table; the package owns bare Escape.** The compile fix had routed `sendControlKey` through upstream's `AgentQuickKey` encoder, leaving `TerminalControlKey.bytes` shipping nowhere; the device-confirmed table (round 15) is back. The re-vendored package registers its own Escape `UIKeyCommand` and withholds it during IME composition, so Kelpie's duplicate is dropped and only Cmd+. remains Kelpie's; `interceptHardwareKey` now runs before upstream's scene-command route for the chords it maps, which is what brought Cmd+arrows back.

**Decided: the vendored package carries no patch.** `sendMousePos(x:y:modifiers:)` is public upstream since `eb4107b`, so `KELPIE-PATCHES.md` is deleted and the "never edit the vendored package" rule has no exception. Three Kelpie-side edits were forced by upstream's new non-open conformances (a renamed Escape selector, a drop delegate, a gesture delegate); behaviour unchanged.

**Kept: `make install` reaches the iPad.** Upstream made it iPhone-only and added `make install-ipad`; Kelpie keeps both and falls back to any physical device.

**Rule: a rebase of this size is three builders and narrow reviewers.** Every Opus builder stops at 80 tool calls and every reviewer at 40; the first rebase builder replayed 65 of 105 commits and left 47 stops unlogged, and each of three reviewers finished part of its checklist. Brief builders by commit range and reviewers by area from the start. The dependency watch's "1 conflicting file" was a floor (its dry run stops at the first conflict); the real set was 14. `git merge-tree` sizes a rebase honestly.

**Hashes.** Everything before round 16 resolves through `kelpie-pre-rebase-20260915`; `origin/kelpie` was force-pushed on Anthony's yes.

## 2026-09-15 — builds go to one fixed path

**Decided: main-checkout builds use `~/Library/Caches/kelpie-build` in every session; scratchpad builds delete themselves.** Anthony: "we have a space issue, it seems there are a number of builds for kelpie that never get deleted." The build recipe said `S=<a scratch dir>`, and every session and every delegate worker read that as its own scratchpad under `/private/tmp/claude-501/`, which nothing ever removes. By 2026-09-15 that was 81 derived-data, SPM and result-bundle folders (22 GB) across 9 sessions, with 3.2 GB left on the disk. All were deleted except those of the live round-17 session; logs, reports, git clones and `.xcarchive`s (dSYMs) were kept, 19 GB freed. One fixed path keeps a single warm copy. The lock that made separate paths necessary only bites when two builds run at the same time, and those still get a scratch path, which they delete themselves. Written into `CLAUDE.md` and the round definition of done.

**Done: every simulator erased.** On Anthony's request ("delete simulator data"), `xcrun simctl shutdown all`, `delete unavailable`, `erase all`: `~/Library/Developer/CoreSimulator` went from 13 GB to 210 MB, but only about 2 GiB came back on the disk, because a simulator's files are mostly APFS clones of its runtime. The device definitions stay, so the simulator destinations in the test commands still resolve. The iPhone 17 simulator had been left booted since 2026-09-13. Free space after both cleanups: 25 GiB.

## 2026-09-15 — no standing push toward `/delegate`

**A — The project no longer tells sessions when to use `/delegate`.** Anthony: "lets remove the push to always use the delegate skill in this project." The 2026-09-13 line in `CLAUDE.md` ("Use `/delegate` when a round splits…; a fix, install and feedback chain stays in the main session") is gone, as is the dependency watch's "run it as a `/delegate` round" (the brief in `scripts/depwatch.py` and `docs/guides/dependency-watch.md` now say a large rebase is a round of its own). One round per session and the rest of the 2026-09-13 session rules stay. The skill runs only when he invokes it (it has `disable-model-invocation`), and its global hooks in `~/.claude/settings.json` are untouched: the guard acts only while a delegation marker exists and the loop guard only on subagents. Round history that names `/delegate` is left as written.

## 2026-09-15 — round 17: the keyboard inset, the reconnect flash, Shift+Tab

**A — Round 17 is Open items 34, 35 and 32; the composer (30) waits for its own round.** Anthony at the session start: "check open items and lets select a group for this session", then "for reconnecting, 1 & 2 plus 34, 35 & 32 for this session". Three root-screen fixes small enough to check on the device in one install; kept in the main session per the `/delegate` rule that a fix, install and feedback chain stays with the manager.

**A — The reconnect flash is fixed by keeping the last frame and delaying the card, not by living longer in the background.** Four options were put to him: keep the last frame under the reconnect, show the Connecting card only after a delay, demote the card to a pill, or a longer background life. He took the first two together. The fourth was already ruled out in round 14 (iOS caps the assertion near 30 s and the app uses 20). Why the flash existed at all: after the grace period the Console suspend tears the SSH connection down, the return execs a fresh `herdr`, `replaceTerminal()` builds a new `AttachTerminalStore` with a new surface id, and `HerdrClientView` swaps in a blank Ghostty surface by `.id`; the card itself never dimmed anything.

**Decided: the retired surface stays mounted over the new one until the new one paints; no snapshot, no reused surface.** Three ways were weighed. Reusing the old surface for the new pipeline was rejected: the surface id doubles as the recovery latch's pipeline identity, `TerminalByteFeed` deliberately refuses to replay bytes into a later surface (#141, #152), and a reused view would never re-report its size to the new store. A `snapshotView` of the terminal taken as the scene left `.active` was built first, installed, and came back blank on Anthony's iPad ("i see a blank screen"): UIKit does not carry Ghostty's Metal drawable into the replicant. What ships instead: `HerdrClientView` mounts its surfaces through a `ForEach` keyed by surface id, so when the store swaps pipelines the outgoing surface is not dismantled but moved to a retired slot drawn on top, input disabled, its feed silent, still showing its last frame because Ghostty draws only when bytes arrive. It is released 150 ms after the new terminal reports live (its first output bytes). Only a surface that was ever live is retired, so a replacement that itself never painted does not displace the good frame. The current surface is state, not a read of the store, so the replacement mounts one frame after the store announces it and the old view is never torn down first; both roles are built by one function returning one view type, because a `ForEach` keeps a view across a role change only while its content stays one type.

**Decided: the Connecting card waits one second.** `showsConnectingCard` arms after `connectingCardDelay` (1 s) from the moment the presentation turns `.connecting` and disarms the moment it changes; a reconnect that finishes inside the second shows nothing. The Host's own reconnecting state (with its Reconnect button) is the same kind and takes the same delay, which is fine: the button is for a wait the user can notice.

**Found: the iPad never insets because the root screen never hands the inset its window.** Upstream's `4b697cb` (arrived with the v0.1.8 rebase) made `TerminalKeyboardInset` measure keyboard frames against the window a view gives it through `.terminalKeyboardInsetWindow`, and returns nil otherwise. `ShellTerminalView` calls it; Kelpie's `HerdrClientView` predates the change and did not, so every keyboard frame measured nil. One modifier fixes it. The iPhone presumably insets only in Anthony's memory of the pre-rebase build; the device check covers both.

**Decided: Shift+Tab is both a mapping row and a priority key command.** Item 32's open question was whether the press reaches `pressesBegan` at all or iPadOS takes it first as the focus-backward chord. Rather than spend a key-trace round finding out, both paths are wired: `TerminalHardwareKeyMapping` gains Tab (usage `0x2B`) with Shift alone → CSI Z (`1B 5B 5A`, the bytes the on-screen `⇧tab` key already sends), so `interceptHardwareKey` answers the press when it arrives; and a `UIKeyCommand("\t", .shift)` with `wantsPriorityOverSystemBehavior` answers it when the focus system would otherwise swallow it. The two share `claimHardwareKeyDelivery`, exactly as Escape and ⌘. do, so one press sends one CSI Z whichever route runs first. Plain Tab and every other Tab chord stay with Ghostty's encoder.

## 2026-09-15 — round 18: the composer (Open item 30)

**A — Round 18 is Open item 30, and item 7 is explained, not acted on.** Anthony at the session start: "check open items, lets do 30 and tell my what the 7 pull request is?" Item 7 (an upstream pull request for the iPad input work) stays his call.

**Found: Stage 0 fails on the device, so the composer is built.** The design's cheap path — autocorrect, spell check and predictions switched on for the root screen's terminal itself, as a new `assisted` input style with capitalisation and smart punctuation off — was built and installed first, per his decision 3. His result: "the tests failed, the auto correct is really bad, teh went to yeh and a general typing test yielded auto corrects that were inaccurate." The rewrite path (a suffix replace turned into DELs and a retype, round 12) was not the fault; the corrections were. iOS corrects against the terminal's `UITextInput` document, which is a one-line shadow with no context, and it corrects badly. The `assisted` style was removed in the same round; nothing of Stage 0 ships.

**Decided: the field is on screen whenever the composer is on (and no hardware keyboard is attached), keyboard up or down.** The design drew it only while the keyboard is up. That would have meant every keyboard raise going through the terminal first and a responder handoff to the field on each one — the Console's composer-to-direct machinery, fragile in both directions. A field that is always there is the thing to tap to raise the keyboard (a message bar, as iMessage), the terminal refuses first responder while the composer is active, and a handoff is only needed for the toggle itself when the keyboard is already up. Cost: one row of chrome at the bottom while the keyboard is down, in a mode that is off by default.

**Decided: the mirror counts characters, not scalars or UTF-16 units.** One DEL per grapheme cluster. Everything the on-screen keyboard produces (`é` included, precomposed) is one cluster and one buffer character in a line editor; a flag emoji would be one here and two in a UTF-16 editor, accepted for v1. Controls never leave the field: newline, tab and CR become a space, the rest are dropped, so a pasted block cannot press Enter.

**Decided: the field's bytes go through the terminal view, not `TerminalInputController`.** The design named a raw `sendTyped` on the controller. `HeelerTerminalView.sendComposerBytes` calls the session's `sendInput` instead, the route `sendControlKey` already takes, so the shadow of the current line and the reliable-input hook see the bytes and the terminal's `isLocalInputEnabled` gate applies. No bracketed paste.

**Decided: the field rides the terminal's own key bar.** The `TerminalComposerTextView.inputAccessoryView` getter returns the terminal's `sharedKeyBar` (the same `TerminalKeyBar` instance), so the pill and its sticky state survive the responder swap and there is one bar, not two. Control keys stay the terminal's; a symbol key types into the field unless a sticky modifier is armed, in which case it is a chord and goes raw. The toggle is a leading key on the pill (`character.textbox`, tinted while on), pinned outside the scroll view like the dismiss key and hidden when the handler offers no composer, so the Console's bar is unchanged.

**Decided: Return submits, Backspace on an empty field deletes on the remote line, and submit retypes first.** Submit brings the PTY up to date with the field before the CR, so a field that outlived a reconnect (the control resets its mirror when the terminal changes) still sends what it shows. An empty field's Backspace sends one DEL, for a character typed before the composer was turned on.

**Decided: the field floats like the pill, and the phone's menu button rides above it.** Anthony's screenshot: "the text bar goes end to end whilst the chip row of keys and the keyboard has rounded edges." The strip went; the field takes the pill's fill, side margins, a continuous 24 pt corner and the same shadow, on the terminal's background, so field, pill and keyboard float in one column. On a phone the bottom-corner menu button then covered the field's right end ("it may need to float above the new text box"), so the bar reports its height through a preference and the button pads by it. His close: "the hosts box now floats above the text box."

## 2026-09-15 — round 19: Open items 36, 37, 38

**A — Round 19 is Open items 36, 37 and 38 as one round.** Anthony at the session start: "lets resume on open items 36 37 38".

**Found: item 38 is a regression from the round-16 re-vendor, and every finger tap has reached herdr twice since.** libghostty-spm `7e45d27` added `sendTapClick` to `UITerminalView.touchesEnded`: a short direct touch now sends a press and a release through the core before its keyboard toggle. Kelpie's tap recognizer already reports the same click from `handleTap` (round 12, finding 5: the click goes out first, with the URL and keyboard policy), and its recognizer has `cancelsTouchesInView = false`, so Ghostty's `touchesEnded` ran too. Two clicks per tap. herdr's mobile switcher is `Mode::Navigate` under the mobile layout, and its `close` button (`mobile_switcher_areas`, `src/ui/mobile.rs`, 10 columns by 2 rows at the top right) occupies exactly the cells of the header's switch button (`compute_mobile_header_hit_areas`, `SWITCH_BUTTON_WIDTH` 10): the first click opened the switcher and the second closed it, with one frame drawn between. On the iPad the second click was invisible (a tab clicked twice is the same tab), which is why it surfaced only on the phone. Neither the focus-lost report (`ESC[O`, herdr only releases held keys on it) nor the keyboard's resize (herdr's `handle_resize_poll` only redraws) closes the switcher; both were checked in the 0.8.2 source before the fix.

**Decided: a direct touch ends for Ghostty as a cancel.** `HeelerTerminalView.touchesEnded` forwards direct touches to `super.touchesCancelled` (which only disarms Ghostty's tap candidate) and pointer touches to `super.touchesEnded` as before, since a trackpad click is Ghostty's to send and its tap-to-dismiss resign lives there. The vendored package is not edited. `clickTouch` now writes `tap click col= row=` to the key trace, so the next tap question can be answered from a log.

**Decided: the Kelpie menu button sits in the bottom corner at every width (item 37).** Anthony: "the hosts button in the ipad may need to move to the bottom as it blocks some tab actions." The top-trailing placement dated from round 2, when the right end of herdr's tab strip read as empty; it is herdr's, and the phone already moved the button down in round 11 for the same reason. One overlay alignment, the composer-height padding on every width. Not tried: a smaller pass-through button (his call was the bottom first).

**Decided: item 36 is a foreground lease in `notifications.json`, filtered by the plugin, and the relay stays stateless.** The app already writes its own entry in each Host's registration file over SFTP, and the notify hook already filters that file per push, so the least new machinery is one additive field: `foreground_until`, an ISO 8601 instant the device writes on `didBecomeActive` and every 60 s while active (a 180 s lease), and removes on `didEnterBackground`. The hook sends an alert push only to lease holders while any device holds a live lease, and to every eligible device otherwise; the foregrounded device keeps its push because `willPresent` turns it into the in-app banner. Live Activity updates are not filtered. Accepted costs: a crash or a dead connection leaves a stale lease for up to three minutes, during which the other device gets nothing; clocks are assumed NTP-synced. Rejected: a relay-side memory of foreground devices (the relay is deliberately stateless and never sees a device's state), and a herdr `ui.presence` heartbeat (there is no such API). Spec: `Archive/round19/spec-36-foreground-lease.md`.

**Decided: the mini runs Kelpie's plugin from the pushed `kelpie` branch.** `herdr plugin install` takes GitHub only, so the lease-aware notify hook reached the mini as `github:Getterbetter/Kelpie/plugin@kelpie`, replacing upstream's `ZingerLittleBee/Heeler/plugin@main` (Open item 1c, open since round 3). The config dir is keyed by the plugin id `heeler`, so `notifications.json` and `notify.json` survived. Consequence: a `plugin/` change is live on the mini only after a push and a re-install.

**Logged, not decided: the guard against upstream regressions is Open item 39.** Anthony: "that's twice now a change broke something we'd previously developed". The three cases all rode in with upstream code on UIKit paths unit tests cannot reach; the candidates are a both-device run of the regression list after every rebase or re-vendor, and an override-point diff of the vendored UIKit files. His call which first, in its own session.

## 2026-09-15 — round 20: the device suite is the gate (Open item 39)

**A — Anthony chose the process guard, and made it stronger than the item proposed.** "i think we run the ui tests at the end of each change, ipad & iphone, ill just plug them in when its time to test." Item 39 had offered a both-device regression run after a rebase or re-vendor; the rule is now every change, both devices, the full `HeelerTests` suite on hardware. The override-point diff of the vendored UIKit files (item 39's piece b) is logged as Open item 40, unscheduled.

**Decided: a gate that is always red is no gate, so the known device failures are fixed, not listed.** Round 19 closed with "15 issues, only the known ones" on the iPad and 6 on the iPhone; the round-16 run had the same 15. A regression among them would have read as a sixteenth known issue. Anthony: "the last round of tests found issues, should we fix them in this session?" Yes, and this is what they were: six tests read the checkout's own files (source policy ×3, licence inventory ×2, the Settings source ×1) through `#filePath`, which no device test host can see; four keyboard tests need the software keyboard, which the docked Magic Keyboard keeps down; one upstream test asserted the iPhone's resolution of `NavigationSplitViewVisibility.automatic`.

**Decided: preconditions the host may not meet are declared as traits, never as failures.** New `Tests/HeelerTests/TestHostConditions.swift`: `readsRepository` (`.enabled(if:)` on `project.yml` being reachable from `#filePath`) and `presentsSoftwareKeyboard` (`GCKeyboard.coalesced == nil` on a physical device; always on for the simulator so CI keeps the four keyboard tests). A skipped test prints its reason in the log and counts as a skip, which the runner reports separately from failures. Why traits and not deleting the tests: the source-policy and licence tests are release commitments that CI still executes on the simulator; the keyboard tests run on the iPhone and on an iPad with the keyboard detached.

**Decided: the split-visibility test asserts what the platform resolves, not what the iPhone does.** `NavigationSplitViewVisibility.automatic` is opaque and compares equal to `detailOnly` on the iPhone and to a visible-sidebar value on the iPad, so `ConsoleSplitVisibilityState` cannot tell a report of `automatic` from the concrete value and reads it as that. Upstream's `automaticReportDoesNotClaimVisibleOrRecordIntent` encoded the iPhone branch only; it is now `automaticReportReadsAsThePlatformsResolution` with both branches, chosen at run time by comparing `.automatic` to `.detailOnly`. Nothing in the app changed: on the iPad a portrait `automatic` report records the sidebar as the user's choice, exactly as an `.all` report would.

**Decided: one command runs the gate.** `scripts/device-tests.sh [ipad|iphone]...` (`make test-device`, `test-device-ipad`, `test-device-iphone`) resolves each device with `devicectl`, waits up to `DEVICE_WAIT` seconds (default 900) for it to be connected so it can be started before the device is plugged in, runs `xcodebuild test` in the fixed warm path, deletes the result bundle, and prints the test-run summary line, every `✘ … recorded an issue` line and the skip count; exit 1 on any failure or missing device. The log stays at `~/Library/Caches/kelpie-build/device-tests-<kind>.log`, overwritten each run.

## 2026-09-15 — round 21: the override-point diff, and build 5 was never distributed (Open items 40, 41)

**A — Anthony chose the round.** "do item 40 and the build 5 check": the re-vendor guard, and plan item 6 from `resume.md`.

**Decided: the diff is derived from Kelpie's sources, not from a hand-kept list.** Item 40 proposed a fixed list of override points (`touchesBegan`, `pressesBegan`, `sendKey`, …). `scripts/ghostty-override-diff.py` instead reads every class that subclasses `UITerminalView` and takes its `override` members as the override points, its non-override members as collision candidates, its extension conformances as conformance candidates, and every identifier in `Sources/Heeler` as the set of public API it may call. Why: the list drifts with every round (45 override points and 267 own members today), and round 16's three collisions were all in members the item's list did not name.

**Decided: only open and public upstream members, and any `@objc` member, count as collisions.** A private or internal upstream twin is invisible across modules and cannot break the build; it is reported as context ("shadow"). `handleEscapeKeyCommand(_:)` still counts because Kelpie's declaration is `@objc`, which is what collided in round 16. Why: the test replaying round 16 would otherwise report `escapeKeyCommands`, a private `let`, as a break it never was.

**Decided: the old side of a re-vendor diff is Kelpie's own history when upstream's is gone.** libghostty-spm has rewritten its history since the first vendoring (`356f730b` no longer exists on any ref), so `--old kelpie:<rev>` reads the vendored copy at a Kelpie commit, and the regression test replays round 16 from tag `kelpie-pre-rebase-20260915` with no network. The bare upstream clone lives at `~/Library/Caches/kelpie-build/libghostty-spm.git` under the fixed-path rule (2026-09-15), fetched on every run unless `--no-fetch`.

**Decided: the diff is a step of the recipe, not a gate on its own.** It exits 1 on findings so the recipe stops to read them, but it is a declaration parser: it does not see behaviour changes inside members Kelpie never touches. The device suite (item 39) stays the gate after the build. Why: two guards with different blind spots, one before the build and one after.

**Decided: `make distribute` is part of the TestFlight recipe.** The build-5 check found builds 3, 4 and 5 uploaded and never put in the external group; the App Store plan recorded the step, the Build and deploy recipe did not, and three rounds followed the recipe. `asc-kelpie.py --distribute-build` is idempotent and dry-run by default like the rest of that script, and the recipe now ends with it. Why: "uploaded" has meant "nobody can install it" three times.

**A — the write to TestFlight waited for Anthony, then went on his "proceed".** The session's permission gate refused the group write, and it is outward-facing to 16 testers; he approved it after the report and build 5 reached `IN_BETA_TESTING` at once, no beta review wait, since the version was already approved on build 2.

**Also fixed: `depwatch_test.py` had been red since round 16** (it asserted the old libghostty tag). It now asserts the pinned tag's shape and the exact parse against a fixture URL, so the next re-vendor does not turn it red again.

## 2026-09-16 — round 22: Kelpie Chat, the roadmap and the spike (Open item 43)

**A — Anthony opened a new direction.** "im wondering how much of the ui we could absract from herdr so it becomes what feels like a polished iphone app" — a chat like the Claude app, tappable artifacts, a workspaces-and-agents panel, richer notifications, a [+] for attachments. Asked, he chose **iPhone-first with a setting to turn the feature off**, and **a roadmap plus a live spike with no app code** for this round. The 2026-09-12 "the direct UI rather than the absracted version" stands for the iPad: ADR 0017 is unchanged there.

**Decided: the chat's read model is Claude Code's transcript file on the host, and herdr keeps control (ADR 0019).** herdr's API has no conversation concept (102 methods on protocol 22; `agent.read` is a flat, capped, idle-only blob), which is why ADR 0012 rejected a chat view. Claude Code's `~/.claude/projects/<cwd>/<session>.jsonl` has every user turn, assistant text, tool call, tool result and inline image, and `pane.process_info` plus `~/.claude/sessions/<pid>.json` map a pane to it exactly. Prompts, permission answers, staging, download and the status push all stay on herdr and the existing `Transport`. Why: it is the only structured source that exists, and it keeps the agent under herdr's supervision, which is the reason Kelpie exists.

**Decided: the spike ran before any code, on the mini, with a throwaway agent.** Six questions (mapping, first-prompt creation, cadence, permission shape, images, cost) were answered live in one session (`Archive/round22/`), the workspace closed and every file removed. Why: the whole programme rests on a file format the app does not own; a build on assumptions would have found out in round 43b what a script found in an hour.

**Decided: the permission card reads the mode before offering buttons.** Auto mode passes through `blocked` for about 5 s while the classifier decides, then answers itself; manual mode waits. The transcript's `permission-mode` line says which. Why: a card that answers itself teaches the user to ignore it.

**Rejected:** headless `claude -p … --output-format stream-json` over exec (loses herdr's supervision and the TUI's permission flow); the `cc-socks` session socket (private); parsing the TUI repaint (ADR 0012). Written up in [[Kelpie Chat]].

**Also: this Mac is the mini.** `ssh mac-mini` resolves to this machine (`hostname` = `Mac-mini.local`), so "over `mac-mini`" in the notes and a local read are the same thing; the spike's ssh timings are a loopback floor, not the Tailscale figure.

