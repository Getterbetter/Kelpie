# r/KelpieConsole copy (draft for Anthony, 2026-09-17)

Character limits are Reddit's current ones; each field is under its cap.

## Community settings

**Display name:** Kelpie for herdr

**Description (public, ≤500):**
Kelpie runs herdr's own terminal on the iPad and iPhone over SSH, so you can check on a coding agent and nudge it along away from the desk. Free, open source (Apache 2.0), a fork of Heeler. Bugs, feature requests, setup questions and screenshots welcome. Developer answers here.

**Welcome message (shown to new members, ≤5000):**
Welcome. Kelpie is herdr's own TUI on your iPad or iPhone, not a native re-skin. The quickest way to help is a post with the flair Bug or Setup help and your herdr version (`herdr --version`), Kelpie build number (Settings → About) and what you expected to happen. The developer reads everything here.

**Community type:** Public. **Post types:** text, image, link. **Discovery:** on.

## Sidebar widgets

**Widget: Get Kelpie (text)**
- App Store: submitted, in review (link when it goes live)
- TestFlight public beta: https://testflight.apple.com/join/AkJxAbnJ
- Source and issues: https://github.com/Getterbetter/Kelpie
- Privacy policy: https://github.com/Getterbetter/Kelpie/blob/kelpie/PRIVACY.md
- herdr itself: https://herdr.dev

**Widget: What you need (text)**
A Mac or Linux machine running herdr that your iPad or iPhone can reach over SSH. Kelpie is a client; it runs nothing on its own. For Agent Notifications, install the Heeler plugin on that machine and pair once.

**Widget: Related communities (community list)**
r/ClaudeCode, r/ClaudeAI, r/ChatGPTCoding, r/commandline
(Reddit's "Related communities" widget only accepts subreddit names; r/herdr if it exists.)

## Rules (≤6, each title ≤100 chars, description ≤500)

1. **Stay on topic: Kelpie, herdr and running agents from iPad or iPhone.** General AI or coding-agent chat belongs in r/ClaudeCode or r/ClaudeAI. herdr questions unrelated to Kelpie are fine if a Kelpie user would hit them.
2. **Bug reports: say what you ran and what you saw.** Include the herdr version, the Kelpie build, the device, and what you expected. A screenshot or a short recording gets it fixed faster. Blur anything private (hostnames, keys, paths).
3. **Never post secrets.** No private keys, Pairing Codes, host passwords, API keys or tokens, not even to show a bug. Redact before you post; a mod will remove a post that leaks one.
4. **Be civil.** Disagree with the design all you like; don't go after the person. No harassment, no slurs, no dogpiling on a new user's question.
5. **No spam, no unrelated self-promotion.** Other iOS terminal or agent apps are welcome in a comparison or a "have you tried" reply, not as drive-by ads. Affiliate links are removed.
6. **Search first, then ask.** If your question has a pinned answer, comment on that post rather than opening a new one, so the fix stays in one place.

## Post flairs (mod-assignable and user-selectable)

| Flair | Colour | Use |
|---|---|---|
| Bug | red | something broken, with the details from rule 2 |
| Setup help | orange | pairing, SSH, notifications, "it won't connect" |
| Feature request | blue | what you wish it did |
| Release | green | mod only: new build, App Store and TestFlight news |
| Showcase | purple | your setup, a screenshot, a workflow |
| Discussion | grey | everything else on topic |
| Fixed | dark green | mod only: added to a Bug when the fix ships |

Require post flair: yes (makes triage cheap; the picker shows on submit).

## User flairs

- Developer (mod only; assigned to Anthony's account)
- Beta tester (self-assignable)

## Pinned post 1: Welcome (flair: Discussion, pinned, sorted first)

**Title:** Welcome to r/KelpieConsole: what Kelpie is, how to get it, how to report a bug

**Body:**

Kelpie puts herdr's own terminal on your iPad and iPhone over SSH. It is the same herdr you use on the desktop, on a different screen, so you can check on a coding agent and answer it from wherever you are. Free and open source (Apache 2.0), a fork of Heeler with credit in the app and the repo.

**Get it**

- TestFlight public beta: https://testflight.apple.com/join/AkJxAbnJ
- App Store: 1.0 is submitted and in review. This post will carry the link the day it is live.
- Source: https://github.com/Getterbetter/Kelpie

**What you need**

A Mac or Linux machine running herdr (https://herdr.dev) that the iPad or iPhone can reach over SSH. On the Welcome screen add the host by hand, or install the Heeler plugin on the machine and pair with a Pairing Code, which also turns on Agent Notifications (encrypted on the host; the relay only ever sees ciphertext).

**Report a bug**

Post here with the flair **Bug** and: herdr version (`herdr --version`), Kelpie build (Settings → About), device and iOS version, what you did, what you expected, what happened. A screenshot or short recording helps. Redact hostnames, keys and anything private first (rule 3). Prefer GitHub? Open an issue on the repo instead; either is fine.

**Ask for something**

Flair **Feature request**. Say what you were trying to do, not only the feature name; the input layer (keyboard, trackpad, touch) is where most of the work goes.

I'm the developer and I read everything here.

## Pinned post 2: Known issues and what's next (flair: Release, pinned second)

**Title:** Known issues in the current beta, and what's next

**Body:**

Current build: TestFlight build 5 (2026-09-15). App Store 1.0 in review.

Known issues:
- A notification can arrive on the device that is already showing the pane, without an in-app banner. Being worked on.
- Over Tailscale, the first reconnect after the network changes can stall for a few seconds before the retry lands.
- No soft newline in the composer yet (Claude Code wants `\` then Return).

Coming:
- App Store release once review passes.
- A chat view of a Claude Code session for the iPhone is designed and paused; it comes back after the release.

Reply here if you hit something not on the list, or open a Bug post.
