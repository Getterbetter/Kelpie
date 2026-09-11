---
note: Proposal for first-run onboarding in Kelpie — what a new user sees before they have a Host, and how they get from nothing to herdr's TUI. Written 2026-09-11 from Anthony's round-2 feedback; not built yet.
---

# Onboarding proposal

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

## Open questions for Anthony

- Should the guide assume the plugin (pairing) or lead with manual SSH? Proposal: plugin first, manual as the fallback link.
- The QR path: fix it (find out why the scanner rejected the code) or hide the button until it works?

Related: [[Pairing and setup]] · [[Feedback log]] · [[Open items]] · [[Kelpie]]
