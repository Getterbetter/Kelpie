---
status: accepted
---

# iPad pointer input reaches herdr through Ghostty's open seams

Kelpie ships for iPad, where a trackpad, a mouse and a hardware keyboard are
ordinary. herdr's TUI enables mouse tracking (DECSET 1000/1002/1003 plus 1006),
so it wants right clicks — its context menu opens on a right-button press at a
cell and a row is chosen with the next left click. Three input paths were
missing on iPad, and all three are fixed from `HeelerTerminalView` alone: the
`GhosttyTerminal` package is a pinned dependency and is never edited.

## Right click from a trackpad or mouse

Ghostty's `handleIndirectPointerTouches` holds the right press back on `.began`
and stores `selectionMenuPoint(at:)`; on `.ended` a stored point shows the
iPadOS copy menu instead of telling the terminal anything, and only a nil point
sends the press and release on to libghostty — which encodes the SGR report and
emits it through the same session write callback Kelpie already bridges to SSH.

`HeelerTerminalView` therefore overrides `selectionMenuPoint(at:)` to return nil
while `TerminalModeTracker.tracksMouse`, and `contextMenuInteraction(_:
configurationForMenuAtLocation:)` to match. The copy menu stays available in a
plain shell, where nothing remote wants the click.

Those overrides are a second line of defence rather than the mechanism: Ghostty
also stores a menu point when the press lands inside a stale pointer
drag-selection rect, and it checks that before asking `selectionMenuPoint(at:)`
at all. So while the remote owns the mouse, `HeelerTerminalView` takes the whole
right-button pointer touch sequence in `touchesBegan`/`Ended`/`Cancelled`,
reports the click itself on release, and forwards none of those touches —
leaving Ghostty's own pointer state untouched.

## Long press is the touch spelling of a right click

A finger produces no mouse event at all — Ghostty's UIKit layer converts
indirect pointers only, which is why `TerminalMouseReporting` encodes touch
reports itself. So a one-finger long press sends
`TerminalModeTracker.remoteRightClickSequence` (button 2, press then release)
for the cell under the finger, with a medium haptic, and suppresses the tap that
release would otherwise produce — herdr would read that tap as picking a menu
row.

The alternative, some new on-screen affordance, was rejected: a hold is what a
right click already means on iPadOS, and herdr's own menu is the destination.

The trade is Ghostty's long-press text selection, which uses the same gesture.
While a remote application owns the mouse that recognizer is refused and two
fingers ask for the selection sheet instead; in a plain shell the one-finger
hold still selects, exactly as before, and the two-finger gesture stands down so
the sheet cannot be presented twice.

### Amended 2026-09-11: hold, then drag, is a left-button drag

herdr is mouse-first — its sidebar edge and pane borders resize by dragging —
and a one-finger drag is already scrolling. So the hold gained a second
outcome: a finger that moves past a slop (a cell height, above the
recognizer's own 10 pt allowance) after the hold registers sends a left-button
press at the origin cell, one SGR motion report per cell crossed with the
button held, and a release where the finger lifts. A finger that never moves
sends the right click as before, now on release rather than on hold. The
signal that the hold has registered is visual — a translucent ring under the
finger that follows it — because iPads have no Taptic Engine and the haptic is
silent on them.

Touch text selection no longer uses Ghostty's selection at all: a double tap
(or the two-finger hold) selects the word under the finger in a Kelpie-drawn
overlay with iPadOS-style handles, copied from the viewport text. Ghostty's
selection machinery is internal to the vendored package and is forwarded to
the PTY under mouse tracking, so it could not have been extended.

## Trackpad scrolling

Ghostty installs a scroll-type pan under macCatalyst only, so on iPadOS a
two-finger trackpad swipe and a wheel did nothing. A scroll-type
`UIPanGestureRecognizer` (indirect pointer, continuous and discrete) feeds
`scrollTouch(translationY:)` — the same entry point the finger pan uses, so
local scrollback and remote wheel reports keep one decision. Events carrying a
touch belong to Ghostty's own pointer pan (drag selection) and are ignored.

### Amended 2026-09-12: a Host path is not worth a tap

The tap policy above had one more claimant: `TerminalLinkDetector` resolves an
absolute or `~`-relative path with a file extension as well as a URL, and
`handleTap` opened both, swallowing the tap. That was wrong for paths in a way
it is not wrong for URLs. A URL genuinely has nowhere else to go — herdr would
open it on the Mac, which is not where the person tapping is — but a path is
ordinary agent output, dense in every build log and diff, and herdr's TUI wants
that tap: to place a cursor, to dismiss its own menu, to pick a row. Claiming
it sent nothing at all, with no way to say "no, I meant the click".

So the tap is herdr's. The file viewer moved to the selection: a double tap, or
a two-finger hold, already selects the whole whitespace-delimited run — the same
token the detector reads — and the edit menu carries **Open** beside Copy and
Select All when that selection is a path. A secondary affordance for a
secondary action, on gestures that already exist, and the URL tap is unchanged.

The matcher was tightened with it. Requiring the path to *exist* on the Host —
an SFTP stat — was considered and rejected: the offer has to be decided
synchronously while the menu is being built, and a network round trip per tap
buys accuracy the extension rule mostly already has. Instead the tapped cell
must land on the path's own characters, not on the bracket or quote wrapped
around it and not on the `:12:3` a compiler appended — the extension and the
leading `/` or `~/` were already required.

### Amended 2026-09-12: the text rewrite runs on the alternate screen too

`TerminalTextRewrite` takes characters back off the remote line with DEL before
typing the keyboard's replacement (the "." shortcut, autocorrection). Refusing to
do that while the remote application is on the alternate screen or tracking the
mouse was considered and **rejected**: the root screen is *always* both — herdr's
own client sets `?1049h` and mouse tracking the moment it attaches (see the
scrolling facts in `CLAUDE.md`) — so the gate would have made the fix inert
exactly where the bug was reported. The agent TUIs that matter inside it (claude,
codex, grok) draw a line-editing input box that reads DEL as Backspace.

The honest gates are the ones about the *line*, not the screen: marked text, a
hardware keyboard, non-printable replaced text, a range that is not a suffix of
the shadow, and — added the same day — a shadow caret that is not at the end of
the line. Nothing calls `selectionDidChange` when an arrow key moves the remote
caret, so UIKit can still offer a range ending at what it believes is the end of
the document; the shadow's own caret is what decides.
