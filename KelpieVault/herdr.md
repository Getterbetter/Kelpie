---
note: What herdr is, and the facts about it Kelpie is built on.
---

# herdr

[herdr.dev](https://herdr.dev) — a Rust terminal multiplexer and runtime built for AI coding agents. A tmux replacement in shape: a `herdr-server` keeps panes alive and a client attaches to them. Workspaces, tabs and panes, with a sidebar. TUI built on ratatui 0.30 + crossterm 0.29; it vendors libghostty-vt for per-pane terminal state. Single binary, `brew install herdr`. On Anthony's Mac mini it is what actually runs the agents; [[Kelpie]] is a window onto it.

On the mini, `herdr` is `~/.local/bin/herdr`, version **0.8.2** on 2026-09-12 (not on a non-interactive login's `PATH`; both the app and the [[Dependency watch]] add the well-known prefixes). Kelpie's committed API schema snapshot is 0.9.0 (protocol 22); the app admits older servers by a protocol floor. The watch reads the mini's version daily and flags it when it runs ahead of the snapshot.

Beyond the TUI, herdr exposes a documented **Socket API** over a Unix socket — that is what [[Heeler upstream|Heeler]] and therefore Kelpie use for everything that is not a terminal. See [[Architecture]].

## Attaching — the CLI facts that matter

| Command | What it attaches |
| --- | --- |
| `herdr` | **The full client.** The default launch command; no subcommand needed. Workspaces, tabs, panes, sidebar. Auto-starts the server if it is not running. **This is what Kelpie runs.** |
| `herdr --session <name>` | The same client, scoped to a named persistent session. |
| `herdr agent attach <target> [--takeover]` | One agent terminal. No client UI, no sidebar. What upstream Heeler runs. |
| `herdr terminal attach <id> [--takeover]` | One raw terminal stream. One writable owner per terminal. |
| `herdr --remote <host>` | Attach from a *different* machine over SSH. **Not** what Kelpie wants — Kelpie's SSH session is already on the target machine, so plain `herdr` is correct. |

There is no socket-path flag on the bare command; the socket comes from the environment. The client requires a TTY, so it only works over an SSH exec channel that requested a PTY.

## Mouse

- `ui.mouse_capture` defaults to **true**. herdr enables mouse capture and writes **SGR 1006** reports (optionally 1016 pixel).
- Per-pane `WheelRouting` sends a wheel either to the child application's own mouse mode or to herdr's internal scroll emulation.
- `ui.right_click_passthrough_modifier` exists as a config key.
- **Right click opens herdr's own context menu**, on the *press* at a cell (`ESC [ < 2 ; col ; row M`), with the release following; a menu row is then chosen by a left-button press. This is why Kelpie must not let a long-press release arrive as a stray left click — herdr would read it as picking a row. No published table of the menu's items was found.

## Scrollback and keys

- herdr keeps **its own per-pane scrollback** on the Host (`advanced.scrollback_limit_bytes`, 10 MB default), so Kelpie leaving and rejoining an attach loses nothing.
- Copy mode: `prefix + [` (prefix is `ctrl+b`), then `h/j/k/l`, PageUp/Down, `Ctrl-b/f`, `Ctrl-u/d`, `/` to search, `v` to select, `y` to copy.
- Sidebar toggle: `prefix + b`.
- An alternate-screen agent (Claude Code, codex, grok) leaves **no herdr-side scrollback** — history belongs to the agent CLI, and the only way back through it is to scroll that CLI itself.

## Config keys Kelpie cares about

| Key | Default | Why it matters |
| --- | --- | --- |
| `ui.mouse_capture` | `true` | Everything in [[Architecture]]'s input section depends on this being on. |
| `ui.mobile_width_threshold` | 64 columns | Below it herdr switches to a single-column mobile layout. At iPad widths it never triggers. |
| `ui.sidebar_width` | 26 columns | (`sidebar_min_width` 18, `sidebar_max_width` 36, `sidebar_start_collapsed` false) |
| `ui.right_click_passthrough_modifier` | — | The only right-click-related key found. |
| `terminal.shell_mode` | `auto` | Login shells on macOS — for *panes*, not for the client process. |

## Environment

- herdr sets `TERM=xterm-256color` and `COLORTERM=truecolor` for the panes it spawns. The **client** reads the *outer* terminal's `TERM` only to decide whether direct/Kitty graphics are available; the TUI itself runs over any reasonable `TERM`. Kelpie exports `COLORTERM=truecolor` and a `LANG` default anyway, because a non-login SSH exec has neither and herdr needs truecolor for its palette and UTF-8 for its box drawing.
- Default API socket: `~/.config/herdr/herdr.sock`; named sessions at `~/.config/herdr/sessions/<name>/herdr.sock`.

## URL handling on the Mac — the reason Kelpie intercepts taps

herdr hit-tests a clicked cell against OSC 8 hyperlinks first (`runtime.visible_hyperlinks`), then falls back to plain-text URL matching in the visible line (`url_at_column`). If the pane did not handle it and `safe_web_url` passes (only `http://` / `https://`), it emits `OpenSafeWebUrl`, which calls `crate::platform::open_url` — **`open <url>` on the Mac**, `xdg-open` on Linux.

That is the wrong machine when the person tapping is holding an iPad, which is why Kelpie resolves URL taps client-side and never sends the click. No keybinding for opening a URL exists; it is mouse-click only.

## Other herdr clients

- **"Herdr Connect"** — herdr's own official iPad app, TestFlight, LAN-only MVP ("remote connectivity not included"). Protocol unconfirmed.
- **Moshi**, **ShadowTerm** — third-party iPad terminals that document herdr usage; generic terminals rather than herdr clients.
- Community web and mobile UIs exist against the Socket API.

Source: [[Archive/research/herdr-findings|herdr scout report]] and [[Archive/research/ghostty-and-herdr-cli-findings|the round 2 CLI/Ghostty findings]]. The load-bearing Socket API facts (one request per connection, wire format, read limits, event kinds) are kept in the repo's `CLAUDE.md`, not duplicated here.
