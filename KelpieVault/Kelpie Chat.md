---
note: Kelpie Chat, the native iPhone surface over herdr and Claude Code (Open item 43) — what the 2026-09-16 spike proved, the architecture, the build rounds, what was rejected.
---

# Kelpie Chat

Anthony's ask (2026-09-16, [[Feedback log]]): on the phone herdr's TUI "works" but "its not really designed for a phone". He wants what feels like a polished iPhone app: text that appears like a chat, the way the Claude app works; artifacts (images, links, files) that are rich and tappable; a side panel with the workspaces and active agents; notifications that explain the status update; a [+] button for attachments. "Claude code is like god mode - having that in my pocket would be next level." His scoping answers the same day: **iPhone-first, with a setting to turn the feature off**; the iPad keeps herdr's TUI as the screen (ADR 0017), Chat reachable from the menu. Round 22 verified the design live and wrote this note; the build starts with item 43a.

## The finding in one paragraph

herdr's API cannot feed a chat and never will on its own: protocol 22 has 102 methods and not one carries a message, a tool call or an artifact; `agent.read` and `pane.read` return one flat text blob, capped at 1000 lines, and for an alternate-screen agent like Claude Code only the viewport and only while idle (ADR 0012 rejected a chat view for exactly this). **Claude Code's own transcript on the host can.** Every interactive session appends typed NDJSON to `~/.claude/projects/<encoded cwd>/<sessionId>.jsonl` (user turns, assistant text, tool calls, tool results, images inline as base64, the session title), and herdr's `pane.process_info` plus Claude Code's `~/.claude/sessions/<pid>.json` map a herdr pane to that exact file with no guessing. Control stays with herdr: `agent.prompt` sends, `agent.send_keys` answers a permission prompt, `pane.agent_status_changed` is the push, the plugin already runs on the host with the agent's cwd. So the chat is a **read model over Claude Code's transcript, driven by herdr**. ADR 0019 records the choice.

## What the spike proved (2026-09-16, on the mini: herdr 0.8.2 protocol 20, Claude Code 2.1.273)

Scripts and captures are under `Archive/round22/` (`rpc.py` speaks the socket, `watch.py` samples at 1 Hz, `perm.py` drives a permission prompt; `watch1-3.log` and `spike-transcript-shape.txt` are the raw captures). A throwaway workspace `kelpie-spike` with a `claude` agent in `~/Developer/Kelpie` was used and closed; nothing was left on the mini.

