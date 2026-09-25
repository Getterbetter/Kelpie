# Builder B — the transport and terminal group (Open item 55)

Letter: **B**. Read `spec-common.md` first; it governs worktree, build lock, paths and reporting.

Pick these from `upstream/main`, in this order:

1. `d0eb616a` fix: never autocorrect on any terminal input surface
2. `c6135ec5` fix(terminal): release a replaced surface's keyboard after the graph update
3. `2b5f4e6c` fix: composer waits out agent_not_ready on freshly created agents (upstream's Console composer, `AgentComposerStore`)
4. `c48346f1` fix: wait out the silent transport replacement before failing composer sends
5. `cd2972c1` fix: wait out the silent transport replacement before failing a send
6. `34d3af8a` fix: bound the dead-transport retry so timed-out sends surface their cause
7. `45fcfd7d` fix: wake the run loop for the dead-transport redial and accept retry re-authorization
8. `c18e8287` test(terminal): poll for the coalesced keyboard height

Read each against Kelpie before picking; these are the traps:

- **Autocorrect (d0eb616a).** Kelpie's root screen has its own composer (Open item 30): a `UITextView` riding the terminal's key bar whose whole point is autocorrect, predictions and dictation on the on-screen keyboard (`sendComposerBytes`, `TerminalComposer*`). It must keep autocorrect. What upstream's commit should do in Kelpie is make sure the **terminal's own** `UITextInput` never autocorrects (Kelpie tried that in round 18 and it corrected badly, so never-autocorrect there is right). If the pick would turn the composer field's autocorrect off, adapt it so it does not, and add or keep a test that pins the composer field's autocorrection on.
- **Replaced surface keyboard (c6135ec5).** Kelpie's `HerdrClientView` keeps a replaced Ghostty surface mounted on top until its replacement paints (a `ForEach` of mounted surfaces). Make sure releasing the old surface's keyboard does not fire while it is still the visible, first-responder surface in that overlap, or drop the pick if Kelpie's mount logic already hands first responder over; explain in the report.
- **Transport series (c48346f1..45fcfd7d) in `Sources/Heeler/Transport/EventsSession.swift`.** Kelpie changed this file heavily: `19277ce8` (a dead transport is abandoned instead of awaiting its close — the Tailscale hang, Open item 22), `90fc39a3` (TCP keepalive), `535f1ab0` (reconnecting state, bounded parked attach), `2542eef9`, and the terminal attach channel (`EventsSessionTerminalChannelTests`). Upstream's series adds a bounded wait for a silent transport replacement and a redial on a dead transport. Both must hold: Kelpie's abandon stays, and a send issued during a silent replacement waits for it instead of failing. Read `KelpieVault/Archive/round14/tailscale-hang-diagnosis.md` before resolving.
- 2b5f4e6c is Console-only (Kelpie hides the Console behind its menu but still ships it); pick it, since c48346f1 builds on the same composer store.

Checks: compile (`build-for-testing`, generic iOS), then on the iPad: `EventsSessionSubscriptionsTests`, `EventsSessionTerminalChannelTests`, `ConsoleStoreTests`, `AgentComposerStoreTests`, `AgentDirectInputTests`, `TerminalAttachTests`, `TerminalSurfaceRetentionTests`, `TerminalComposerMirrorTests`, `TerminalComposerControlTests`, `TerminalInputControllerTests`, `HerdrClientStoreTests`, plus whatever suites the picks add. The keyboard tests skip while the Magic Keyboard is docked; report which skipped.

If you reach about 70 tool calls with picks left, stop cleanly after the current pick, write the report with the exact next sha, and end.
