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
