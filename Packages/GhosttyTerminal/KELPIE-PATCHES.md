# Kelpie patches to this vendored package

This package is vendored (see the repo root `CLAUDE.md`) and is normally **not**
edited: Kelpie overrides its `open` members from `HeelerTerminalView` instead.
There is exactly one sanctioned exception, listed here. **A re-vendor must
reapply it.**

## 1. `Surface/TerminalSurface.swift` — public `sendMousePos(x:y:modifiers:)`

**What changed.** One added public wrapper next to the internal
`sendMousePos(x:y:mods:)`:

```swift
public func sendMousePos(x: Double, y: Double, modifiers: TerminalInputModifiers)
```

It forwards to the internal mods-carrying call. Nothing else in the file, and no
existing member's access level, changed. `TerminalInputModifiers` is already
public, so no libghostty C type is exposed.

**Why.** Kelpie resolves a tap on an OSC 8 hyperlink — Claude Code pins its
artifact links below the input bar as `ESC ] 8 ; ; <url> ESC \ title …`, so the
row holds a title and the URL exists only in libghostty's hyperlink table.
`ghostty.h` has no link-at-point query: the core hit-tests links wherever its
own mouse is put and reports what it found through
`GHOSTTY_ACTION_MOUSE_OVER_LINK`. It reports only when the mouse mods match the
link's modifier, and every mods-carrying entry point in this package
(`sendMousePos`, `sendMouseButton`, `sendKeyEvent`) was internal. The one `open`
member that moves the core's mouse — the context-menu hook in
`Platform/UIKit/UITerminalView+Interaction.swift` — hardcodes mods 0, and mods 0
was measured on the iPad to report nothing at all. See
`Sources/Heeler/Terminal/TerminalSurfaceLinkQuery.swift` and
`HeelerTerminalView.surfaceLinkURL(at:)`.

**Forgetting it fails loudly.** `HeelerTerminalView.surfaceLinkURL(at:)` calls
the member by name, so a re-vendor that drops the patch does not degrade
quietly — the app target stops compiling. `TerminalSurfaceLinkQueryTests`
asserts the resolution end to end against a live surface on the device, so a
libghostty that changes the hover contract fails there rather than in the field.
