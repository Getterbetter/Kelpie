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

## 2026-09-12 — round 11b: re-parenting after the purge

**A history purge must be followed by a re-parent onto upstream.** Round 11's `git filter-repo` rewrote every commit back to 2026-07-18, not only the ones after the leaked clip, so `kelpie` shared no object with `upstream/main` and `git rev-list upstream/main..kelpie` reported 1252. The dependency watch's rebase rehearsal would have replayed upstream's own commits. The fix was `git tag kelpie-pre-rerebase-20260912`, then `git rebase --onto 375267c <rewritten twin> kelpie` — the twin found by subject, confirmed by identical tree hash — 77 commits, no conflicts, working tree unchanged. The cost is a second hash rewrite for rounds 8 to 11 and a force push. Rule going forward: after any `filter-repo`, check `git merge-base --is-ancestor <upstream base> kelpie` before pushing.

## Distribution

**A — Xcode sideload now, TestFlight later, App Store possibly.** *(Overtaken 2026-09-11 to 12: the App Store became the plan. `scripts/ExportOptions.plist` carries team `8JQWBQKEXX`; build 1 of 1.0 was uploaded 2026-09-12 and version 1.0 plus the three tips were submitted for review at 02:20 UTC that day as **Kelpie for herdr**. A TestFlight public beta went in alongside it. See [[App Store plan]].)*

**Push notifications were knowingly broken in Kelpie until 2026-09-11.** Heeler's hosted relay signs for bundle `dev.bybee.heeler` with the upstream developer's APNs key, so Apple rejected any push aimed at `TME.Kelpie`. **Fixed 2026-09-11**: `relay/` is deployed on Anthony's own Cloudflare account at `kelpie-apns.getter-tilbury-0m.workers.dev`, APNs key 7RJ68B8QX8 held as a Wrangler secret, and the app and plugin defaults both point at it. Heeler's old relay is on the legacy list so an existing install migrates on its next registration. The pipeline was verified end to end with a hand-run hook; a real delivery to the iPad is still to be seen by Anthony. See [[Heeler upstream]] and [[Open items]].
