# herdr image/file paste research

## 1. `remote_image_paste`
- Config default (`herdr --default-config`, local, line 87): `remote_image_paste = "ctrl+v" # only active in herdr --remote; empty disables raw-key image paste`.
- Config reference (https://raw.githubusercontent.com/herdrdev/herdr/v0.9.0/docs/next/website/src/data/config-reference.json, key `keys.remote_image_paste`): "Local-client shortcut that sends a clipboard image to a remote Herdr session." Sibling key `terminal.kitty_graphics` notes graphics rendering/API is separately toggled client vs server side.
- Persistence/remote doc (raw.githubusercontent.com/herdrdev/herdr/v0.9.0/.../persistence-remote.mdx): "Herdr can bridge local desktop features such as image clipboard paste into the remote session by copying the image to a remote temp file and pasting that path." Plain SSH-into-server mode ("Herdr runs entirely on the server") has no such bridge — clipboard access requires the local `--remote` client.
- CHANGELOG.md (github.com/herdrdev/herdr/blob/master/CHANGELOG.md):
  - 0.6.0: "Remote clients now bridge local clipboard images into the remote pane by staging them as temporary image files and pasting the remote path, so Claude Code image paste works over `herdr --remote`." (#205). Same release: "Clipboard image reads are now capped to Herdr's image payload limit."
  - 0.7.2: "`herdr --remote` keeps `keys.remote_image_paste = "ctrl+v"` by default"; also WSL clipboard image paste added.
  - 0.6.1: `--remote-keybindings local|server` flag introduced.
- Mechanism, as documented: client reads the local OS clipboard image (mechanism/tool for the read is not published — only "clipboard" is named, no pbpaste/osascript detail found in official docs), transmits it to the server side over the `--remote` client-socket path, the server stages it to a **temporary file** (path/naming/format not documented), and the client then **pastes the resulting remote file path as text** into the focused pane (not bracketed paste, not a kitty-graphics placement — it becomes a typed path an agent CLI like Claude Code can read as `[Image #1]`/file-path input). Bound only in `--remote` mode; empty string disables it.
- Known failure mode: GitHub issue https://github.com/herdrdev/herdr/issues/205 — a user reports Claude Code image paste over `herdr --remote` (macOS/Ghostty client → Linux server) fails silently despite `experimental.kitty_graphics = true` on both ends; works over plain SSH+tmux. Suspected cause per reporter: image bytes/escape sequence not forwarded across the herdr remote transport, or the flag only honored on one end. (Note: this issue was filed against an older herdr version judging by referenced flag name; not re-verified live here.)
- Separate/unofficial: a third-party plugin `ddfonseca/herdr-paste-image` (https://github.com/ddfonseca/herdr-paste-image) is NOT the built-in mechanism — it's a community script that reads the clipboard client-side via `pngpaste`/`osascript` (macOS), `wl-paste`/`xclip` (Linux), or PowerShell (WSL), writes to a **local** `~/.cache/herdr-paste-image/image_<timestamp>.png`, and injects the path with `herdr pane send-text` (no Enter). Do not conflate this with the built-in `keys.remote_image_paste` feature — it operates only locally, not across the SSH remote boundary.

## 2. JSON API non-text capabilities
Full method list extracted from `herdr api schema --json` (herdr 0.8.2 installed locally, command run directly): no method has "paste", "upload", "clipboard", "attachment" in its name. Only image/graphics-bearing methods:
- `pane.graphics.set` — params (`PaneGraphicsSetParams`) include `data_base64` (string, default ""), `format` (`PaneGraphicsFormat`), `image_width`/`image_height` (required uint32), optional `layer_id`, `placement`, `z_index`. **This is the only request method whose params carry arbitrary binary payload (base64-encoded image bytes).**
- `pane.graphics.clear` — clears a placement, no payload.
- `pane.graphics.info` — takes `PaneTarget` only (capability/cell-size query).
- Socket API doc (raw.githubusercontent.com/herdrdev/herdr/v0.9.0/.../socket-api.mdx) adds: inline frames accept `png`, `rgb`, `rgba`, or `bgra` (bgra normalized to rgba); for repeated frames, "open a dedicated socket with `pane.graphics.stream`" and send a JSON header then exactly `data_length` raw bytes per frame (NOTE: `pane.graphics.stream` does **not** appear in the locally-installed 0.8.2 schema's method enum — it is documented against 0.9.0, so it looks newer than the installed CLI; not verified live here). Direct Kitty file transport is reserved for the primary layer.
- `pane.send_text` (`{pane_id, text}`), `pane.send_keys` (`{pane_id, keys[]}`), `pane.send_input` (`{pane_id, text?, keys?}`) — all params are `string`/`string[]` only (confirmed by reading the schema `$defs` directly). **No method other than `pane.graphics.*` can deliver non-text bytes; `pane.send_input` cannot carry an image or file, only text/key-name strings.**

## 3. Claude Code image input (per docs.anthropic.com / docs.claude.com "Common workflows", via web search, not independently re-fetched page-by-page)
- Drag-and-drop an image into the Claude Code window works.
- Ctrl+V (Alt+V on Windows/WSL) pastes a copied image directly into the CLI.
- Typing a file path in the prompt (e.g. "Analyze this image: /path/to/image.png") is sufficient — Claude Code reads the file by path.
- `@` opens a path-suggestion menu to attach a file/directory by reference.
Sources: https://docs.anthropic.com/en/docs/claude-code/common-workflows , https://docs.claude.com/en/docs/claude-code/common-workflows

## 4. herdr agent-guide.md
Fetched https://herdr.dev/agent-guide.md: contains **no** statement about giving an agent a file, file transfer, or image paste. It covers workspace/pane/agent-state topics only. (Not found — explicitly checked.)

## Sources
- `herdr --help`, `herdr config --help`, `herdr --default-config`, `herdr api schema --json` (all run locally against installed herdr 0.8.2)
- ~/.config/herdr/config.toml (read-only; contains no image/paste keys)
- https://herdr.dev/llms.txt
- https://herdr.dev/agent-guide.md
- https://raw.githubusercontent.com/herdrdev/herdr/v0.9.0/docs/next/website/src/data/config-reference.json
- https://raw.githubusercontent.com/herdrdev/herdr/v0.9.0/docs/next/website/src/content/docs/keyboard.mdx (no image-paste mention)
- https://raw.githubusercontent.com/herdrdev/herdr/v0.9.0/docs/next/website/src/content/docs/persistence-remote.mdx
- https://raw.githubusercontent.com/herdrdev/herdr/v0.9.0/docs/next/website/src/content/docs/socket-api.mdx
- https://github.com/herdrdev/herdr/blob/master/CHANGELOG.md
- https://github.com/herdrdev/herdr/issues/205
- https://github.com/ddfonseca/herdr-paste-image/blob/main/README.md (third-party, not the built-in feature)
- https://docs.anthropic.com/en/docs/claude-code/common-workflows / https://docs.claude.com/en/docs/claude-code/common-workflows
