---
note: Anthony's feedback on each round. Record it here before acting on it.
---

# Feedback log

## Round 1 — 2026-09-10/11, first use on the 11-inch iPad Pro with a Magic Keyboard

### Liked

- **The bottom active-agents status bar.** The agent switcher strip along the bottom of the terminal screen.
- **The composer / keyboard choice.** Having both input modes available was right, even though the switching was wrong (below).

### Disliked

- **The composer appeared centred on screen with a hardware keyboard attached**, with no software keyboard under it. It had nothing to anchor to.
- **Return did not submit in keyboard (direct) mode.** Pressing Return on the hardware keyboard did nothing.
- **Above all: the UI deviated from herdr's.** Heeler's native console — the agent list, the per-agent terminal, the composer, the switcher bar — is not what he wants as the main screen. He wants exactly what his Mac terminal shows: the full herdr TUI with its own workspaces sidebar, tabs and panes, full-screen, with the iPad simply making it seamless to interact with.

### What round 2 did about it

The third point is the whole of round 2: herdr's own client became the root screen and Heeler's console was demoted behind one floating menu button, deliberately keeping every feature rather than deleting any. The first two both traced to the same cause — asking the user to track their input device in Settings — so keyboard mode became automatic from hardware-keyboard presence, which removes the centred composer by default. Return-to-submit got a partial fix (Direct Input now claims first responder while a keyboard is attached, which was a genuine gap) and is **still unconfirmed**; see [[Open items]].

The full reasoning is in [[Decisions]] and ADR 0017.

## Round 2 feedback

*The round-2 Release build is installed on Anthony's iPad and paired with the mini. He is testing it now.*

<!-- Record his feedback here, verbatim in substance, before acting on it. -->

### Liked

### Disliked

### Notes

---

If he does not raise them himself, the things worth asking about: trackpad two-finger scroll inside a pane · trackpad right-click opening herdr's menu · one-finger long-press as a right click · tapping a URL, especially one that ends a line · the keyboard pad appearing when the Magic Keyboard is detached · Ctrl+B prefix · the floating menu and the Agents cover · whether Return submits in the old console's Keyboard mode.

Related: [[Kelpie]] · [[Testing status]] · [[Open items]] · [[Decisions]]
