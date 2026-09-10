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
`ConsoleActivityDriver` task — is created and driven in `ContentView`, above the
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
