---
note: The fixed per-build device checklist; run all of it after every install, tick nothing off permanently.
---

# Device regression list

Written 2026-09-12 after a trackpad right-click regression (introduced in round 6, never device-verified before it) shipped three rounds unnoticed because each round only tested its own new feature. Run every item below, in this order, on every fresh install — before handing the build to Anthony or calling a round done. Since round 20 the unit suite on hardware is the other half of the gate: `make test-device` runs `HeelerTests` on the iPad and the iPhone at the end of every change, and a rebase or re-vendor round runs this list on both devices as well (Open item 39, [[Decisions]] 2026-09-15).

## Magic Keyboard attached

- Press Escape or Cmd+. → herdr receives Escape. ("escape works, thank you", round 3b — `Feedback log.md:50`; confirmed for real on Cmd+., round 3b — `resume.md:11`)
- Press Option+Backspace in a shell → deletes exactly one word. (round 3 — `Feedback log.md:48`, `resume.md:11`)
- The floating menu is a labelled Host capsule top-right with Switch Host / Hosts listed first. ("great stuff", round 3 — `Feedback log.md:49`)

## Keyboard detached (touch + software keyboard)

- Tap Return on the on-screen keyboard in a shell pane → submits the line. (round 9 — `Feedback log.md:130-132`, `Open items.md:20`)
- Double-tap a word in a pane → selection handles appear; drag a handle → selection extends and stays inside the pane; Copy works. (round 6b — `Feedback log.md:90`, `resume.md:16-17`)
- Long-press the sidebar edge, then drag with the same finger → a translucent ring shows under the finger and the pane resizes. ("the ring is good", round 6c — `Feedback log.md:92`, `resume.md:17`)

## Both

- Right-click a herdr tab or any other part of the terminal with a trackpad or mouse → herdr's own context menu opens, never iPadOS's Copy/Select edit menu. (broke silently between round 1 and round 6; caught and fixed round 9 — `Feedback log.md:134-140`; ADR — `docs/adr/0016-ipad-pointer-input.md:14-33`)
- Resize the app to Split View (half-screen) with another app → the window reshapes instead of keeping its old aspect. ("Split View works well", round 5 — `Feedback log.md:73`, `resume.md:13`)

## iPhone (herdr's mobile layout, 64 columns or fewer)

- Tap herdr's "switch" button in the top right → the tab switcher stays open until a row or its close button is tapped. (broke silently at the round-16 re-vendor, Ghostty's own tap click doubling Kelpie's; caught by Anthony in round 18, fixed round 19 `f6b642f` — Open item 38)
- Tap an agent's screen text with the keyboard down → the keyboard rises; tap it again outside the input band → the keyboard drops after the 350 ms grace. (round 14 — Open item 24; the doubled click of item 38 would have shown here too)
- One-finger drag on a Claude pane → its viewport scrolls and it draws its own "Jump to bottom" affordance. (round 1; never re-confirmed on the phone)
- Turn the composer on from the pill → the field appears above the key bar, autocorrect and a prediction land in the field, Return sends the line and the terminal takes the keyboard back on Esc. (round 18 — Open item 30, "it works well")
- Rotate to landscape with an Agent open → the terminal keeps the full width and the keyboard inset still reflows it. (round 11, not separately confirmed since the rebase)

## Console cover and menu

- Open the Kelpie menu → Settings → Tip sheet lists all three tip tiers. (round 9 — `Feedback log.md:130`)

## Media and files

- Copy a photo in Photos, use Attach Photo/File from the Kelpie menu → an upload capsule appears and a staged path is typed into the pane. (round 4 — `Feedback log.md:65`)
- Select text in herdr and copy it → pastes correctly into another iPad app. (round 4 — `Feedback log.md:67`, `Open items.md:15`)

## Never confirmed on the device

- Trackpad two-finger scroll inside a pane. (`Open items.md:19`, `Testing status.md:47`)
- One-finger long-press as a right click, reaching herdr's menu. (`Testing status.md:36`, `Open items.md:19`)
- Cmd+arrows as Home/End/Page keys. (`Archive/round14/resume-before-trim.md`, line 24)
- Bell haptic on `printf '\a'`. (`Archive/round14/resume-before-trim.md`, line 24)
- Quick Look file viewer from a tapped path. (`Archive/round14/resume-before-trim.md`, line 24)
- Desktop notifications (gated on the mini's `ui.toast.delivery` config). (`Archive/round14/resume-before-trim.md`, line 24)
- Welcome screen with zero Hosts configured. (`Archive/round14/resume-before-trim.md`, line 24)
- Drag-and-drop from Files onto the terminal (last seen actively broken, round 4 — `Feedback log.md:66`). (`Archive/round14/resume-before-trim.md`, line 24)
- Paste-first pairing flow. (`Archive/round14/resume-before-trim.md`, line 24)
- Tapping a URL, opening it on the iPad rather than sending it to herdr. (`Testing status.md:23`)
- Automatic keyboard mode switching live as a hardware keyboard connects/disconnects. (`Open items.md:19`)
- Notification deep links landing on the right agent. (`Open items.md:19`)

## Before any commit of media

- Open every new screenshot, clip or recording under the vault and look at its first and last frames and every visible window before `git add`. The round-8 review clip shipped a lock screen to the public repo because nobody did.

## Automatable now

`scripts/drive-ipad.sh` (see `docs/guides/driving-the-ipad.md`) can already drive: opening the Kelpie menu and any item in it (`menu:Settings`, `menu:Setup`, `menu:Tip`), hardware key presses including `escape`, `cmd+.`, `return`, `ctrl+c`, arrows, typing text into a focused field, toggling switches, and back navigation — so the Console-cover-and-menu section and the Return-submits check above are scriptable today. It has no gesture step for a trackpad right-click, long-press, drag, or selection handle, so the Magic-keyboard-attached word-editing checks and everything pointer/touch-based in **Both** and **Keyboard detached** still need a human. With `-kelpie.key-trace YES` and the log pulled via `xcrun devicectl device copy from --domain-type appDataContainer --domain-identifier TME.Kelpie --source Documents/key-trace.log`, a trackpad right-click must produce a `right click reported sent=true` line and a touch hold must produce a `hold right click … sent=true` line — both assertable without a human once the trace is pulled.

Related: [[Open items]] · [[Feedback log]] · [[Testing status]]
