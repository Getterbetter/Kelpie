---
source: "delegate-20260910-191536/inputmap/inputmap.md — Heeler terminal input map with file:line anchors, 2026-09-10 19:29"
---

# Heeler terminal input map

Repo: `/private/tmp/claude-501/-Users-anthonytopalides-Developer/92b1adb6-9c52-4a55-9bde-f6a341d45ac6/scratchpad/delegate-20260910-191536/heeler/repo`
All paths below are under this root. Files inspected: everything in `Sources/Heeler/Terminal/` (14 files) plus `Sources/Heeler/Console/{AgentTerminalView,ShellTerminalView,AttachTerminalStore,ShellTerminalStore}.swift`, `Sources/Heeler/Transport/{TerminalAttach,HeelerSSHTransport}.swift`, `Sources/Heeler/Settings/TerminalThemePreview.swift`, `docs/adr/0001-native-swift-stack.md`, `CHANGELOG.md`; whole-tree grep across `Sources/` for the keywords in the brief.

## 1. View hierarchy

- `Sources/Heeler/Terminal/TerminalScreenView.swift:537` — `final class HeelerTerminalView: UITerminalView, TerminalByteSink`. `UITerminalView` is imported from the external `GhosttyTerminal` package (`import GhosttyTerminal` at line 1) — it is libghostty's iOS surface, not defined in this repo.
- `TerminalScreenView.swift:117` — `struct TerminalScreenView: UIViewRepresentable` wraps `HeelerTerminalView` for SwiftUI; `makeUIView` at line 160, `updateUIView` at line 223.
- Gesture recognizers, all attached in `TerminalScreenView.swift` inside `HeelerTerminalView`:
  - `touchScrollGesture` (`UIPanGestureRecognizer`) — declared 623, installed in `installTouchScrolling()` 1570–1591, handler `handleHerdrTouchScrollGesture` 1692.
  - `zoomGesture` (`UIPinchGestureRecognizer`) — declared 627, installed in `installZoom()` 1593–1598 (disables Ghostty's own pinch handler first), handler `handleHerdrZoomGesture` 1600–1612.
  - `tapGesture` (`UITapGestureRecognizer`) — declared 631, installed in `installTouchScrolling()` 1583–1591, handler `handleHerdrTap` 1645.
  - `gestureRecognizerShouldBegin` override 1296–1313 arbitrates tap vs. Ghostty's own handling.
  - No `UILongPressGestureRecognizer` anywhere in `Sources/`.
- `UIContextMenuInteraction`: used only in `Sources/Heeler/Terminal/TerminalAgentSwitcher.swift:71,279,301,309` — this is the agent-switcher chip UI, **not** the terminal surface.
- No `UIEditMenuInteraction`, no `UIPointerInteraction`, no SwiftUI `.contextMenu(` modifier anywhere in `Sources/`.

## 2. Touch handling

- `touchesBegan`/`touchesEnded`/`touchesCancelled` overrides: `TerminalScreenView.swift:1275,1280,1287` — they only feed `responderGate` (a first-responder arbitration gate, `TerminalTouchScroll.swift:66-106`) via `directTouchCount` (line 1292, filters `$0.type == .direct`); they call `super.touchesX` so Ghostty's own touch handling (tap-to-focus, its own long-press-to-select, indirect-pointer mouse events) still runs underneath, unmodified by this app.
- `touchScrollGesture` (pan): `allowedTouchTypes = [.direct]` (line 1575) — local scrollback / remote wheel-report scrolling; handler `handleHerdrTouchScrollGesture` (1692) calls `scrollTouch(translationY:)` (1531).
- `tapGesture`: `allowedTouchTypes = [.direct]` (1579) — click-report or keyboard-raise; handler `handleHerdrTap`→`handleTap(at:)` (1650)→`tapAction(at:)` (1677).
- `zoomGesture` (pinch): unrestricted touch type — font-size zoom only, not remote mouse.
- `UITouch.type`/`allowedTouchTypes` checks: `TerminalScreenView.swift:1571` (`UITouch.TouchType.direct`), `1292` (`$0.type == .direct`), `1575`, `1579`. **No indirect/trackpad path is ever built here** — comment at `TerminalMouseReporting.swift:6-8` states Ghostty's UIKit layer converts indirect pointers (trackpad/mouse) into mouse events itself; only direct touch reaches this app's gesture code.
- No `UIEvent.buttonMask` or `allowedScrollTypesMask` anywhere in `Sources/`.

## 3. Text selection

- Entry point: `HeelerTerminalView.terminalDidRequestTextSelection(_:)` — `TerminalScreenView.swift:1787-1789` — called by the Ghostty delegate protocol, i.e. **Ghostty itself decides the trigger gesture** (long-press) inside `UITerminalView`; nothing in `Sources/` recognizes a long-press for selection.
- `Sources/Heeler/Terminal/TerminalTextSelectionPresenter.swift:5-18` — `TerminalTextSelectionPresenter.present(_:from:)` presents a `UINavigationController`/`UITextView`-based sheet (`TerminalTextSelectionViewController`, lines 22-60+) with a Done button; no native copy/paste callout menu — it's a dedicated selectable read-only text sheet, not `UIMenuController`/`UIEditMenuInteraction`.

## 4. Mouse reporting (full detail)

`Sources/Heeler/Terminal/TerminalMouseReporting.swift` (89 lines, entire file):
- `enum TerminalMouseEncoding { case legacy, case sgr }` (9-15).
- `enum Button: Int { left = 0, wheelUp = 64, wheelDown = 65 }` (18-22) — only left/wheel button codes defined; no right/middle button case exists yet.
- **`func report(button: Button, column: Int, row: Int, isRelease: Bool = false) -> Data`** (25-41) — builds both SGR (`"\u{1B}[<\(button);\(col);\(row)\(M|m)"`, line 29) and legacy (`ESC [ M Cb Cx Cy`, bytes 0x1B 0x5B 0x4D + biased/clamped values, lines 34-39) sequences. **This already supports press and release for any `Button` case** (via `isRelease`), so the low-level encoder for a button press/release already exists — right-click just needs a new `Button` case + calling `report(button:.right, ...)` / `isRelease: true`.
- `struct TerminalGridPointMapper` (57-89) converts a view-space `CGPoint` to a 1-based `(column, row)` cell: `cell(at:)` (80-88), using `gridOrigin` (71-76, reproduces Ghostty's fixed `window-padding-x/y=2` inset) and `cellSize`/`viewSize`/`columns`/`rows`/`scale`.

`Sources/Heeler/Terminal/TerminalTouchScroll.swift` — `struct TerminalModeTracker` (108-243) parses DECSET (`ESC [ ? ... h/l`) from outbound terminal data (`receive(_:)`, 128-153) and tracks:
  - mode `1` → `usesApplicationCursorKeys` (192-193)
  - modes `47, 1047, 1049` → `isAlternateScreen` (194-195)
  - modes `1000, 1002, 1003` → inserted/removed from `mouseTrackingModes: Set<Int>` (196-201) — `tracksMouse` is `!mouseTrackingModes.isEmpty` (120-122)
  - mode `1006` → `usesSGRMouseEncoding` (202-203)
  - mode `2004` → `usesBracketedPaste` (204-205)
  - **Mode `1016` (SGR-Pixel) is not tracked at all.**
- `mouseEncoding` (124-126) picks `.sgr` if `usesSGRMouseEncoding` else `.legacy`.
- `func remoteScrollSequence(towardOlderContent:columns:rows:) -> Data?` (155-178) — wheel report via `mouseEncoding.report(button: .wheelUp/.wheelDown, ...)` when `tracksMouse`, else cursor-key fallback on the alternate screen.
- **`func remoteClickSequence(column: Int, row: Int) -> Data?`** (183-188) — "A full left-button click on a 1-based cell" — calls `encoding.report(button: .left, ...)` then `encoding.report(button: .left, ..., isRelease: true)`, concatenated. **This is the existing (left-)button press+release sender**; there is no separate press-only/release-only public entry point (needed for drag-select or a genuine right-click-menu flow) and no right/middle button variant.

Byte path to the PTY (how bytes leave the click/scroll code):
- `TerminalScreenView.swift:1493` — `clickTouch(at:)` calls `terminalSession.sendInput(report)` where `terminalSession: InMemoryTerminalSession` (declared line 541) — this type/method is from the external `GhosttyTerminal` package, not defined in `Sources/`.
- Ghostty's session `onSend` callback → `TerminalScreenView.swift:368` `nonisolated func send(_ data: Data)` on `TerminalSessionCallbackBridge`, which calls `onSend?(data)`.
- That wires up to `Sources/Heeler/Console/AttachTerminalStore.swift:311` `func send(_ keystrokes: Data) { input.send(keystrokes) }` and similarly `Sources/Heeler/Console/ShellTerminalStore.swift:323`, `Sources/Heeler/Console/AgentAttachStore.swift:251`.
- `input` is `TerminalAttachInputQueue` (`Sources/Heeler/Transport/TerminalAttach.swift:145` class def, `.send(_:)` at line 158) — a reliable/ordered queue distinct from scroll coalescing (`scroll(_:rows:)`).
- Final SSH channel write: **`Sources/Heeler/Transport/HeelerSSHTransport.swift:2296`** — `write: { data in try await channel.write(data, timeout: requestTimeout) }` — this is the function that actually sends bytes to the PTY over the SSH channel.
- Scroll rows for remote wheel reports flow through `TerminalScreenView.swift:1555` `applyScroll(towardOlderContent:rowCount:)` → `callbackBridge.scroll(sequence, rows:)` (line 1561) → `TerminalScreenView.swift:376` `scroll(_:rows:)` → `onScroll?` → `AttachTerminalStore`/store-level `.scroll(_:rows:)` → same `TerminalAttachInputQueue`.

## 5. Keyboard

- Software keyboard: `HeelerTerminalView` overrides UIKit text-input methods directly on the Ghostty view — `insertText(_:)` `TerminalScreenView.swift:1142`, `deleteBackward()` 1151, `paste(_:)` 1215/1227, `canPaste` 1240, `canPerformAction` 1247 — these feed Ghostty's own `UITextInput` document (comment 736-739 area) which forwards to libghostty's key-event handling; there is no separate `UIKeyInput` conformance authored in this repo — it rides on Ghostty's `UITerminalView` built-in text input.
- Accessory toolbar (Esc/Tab/arrows/Ctrl): `Sources/Heeler/Terminal/TerminalKeyboard.swift` (477 lines) — `TerminalControlPadView` (230), `configureKeys()` (244), `makeButton(for:)` (271), `TerminalKeyButton` (302), `sendControlKey(_:)` (432), `sendQuickKey(_:)` (440), `sendNewLine()` (445); byte tables for control keys at lines 83 and 184 (`func bytes(applicationCursor:) -> [UInt8]`).
- Hardware keyboard: the **only** hardware-key path in `Sources/` is `TerminalScreenView.swift:1617-1633` — `override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?)` and `pressesEnded` — these intercept only ⌘+ / ⌘= / ⌘- / ⌘_ (font zoom, via `zoomShortcutStep(for:)` line 1636) and forward everything else (`super.pressesBegan(forwarded, with: event)`, line 1627) down to Ghostty's own `UITerminalView`, which is where all other hardware-key handling (character keys, arrows, ctrl/opt modifiers, etc.) actually happens — no code in `Sources/` implements it.
- No `UIKeyCommand`, `keyCommands`, or `GCKeyboard` usage anywhere in `Sources/` (whole-tree grep, zero hits).

## 6. Layout

- Top-level nav: `Sources/Heeler/Console/ConsoleView.swift:56` — `NavigationSplitView` (adaptive: sidebar + detail; becomes a stack on compact width). Comment at line 51: "A split view instead of a plain stack for the iPad's sake: regular width gets a sidebar."
- Several sub-screens bring their own `NavigationStack` (e.g. `StartAgentView`, `HostListView`) — see grep list; `ConsoleView.swift` is the outermost container.
- `horizontalSizeClass` checked in: `Sources/Heeler/Console/AgentTerminalView.swift:227` (`@Environment`) used at `:953` to switch the composer mode control between `.segmented` (regular) and `.button` (compact); `Sources/Heeler/Console/AgentDirectInputChrome.swift:43` (`@Environment`), used at `:85`.
- The terminal screen itself: `Sources/Heeler/Console/AgentTerminalView.swift:144` — `struct AgentTerminalView: View`, which builds `TerminalScreenView` at `:316` and wires `onSizeChanged` at `:322`. It is pushed as `ConsoleView`'s detail/destination (via the `NavigationSplitView`/`NavigationStack` machinery in `ConsoleView.swift`). A parallel `Sources/Heeler/Console/ShellTerminalView.swift:14` (`struct ShellTerminalView: View`) builds `TerminalScreenView` at `:31` for the direct-shell-attach flow (ADR 0015).
- Fixed widths found near iPad-relevant code: `AgentTerminalView.swift:1468` `.frame(width: 24)` (an icon, inside a `NavigationStack`-wrapped sheet at 1421/1491, not the terminal itself); no fixed-width constraint found directly on `TerminalScreenView`/`HeelerTerminalView`.
- **Full-bleed terminal on iPad regular width**: `ConsoleView.swift:56`'s `NavigationSplitView` already gives the terminal detail pane the available width (no cap found on the terminal column itself); the places to touch for iPad pointer/keyboard work are `AgentTerminalView.swift:953` (composer mode is already `horizontalSizeClass`-aware) and `AgentDirectInputChrome.swift:85`. ADR note below says current App Store builds are iPhone-only despite this adaptive code being present.

## 7. Resize (columns/rows → PTY)

- `TerminalScreenView.swift:125` — `HeelerTerminalView.onSizeChanged: ((cols: Int, rows: Int) -> Void)?`, populated from Ghostty's own viewport-resize callback (`TerminalSessionCallbackBridge.resize(_:)` line 380, `receiveResize` 426, `deliverSize` 488-497) — Ghostty computes columns/rows from the view's pixel size and font metrics internally; this app only receives the result.
- `Sources/Heeler/Console/AgentTerminalView.swift:322-323` — `screen.onSizeChanged = { cols, rows in attach.viewDidResize(cols: cols, rows: rows) }`.
- `Sources/Heeler/Console/AttachTerminalStore.swift:292` — `func viewDidResize(cols: Int, rows: Int)` — stores `cols`/`rows`, calls `session?.resize(cols:rows:)` (start-of-session) which ultimately triggers a PTY window-change over the same SSH channel (`HeelerSSHTransport.swift`).

## 8. Existing TODO/iPad/pointer/mouse/keyboard mentions

- `docs/adr/0001-native-swift-stack.md:6-9` — **"Distribution update (2026-08-13): current App Store builds target iPhone only. The original native-stack decision below included iPad, and the adaptive layout code remains available if iPad distribution is restored later."** Also stale: this ADR's body still says "SwiftTerm for terminal rendering" (line 11) though ADR 0004 (`libghostty-terminal.md`) superseded it — the actual surface is `GhosttyTerminal`'s `UITerminalView`, not SwiftTerm.
- `CHANGELOG.md:296-299` — "An iPad-fit Console: on regular widths the Agent list becomes a sidebar beside the open terminal (a split view)... iPhone navigation is unchanged." (the `ConsoleView.swift` `NavigationSplitView` work above.)
- No mentions of "pointer", "trackpad", "right click", or "hardware keyboard" as TODOs/issues in code comments, `docs/`, `CHANGELOG.md`, or `docs/adr/` beyond the code comments already quoted in sections 1-6 above (`TerminalMouseReporting.swift:6-8` on indirect pointers being Ghostty-owned; `TerminalScreenView.swift:50` and `Console/AgentDirectInputPresentation.swift:8` and `AgentTerminalView.swift:1260` on hardware-keyboard footprint/inset behavior, not input handling).
- No GitHub issue numbers found tagged specifically to iPad pointer/trackpad/right-click/hardware-keyboard work (searched whole `Sources/`, `docs/`, `CHANGELOG.md`).