**1. Pane → transcript, exactly.** `pane.process_info {pane_id}` on 0.8.2 (the method exists on the mini's version, not only in the 0.9.0 snapshot) returns `foreground_processes[0] = {pid: 86367, argv0: "claude", argv: [...], cwd: "/Users/anthonytopalides/Developer/maple-and-salt"}` for Anthony's live pane `wC:p1`. `~/.claude/sessions/86367.json` reads `{pid, sessionId: "91233534-…", cwd, status: "idle", name: "maple-and-salt-c6", version: "2.1.273", startedAt, updatedAt, messagingSocketPath, …}`. `~/.claude/projects/-Users-anthonytopalides-Developer-maple-and-salt/91233534-….jsonl` exists (1.2 MB, 261 lines) and is the live file. The cwd encoding is every non-alphanumeric character to `-` (seen on `/`, `.`, `~` and a space in the project directory names). `AgentInfo.agent_session` is absent on 0.8.2; the process route does not need it. The `sessions/<pid>.json` entry disappears when the agent exits.

**2. The transcript does not exist until the first prompt.** The spike agent launched at 10:15:58; its `sessions/1407.json` appeared at once, the `.jsonl` only when the first prompt went in. A chat for a fresh agent starts empty and watches for the file.

**3. Cadence, measured at 1 Hz with `agent.prompt` at t = 0** (`watch1.log`, `watch2.log`):

| t | transcript | Claude `sessions` status | herdr status |
| --- | --- | --- | --- |
| 0 s | (prompt accepted, `agent_prompted` returned in < 0.5 s) | idle | idle |
| 3 s | `user` line (the prompt text) and, on the first turn only, 15 `attachment` lines totalling 170 KB (CLAUDE.md, memory, skills, reminders) | busy | working |
| 4 s | `ai-title` ("Pong response") | busy | working |
| 5 s | `assistant` text, then `system {subtype: turn_duration, durationMs}` | idle | **done** |
| 8 s | | idle | idle |

A tool-using turn: `user` at 3 s, `assistant tool_use` (Bash, with `input.command` and `input.description`) at 5 s, `user tool_result` (the output, `is_error`) at 6 s, `assistant` text and herdr `done` at 7 s. **Assistant text lands once per message, not per token; tool calls and results land within a second of happening.** herdr's `done` and Claude's `idle` flip within the same second as the final text.

**4. Permission prompts are a renderable state** (`perm.py enter`). In manual mode, `agent.prompt` with a Bash command: at 4.1 s herdr reads **`blocked`**, Claude's `sessions` status reads **`waiting`**, and the transcript's last line is an `assistant tool_use` with no matching `tool_result`. `pane.read visible` at that moment shows the prompt itself:

```
 Bash command
   touch /tmp/kelpie-spike-perm2.txt
   Create an empty file in /tmp
 Do you want to proceed?
 ❯ 1. Yes
   2. Yes, and always allow access to /tmp from this project
   3. Yes, and switch to auto mode
   4. No
 Esc to cancel · Tab to amend
```

`agent.send_keys ["enter"]` accepted it; herdr read `done` 1.5 s later. `["esc"]` on a plan-approval prompt (the same `blocked` + dangling `ExitPlanMode` tool_use shape) refused it; the transcript then carried a `tool_result` beginning "The user doesn't want to proceed with this tool use" and herdr read `done` 0.5 s later. So a native card needs: the tool name and input from the transcript, the option list from the visible screen (numbers and labels change with the tool and the mode), and keys `1`–`4`, `enter`, `esc`. **Caveat, auto mode:** the first attempt, with the agent in auto mode, still passed through `blocked`/`waiting` for about 5 s while the classifier decided, then resolved itself. The card must read the mode (the transcript writes a `permission-mode` line with `permissionMode: auto|default|acceptEdits|plan` every turn) and show buttons only when a human answer is expected, or debounce.

**5. Modes.** Shift+Tab over `agent.send_keys ["shift+tab"]` cycles plan → auto → manual → accept edits → plan on 2.1.273; the cycle is state-dependent, so an app reads the mode from the `permission-mode` line or the status row, never by counting presses.

**6. Images.** A prompt naming `/tmp/kelpie-spike-red.png` produced a `Read` tool_use and a `tool_result` whose content is `[{type: "image", source: {type: "base64", media_type: "image/png", data: …}}]`: **every image the agent looks at is in the transcript, inline**, so the chat renders it without a download. Anthony's own photos already reach the pane as a staged SFTP path typed into the prompt (round 5, ADR 0006); the chat's [+] reuses that pipeline and the transcript then echoes the path in the `user` line and the image in the `Read` result.

**7. Cost and size.** Over ssh to `mac-mini` (loopback here, so a floor; the real figure is the Tailscale round trip): `stat -f %z` 0.18 s, `tail -c +N` of the last 20 KB 0.36 s, the whole 810 KB file 0.19 s. `~/.claude/projects` on the mini is 1.5 GB; the Kelpie project has 52 sessions, the largest 8.6 MB; tool results dominate. The chat reads by byte offset and never the whole file at once, and renders tool results truncated.

**8. Titles and noise.** `ai-title` gives the session a title after the first reply and updates later; `system turn_duration` ends a turn. `attachment`, `mode`, `permission-mode`, `atis-latch`, `last-prompt`, `file-history-snapshot` and `queue-operation` lines are skipped by the chat (the `permission-mode` value is kept). Unknown line types must be ignored, the format is unversioned (each line does carry `version`).

## Architecture

```
iPhone (idiom .phone, setting "Chat on iPhone" on; off → HerdrClientRootView as today)
┌─ ChatRootView ──────────────────────────────────────────────────────────────┐
│ side panel (drawer): hosts › workspaces › agents      ← ConsoleStore.agents,│
│                                                        workspacesByHost     │
│ ChatView(agent)                                                             │
│   messages   ← ChatTranscriptStore: Transport.paneProcessInfo (new) →       │
│                 sessions json → transcript path → Transport.readHostFileRange│
│                 (new, exec `tail -c +N`, marker-framed like SkillProbe)      │
│   refresh    ← ConsoleStore.agentStatusUpdates(for:) + a 1–2 s timer while  │
│                 working and foregrounded; byte offset per session           │
│   send       ← ConsoleStore.promptAgent (agent.prompt); optimistic row until │
│                 the transcript echoes the user line                          │
│   permission card ← herdr blocked + dangling tool_use + screen options;      │
│                 answers via agent.send_keys                                  │
│   [+]        ← HerdrMediaStagingStore (stageImage/stageFile), path typed    │
│   tap a path ← Transport.downloadFile → Quick Look; URLs open on the device │
│   images     ← inline from tool_result base64                               │
│   "Open terminal" ← the existing Attach (AgentTerminalView)                 │
└─────────────────────────────────────────────────────────────────────────────┘
plugin: notify-hook adds `summary` (last assistant text; for blocked, the pending tool and command) from the transcript, inside CT_BUDGET
```

Read model: `ChatMessage { id, role: user | assistant | tool, blocks: [text(markdown) | toolUse(name, inputSummary) | toolResult(truncated, isError) | image(data) | filePath], timestamp }`, built by an incremental NDJSON parser that keeps a byte offset per session and tolerates unknown line types. Markdown through `AttributedString(markdown:)` first. iPad: unchanged root; a "Chat" item in the Kelpie menu opens the same `ChatView` for the presented agent.

Codex and grok panes have no transcript route yet; they keep the terminal. Only Claude Code gets a chat in the first cut.

## Build rounds (one session each, `make test-device` green on both devices at the end)

- **43a — transport and read model, no UI. Done 2026-09-16, round 24** (see *What exists* below).** `Transport.paneProcessInfo` (wire type from the schema snapshot, never hand-edited), `Transport.readHostFileRange(path, offset, maxBytes)`, `ClaudeSessionLocator` (pane → transcript path, with the `sessions` json read), `ClaudeTranscriptParser` with fixtures cut from real transcript lines (redacted), unit tests on the device.
- **43b — read-only ChatView on the iPhone behind a setting.** `ChatTranscriptStore`, the message list with Markdown text and collapsed tool rows, "Open terminal", setting `kelpie.chat-on-iphone` (default on for the phone idiom), the root switch in `ContentView`/`HerdrClientRootView`.
- **43c — composer, [+] and the permission card.** Send through `promptAgent`, attachments through the staging store, the card through `sendAgentKeys` with the mode read from the transcript, optimistic sent rows.
- **43d — side panel and sessions.** Hosts, workspaces and agents over `ConsoleStore`; new agent through `StartAgentStore`; past sessions per workspace from the project directory with `ai-title`.
- **43e — rich artifacts and notifications.** File paths → `downloadFile` + Quick Look, inline images, links; the plugin's `summary` field and its rendering in `AgentNotificationRenderer`; the notification deep link into the chat (`AgentNotificationRouter` already carries the pane id); the Live Activity's rows reused.
- **43f — polish.** Dynamic Type, haptics, empty states, iPhone screenshots for the App Store 1.1, this note and [[iPhone assessment]] refreshed.

## What exists (after round 24, 2026-09-16)

- `Transport.paneProcessInfo` — generated from the schema snapshot (`PaneProcessInfoParams`, `PaneProcessInfo`, `PaneProcessInfoProcess`, `PaneProcessInfoResponse`); `ScriptedTransport.setPaneProcessInfo` scripts it in tests.
- `Transport.readHostFileRange(path:offset:maxBytes:)` → `HostFileRange { offset, data, fileSize, nextOffset, reachedEnd }`, over `HostFileProbe`'s marker-framed `tail -c +N | head -c M` exec with the size printed after the body (byte-exact, `~`-relative paths resolved by the transport, 1 MiB clamp). `ScriptedTransport.setHostFile(_:atPath:)` scripts it.
- `ClaudeSessionLocator` (`Sources/Heeler/Chat/`): `claudeProcess(in:)`, `sessionsFilePath(pid:)`, `encodedProjectDirectory(cwd:)`, `transcriptPath(cwd:sessionID:)`, `decodeSession`, and `locate(paneID:transport:)` → `ClaudeSessionLocation`; errors `noForegroundProcess`, `foregroundIsNotClaude(name:)`, `malformedSessionsFile`.
- `ClaudeTranscriptParser`: `feed(Data)` in any chunking; `messages: [ChatMessage]`, `bytesConsumed`, `nextOffset`, `permissionMode`, `title`, `version`, `lastTurnDurationMs`, `droppedLineCount`, `pendingToolUse`. `ChatMessage { id, role user|assistant|tool, blocks text|toolUse|toolResult|image, timestamp }`; `ClaudePermissionMode.expectsHumanAnswer`.
- Fixture `Tests/Fixtures/claude-transcript-v1.jsonl` from `scripts/cut-transcript-fixture.py`; suites `HostFileProbeTests`, `ClaudeSessionLocatorTests`, `ClaudeTranscriptParserTests`, two wire round trips, one real-sshd E2E case.
- Learned from real files: one API message spans several lines sharing `message.id` with tool results interleaved (the parser groups them); `user` lines can be `isMeta`; new line types since the spike (`agent-name`, `cost-state`, more `system` subtypes) are skipped. Not yet: `ConsoleStore` passthroughs and `ChatTranscriptStore` (43b).

## Rejected

- **herdr's API as the read model.** No conversation concept; see above and ADR 0012.
- **`claude -p --input-format stream-json --output-format stream-json --resume <id>` over an SSH exec channel.** Documented and structured, but it bypasses herdr's supervision: the session dies with the channel, the TUI's permission flow is gone, and it is no longer the pane Anthony sees on the Mac.
- **Claude Code's `/tmp/cc-socks/<pid>.sock` messaging socket** (`peerProtocol: 1`, per-session `.key` files). Private and undocumented.
- **Parsing the TUI repaint into messages.** ADR 0012's reason still holds: breaks with every upstream TUI change.

## Risks

- The transcript format is Claude Code's own and unversioned in shape. Lenient parser, fixture tests, the `version` field logged, the terminal one tap away: the posture the repo already takes with herdr's API.
- `agent.prompt` types into the TUI; if the TUI is mid-dialog the text lands in the dialog. The status check before sending and the permission card cover the known cases.
- Auto mode's 5 s pass through `blocked` (finding 4) would flash a card that answers itself; read the mode first.

Related: [[Open items]] item 43 · [[iPhone assessment]] · [[Decisions]] 2026-09-16 · ADR 0019, 0017, 0012 · [[Archive/round22/spike-transcript-shape|the spike's transcript shape]]
