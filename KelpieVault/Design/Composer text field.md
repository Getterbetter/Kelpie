---
note: Design for Open item 30 — a composing text field above the key bar so autocorrect, predictive text, dictation and hold-to-accent reach herdr. Written 2026-09-15 before any build; Anthony's decisions at the end.
---

# Composer text field (Open item 30)

Anthony, 2026-09-15: "Typing with the on-screen keyboard might need a text box that replicates into kelpie so auto correct and other QOL improvements pass through."

## Why typing is dumb today

The herdr screen's terminal (`HeelerTerminalView`, `TerminalScreenView.swift:920`) is the first responder and conforms to full `UITextInput`, but Kelpie pins its traits to a `.terminal` style (`TerminalScreenView.swift:924-956`): autocorrect, spell check, capitalisation, smart quotes and smart dashes all off. Every committed character is re-encoded by Ghostty as a key event and written to the PTY at once. Nothing can be taken back, so iOS is never allowed to try. A `.naturalLanguage` style exists and is used only by Heeler's Console prompt pane (`AgentTerminalView.swift:343`).

## Shape

A one-to-five-line text field sits between the terminal and the key bar, only when the on-screen keyboard is up. What you type goes into the field, where iOS does its work, and the field mirrors itself into the PTY as you go.

```
┌──────────────────────────────────────────┐
│ herdr (Claude Code input box shows the   │
│ same text as it arrives)                  │
├──────────────────────────────────────────┤
│ ⌨︎  Fix the failing test in HostFor|      │  ← composer (UITextView)
├──────────────────────────────────────────┤
│ esc  tab  ⇧tab  ctrl  alt  ←↑↓→  ⌨︎↓      │  ← the round-15 pill (unchanged)
├──────────────────────────────────────────┤
│              on-screen keyboard          │
└──────────────────────────────────────────┘
```

## Decisions taken in the design

**1. Mirror per keystroke, not send-on-submit.** The field owns a string `committed` = what the PTY has received. On every text change it computes the common prefix with the new text, sends that many `DEL` (`0x7f`) for the removed tail, then the new tail, and updates `committed`. Autocorrect replacing "teh" with "the", a predictive-bar tap, a dictation chunk landing, a hold-to-accent pick: all are just diffs. Return sends `\r` and clears the field and `committed`. Send-on-submit would be simpler but the TUI would show nothing until Enter, and Claude Code's `/` command menu and `@` file completion would never open. Mirroring keeps the terminal honest and the field is only a smart proxy for the keyboard.

**2. Raw writes, not bracketed paste.** The existing "send a string" helpers (`TerminalInputController.insertSnippet`, `requestPaste`) wrap in bracketed-paste sequences, which makes Claude Code treat the text as a paste. The composer needs a new raw `sendTyped(String)` on `TerminalInputController` beside them. Backspace must be the same byte the terminal's own delete key sends; confirm against Ghostty's encoding on the device before relying on `0x7f`.

**3. Control keys bypass the field.** The key bar keeps its `TerminalKeyBarHandler` (`TerminalKeyBar.swift:8-20`) but the handler becomes a small coordinator: `didPress(TerminalControlKey)` (esc, tab, shift-tab, arrows, sticky ctrl and alt chords) always goes to the PTY; `didType(String)` goes into the field while the composer is active, to the PTY otherwise. So Esc still interrupts Claude and ctrl-c still kills, with the field left as it was. Arrow keys move the TUI cursor, not the field's; the field's own cursor moves by touch. A field edit while the TUI cursor is not at the end of its line will mis-repair; accepted, same as any readline.

**4. The pill survives the responder swap.** The key bar is `HeelerTerminalView`'s `inputAccessoryView` (`TerminalScreenView.swift:1092`). When the field takes first responder its own accessory would replace it, so the field is given the same `TerminalKeyBar` instance as its `inputAccessoryView`. `TerminalKeyboardInset` already carries composer-to-terminal handoff scaffolding (`beginResponderHandoff`, `TerminalKeyboardInset.swift:121-173`) built for the Console; reuse it rather than writing a second one.

**5. Hardware keyboard keeps the raw path.** When `HardwareKeyboardObserver` reports a keyboard the composer is hidden and the terminal is first responder, exactly as today. The composer is an on-screen-keyboard feature only.

**6. Traits on the field.** Autocorrect, spell check and predictive on; capitalisation `.none` (shell commands and paths); smart quotes and smart dashes off (they corrupt code); `keyboardType .default`; `returnKeyType .send`. Return submits. A newline inside the field is not offered in v1: the TUI convention for a soft newline differs per agent (Claude Code wants `\` then Return), so the field stays single-message.

**7. A mode, not a takeover.** A toggle at the leading edge of the pill (a keyboard glyph, filled when the composer is on) switches between composer and raw typing, persisted in `UserDefaults` (`kelpie.composer-enabled`). Some TUIs (vim normal mode, a `less` pager, a password prompt) are wrong with a field in front of them, and the toggle is the escape hatch. Default off for the first build until Anthony has lived with it; his call below.

**8. Multiline growth.** The field grows to five lines then scrolls, above the pill, inset by `TerminalKeyboardInset` so the terminal reflows once, not twice (the reason that class exists, see its header comment).

## Stage 0: a thirty-minute experiment first

Flip the herdr screen's terminal to `setTextInputStyle(.naturalLanguage)` (one call, `TerminalScreenView.swift:1460`) and type in a Claude pane on the iPad. Prediction: the predictive bar appears and a tapped suggestion works, because predictive taps arrive as plain `insertText`; autocorrect replacement does not, because UIKit applies it through `replace(_:withText:)` on text ranges Ghostty does not model, so it will either do nothing or double the word. Dictation may partly work. Whatever happens is recorded in this note. If the cheap path covers what Anthony wants, item 30 closes there; if not, the result tells us exactly which behaviours the composer has to supply.

## Files the build touches

- New `Sources/Heeler/Terminal/TerminalComposerView.swift` (the `UITextView`, traits, the diff mirror, the coordinator) and its tests (`TerminalComposerMirrorTests`: prefix diff, DEL count, Return clears, dictation-size insert).
- `TerminalKeyBar.swift`: the toggle at the leading edge; `didType` routed through the coordinator.
- `TerminalInputController.swift`: `sendTyped(String)` raw.
- `TerminalScreenView.swift` / `HerdrClientView.swift`: mount the composer, share the accessory bar, hide on hardware keyboard.
- `TerminalKeyboardInset.swift`: reuse the handoff, add the composer height to the inset.
- `KelpieVault/Testing status.md`: the device checks (autocorrect a misspelt word, tap a prediction, dictate a sentence, hold e for é, Esc mid-sentence, ctrl-c, `/` menu opens in Claude Code, toggle off then type raw).

Risk to name: touches keyboard input on the screen Anthony uses all day, so the build gets an `opus-reviewer` pass and the toggle defaults to off.

## Anthony's decisions (2026-09-15)

1. Mirror per keystroke. **Taken.**
2. Off by default; the toggle's state must persist across launches. **Taken**: the toggle is stored in `UserDefaults` (`kelpie.composer-enabled`) and read at launch, never reset by a reconnect or a Host switch.
3. Stage 0 first, same session as the build. **Taken.**
4. Return submits, no soft newline in v1. **Agreed.**

Next: its own round, from `resume.md`.
