---
status: accepted
---

# herdr's own client is the screen; the Console is one tap behind it

Round 1 made the iPad's pointer, touch and scroll input reach herdr. Using it
answered a larger question: Heeler's native Console — the Agent list, the
per-Agent terminal, the Composer and the Agent switcher bar — is not what a
herdr user wants on an iPad with a keyboard. What they want is the screen their
Mac terminal shows: herdr's own TUI, with its workspaces sidebar, its tabs and
its panes, full screen, with the iPad simply making it seamless to interact
with.

So Kelpie's root is now `HerdrClientRootView`: a full-screen Attach running the
herdr **client** (`exec herdr`, or `exec herdr --session "<name>"` when the Host
names one) for one primary Host, persisted in `kelpie.primary-host` and healed
when that Host is deleted. A 36 pt `ellipsis.circle` sits over the empty right
end of herdr's tab strip and opens everything else.

## Why the Console is demoted, not removed

The Console is not decoration around the terminal — it is the part of the app
that is not a terminal at all. It owns push registration and per-Host
notification preferences, the Live Activity coordinator, the foreground banner,
Agent start/close/rename, image and file staging, and the notification router
that a tapped notification lands in. Deleting it would delete all of that;
rebuilding it inside herdr's TUI is not possible from an iPad at all.

It therefore stays whole, in a `fullScreenCover` behind the menu's "Agents"
item, and a notification deep link presents that cover by itself so routing
lands on the Agent exactly as it did before. Everything the Console needs alive
between visits — `ConsoleStore`, `HostLiveActivityCoordinator`,
`NotificationPreferencesStore`, `PushRegistrationStore` and the
`ConsoleActivityDriver` task — is created once by `HeelerAppModel` (upstream's
composition root since the Heeler v0.1.8 rebase of 2026-09-15; before that
`ContentView` created them) and read by `ContentView`, above the
cover, so lowering it changes nothing about push or Live Activities. An install
with no Hosts still gets the Console's own "No Hosts" onboarding as the root.

One Transport serves one Attach channel at a time, so the Client explicitly
ends its attach while the cover is up and reattaches when it comes down
(`HerdrClientStore.setPresented`). herdr keeps its own scrollback on the Host,
so a reattach loses nothing.

Every attach — Client, Agent and shell alike — now exports `COLORTERM=truecolor`
and a `LANG` default alongside the existing PATH and socket exports. A non-login
`ssh` exec inherits neither, and herdr needs truecolor for its palette and UTF-8
for its box drawing.

## Why link taps are intercepted client-side

herdr hit-tests URL clicks itself (`url_at_runtime_cell`) and opens the result
with `crate::platform::open_url` — `open` **on the Mac**. That is the wrong
machine: the person tapping is holding the iPad. A click must therefore never
reach herdr for a cell that holds a URL.

libghostty cannot answer that question on iOS. Its only link surface is the
pushed `GHOSTTY_ACTION_OPEN_URL` action, fired by a cmd-click the platform never
produces here, and `ghostty.h` has no "link at point" query. So
`TerminalLinkDetector` resolves the URL from the viewport text the selection
sheet already reads, including a URL wrapped onto the next row, and both the
direct tap and the indirect-pointer primary click open it through the same
`onOpenLink` seam SwiftUI's `openURL` is wired to. The pointer click is owned
for its whole touch sequence, as round 1's right click already is, and opens
only if it ended on the same URL it began on. `TerminalLinkPolicy` still gates
the result to `http`/`https`, because terminal output is untrusted.

## Why keyboard mode is automatic

The two Agent input modes each assume their input device. The Composer (ADR
0013) is a text field to type into because a touch keyboard needs one; Direct
Input (ADR 0016) routes the keyboard straight into the PTY, which is what a
hardware keyboard should do and is useless without one. Asking the user to
track that in Settings produced exactly the two bugs reported from round 1: a
Composer centred on screen with no keyboard under it, and Direct Input with
nothing holding first responder.

`HardwareKeyboardObserver` publishes `GCKeyboard.coalesced`, live — UIKit only
ever reports the *software* keyboard's frame, which is zero whether a hardware
keyboard is attached or nothing has focus, so GameController is the only honest
answer. Agent input takes a new `automatic` preference as its default, resolving
to Direct Input with a keyboard and the Composer without; either explicit choice
still wins and still persists, and Settings offers all three. The Client screen
reads the same observer: with a keyboard it takes first responder on appear and
shows no control pad, without one it shows the shell terminal's pad above the
software keyboard.

## Amendment (round 12): what the Client reads live, and what it draws

Three gaps in the original implementation, all of the same shape — state the
screen held but never revalidated, and states the screen could reach but never
drew.

**The Host is read live, not captured.** `HerdrClientHostView` is identified by
`host.id`, and `Host.id` survives `HostStore.update`, so editing a Host does
not rebuild the store. Everything the attach needs is therefore late-bound:
`ConsoleStore.terminalRunner(for:)` already resolved the Host's live projection
on every call, and the herdr session name — the one field the store had
captured — now arrives through `HerdrClientStore.hostDidChange(sessionName:)`
from an `onChange` on the live `Host`. On stage that replaces the pipeline at
once; off stage the new name is simply what the next `adoptReplacement` builds
with. Trimming lives in the store, so an emptied field means bare `herdr`.

**Every state the store can be in has a visible representation.**
`HerdrClientStore.statusPresentation` is the single mapping the screen draws
from:

| Store state | Overlay |
|---|---|
| active, on stage, waiting for size / connecting / replacing / stopped | "Connecting…", progress, no dim |
| active, on stage, live | none |
| active, on stage, ended | "Session Ended" + Reconnect |
| left, off stage (the Console cover is up) | none — the cover draws its own screen |
| left, still on stage (an `onDisappear` with no balancing `onAppear`) | "Disconnected" + Reconnect |
| rejoin required (a replacement abandoned off stage) | "Disconnected" + Reconnect |

The last two are what `needsRejoin` names, and `reconnect()` now handles them
by rejoining rather than guarding itself into a no-op. Before this they fell
through `.stopped` to no overlay at all: a frozen last frame with no spinner,
no message and no Reconnect, recoverable only by a background round trip.

**The Console hand-off is bounded and visible.** A Transport serves one Attach
channel at a time, so `prepareForConsole()` still ends the Client's attach
before the cover comes up — but against a deadline
(`HerdrClientCommands.consoleHandoffTimeout`, 4 s). While it is in flight the
menu chip shows a spinner in place of its glyph. On expiry the cover is
presented anyway — the Console is the only route to Agents, and an Agent Attach
that is refused surfaces `terminalChannelAlreadyOpen` properly — with a one-line
notice over it carrying a Retry.

That notice strip is also where an unreadable notification tap lands.
`AgentNotificationRouter.open(nil)` expresses "no target" as `path = []`, which
on this root is not a change at all, so such a tap did nothing;
`HerdrClientNoticeStore` is the separate "a tap happened" signal, and the root
presents the Console on it.

**The menu chip keeps its size and gains a 44 pt target.** It is the only route
to Hosts, Agents, Settings, Setup Guide, Reconnect and every attach command,
it is about 28 pt tall on its own, and on a phone it sits in the bottom corner
over herdr's mobile surface — where a miss is forwarded to the PTY as a click.
The capsule is unchanged; a `frame(minWidth: 44, minHeight: 44)` plus a
rectangular `contentShape` swallows the margin, and the pointer highlight keeps
the capsule's own shape.
