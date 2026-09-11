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

## Distribution

**A — Xcode sideload now, TestFlight later, App Store possibly.** `scripts/ExportOptions.plist` already carries team `8JQWBQKEXX`.

**Push notifications are knowingly broken in Kelpie.** Heeler's hosted relay signs for bundle `dev.bybee.heeler` with the upstream developer's APNs key, so Apple rejects a push aimed at `TME.Kelpie`. Kelpie needs its own deploy of `relay/`. Not done — it is outward-facing and needs Anthony's explicit yes. See [[Heeler upstream]] and [[Open items]].
