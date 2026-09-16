---
status: accepted
---

# A native chat on the iPhone reads Claude Code's transcript; herdr keeps control

Date: 2026-09-16

## Context

On the iPhone, herdr's TUI runs inside Kelpie and works (its own mobile layout takes over at 64 columns), but it is a terminal on a phone. Anthony wants a chat: messages, tappable artifacts, a workspaces-and-agents panel, notifications that say what happened, a [+] for attachments.

ADR 0012 rejected a chat-style view because herdr's API has no conversation concept, and that is still true of protocol 22: `agent.read` and `pane.read` return a flat text blob capped at 1000 lines, and for an alternate-screen agent only the viewport, only while idle. ADR 0013 and ADR 0017 then made the terminal the presentation of record.

What changed is not herdr. Claude Code writes an append-only NDJSON transcript per session on the host (`~/.claude/projects/<encoded cwd>/<sessionId>.jsonl`) with typed lines: the user's prompt, the assistant's text, every tool call with its input, every tool result including images as inline base64, and the session title. It also registers each running session in `~/.claude/sessions/<pid>.json` with the session id, cwd and a status (`idle`, `busy`, `waiting`). herdr's `pane.process_info` gives the pane's foreground pid and cwd. Verified live on 2026-09-16 (herdr 0.8.2, Claude Code 2.1.273): the pane maps to its transcript exactly; a tool call appears in the file within a second of happening, the reply text within a second of herdr reporting `done`; a permission prompt is herdr `blocked` plus a tool call with no result, and `agent.send_keys` answers it.

## Decision

On the iPhone, Kelpie's root screen is a native chat built as a **read model over Claude Code's transcript file on the host**, refreshed on herdr's `pane.agent_status_changed` push and a short timer while an agent is working. Control stays with herdr: prompts go through `agent.prompt`, permission answers through `agent.send_keys`, attachments through the existing SFTP staging, file taps through the existing SFTP download. The terminal (the existing Attach) stays one tap away for anything the chat cannot show. The feature has an off switch that restores herdr's TUI as the root; the iPad keeps ADR 0017 with the chat reachable from the menu.

The transcript is read by byte offset over an SSH exec channel (`tail -c +N`, marker-framed like the skill-file read), never whole; unknown line types are ignored; `attachment` lines (which carry the agent's context and dominate the first turn) are skipped.

## Consequences

- A second file format the app depends on and does not own. Claude Code's transcript is unversioned in shape (each line carries the CLI `version`). The parser is lenient, fixture-tested against real lines, and the terminal is always available: the posture the app already takes with herdr's API.
- Only Claude Code panes get a chat. Other agents keep the terminal until they have a comparable transcript route.
- The chat is not a stream: assistant text arrives when a message completes. Tool activity fills the gap.
- Auto mode passes through `blocked` for a few seconds while Claude Code's classifier decides; the permission card reads the `permission-mode` line before offering buttons.
- Supersedes ADR 0012's rejection of a chat-style view for the iPhone only. ADR 0013 and ADR 0017 stand for the iPad and for the terminal behind the chat.

## Alternatives considered

- **herdr's API as the source.** No conversation data; rejected on the same evidence as ADR 0012.
- **`claude -p --input-format stream-json --output-format stream-json --resume <id>` over exec.** Documented and structured, but the session then lives and dies with the SSH channel, loses the TUI's permission flow, and is no longer the pane Anthony sees on the Mac. herdr's supervision is the point.
- **Claude Code's `/tmp/cc-socks/<pid>.sock` session messaging socket.** Private, keyed, undocumented.
- **Reconstructing messages from the TUI repaint.** Rejected in ADR 0012 and still wrong: it breaks with every TUI change.
