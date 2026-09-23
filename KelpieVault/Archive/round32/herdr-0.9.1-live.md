# herdr 0.9.1 on the mini, live re-verification (round 32, 2026-09-23)

Open items 47 and 14. Anthony upgraded the mini himself after round 31: `~/.local/bin/herdr --version` reads `herdr 0.9.1`, and `herdr.sock` / `herdr-client.sock` are dated 2026-09-17 14:03 (the restart). `ping` answers `{"version":"0.9.1","protocol":22}` with capabilities `live_handoff`, `detached_server_daemon`, `endpoint_protocol_generation: 1`, `surface_interest`, `health_check`. `herdr api schema --json` is byte-for-byte equal (as parsed JSON) to `scripts/herdr-schema.json`.

Method: a throwaway workspace `kelpie-verify-r32` (`wF`) with a cwd in the session scratchpad, driven over `~/.config/herdr/herdr.sock` by `verify.py`, `verify2.py`, `verify3.py` (captures `verify-1/2/3.json`) and two inline probes, then closed with `workspace.close`; Anthony's six workspaces were never touched. Two throwaway `claude` agents: one in the untrusted scratch cwd (it sat on the trust dialog), one in a tab whose cwd was this checkout (trusted, reached `idle`); neither was prompted.

| CLAUDE.md fact | 0.9.1 result |
| --- | --- |
| One request per connection | Second write on a served connection: `BrokenPipeError` (EPIPE). Holds. |
| Malformed requests answered with `id: ""` | Missing `params`, non-JSON, and an unknown method all answer `id: ""`, `invalid_request`. Holds. |
| Lifecycle subscriptions are live-only, ack first | Ack `{"id":"sub32","result":{"type":"subscription_started"}}` is the first line; a tab created 0.5 s before subscribing is not replayed; one created after arrives as `tab_created`. Holds. |
| `events.subscribe` is all-or-nothing | A valid global entry plus a pane-scoped entry on `wF:p999`: `{"id":"sub32:sub:1:probe","error":{"code":"pane_not_found"}}`, then EOF. Holds, id shape unchanged. |
| `pane_output_changed` not subscribable | `pane.output_changed` is an unknown variant; the schema's 27 `Subscription` kinds omit it. Holds. |
| Reads | `pane.read recent lines:2000` after 1500 echoed lines: 1000 lines, `truncated: true`, `revision: 0`, text at `result.read.text`; default `recent` is 80 lines. Holds. |
| Alternate-screen agent leaves no herdr scrollback | Idle claude pane: `max_offset_from_bottom: 0`, `agent.read`/`pane.read` 400 lines return the 20-row viewport. Holds. |
| `events.wait` | `match` → `missing field match_event`; a `workspace_created` match → `unsupported_event_wait_match` ("currently supports pane agent status matches"). Holds. |
| Key parsing | `ctrl-c` → `invalid_key`; `ctrl+c`, `C-c`, `CTRL+C`, `Enter`, `esc` accepted. Holds. |
| `agent.rename` rules | `Bad`, `1abc`, 33 chars → `invalid_agent_name`; `ok_name-1`, 32 chars → ok; `name: null` and omitted both clear the name. Holds. **New:** while the launch is pending, a valid name is refused with `agent_launch_pending`. |
| `workspace.rename` accepts any label | Empty and 500-char labels accepted; each fires `workspace_renamed` carrying the label. Holds. |
| `agent.start` is asynchronous | Returns `launch_pending: true` at once. **New detail:** it stays `true` while claude is on the trust dialog (status `blocked`); after launch `agent.get` omits the key (it also gains `interactive_ready`). |
| Status push | `pane_agent_detected`, then `pane.agent_status_changed` (`blocked`) within 12 s of start. Event naming is still mixed (underscore vs dotted). |
| `agent attach` resolves agents only | `herdr agent attach wF:p1` (a shell pane): `agent_not_found`, id `cli:agent:attach:resolve`. Holds. |
| `terminal attach <terminal_id>` | Resolves the root pane's terminal id and enters the client; under `script` with no window size it exits on "terminal reported a zero-sized grid". Command and targeting hold; takeover not re-tested. |
| Trust dialog in an untrusted cwd | Reproduced: the scratch-cwd agent stayed `blocked` with `launch_pending: true`. |

**New on 0.9.1, not in the schema:** the server's request parser lists `pane.graphics.stream` (and the exported schema does not). Not exercised.

**Not re-tested:** `agent.prompt` and its `wait.until`, `agent_not_idle` on a working agent (both need a prompted agent), `pane.updated` noise rate, named-session sockets, multi-client sizing and takeover.

## notifications.json

Four entries, not the two expected: each device (told apart by a hash of its Notification Key) has one `sandbox` entry with today's `foreground_until` (the Xcode-signed builds from `make test-device`) and one `production` entry last leased 2026-09-16 (TestFlight build 5). The production pair predates round 29's replace-on-re-register (`dfe80220`), whose record of "the token this install last registered" build 5 never wrote, so the Xcode build could not drop them; the plugin's `BadDeviceToken` prune has not retired them either, so APNs has not rejected them in a week. Open item 51. Also 15 orphaned `notifications.json.tmp-<uuid>` files (app-side SFTP writes, 2026-09-16 and 17, none since): Open item 52.
