# Hardware key -> PTY byte path, herdr client screen

Scope: `Sources/Heeler/Client/{HerdrClientRootView,HerdrClientView,HerdrClientStore}.swift`,
`Sources/Heeler/Terminal/TerminalScreenView.swift` (class `HeelerTerminalView`), vendored
`Packages/GhosttyTerminal/Sources/GhosttyTerminal/Platform/UIKit/`.

## 0. Screen wiring (confirms which code path is live)

- `HerdrClientView.terminalScreen` (`Sources/Heeler/Client/HerdrClientView.swift:24-45`) builds a
  `TerminalScreenView(feed: store.terminalFeed)`, sets `screen.onSend = { store.send($0) }` (line 29)
  and `screen.claimsKeyboard = { hardwareKeyboard.isConnected }` (line 37-39, comment: "A hardware
  keyboard's keys only reach the PTY through a terminal that holds first responder").
- `isKeysDockPresented` (`HerdrClientView.swift:65-67`) is `keyboardMode == .controls &&
  !hardwareKeyboard.isConnected` — the software keys pad (`ShellTerminalInputRow` /
  `TerminalKeysKeyboard`) is only shown when **no** hardware keyboard is attached; with a Magic
  Keyboard connected it never mounts. `keyboardPresentation` (`HerdrClientView.swift:47-51`) also
  short-circuits to `.hidden` whenever `hardwareKeyboard.isConnected`.
- So on this screen, with a hardware keyboard attached: **TerminalKeyboard.swift /
  TerminalKeysKeyboard.swift / TerminalInputController.swift (software pad + sticky-modifier
  accessory) are not in the path at all.** They exist only for the no-hardware-keyboard case (old
  Console and this screen alike). Answers Q5.
- `TerminalScreenView` (`Sources/Heeler/Terminal/TerminalScreenView.swift:537`) declares
  `final class HeelerTerminalView: UITerminalView, TerminalByteSink` — the vendored base class from
  `Packages/GhosttyTerminal/Sources/GhosttyTerminal/Platform/UIKit/`.

## 1. Where hardware key presses are received (Q1)

Two independent entry points, both active on this screen (both live on the same `HeelerTerminalView`
instance):

- **`pressesBegan`/`pressesEnded`** — overridden twice in the responder chain:
  - `HeelerTerminalView.pressesBegan/pressesEnded` (`Sources/Heeler/Terminal/TerminalScreenView.swift:1868-1884`)
    — Heeler's own override, checked **first** (it is the most-derived class). It intercepts only
    ⌘+ / ⌘= / ⌘- / ⌘_ font-zoom shortcuts (`zoomShortcutStep(for:)`, lines 1886-1893) and forwards
    every other press to `super`.
  - `UITerminalView.pressesBegan/pressesEnded` (`Packages/GhosttyTerminal/.../UITerminalView+Keyboard.swift:164-234`)
    — the vendored base implementation everything else reaches. Calls `handleKeyPress(key, action:)`
    (line 265) for undeferred keys, after first checking `shouldDeferKeyToInputMethod` (IME
    composition case, lines 250-262) — irrelevant for plain-ASCII/control combos.
- **`UIKeyCommand`/`keyCommands`** — `UITerminalView.keyCommands` override
  (`UITerminalView+Keyboard.swift:110-118`) appends `controlKeyCommands`: one `UIKeyCommand` per
  Ctrl+`[a-z0-9 -=[]\;',./\``] combo (built in `controlKeyCommandInputs`/`controlKeyCommands`,
  lines 90-108), each with `wantsPriorityOverSystemBehavior = true` (line 106). This exists
  specifically because, as a `UITextInput` first responder, UIKit's own text machinery would
  otherwise consume most Ctrl+letter chords (emacs-style bindings) before `pressesBegan` fires
  (comment, lines 81-89). No other `UIKeyCommand`s exist anywhere in the app or the package (see Q6).
- **`UITextInput`/`UIKeyInput`** (`insertText`/`deleteBackward`) — present on `HeelerTerminalView`
  (`insertText(_:)` around `TerminalScreenView.swift:1142`, `deleteBackward()` ~1151, per the
  existing vault note `KelpieVault/Archive/research/inputmap.md:66`) but these back the **software**
  keyboard/IME echo path, gated by `hardwareKeyboard.keyHandled`
  (`HardwareKeyboardState.keyHandled`, `UITerminalView+Keyboard.swift:14-17`) to avoid double
  delivery — not the primary hardware-key route.
