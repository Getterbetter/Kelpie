---
note: First-run onboarding in Kelpie — proposed and built 2026-09-11 (commit `a2d66a2`), see the Status section at the top.
---

# Onboarding proposal

## Status (2026-09-11)

**Built**, per Anthony's decisions: lead with the plugin and pairing, manual SSH as an option to dive into; fix the QR if possible; pasting the code is the clean path when iCloud clipboard works, typing it or scanning the QR otherwise. `WelcomeView` is the no-Host root and the menu's **Setup Guide**; `PairingCodeEntryView` is the paste-first pairing entry (Paste button, typed field, "Scan QR Code instead"). The clipboard is read only on a tap, never on appear — the iOS Allow Paste alert and upstream #204 ruled out the auto-submit the proposal wanted. QR: the scanner runs at `.accurate`, and the plugin no longer slices into the QR when its pane is too short (`Archive/round3/qr-investigation.md`). **Not yet seen on the device**: Anthony has a Host, so the Welcome root only shows after removing it; Setup Guide in the menu shows the same screen.


## What exists today

- With zero Hosts the root screen is Heeler's `ConsoleView` and its "No Hosts" empty state: a `server.rack` icon, "Add a machine that runs herdr to see its Agents here." and one **Add Host** button. It opens the Hosts sheet, whose own empty state offers **Scan to Pair** and **Add Manually**.
- The only written setup instructions are the upstream README and the landing page (`landing/src/components/Connect.astro`), both describing the upstream Console-first app. Nothing in the app tells the user what to run on the Mac.
- The pieces a new user needs are all real and working: QR/paste pairing (`Sources/Heeler/Pairing/`), the manual Host form with on-device key generation and a copyable `authorized_keys` line, and the per-Host preflight checklist (`HostOnboardingView`) with fix-it hints for SSH, home dir, herdr installed, server running, protocol.
- The mini-side steps that actually worked are already written down in [[Pairing and setup]]; the QR was not recognised, pasting the code over the iCloud clipboard was.

So the gap is not a missing capability. It is that the first screen says "Add Host" and nothing else, and the Mac-side half of the setup lives only in the vault.

## Proposal: a Welcome screen replaces the no-Host root

Replace the console's "No Hosts" state with a Kelpie `WelcomeView` shown as the root while there are zero Hosts. One screen, no paging:

1. **Title and one line.** "Kelpie runs herdr on your Mac, full screen, on your iPad." Below it: "You need a Mac with herdr running and Remote Login on."
2. **On your Mac** — a numbered list with copyable commands:
   - Turn on Remote Login: System Settings → General → Sharing.
   - Install herdr's pairing plugin: `herdr plugin install ZingerLittleBee/Heeler/plugin --ref main --yes` (copy button).
   - Open the pairing popup: `herdr plugin action invoke heeler.pair` (copy button), with the note that the popup appears inside herdr's TUI, not the shell, and that `c` copies the Pairing Code.
3. **On this iPad** — three buttons: **Paste Pairing Code** (primary; universal clipboard is the path that worked), **Scan QR**, **Add Manually** (the existing `HostFormView` for people without the plugin, which shows the public key to paste into `authorized_keys`).
4. After a Host is added, the existing preflight checklist runs unchanged and the root switches to herdr's TUI as it does now. The console's own "No Hosts" state stays for the Agents cover.

Reachable again later as **Setup guide** in the Kelpie menu, so a second device can be set up without deleting the first Host.

## Why this shape

- It reuses every existing flow and adds one SwiftUI file plus a menu item; the pairing, key generation and preflight code do not change.
- It puts the Mac-side commands on the iPad screen, which is where the user is standing when they wonder what to do.
- "Paste" is primary because it is the route that worked; the QR path can be promoted once it is fixed.
- Skipped: a multi-page carousel (nothing to say beyond the one screen), and any in-app account or relay setup (push relay is an [[Open items]] item of its own).

## Answered questions

- Plugin and pairing first; manual SSH as an option they can dive into. *(Anthony, 2026-09-11)*
- QR: fixed where the evidence pointed (plugin clamp, scanner quality); paste stays primary, typing and QR are the fallbacks.

Related: [[Pairing and setup]] · [[Feedback log]] · [[Open items]] · [[Kelpie]]
