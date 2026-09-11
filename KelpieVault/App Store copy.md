---
note: Listing copy for Kelpie Console 1.0 — description, keywords, promotional text, what's new, review notes. Draft by Claude, 2026-09-11; Anthony to approve before it goes into App Store Connect.
---

# App Store copy (1.0)

**Name** (30): Kelpie Console
**Subtitle** (30): herdr console for iPad

**Promotional text** (170):
Your herdr agents, on the iPad. A real terminal for herdr's own TUI, plus Agent Notifications when Claude needs you or finishes.

**Description** (4000):
Kelpie turns an iPad into a console for herdr, the terminal multiplexer that runs your coding agents on a Mac or Linux machine. Connect over SSH and herdr's own interface fills the screen: your workspaces, panes and agents, exactly as on the desktop, driven by a Magic Keyboard, trackpad or touch.

Built for the iPad
• herdr's TUI is the app. Escape, Cmd+., Option word keys, Ctrl+B prefixes and Cmd+arrows all reach herdr.
• Trackpad and mouse scroll inside agent panes. Right-click opens herdr's menu. Long-press does the same by touch, and a hold-then-drag resizes panes and the sidebar.
• Touch text selection with handles, copy to the iPad clipboard, and paste back with Cmd+V.
• Photos and files go straight into an agent pane: paste, drop from Files, or attach from the menu. Kelpie stages the file on the host and types its path for you.
• Tap a URL to open it on the iPad. Tap a file path to view it from the host with Quick Look.
• Works in Split View, Slide Over and Stage Manager, in every orientation, with the font stepping down as the window narrows.

Agent Notifications
Turn them on and your host tells you when an agent is waiting for input or has finished. Each notification is encrypted on the host with a key only your iPad holds; the push relay forwards it to Apple without being able to read it.

Pairing in a minute
Install the Heeler plugin on your machine, run its pair action inside herdr, and paste or scan the Pairing Code. Kelpie keeps its SSH key in the Secure Enclave-backed Keychain; private keys never leave the device.

What you need
A Mac or Linux machine running herdr (herdr.dev) that the iPad can reach over SSH. Kelpie is a client; it runs nothing on its own.

Free and open source
Kelpie is free, with an optional tip jar for the developer. It is a fork of the open-source Heeler app, under the Apache 2.0 licence, and the source is at github.com/Getterbetter/Kelpie. Feedback and support: r/KelpieConsole.

**Keywords** (100):
herdr,terminal,ssh,claude code,codex,agent,console,tmux,developer,remote,coding,cli

**What's new** (1.0):
First release.

**App Review notes** (from docs/guides/app-review-host.md, host details filled in at submission):
Kelpie is a client for herdr, a developer tool that runs on the user's own machine, so it needs a machine to connect to. We have provided one for review. On the Welcome screen choose "Add a Host manually", enter host <IP>, user review, password <password>, and accept the host key. herdr's interface appears with a shell pane; type `ls` and press Return to see it respond. A 30-second recording of the same flow is attached. Notifications require the user's own machine and are not needed for review.

Related: [[App Store plan]]