- No `pressesChanged`, no custom `GCKeyboard` usage anywhere (confirmed by grep, Q6).

## 2. Per-combo trace (Q2)

All combos below funnel through `HeelerTerminalView.pressesBegan` (does nothing but forward, since
none is ⌘=/⌘-) → `UITerminalView.pressesBegan` (`UITerminalView+Keyboard.swift:164`) →
`handleKeyPress(key:action:)` (line 265) → `TerminalSurface.sendKeyEvent`
(`Packages/GhosttyTerminal/Sources/GhosttyTerminal/Surface/TerminalSurface.swift:32-40`) →
`ghostty_surface_key(s, event)` (line 37) — **the one key-encoding call, see Q3** — unless a note
below says otherwise. From the core's returned bytes, delivery to the PTY is:
`TerminalScreenView.HeelerTerminalView` (`TerminalByteSink`) → `screen.onSend` closure
(`HerdrClientView.swift:29`) → `HerdrClientStore.send(_:)` (`HerdrClientStore.swift:88`, calls
`terminal.send(data)`) → `AttachTerminalStore.send(_:)` (`Sources/Heeler/Console/AttachTerminalStore.swift:311`,
comment: "Keystrokes from the terminal view, forwarded raw") → `input.send(keystrokes)` on
`TerminalAttachInputQueue` (`Sources/Heeler/Transport/TerminalAttach.swift:165`, and the terminal-
attach-owner variant at line 349) → drained by `TerminalAttachInputQueue.pump` inside
`HeelerSSHTransport.runAttachPumps` (`Sources/Heeler/Transport/HeelerSSHTransport.swift:2307-2317`)
→ `channel.write(data, timeout:)` on the SSH exec/PTY channel (line 2317) — the literal bytes
written to the wire.

- **Escape** — HID usage `0x29` maps to `GHOSTTY_KEY_ESCAPE`
  (`TerminalHardwareKeyRouter.swift:85`). No app or package `UIKeyCommand` claims
  `UIKeyCommand.inputEscape` anywhere (grep, Q6) — Escape is not intercepted before `pressesBegan`.
  Goes to `ghostty_surface_key` with keycode `GHOSTTY_KEY_ESCAPE`, no `characters` text (Escape's
  `key.characters` is `\u{1B}`, not a private-use function-key glyph, so `filteredFunctionKeyText`
  passes it through as `derivedText`). Reaches the PTY (0x1B byte) via the chain above — not dropped.
