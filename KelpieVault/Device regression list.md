---
note: The fixed per-build device checklist; run all of it after every install, tick nothing off permanently.
---

# Device regression list

Written 2026-09-12 after a trackpad right-click regression (introduced in round 6, never device-verified before it) shipped three rounds unnoticed because each round only tested its own new feature. Run every item below, in this order, on every fresh install — before handing the build to Anthony or calling a round done.

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

## Console cover and menu

- Open the Kelpie menu → Settings → Tip sheet lists all three tip tiers. (round 9 — `Feedback log.md:130`)

## Media and files

- Copy a photo in Photos, use Attach Photo/File from the Kelpie menu → an upload capsule appears and a staged path is typed into the pane. (round 4 — `Feedback log.md:65`)
- Select text in herdr and copy it → pastes correctly into another iPad app. (round 4 — `Feedback log.md:67`, `Open items.md:15`)

## Never confirmed on the device

- Trackpad two-finger scroll inside a pane. (`Open items.md:19`, `Testing status.md:47`)
- One-finger long-press as a right click, reaching herdr's menu. (`Testing status.md:36`, `Open items.md:19`)
- Cmd+arrows as Home/End/Page keys. (`resume.md:24`)
- Bell haptic on `printf '\a'`. (`resume.md:24`)
- Quick Look file viewer from a tapped path. (`resume.md:24`)
- Desktop notifications (gated on the mini's `ui.toast.delivery` config). (`resume.md:24`)
- Welcome screen with zero Hosts configured. (`resume.md:24`)
- Drag-and-drop from Files onto the terminal (last seen actively broken, round 4 — `Feedback log.md:66`). (`resume.md:24`)
- Paste-first pairing flow. (`resume.md:24`)
- Tapping a URL, opening it on the iPad rather than sending it to herdr. (`Testing status.md:23`)
- Automatic keyboard mode switching live as a hardware keyboard connects/disconnects. (`Open items.md:19`)
- Notification deep links landing on the right agent. (`Open items.md:19`)

## Automatable now

`scripts/drive-ipad.sh` (see `docs/guides/driving-the-ipad.md`) can already drive: opening the Kelpie menu and any item in it (`menu:Settings`, `menu:Setup`, `menu:Tip`), hardware key presses including `escape`, `cmd+.`, `return`, `ctrl+c`, arrows, typing text into a focused field, toggling switches, and back navigation — so the Console-cover-and-menu section and the Return-submits check above are scriptable today. It has no gesture step for a trackpad right-click, long-press, drag, or selection handle, so the Magic-keyboard-attached word-editing checks and everything pointer/touch-based in **Both** and **Keyboard detached** still need a human. With `-kelpie.key-trace YES` and the log pulled via `xcrun devicectl device copy from --domain-type appDataContainer --domain-identifier TME.Kelpie --source Documents/key-trace.log`, a trackpad right-click must produce a `right click reported sent=true` line and a touch hold must produce a `hold right click … sent=true` line — both assertable without a human once the trace is pulled.

Related: [[Open items]] · [[Feedback log]] · [[Testing status]]
