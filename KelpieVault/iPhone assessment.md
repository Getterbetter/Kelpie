---
note: Whether Kelpie's concept (herdr's own TUI as the screen) carries to the iPhone, measured live on 2026-09-12; the answer is yes, and mostly for free.
---

# iPhone assessment

Anthony's ask (2026-09-12, [[Feedback log]]): keep herdr's UI on the phone too, sidebar collapsed, the agent pane filling the screen, the Kelpie menu as the fallback.

## What herdr does at phone widths (measured live on the review host, herdr 0.9.0)

- `[ui] mobile_width_threshold = 64`: at 64 columns or fewer herdr switches itself to a **single-column mobile layout** — a two-line header (workspace · tab, agent status), no sidebar, one pane full width. No "terminal too small" message at 47×38, 60×30 or 100×20. Captures: `Archive/round9/phone-captures/`.
- Above 64 columns (a phone in landscape at 12 pt is ~100) the desktop layout comes back: sidebar 25 columns, `prefix+b` collapses it to a 3-column rail (`sidebar_collapsed_mode = "compact"`; `"hidden"` exists as a config value).
- Keys: prefix `ctrl+b`; sidebar `prefix+b`; zoom `prefix+z`; tabs `prefix+1..9`, `prefix+n` / `prefix+p`; detach `prefix+q`.

So the "sidebar collapsible somehow" and "agent transcript in the main screen" requirements are met by herdr itself in portrait; nothing in Kelpie has to draw or hide anything.

## What of Kelpie carries over unchanged

Everything on the touch path: the root screen (`exec herdr` over SSH), touch long-press as right click, hold-then-drag, double-tap selection with handles, the chip row above the keyboard, on-screen Return, URL taps, photo and file intake, the host capsule (already icon-only under 500 pt), the console cover, push notifications and Live Activities. The trackpad and hardware-keyboard paths are simply inert on a phone.

## What an iPhone build needs

1. `TARGETED_DEVICE_FAMILY: "1,2"` on the app targets (one line; 7c made it iPad-only for the 1.0 review).
2. Font: 12 pt gives about 50 columns portrait on a 6.1"–6.9" phone — inside the mobile threshold — and about 100 landscape. Worth an iPhone default of 11 pt so landscape keeps room; check the width-aware stepping already in `HerdrClientRootView`.
3. Navigation with no sidebar: herdr's mobile header has no tap targets for workspaces. Add "Next tab / Previous tab / Toggle sidebar / Zoom pane" to the Kelpie menu, each sending the prefix sequence — the "backup menu" Anthony asked for. The Agents cover and Switch Host already exist.
4. Keyboard up in portrait leaves ~18–20 rows; acceptable for an agent transcript, cramped for a shell. Landscape with the keyboard up is not usable, same as every phone terminal.
5. App Store: iPhone becomes a 1.1 — 6.9" screenshots (mandatory) and a universal listing; do not touch the 1.0 submission. Privacy and everything else carries.
6. Test on a real iPhone; the simulator does not run on this Mac.

Effort: a day, most of it screenshots and the menu items. Risk: low — the whole phone layout is herdr's, so herdr updates keep working the way they do on the iPad.

## Built (2026-09-12)

Points 1–3 are done. `TARGETED_DEVICE_FAMILY` is `"1,2"` on all four targets (app, notification service, widgets, UI-test runner) and `Heeler.xcodeproj` is regenerated; the orientation keys already read the way a phone wants them — three for the iPhone, all four for the iPad, no `UIRequiresFullScreen`. `TerminalZoomSettings.defaultFontSize` is 12 pt (the builder tried 11 and its own estimate put a 6.9" phone two columns outside the threshold), so a phone that has never been pinched starts there and the iPad's width-aware stepping is untouched. The Kelpie menu gains a **herdr** submenu between Hosts and Agents — Next Tab, Previous Tab, Toggle Sidebar, Zoom Pane — each typing `ctrl+b` and the letter through `TerminalKeyboardControl.sendHerdrPrefixed`, on every idiom. Estimated at the vault's 0.6 × pt cell width: portrait ≈ 59 columns at 393 pt and ≈ 66 at 440 pt, landscape ≈ 129 and ≈ 145. So a 6.1" phone sits inside the 64-column threshold and a 6.9" one lands a couple of columns outside it — at 12 pt both sit inside (≈54 and ≈61); measure on the real phone. Points 4–6 (rows with the keyboard up, iPhone screenshots for a 1.1, testing on a real phone) are untouched, and the Welcome screen still says "iPad" in its copy.

Related: [[App Store plan]] · [[Open items]] · [[Mac vs iPad gaps]]