- **Cmd+.** — no `UIKeyCommand.inputEscape`/period-with-command registration anywhere in
  `Sources`/`Packages/GhosttyTerminal/Sources` (grep, Q6), and `HeelerTerminalView.pressesBegan`
  only special-cases ⌘+/⌘-/⌘=/⌘_ (`zoomShortcutStep`, lines 1886-1893) — `.` is not among them. So
  the press reaches `handleKeyPress` with `isCommandModified == true` (Command bit set in
  `filteredModifierFlags`). Because it is command-modified, `handleKeyPress`
  (`UITerminalView+Keyboard.swift:339-345`) takes the early-return branch: it calls
  `surface.sendKeyEvent(keyEvent)` with **keycode = GHOSTTY_KEY_PERIOD and Cmd in `mods`** — it is
  sent as literal Cmd+Period, not translated to a bare Escape by this codebase. Any "Cmd+. behaves
  like Escape" effect would have to come from iPadOS system-level handling upstream of the
  responder (e.g. a system Escape-equivalent shortcut on some other object in the responder chain,
  or ghostty's own core keybind table) — nothing in this repo maps or intercepts it, and nothing in
  this repo confirms iPadOS actually does that translation for a raw hardware press (that is a
  UIKit/system behavior document, not something this codebase implements or tests).
- **Option+Backspace** — HID `0x2A` → `GHOSTTY_KEY_BACKSPACE`. `shouldSuppressUIKeyInput`
  (`UITerminalView+Keyboard.swift:374-392`) explicitly leaves Option-held presses on the "not
  suppressed" branch (`guard key.modifierFlags.intersection([.alternate]).isEmpty else { return
  false }`, line 385-387; comment: "Alt stays on the text path: option+letter legitimately types the
  composed character") — this only controls whether the parallel `UITextInput` echo is silenced, not
  whether the key event itself is sent. `handleKeyPress` unconditionally builds and sends the
  `ghostty_input_key_s` (keycode BACKSPACE, `mods` carrying the alt bit via `TerminalInputModifiers`)
  through `ghostty_surface_key`. The choice of resulting bytes (`ESC DEL` vs `Ctrl+W`-style word
  delete) is made **inside the compiled Ghostty core** (`ghostty_surface_key`), which this repo does
  not vendor as inspectable source (`Packages/GhosttyTerminal/Artifacts/GhosttyKit.xcframework` is a
  gitignored prebuilt binary) — not dropped in Swift, but its exact byte output is opaque to static
  reading here.
- **Option+Left/Right arrows** — HID `0x50`/`0x4F` → `GHOSTTY_KEY_ARROW_LEFT`/`RIGHT`
  (`TerminalHardwareKeyRouter.swift:110-111`). Arrow-key `characters` are UIKit private-use glyphs
  (`0xF700`-range) and get filtered to `nil` by `TerminalInputText.filteredFunctionKeyText`
  (`Packages/GhosttyTerminal/Sources/GhosttyTerminal/Platform/Shared/TerminalInputText.swift:14-28`,
  `isPrivateUseFunctionKey`), so `handleKeyPress` takes the `guard let text = derivedText ...`
  early-exit (`UITerminalView+Keyboard.swift:363-366`) and sends a pure `ghostty_input_key_s`
  (keycode ARROW_LEFT/RIGHT, alt bit set in `mods`, no text) to `ghostty_surface_key`. As with
  Option+Backspace, whether this becomes `ESC b`/`ESC f`, a CSI `1;3D`/`1;3C` modified sequence, or
  something else is decided inside the opaque core, not in Swift — not dropped by this codebase,
  final bytes not verifiable by reading source here.
- **Ctrl+C / Ctrl+B / Ctrl+D / Ctrl+Z / Ctrl+L** — all letters, so all are registered
  `controlKeyCommands` (`UITerminalView+Keyboard.swift:90-108`, `wantsPriorityOverSystemBehavior =
  true`). `handleControlKeyCommand` (line 120-137) calls `claimControlKeyDelivery` (dedup against a
  same-turn `pressesBegan` delivery, lines 142-163) then `sendModifiedTextKey(input, modifiers:)`
  (`Packages/GhosttyTerminal/Sources/GhosttyTerminal/Platform/UIKit/UITerminalView+InputAccessory.swift:171-197`),
  which builds a `ghostty_input_key_s` (keycode from `keyMapping(for:)`, ctrl bit in `mods`) and
  calls `surface.sendKeyEvent` → `ghostty_surface_key`. If `pressesBegan` wins the race instead, the
  same combo reaches `handleKeyPress` directly (its own `claimControlKeyDelivery` call at
  `UITerminalView+Keyboard.swift:328-336` dedupes the other way) — either way it reaches the PTY
  exactly once, as the raw control byte (e.g. Ctrl+C -> 0x03) that a shell/TUI expects.
- **Tab and Shift+Tab** — HID `0x2B` → `GHOSTTY_KEY_TAB`. Tab's `characters` is `"\t"`, not a
  private-use glyph, so it survives `filteredFunctionKeyText` and is sent as both keycode and text
  (`\t`) via `ghostty_surface_key`; Shift is carried in `mods`. Reaches the PTY (plain `\t` byte for
  Tab; the core forms the shift-tab CSI sequence, e.g. back-tab, for Shift+Tab from `mods`).
- **Home/End**, **Page Up/Down** — HID `0x4A`/`0x4D`/`0x4B`/`0x4E` → `GHOSTTY_KEY_HOME`/`END`/
  `PAGE_UP`/`PAGE_DOWN` (`TerminalHardwareKeyRouter.swift:105-109`). Same private-use-glyph filtering
  as arrows: `derivedText` is `nil`, pure keycode event sent to `ghostty_surface_key`, which emits
  the corresponding CSI sequence. Reaches the PTY.
- **Fn/Globe combos** — `TerminalHardwareKeyRouter`'s `uiKitMap` has no HID entry for Fn/Globe (the
  `appKitMap` has `0x3F -> GHOSTTY_KEY_FN` but that table is only consulted for AppKit/Catalyst
  keycodes, and there is no corresponding literal pair in `uiKitMap`'s `literalPairs`/`groupedPairs`,
  `TerminalHardwareKeyRouter.swift:82-187`) — an unmapped usage falls through to
  `GHOSTTY_KEY_UNIDENTIFIED` (line 18). In practice, iPadOS intercepts the physical Globe/fn key
  itself for input-source switching before any `UIPress` reaches the app; this repo has no code
  path for it either way — **not verifiable as "reaches the PTY" from source alone**, and no
  evidence it's ever handled here.
- **Cmd+K** — no `UIKeyCommand` or `pressesBegan` special case for `k`/`K` anywhere in `Sources` or
  the package (grep, Q6). Goes to `handleKeyPress` with `isCommandModified == true`; takes the same
  early-return branch as Cmd+. (`UITerminalView+Keyboard.swift:339-345`): sent as literal Cmd+K
  (keycode `GHOSTTY_KEY_K`, Cmd in `mods`) straight to `ghostty_surface_key` — not intercepted by
  Heeler code, not translated to any app action on this screen.
- **Cmd+arrow** — likewise unhandled by any `Sources` code; `commandZoomDirection`
  (`UITerminalView+Keyboard.swift:405-426`) only recognizes `+`/`=`/`-`/`_`, not arrow keys. Cmd+Left/
  Right/Up/Down are sent as literal Cmd-modified arrow key events to `ghostty_surface_key` (no
  `characters` text, since arrows are private-use-filtered as above) — again, what escape sequence
  (if any) the core emits for a Cmd-modified arrow is opaque to this repo's Swift source.
- **Arrow keys (unmodified)**, **Return**, **Delete forward** — Return (HID `0x28` →
  `GHOSTTY_KEY_ENTER`, `characters == "\r"`) and Delete-forward (HID `0x4C` → `GHOSTTY_KEY_DELETE`,
  private-use characters, filtered to no text) both go through the same `handleKeyPress` →
  `ghostty_surface_key` route with no special-casing anywhere in `Sources` — reach the PTY as CR
  and the forward-delete sequence respectively. Plain arrows: as above, minus the Option/Cmd
  modifier bits, reach the PTY as the core's cursor sequences.

## 3. Ghostty core call and modifier/keycode mapping (Q3)

- **Every hardware key on this screen ends at `ghostty_surface_key`**, called from exactly one
  place: `TerminalSurface.sendKeyEvent(_:)`
  (`Packages/GhosttyTerminal/Sources/GhosttyTerminal/Surface/TerminalSurface.swift:32-40`, the
  `ghostty_surface_key(s, event)` call is line 37). All UIKit-side call sites
  (`handleKeyPress` in `UITerminalView+Keyboard.swift:265-372`, `sendModifiedTextKey` in
  `UITerminalView+InputAccessory.swift:171-197`, and the deferred-key replay path in
  `UITerminalView+Keyboard.swift:519-611`) build a `ghostty_input_key_s` and call
  `surface.sendKeyEvent`, never `ghostty_surface_key` directly. Confirmed: **yes, the vendored
  package calls `ghostty_surface_key`**, and only through this one wrapper.
- **UIKit-key -> Ghostty-key mapping**: `TerminalHardwareKeyRouter.ghosttyKey(forUIKitUsage:)`
  (`TerminalHardwareKeyRouter.swift:17-19`) backed by the `uiKitMap` table (lines 82-187) — covers
  letters, digits, F1-F24, all named keys (Enter, Escape, Backspace, Tab, Space, punctuation, Caps
  Lock, Print Screen, Scroll Lock, Pause, Insert, Home, PageUp/Down, Delete, End, arrows, NumLock,
  numpad ops incl. NumpadEnter/Equal, IntlBackslash, ContextMenu, Help, Cut/Copy/Paste, volume keys,
  and left/right Ctrl/Shift/Alt/Meta). **Left unmapped**: anything not in that table falls back to
  `GHOSTTY_KEY_UNIDENTIFIED` (line 18) — notably Fn/Globe (see Q2) and JIS-only keys (explicitly
  called out as still absent at lines 189-191 for the *AppKit* table; the UIKit table has no JIS
  entries either).
- **HID→AppKit keycode translation**: `appKitKeyCodeForUIKit(usage:)` (lines 51-61) — required
  because "Ghostty expects a platform-native keycode... on iOS that table uses macOS virtual
  keycodes" (comment, `UITerminalView+Keyboard.swift:297-299`); a small override table
  (`uiKitToAppKitKeyCodeOverrides`, lines 73-78) handles two keys (NumLock, NonUSBackslash) whose
  UIKit and AppKit logical keys differ.
- **Modifiers**: `TerminalInputModifiers(from: UIKeyModifierFlags)` builds the mod set (shift/ctrl/
  alt/super definitions at `Packages/GhosttyTerminal/Sources/GhosttyTerminal/Metrics/TerminalInputModifiers.swift:23-26`);
  `handleKeyPress` separately computes `consumed_mods` (control and command stripped, line 307-310)
  passed alongside `mods` in the same `ghostty_input_key_s`.
- **Kitty keyboard protocol / macOS-option-as-alt config**: no occurrence of `macos-option-as-alt`,
  `option_as_alt`, or any Kitty-protocol config key anywhere in `Sources` or
  `Packages/GhosttyTerminal/Sources` (grep, confirmed empty). The only "kitty" hits are theme names
  (`Themes_K.swift`), shell-integration comments referencing Kitty's own shell scripts, and two code
  comments noting the core's internal key encoder implements "kitty keyboard protocol" and
  modifier-aware escapes (`TerminalHardwareKeyRouter.swift:10-15`,
  `TerminalTextInputHandler@UIKit.swift:83`, `UITerminalView+UITextInput.swift:121`) — i.e. Kitty
  protocol support, if any, lives entirely inside the opaque compiled core and is never configured
  or toggled from Swift.

## 4. Ghostty config passed at surface creation (Q4)

- `TerminalController.createApp()` (`Packages/GhosttyTerminal/Sources/GhosttyTerminal/Controller/TerminalController+Config.swift:97-113`)
  builds `ghostty_runtime_config_s` with only runtime callbacks (`wakeup_cb`, `action_cb`,
  `close_surface_cb`, `write_clipboard_cb`, `read_clipboard_cb`, `confirm_read_clipboard_cb`) and
  `supports_selection_clipboard = true` — no key-behavior fields.
  `ghostty_app_new(&runtimeConfig, cfg)` takes the separate text-format `cfg`
  (`ghostty_config_t`), assembled by `GhosttyConfigRenderer.render(baseContents:configuration:theme:)`
  (`Packages/GhosttyTerminal/Sources/GhosttyTerminal/Configuration/GhosttyConfigRenderer.swift:11-35`)
  from three text sections: a `baseConfigTemplate`, a `TerminalConfiguration.commands` block, and a
  theme-commands block.
- Config keys this codebase actually emits into that text config
  (`Packages/GhosttyTerminal/Sources/GhosttyTerminal/Configuration/TerminalConfiguration.swift`,
  `renderedLine` cases, lines 63-75): `cursor-style`, `cursor-style-blink`, `cursor-color`,
  `cursor-text`, `cursor-opacity` — plus (from `Sources/Heeler/Terminal/TerminalScreenView.swift:966-1000`,
  `applyFontSize`/`applyFontFamily`/`fontConfiguration`): `font-size`, `font-family` (cleared to
  `""` before re-setting, to reset ghostty's additive font-family list) and whatever the theme's
  own `TerminalConfiguration` (colors, from `TerminalThemeSettings.swift`/`TerminalThemePreview.swift`)
  contributes. **No key-behavior config** (no `macos-option-as-alt`, no keybind overrides, no Kitty
  protocol toggle) is set anywhere at surface creation, in `HeelerTerminalView`, or in the package —
  confirmed by grep across both trees.

## 5. Software pad relation (Q5)

Already covered in section 0: `TerminalKeyboard.swift`, `TerminalKeysKeyboard.swift`, and the
sticky-modifier logic in `UITerminalView+InputAccessory.swift` (`TerminalInputController` role) exist
to synthesize `ghostty_input_key_s` events for **on-screen tapped keys** (`sendModifiedTextKey`,
`sendControlByte`) — the same terminal call, `ghostty_surface_key`, but a different origin than a
physical `UIPress`. On the herdr client screen they are only mounted/visible when
`hardwareKeyboard.isConnected == false` (`HerdrClientView.swift:47-51,65-67`); with a Magic Keyboard
attached they play no role in the key path at all, on this screen or (per the vault's prior note)
the old Console.

## 6. `keyCommands`/`UIKeyCommand`/`pressesBegan`/`wantsPriorityOverSystemBehavior` grep (Q6)

Full result of
`grep -rn "UIKeyCommand\|keyCommands\|pressesBegan\|pressesEnded\|wantsPriorityOverSystemBehavior" Sources Packages/GhosttyTerminal/Sources`:

- `Sources/Heeler/Terminal/TerminalScreenView.swift:1868,1878,1881,1884` — `HeelerTerminalView`'s
  `pressesBegan`/`pressesEnded` override, font-zoom-only (see Q2/section 0).
- `Packages/GhosttyTerminal/.../UITerminalView+Keyboard.swift` — the only `UIKeyCommand`
  registrations in the whole tree: `controlKeyCommands`/`controlKeyCommandInputs` (lines 90-108),
  `keyCommands` override (110-118), `handleControlKeyCommand` (120-137). `wantsPriorityOverSystemBehavior`
  is set **only** on these Ctrl+letter/digit/punctuation commands (line 106) — nowhere else in the
  app or package. Consequently, **no combo in this codebase claims priority over system behavior
  except Ctrl+<key>**; Escape, Cmd+., Cmd+K, Cmd+arrow and all Option combos have no
  `wantsPriorityOverSystemBehavior` registration and rely solely on `pressesBegan` ordering (and
  whatever iPadOS itself reserves upstream of the responder, e.g. Cmd+H/Cmd+Tab/system Escape-as-
  dismiss, is not overridden or even referenced anywhere in this repo).
- No `UIKeyCommand.inputEscape` reference anywhere (separately grepped, zero hits).

## 7. Prior review/ADR notes (Q7)

- `docs/adr/0016-ipad-pointer-input.md` and `docs/adr/0017-herdr-client-is-the-screen.md`: no
  mentions of "Escape", "Option", or "keyboard" keyboard-behavior specifics (grepped, zero hits in
  either).
- `KelpieVault/Archive/round2/notes.md`, `review.md`, `SPEC2.md`: no "Escape"/"Option"/`inputEscape`
  hits beyond an unrelated "Optional (nits)" section heading.
- `KelpieVault/Archive/research/inputmap.md` (older scout note, pre-dates the herdr client screen,
  line numbers now shifted by ~230 lines due to intervening edits) already recorded the same shape
  this scout re-verified independently: `HeelerTerminalView`'s own `pressesBegan`/`pressesEnded`
  intercept only the font-zoom combos and forward everything else to Ghostty's base
  `UITerminalView`; "no `UIKeyCommand`, `keyCommands`, or `GCKeyboard` usage anywhere in `Sources/`"
  (true — all such registrations live in the vendored package, not `Sources/`); software keyboard
  rides on Ghostty's own `UITextInput` conformance, not a separate one authored in this repo.

## What was checked but yielded nothing

- No `macos-option-as-alt` / `option_as_alt` / Kitty-protocol config key set anywhere (Q3/Q4).
- No `UIKeyCommand.inputEscape` registration anywhere (Q2/Q6).
- No Cmd+K / Cmd+arrow handling anywhere in `Sources` (Q2).
- No Fn/Globe key mapping in `TerminalHardwareKeyRouter`'s UIKit table (Q2).
- ADRs 0016/0017 and the round-2 vault notes have no keyboard-specific detail beyond what's above.

## Caveat

The exact terminal byte sequence libghostty's core produces for Option+Backspace, Option+arrows,
Cmd+., Cmd+K, Cmd+arrow, and Fn combos is decided inside `ghostty_surface_key`, implemented in the
prebuilt, gitignored `GhosttyKit.xcframework` binary — not Swift or readable Zig source in this
repo. This report establishes, with citations, that these presses are **not dropped by any Swift
code on this screen** (they all reach `ghostty_surface_key` with correct keycode/mods/text), but the
resulting byte sequence itself cannot be confirmed by static reading alone.
