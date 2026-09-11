---
note: What a Mac user of herdr gets that the iPad user does not yet, ranked, with the fix idea for each. Anthony asked for this on 2026-09-11; the scout's full evidence is in Archive/round3/mac-vs-ipad-gaps.md.
---

# Mac vs iPad gaps

Working through the iPad means herdr runs on the mini and only the terminal byte stream crosses to the iPad. Everything herdr does *outside* the byte stream — the Mac clipboard, `open`, Preview, notifications, sounds — stays on the mini. This is the list of what that costs and what closes each gap.

| # | Gap | Today on the iPad | Fix idea | Effort |
|---|-----|-------------------|----------|--------|
| 1 | **Photos and files into a pane** | Being built (round 4): paste incl. Cmd+V, drop, Attach Photo/File in the menu → SFTP → path typed into the pane | — | done |
| 2 | **Copy out of a pane to the iPad clipboard** | **Works** (confirmed on the device 2026-09-11, no code needed). Was: Unknown. herdr copies with `pbcopy` on the mini; it also forwards OSC 52 writes, and Ghostty on the iPad wires OSC 52 to `UIPasteboard`. A local test could not provoke a selection, so **check on the device**: select text in herdr with the trackpad, paste into Notes. | If it lands on the mini only: a Kelpie-side selection (the two-finger selection sheet already exists) that copies from Ghostty's own grid, not herdr's | S–M |
| 3 | **Desktop notifications from herdr** (`ui.toast.delivery = "terminal"`, OSC 9/777) | **Built** (round 5): banner in the foreground, local notification in the background. Needs the mini config line; gated. Was: Dropped. Ghostty decodes them (`TerminalSurfaceDesktopNotificationDelegate`) and nothing in the app adopts the delegate | Adopt it: local notification when backgrounded, in-app toast when not | S |
| 4 | **Push notifications when the app is closed** | Not working until the relay is deployed ([[Open items]] 4) | Deploy `relay/` as a Cloudflare Worker; needs Anthony's yes | M |
| 5 | **Viewing a file an agent made** (PDF, screenshot, report) | **Built** (round 5): tap a path or Open File on Host… → SFTP download → Quick Look + share. Was: Nothing: only URL taps are intercepted; no Quick Look, no share sheet, no download | "Open on iPad" for a path under the pointer or a long-press: SFTP download → Quick Look / share sheet | M |
| 6 | **Inline images in the terminal** (Kitty graphics, herdr's experimental `kitty_graphics`) | Not rendered; the vendored Ghostty iOS build has no graphics-protocol code | Upstream libghostty question; not ours | L |
| 7 | **Mouse drag to resize panes, sidebar drag** | Trackpad drag is already reported by the vendored view (motion under `?1002h`). **Finger** hold-then-drag is a left-button drag (round 6); taps always worked | Encode SGR motion events while a trackpad button is held; check on the device first | M |
| 8 | **Stage Manager / multiple windows** | Off. Assessed in round 5: the stores live in `ContentView` per scene; five moves listed in `Archive/round5/report-5b.md` | Enable scenes; one Host per window would be the natural model | M–L |
| 9 | **Keys the Magic Keyboard lacks** | Escape via Cmd+. done; **Cmd+arrows = Home/End/PageUp/PageDown** (round 5) | Map Fn+arrows if iPadOS delivers them; on-device check | S |
| 10 | **Terminal bell, herdr sounds** | **Bell is a haptic** (round 5); sounds play on the mini | Haptic on BEL; sounds stay on the Mac | S |
| 11 | **Dictation, emoji, IME** | Autocorrect and smart quotes are off on the terminal; dictation unverified | On-device check | — |

Already fine: background/resume reconnect, bracketed paste end to end, text paste, URL taps opening on the iPad, keyboard mapping (rounds 3–3b).

## Suggested order

3 (small, visible), then 2 once the device check says what is needed, then 5. 4 stays gated on Anthony. 6 and 8 are not worth chasing yet.

Related: [[Open items]] · [[Feedback log]] · [[Kelpie]]
