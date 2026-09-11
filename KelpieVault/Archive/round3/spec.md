# Kelpie round 3 — build spec

Project: /Users/anthonytopalides/Developer/Kelpie, branch `kelpie`. Swift 6 strict concurrency, no force unwraps / `try!` outside tests. Read the Kelpie section of `CLAUDE.md` first. **Never edit anything under `Packages/GhosttyTerminal`** — it is vendored; override its `open` members from `HeelerTerminalView` (`Sources/Heeler/Terminal/TerminalScreenView.swift`).

Background reading (already mapped, do not re-derive): the scouts' notes at
`../scout-keys/key-path.md` and `../scout-nav/nav-and-onboarding.md` (relative to this file's folder).

## Piece A — hardware key pass-through on the herdr client screen

Observed on the iPad (Magic Keyboard, herdr TUI full screen): Escape and Cmd+. never reach herdr; Option+Backspace never deletes a word.

Root causes:
1. `UITerminalView` (vendored) is a `UITextInput` first responder. On iPadOS the text-input system consumes Escape (and Cmd+., its system equivalent) before `pressesBegan` runs, exactly as it does for Ctrl+letter chords — which the package solves by registering `UIKeyCommand`s with `wantsPriorityOverSystemBehavior = true` (see `Packages/GhosttyTerminal/Sources/GhosttyTerminal/Platform/UIKit/UITerminalView+Keyboard.swift`, `controlKeyCommands`). Nothing registers `UIKeyCommand.inputEscape`.
2. Option+Backspace reaches Ghostty's key path with the alt bit set, but the surface is configured with Ghostty's default `macos-option-as-alt = false`, so alt is not turned into an ESC prefix and the PTY gets a plain 0x7f. The text-input echo path is deliberately left un-suppressed for alt presses (`shouldSuppressUIKeyInput`), so `deleteBackward()` may fire as well.

Do NOT change the Ghostty config (`macos-option-as-alt`); handle these combos in the app so Option+letter composition stays as it is.

### A1. New file `Sources/Heeler/Terminal/TerminalHardwareKeyMapping.swift`

A pure, `Sendable`, UIKit-free value type that answers "which bytes does this physical key + modifier combination send", so it is unit-testable:

```swift
enum TerminalHardwareKeyMapping {
    struct Key: Hashable, Sendable { let usage: UInt16; let control, option, shift, command: Bool }
    /// Bytes the app sends itself for combos UIKit or Ghostty would otherwise lose; nil = leave it to the normal path.
    static func bytes(for key: Key) -> Data?
}
```
Table (HID usages from `UIKeyboardHIDUsage`):
- Escape (0x29), no modifiers → `1B`
- Period (0x37) with **command** only → `1B` (Cmd+. is iPadOS's Escape equivalent; keep it even though UIKit may already fold it into `inputEscape`)
- Delete/Backspace (0x2A) with **option** (shift allowed, no control/command) → `1B 7F` (ESC DEL: delete word backward in readline, zsh, fish, Claude Code)
- Left arrow (0x50) with option → `1B 62` (ESC b, word left)
- Right arrow (0x4F) with option → `1B 66` (ESC f, word right)
- Forward delete (0x4C) with option → `1B 64` (ESC d, delete word forward; Fn+Delete on the Magic Keyboard)
- Everything else → nil.

Doc comment explains why these live in the app (the two root causes above) and that the bytes are legacy/xterm encodings sent raw, bypassing Ghostty's key encoder, so a Kitty-keyboard-protocol client would not see CSI u forms — acceptable for herdr's ratatui TUI, note it.

### A2. `HeelerTerminalView` overrides (in `TerminalScreenView.swift`)

1. `override var keyCommands: [UIKeyCommand]?` — take `super.keyCommands ?? []` (this keeps the package's Ctrl commands) and append two commands, both `wantsPriorityOverSystemBehavior = true`, both routed to one `@objc` handler: `UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [])` and `UIKeyCommand(input: ".", modifierFlags: .command)`. Give them a `discoverabilityTitle` of "Escape" so they appear in the iPad shortcut HUD (hold Cmd).
2. The handler sends `TerminalHardwareKeyMapping.bytes(for: escapeKey)` through the same raw route the mouse reports already use (`terminalSession.sendInput(...)` — see `remoteClickSequence` usage around line 1700 of the same file), guarded by `isLocalInputEnabled` like the click path.
3. Dedupe against a second delivery: on some iPadOS versions the same physical press arrives both as the key command and in `pressesBegan`. Keep a private `Set<TerminalHardwareKeyMapping.Key>` of combos claimed this run-loop turn, cleared with `DispatchQueue.main.async` — the same shape as the package's `claimControlKeyDelivery`, which is internal to the package and not callable. Whichever path claims first wins; the other stays silent.
4. `override func pressesBegan(_:with:)`: for each press whose key maps to non-nil bytes, claim it and send the bytes yourself; pass **only the remaining presses** to `super.pressesBegan`. Track the intercepted `UIPress` objects (weakly or by identity in a `Set<UIPress>`) so `pressesEnded` / `pressesCancelled` drop them too instead of handing a release to `super` for a press it never saw. Remember the alt-modified ones in a separate flag set for step 5.
5. Suppress the text-input echo for the intercepted alt combos: `override func deleteBackward()` — if an intercepted Option+Backspace press was claimed this turn, swallow it (do not call `super`), otherwise call `super`. Do the same for `insertText(_:)` only if the intercepted press was an alt combo *and* the text is a single character; software-keyboard typing (no press in flight) must be unaffected. Clear these flags with the same end-of-turn reset and on `pressesEnded`/`pressesCancelled`.
6. Do not touch `becomeFirstResponder` / focus logic. Do not add `keyboardShortcut`s in SwiftUI for these; the terminal view owns them.

### A3. Tests

`Tests/HeelerTests/TerminalHardwareKeyMappingTests.swift` (Swift Testing or XCTest, whichever the neighbouring files use): every row of the table above, plus negatives (Escape with Cmd → nil; Backspace with no modifier → nil; Backspace with option+control → nil; Period without command → nil). Tests cannot be executed on this Mac (no working simulator) — they only need to compile in the device build of the test target is not required; the app target must build.

## Piece B — make the way to Hosts visible on the herdr screen

`Sources/Heeler/Client/HerdrClientRootView.swift`, `menuButton` (around lines 161–208). The menu already contains Hosts and Switch Host; the user cannot find it because the label is a bare 36 pt `ellipsis.circle` resting at 0.55 opacity that only lifts on hover.

Change the **label only** (menu items stay, but reorder them: Switch Host (when >1 hosts), Hosts, then a Divider, then Agents, Settings, Reconnect):
- A capsule: `Image(systemName: "server.rack")` + the primary host's `displayName` (fall back to "Kelpie" when there is no primary host) in `.caption.weight(.medium)`, single line, `lineLimit(1)`, max width ~180 pt with truncation, horizontal padding 10, vertical 6.
- Background `.regularMaterial` in a `Capsule()`, subtle 0.5 pt `Capsule().strokeBorder(.separator)`.
- Resting opacity 0.92, 1.0 on hover; keep `.hoverEffect(.highlight)`, `.padding(12)`, alignment and the accessibility label ("Kelpie Menu"). Add `.accessibilityHint("Hosts, agents and settings")`.
- Update the two comments above it (they justify the tiny dim button) to explain the new choice: it must be discoverable without a pointer resting on it, and it still sits over the empty right end of herdr's tab strip.
- Nothing else in the file changes. Do not add gestures.

## Piece C — housekeeping

- Run `xcodegen generate` after adding the two Swift files and stage the regenerated `Heeler.xcodeproj` together with the sources (Kelpie rule).
- Add a `CHANGELOG.md` entry under `[Unreleased]` → Fixed/Changed: Escape and Cmd+. now reach the remote client; Option+Backspace / Option+arrows send word-wise editing keys; the Kelpie menu is a labelled host capsule. No PR number — write `(Kelpie)` where upstream entries put the PR link.
- Build for the device, in the background, log to a file, read only the tail:
  ```
  S=/private/tmp/claude-501/-Users-anthonytopalides-Developer-Kelpie/2beb8609-5f8f-488c-8847-4514dad12a4b/scratchpad/build
  mkdir -p $S
  xcodebuild build -project Heeler.xcodeproj -scheme Heeler -configuration Release \
    -destination 'platform=iOS,id=09D7738D-2173-55EF-8966-A9C3EA1D0514' \
    -clonedSourcePackagesDirPath $S/kelpie-spm -derivedDataPath $S/kelpie-dd -allowProvisioningUpdates \
    > $S/build.log 2>&1
  ```
  Never use the simulator. Fix any error the build reports. Do NOT install to the device and do NOT commit — the orchestrator does both after review.
- Do not edit `KelpieVault/`, `resume.md`, or docs.

## Return

At most 300 words: what changed per file (paths), the build result (exact tail line), anything in the spec you could not do and why. Write the same to `<your folder>/report.md`.
