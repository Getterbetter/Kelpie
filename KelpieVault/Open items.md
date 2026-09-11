---
note: The Kelpie checklist — open work in priority order, plus the reviewer nits not taken.
---

# Open items

## Priority order

- [ ] **1. Confirm round 3 on the iPad**: ~~Escape and Cmd+.~~ (confirmed working, `5afab42`) · Option+Backspace deleting one word and only one word · Option+Left/Right jumping words · plain Backspace and Return unchanged · the host capsule top-right, and Hosts / Switch Host from it. If Option+Backspace deletes a word *plus* a character, the UIKit echo arrived after the press ended — see the note in `scheduleHardwareKeyClaimReset`.
- [ ] **1f. Round 5 on the device**: drop from Files · Cmd+←/→/↑/↓ in a shell · tap a file path in Claude's output (Quick Look + share) · Open File on Host… · bell haptic (`printf '\a'`) · font stepping down as the window narrows · desktop notification once the mini config line is in.
- [ ] **1g. Round 6 (next)**: finger taps on herdr's sidebar do nothing, finger drag cannot resize it; selection by touch stops at one word — wants iPadOS-style handles. Scout notes in `Archive/round5/` when they land.
- [ ] **1a. Try media into herdr on the device** (round 4, installed): copy a photo in Photos → Cmd+V in a Claude Code pane inside herdr (expect an upload capsule, then a `/tmp/heeler.…/stage-…/photo.jpg` path typed into the pane) · drag a file from Files in Split View onto the terminal · Attach Photo / Attach File in the Kelpie menu · a paste of plain text still pastes text. Then ask Claude what is in the image.
- [x] **1d. Clipboard out** — works (2026-09-11).
- [x] **1e. Window size** — built in round 5; "split view works well".
- [ ] **1b. See the Welcome screen on the device.** Setup Guide in the Kelpie menu shows it; the no-Host root needs the Host removed first. Try Paste Pairing Code with a fresh code from the mini, and the typed field.
- [ ] **1c. Put the fixed pairing plugin on the mini** — *Anthony will not test the QR himself; low priority.* The installed plugin is upstream's (`github:ZingerLittleBee/Heeler/plugin@main`); the QR clamp fix lives in this repo's `plugin/`. Either link the local checkout into herdr or upstream the fix.
- [ ] **2. On-device verification of round 2.** Nothing in round 2 has been exercised on the iPad beyond launching it. The list: trackpad two-finger scroll inside a pane · trackpad right-click opening herdr's menu · one-finger long-press as a right click · tapping a URL (especially one ending a line) · the keyboard pad appearing when the Magic Keyboard is detached · automatic keyboard mode switching live · the floating menu and the Agents cover · notification deep links landing on the right agent. Detail in [[Testing status]].
- [ ] **3. Return-to-submit in the console's Keyboard mode.** Partial fix only: Direct Input now claims first responder while a hardware keyboard is attached, which was a real gap. If Return still fails, the remaining suspect is UIKit loaning Return to the IME under the `.naturalLanguage` text-input traits the agent terminal uses — shell terminals use `.terminal` and are reported working. Needs a device to confirm.
- [ ] **4. Deploy our own push relay.** Cloudflare Worker from `relay/` with Anthony's own APNs `.p8`, `APNS_TEAM_ID = 8JQWBQKEXX`, `APNS_TOPIC = TME.Kelpie`; point the app (or the in-app Custom Push Relay setting) and the plugin default at it. Cost ≈ zero. **Mandatory for any App Store build**; a personal build could instead have the plugin on the mini call APNs directly. Outward-facing — needs Anthony's explicit yes. Background in [[Heeler upstream]].
- [ ] **5. TestFlight upload.** Needs his yes. `scripts/ExportOptions.plist` already carries team `8JQWBQKEXX`; `make bump && make testflight` is the upstream path.
- [ ] **6. Rebase on Heeler upstream.** It moves daily. The conflict surface is small by design — see [[Heeler upstream#Rebase strategy]].
- [ ] **7. Consider a pull request upstream** for the iPad input work. Anthony's call; deliberately deferred while the fork is private.
- [ ] **8. Run the unit suite** on any machine whose CoreSimulator can install an app. Every suite is platform-independent logic.

## Reviewer nits not taken

From the two fresh-context reviews. The "should-fix" findings from both rounds were all addressed (round 1 in `01a7923`, round 2 in `58199a7`); these are the ones left deliberately.

### Round 1 — [[Archive/round1/review|review]]

- [ ] **`.detailOnly` assumes a sidebar toggle that may not be visible.** `ConsoleView` hides the sidebar whenever an agent is open on regular width, on the premise that the standard display-mode button brings it back — but the agent terminal deliberately draws an empty, clear-backed nav bar it renders *under*. Nobody has seen this on an iPad. Not a hard trap: `AgentEdgeBackGesture` dismisses and restores `.automatic`. **Check this during round-2 device verification.**
- [ ] **The collapse trigger is "an agent is selected", not "a terminal is open".** A non-empty router path also covers the removed-worktree and missing-agent `ContentUnavailableView`s, so the sidebar hides behind those too. Harmless; both carry their own way back.
- [ ] **The sidebar can stay revealed when switching agents.** Reveal it by hand inside agent A, tap agent B: the preferred value has not changed, so the new terminal is not full-bleed. Deliberate — the alternative fights the manual toggle — and self-correcting on the next navigation.
- [ ] **The two-finger selection sheet loses its anchor.** Ghostty's own path computes an anchor from `quicklookWord()` so the sheet opens with the touched word selected; Kelpie passes `anchorRange: nil`. Per spec; noted so the difference in feel is not a surprise.

### Round 2 — [[Archive/round2/review|review]]

- [ ] **A full viewport read on every tap, twice.** `linkURL(at:)` does a C call plus a whole-viewport UTF-8 copy on the main thread, and runs twice per direct tap and twice per trackpad click (once in `gestureRecognizerShouldBegin`, once in the handler). A short-lived cache keyed on the surface's damage counter would collapse it to one.
- [ ] **Wide characters and tabs shift link columns.** The detector indexes by grapheme while the grid mapper counts cells, so a CJK or wide-emoji glyph earlier in a row puts everything to its right off by one per glyph. Rare in herdr's TUI. At minimum it wants a line in the doc comment, which currently claims wrapping is "the one piece of terminal-specific knowledge".
- [ ] **The grid mapper clamps to the grid,** so a tap in the bottom or right padding resolves to an edge cell and can open a URL that is not under the finger.
- [ ] **`.environment(hardwareKeyboard)` is dead.** `ContentView` injects it and nothing reads `@Environment(HardwareKeyboardObserver.self)` — every consumer takes it as an explicit `let`. Should be one or the other, not both.
- [ ] **The font default keys off idiom, not width.** `UIUserInterfaceIdiom == .pad` rather than a regular-width window, so an iPad in a compact Slide Over still starts at 12 pt. A quiet narrowing of the spec.
- [ ] **A `UITouch` is retained strongly** in the link-claim state, where round 1's right-button equivalent is `weak`. UIKit's guidance is not to retain touch objects past the event; a stale claim is inert rather than harmful thanks to the `touches.contains` guard.
- [ ] **`.onDisappear { notificationRouter.path = [] }`** sits on a view used both as the cover's content and as the no-host root, so adding the first Host clears the path as a side effect. Harmless today.
- [ ] **The menu button raises opacity on hover but not on press.** The spec said "hover/press"; the menu dims the screen anyway.

## Known and accepted

- **Push notifications do not work in Kelpie** until item 4 is done. Not a bug to chase.
- **Unit tests cannot be executed on this Mac.** Item 8; do not spend more time on the simulator.
- **The test target cannot compile for a device destination** — `SidebarConsoleIntegrationTests` depends on simulator-only demo code. Pre-existing upstream.
- **Only the forward wrapped-URL join is implemented:** a tap on the *continuation* row of a wrapped URL returns nil. The first row is the larger target.

Related: [[Kelpie]] · [[Testing status]] · [[Decisions]]
