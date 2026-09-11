---
source: "delegate-20260910-191536/herdr/findings.md — scout report on herdr itself, 2026-09-10 19:19"
---

# herdr findings (scout, 2026-09-10)
Repo clone: ./repo (https://github.com/herdrdev/herdr, shallow)

What: Rust terminal multiplexer/runtime for AI coding agents. TUI = ratatui 0.30 + crossterm 0.29; vendors libghostty-vt per pane.
Single binary (brew install herdr). Server/client split: herdr-server keeps panes alive, client attaches.
Non-terminal interface: documented Socket API https://herdr.dev/docs/socket-api/ (herdr.sock). Community web/mobile UIs exist.

Official app: "Herdr Connect" TestFlight https://testflight.apple.com/join/ZkRzJ6rm. LAN-only MVP, "remote connectivity not included". Protocol UNCONFIRMED.
Third-party iPad terminals with herdr docs: Moshi (https://getmoshi.app/docs/herdr), ShadowTerm (unconfirmed).

Mouse (source: src/client/terminal_setup.rs, src/pane/terminal.rs): crossterm EnableMouseCapture, writes SGR 1006 (+ optional 1016 pixel).
Per-pane WheelRouting: to child app's mouse mode or herdr's internal scroll emulation. Config: ui.mouse_capture (default true), ui.right_click_passthrough_modifier.
No EnterAlternateScreen found in outer client setup (inference). herdr keeps its own per-pane scrollback (advanced.scrollback_limit_bytes, 10MB default).

Right-click menu: docs claim mouse-first parity; no item list / key mapping table found. UNCONFIRMED.

Scrolling/keys: copy mode prefix+[ (prefix ctrl+b): h/j/k/l, PageUp/Down, Ctrl-b/f, Ctrl-u/d, / search, v select, y copy. https://herdr.dev/docs/keyboard/
No herdr-specific mobile scroll issue found. Blink+mosh cannot scroll (blinksh/blink#334). Moshi recommends mosh + multiplexer for scrollback.
Docs: SSH only for remote; no mosh/tmux/iPad mention. herdr positions itself as a tmux replacement.
