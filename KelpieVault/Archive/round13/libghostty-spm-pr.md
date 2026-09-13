# NOT SENT — upstream already has the wrapper

Checked 2026-09-13 before opening: `Lakr233/libghostty-spm` `main` (`7e45d27`) has `public func sendMousePos(x:y:modifiers: TerminalInputModifiers = [])` since `eb4107b` (2026-09-02). A fork `Getterbetter/libghostty-spm` was created and nothing pushed. Kept for the record.

# Draft PR to Lakr233/libghostty-spm (awaiting Anthony's yes; nothing pushed)

**Branch:** `public-send-mouse-pos` on a fork under Anthony's GitHub account, one commit carrying the `TerminalSurface.swift` hunk from Kelpie's `8834b2a`.

**Title:** Expose a mods-carrying `sendMousePos` on `TerminalSurface`

**Body:**

libghostty hit-tests hyperlinks wherever the surface's mouse is placed and reports the result through `GHOSTTY_ACTION_MOUSE_OVER_LINK`, but only when the mouse modifiers match the link's modifier (Command on Apple platforms for `link-url`). A host app that wants to ask "which link covers this cell?" — for example to make an OSC 8 hyperlink with title text tappable on iOS, where there is no pointer hover and no Cmd-click — needs a mouse move that carries modifiers. `sendMousePos(x:y:mods:)` is internal today, and none of the `open` members reach it.

This adds one public wrapper, `sendMousePos(x:y:modifiers: TerminalInputModifiers)`, forwarding to the internal call. `TerminalInputModifiers` is already public, so no libghostty C type is exposed and no existing member changes access level.

Used in Kelpie (an iPad/iPhone client for herdr built on this package): a tap that the viewport text scan cannot resolve moves the core's mouse to the cell with the link modifier, reads the URL from the hover-link delegate, and opens it on the device. Verified on an iPad Pro against an OSC 8 link with title text and a bare URL. Note for anyone doing the same: while the application has mouse tracking on (`?1003h`), the core zeroes the mouse modifiers, and shift+super is what restores the link hit test; super alone works only on screens without tracking.

**Commands (after the yes):**
```
gh repo fork Lakr233/libghostty-spm --clone=false
git clone git@github.com:<anthony-account>/libghostty-spm.git /tmp/libghostty-spm && cd /tmp/libghostty-spm
git checkout -b public-send-mouse-pos
# apply the TerminalSurface.swift hunk from Kelpie 8834b2a
git commit -am "Expose a mods-carrying sendMousePos on TerminalSurface"
git push -u origin public-send-mouse-pos
gh pr create --repo Lakr233/libghostty-spm --title "..." --body-file <this body>
```
