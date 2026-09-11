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

*(none recorded yet)*

### Disliked

- **Escape does not reach herdr.** Neither Escape nor Cmd+. on the Magic Keyboard passes through to the herdr client. He asked what else still needs to be mapped.
- **Option+Backspace has never deleted the whole word** in terminal sessions for him, on any build. It should, if that is possible.

### Notes — things to think about (2026-09-11)

- **Onboarding.** There are no instructions for a new user on how to connect to their herdr instance.
- **Reaching Hosts from inside herdr.** The herdr view is full screen and he could not see a way to get to Hosts to connect to another device. His suggestion: perhaps it just needs a button somewhere.

### Round 3 feedback (2026-09-11, on the device)

- **Option+Backspace works.**
- **The host capsule works** — "great stuff".
- **Escape and Cmd+. still do not work** (first round-3 build). Fixed the same day: **"escape works, thank you."** His Magic Keyboard **has no Escape key**, so Cmd+. is the only Escape he has — and iPadOS delivers Cmd+. as a *press* with the period keycode, the Command modifier stripped and `UIKeyInputEscape` as its characters, which the first build did not recognise.
- Asked to be talked through the onboarding proposal. Then: **happy with the scope. Lead with the plugin and pairing, manual SSH as an option they can dive into. Fix the QR if possible**, though copying the pair code was very clean as long as iCloud clipboard works; otherwise the user can type it in or use the QR.
- Testing: the iPad is plugged into the Mac with Enable UI Automation on, so Claude can drive it.

### Round 3b feedback (2026-09-11)

- **The Welcome screen looks good.**
- **He will not test the QR code**: it is a free app, someone else will test it. (So the plugin-on-the-mini step in [[Open items]] is not needed for him.)
- **Wanted next: bringing media into herdr from the iPad** — files, photos, etc. — by drag and drop, or ideally by copy and paste. Fine to do here or in a new session.

### What round 3 did about it (2026-09-11, commit `77cabda`)

Escape and Cmd+. are now claimed as priority key commands on the terminal view (iPadOS's text-input system was eating them before the press ever arrived, as it does Ctrl chords). Option+Backspace, Option+Left/Right and Option+Fn+Delete send the ESC-prefixed word keys. The dim ellipsis became a labelled capsule naming the current Host, with Switch Host and Hosts first — the menu always had Hosts in it; it was just invisible. Onboarding is a written proposal only: [[Onboarding proposal]]. Spec and review in `Archive/round3/`. **None of it is confirmed on the device yet.**

---

If he does not raise them himself, the things worth asking about: trackpad two-finger scroll inside a pane · trackpad right-click opening herdr's menu · one-finger long-press as a right click · tapping a URL, especially one that ends a line · the keyboard pad appearing when the Magic Keyboard is detached · Ctrl+B prefix · the floating menu and the Agents cover · whether Return submits in the old console's Keyboard mode.

Related: [[Kelpie]] · [[Testing status]] · [[Open items]] · [[Decisions]]
