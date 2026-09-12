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
- **The zero-code route (copy a photo on the iPad, Ctrl+V in Claude Code via Universal Clipboard) did not work for him** — "hence the ask". iCloud clipboard can be flaky, so a native path is what he wants.
- **Asked for a sub-agent to research what else is missing** when working through the iPad that would otherwise be available directly on the Mac.
- **New feature to workshop: reducing the size of the window, and how that works in side-by-side viewing** (Split View / Slide Over / Stage Manager).

### Round 4 feedback (2026-09-11)

- **Media works for copy and paste.** Attaching from the menu works.
- **Drag and drop from Files does not work**: the item just disappears from the screen when released. Copy and paste of the same file works.
- **Clipboard out works**: text selected in herdr pastes into other iPad apps. (Gap 2 closed with no code.)
- **"The Mac vs iPad gaps: implement all of them."**
- **Window size**: "resizing keeps its shape so a side by side view is near impossible. Most apps will let you do half a screen to share it with another half a screen." Asked to see the workshop details.

### Round 5 feedback (2026-09-11)

- **Split View works well.**
- **herdr's sidebar is either impossible to touch with a tap or not moveable with a tap; it only works with the mouse.** *Clarified after a diagnostic round:* workspace and agent taps **work fine**; the ask is **resizing the side pane by touch** (dragging its edge with a finger), which only works with the mouse. (A local test also showed herdr accepts a bare click on a sidebar row with no pointer motion.)
- **Selecting text by touch**: a double tap selects one word and there is no way to extend it. He would like iPadOS-style selection handles. Highlighting with the trackpad or mouse is fine.

### Round 6 feedback (2026-09-11, first build)

- **Selection handles appear**, but tapping a handle to drag it makes the selection disappear.
- **Long-press-then-drag does not respond to touch**; the sidebar still resizes with the mouse. *Second try with the trace on:* **dragging worked** — but "there is no tap because there's no haptic on an iPad; might need another way to signal" that the hold has registered.

### Round 6 feedback (2026-09-11, second build)

- **Selection handles can be dragged now**, but a multi-line selection spans over the sidebar, "which isn't ideal compared to when highlighting by text" (herdr's own selection stays inside the pane).
- **A huge blue box covers most of the screen** on the long-press hold (both when resizing and when holding without moving) — "wasn't a ring". The hold cue is mis-sized.
- Context at 45%; asked whether a new session is needed and, if so, to update `resume.md`.

### Round 6b feedback (2026-09-11)

- **The ring works and the selection stays in the pane now.**
- The ring is a little small, hard to see behind the finger; "maybe 25–50% bigger".
- After the 64 pt ring: **"the ring is good."** Pausing here to start a new session; a separate session is handling disk space. "Not sure if we're using git for this project but we should."

### What round 3 did about it (2026-09-11, commit `77cabda`)

Escape and Cmd+. are now claimed as priority key commands on the terminal view (iPadOS's text-input system was eating them before the press ever arrived, as it does Ctrl chords). Option+Backspace, Option+Left/Right and Option+Fn+Delete send the ESC-prefixed word keys. The dim ellipsis became a labelled capsule naming the current Host, with Switch Host and Hosts first — the menu always had Hosts in it; it was just invisible. Onboarding is a written proposal only: [[Onboarding proposal]]. Spec and review in `Archive/round3/`. **None of it is confirmed on the device yet.**

---

If he does not raise them himself, the things worth asking about: trackpad two-finger scroll inside a pane · trackpad right-click opening herdr's menu · one-finger long-press as a right click · tapping a URL, especially one that ends a line · the keyboard pad appearing when the Magic Keyboard is detached · Ctrl+B prefix · the floating menu and the Agents cover · whether Return submits in the old console's Keyboard mode.

Related: [[Kelpie]] · [[Testing status]] · [[Open items]] · [[Decisions]]

### App Store direction (2026-09-11)

Anthony, after round 7: "The other task required is getting this into the app store. It's going to be a free app, potentially with a donate to the dev option at some point. No internal or external testing - I'll start a reddit page for it and people can post there."

Read as: ship Kelpie to the App Store as a free app; no TestFlight tester groups (the upload still goes through App Store Connect, testing is just skipped); a donate option is a later version, not 1.0; the subreddit becomes the support channel. The push-to-GitHub question (item 0) is parked until he is at his desk.

### App Store plan answers (2026-09-11)

Anthony, to the eight decisions in [[App Store plan]]: "1- yes 2- what does that mean? 3- is this for notifications? If it'll be really cheap, then fine. 4- how can I give you access to cloudflare 5- fine 6- draft options 7- yep 8- I'm fine with in app purchase tip if it means less piping of infra to take payments, can be in v1.0"

Read as: iPad-only for 1.0 (done); public-vs-private repo needs explaining (the privacy policy URL must be a public page); he conflated 3 (a VPS so App Review can pair with a herdr host) with 4 (the push relay) — both are cheap, clarified in the session; he wants to hand over Cloudflare access (answer: `wrangler login` in his own terminal, plus an APNs key from the developer portal); name/subtitle fine; icon options wanted; `r/KelpieApp` confirmed; a StoreKit tip jar goes into 1.0.

### App Store follow-ups (2026-09-11)

Anthony: "1- I think the Weights project in ~/Developer/ already has these 2- make it public 3- yes 4- lets go with two."

Read as: reuse the APNs key from his Weights app (one APNs auth key serves every app on the team); the GitHub repo is public; the reviewer VPS is approved; icon draft 2 (front-facing head, `>_` eyes) is the icon.

### Dependency watch (2026-09-12)

Anthony, `/delegate` while another session works in the same directory: "Kelpie has dependencies and could break if things change. I'm looking for a routine that runs on a recurring basis to check for these dependencies and feed the pipeline of development needed to respond to changes quickly. the goal would be to optimise for automation to respond to change quickly where fixes dont then break something else."

Read as: a scheduled watcher (his launchd fleet pattern) over everything Kelpie depends on (herdr releases and the API schema, Heeler upstream, libghostty-spm, libssh2 and OpenSSL, the Node plugin and relay, the Xcode toolchain, the relay Worker and the review host), which detects change, opens the work as GitHub issues on the public repo, prepares the mechanical fixes on branches, and gates every fix behind the existing checks (wire-type drift check, a compile, CI on the fork, a device build) so a fix cannot land unverified. Outward-facing steps (loading the launchd job, publishing issues, pushing) wait for his yes.

### Round 9 device checks and feedback (2026-09-12)

Anthony, after the App Store submit: "return on the on-screen keyboard works now but feature: the 'keys section' should be a row of chips sitting above the keyboard instead of separate section. tips are showing in the settings menu, all three. the other unprompted suggestions i think are fine to do later unless you think they need to be done now."

Read as: on-screen Return in a shell pane is confirmed; the tip sheet lists all three tips (the earlier capture was wrong, not the app); the key pad that appears with the software keyboard should become a keyboard-attached chip row (an input accessory above the keyboard) rather than its own section of the screen; the Hetzner teardown, the universal test target and the review watch can wait.
