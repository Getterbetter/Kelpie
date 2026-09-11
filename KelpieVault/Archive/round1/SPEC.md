---
source: "delegate-20260910-191536/ipad/SPEC.md — round 1 build spec, 2026-09-10 20:47"
---

# Kelpie iPad spec (v1)

Kelpie = private fork of Heeler (SwiftUI + libssh2 + libghostty iOS client for herdr) at /Users/anthonytopalides/Developer/Kelpie, branch `kelpie`.
Already done by a previous worker: rebrand (bundle TME.Kelpie, team 8JQWBQKEXX, display name Kelpie, module name still `Heeler`), TARGETED_DEVICE_FAMILY 1,2, UIApplicationSupportsIndirectInputEvents=YES, xcodegen regenerate, iPad-simulator build.
Do NOT touch: Packages/, plugin/, relay/, landing/, project.yml (except if a new Swift file needs no registration since sources are folder-based), any bundle id / signing / push code.

Reference reading (read these before writing code):
- Input map with file:line anchors: ../inputmap/inputmap.md (same scratchpad tree as this file)
- Ghostty package source pinned at the exact revision the app uses: ../ghostty-spm/Sources/GhosttyTerminal/Platform/UIKit/ (UITerminalView.swift, UITerminalView+Interaction.swift). It is an SPM dependency: you cannot edit it, only override its `open` members from `HeelerTerminalView`.
- herdr context-menu behaviour (verified in herdr source src/client/shell/mouse.rs): the menu opens on an SGR right-button PRESS at a cell (`ESC [ < 2 ; col ; row M`) followed by release (`... m`); menu rows are activated by a left-button press on the row. herdr enables DECSET 1000/1006 (SGR) and keeps its own scrollback.

Key facts already established about how input flows today (Sources/Heeler/Terminal/TerminalScreenView.swift, class HeelerTerminalView: UITerminalView):
- Direct touch: Heeler's own pan (touchScrollGesture, allowedTouchTypes .direct) -> scrollTouch(translationY:) -> local scrollback OR remote wheel reports via TerminalModeTracker.remoteScrollSequence when the remote enabled mouse tracking. Heeler's own tap -> tapAction(at:) -> remoteClickSequence (left press+release) when tracking, else keyboard raise.
- Indirect pointer (trackpad/mouse): handled entirely inside Ghostty's UITerminalView.handleIndirectPointerTouches. LEFT: press/release sent to surface (libghostty encodes mouse reports and emits them through the session write callback -> Heeler's onSend -> SSH). RIGHT: on .began Ghostty does NOT send the press; it stores `selectionMenuPoint(at:)`; on .ended, if that was non-nil it calls showSelectionCopyMenu (an iPadOS edit menu) and returns WITHOUT telling the terminal; otherwise it sends right PRESS then RELEASE to the surface. Ghostty also attaches a UIContextMenuInteraction whose configurationForMenuAtLocation returns nil unless selectionMenuPoint(at:) is non-nil. Both `selectionMenuPoint(at:)` and `contextMenuInteraction(_:configurationForMenuAtLocation:)` are `open`.
- Trackpad/mouse SCROLL on iPad: no path at all. Ghostty only installs a scroll-type pan under macCatalyst (allowedScrollTypesMask). On iOS its pan is direct-touch only. So two-finger trackpad scroll and mouse wheel currently do nothing on iPad.
- Long press: Ghostty's own UILongPressGestureRecognizer (direct, 0.5s) fires terminalDidRequestTextSelection on the delegate (Heeler implements it at TerminalScreenView.swift ~1787, presenting TerminalTextSelectionPresenter). gestureRecognizerShouldBegin on UITerminalView gates it on activeTextSelectionDelegate; HeelerTerminalView overrides gestureRecognizerShouldBegin at ~1296.
- Hardware keyboard: Ghostty handles it (pressesBegan -> TerminalHardwareKeyRouter); Heeler only intercepts Cmd+/Cmd- for zoom and forwards the rest.
- Layout: ConsoleView.swift:56 uses NavigationSplitView; AgentTerminalView.swift:144 is the terminal screen; horizontalSizeClass already used at AgentTerminalView.swift:953 and AgentDirectInputChrome.swift:85.

## Deliverables (all in Sources/Heeler, plus tests in Tests/)

### 1. Right-click reaches herdr (trackpad and mouse)
In HeelerTerminalView:
a. Override `selectionMenuPoint(at:)` to return nil whenever the remote application is tracking the mouse (TerminalModeTracker.tracksMouse is true, i.e. herdr or another TUI owns the mouse). Otherwise call super. Effect: Ghostty forwards the right press+release to libghostty, which reports it to herdr; the iPadOS copy menu never appears while herdr owns the mouse.
b. Override `contextMenuInteraction(_:configurationForMenuAtLocation:)` to return nil under the same condition (defensive; it already routes through selectionMenuPoint, but make it explicit), else super.
c. Confirm (by reading Ghostty source) that a right press/release sent via surface.sendMouseButton is emitted as SGR bytes through the same write callback Heeler bridges (TerminalSessionCallbackBridge.send / onSend). Write one sentence in your notes about where in the SPM package or libghostty that happens. If you find libghostty does NOT emit mouse reports for in-memory sessions, fall back to: in the indirect-pointer path, intercept right-button `touchesEnded` in HeelerTerminalView (event.buttonMask.contains(.secondary), touch.type == .indirectPointer), send TerminalModeTracker's right-click sequence yourself, and do not call super for that touch.

### 2. Touch long-press = herdr right-click
a. Add `case right = 2` to TerminalMouseEncoding.Button (TerminalMouseReporting.swift) and `func remoteRightClickSequence(column:row:) -> Data?` on TerminalModeTracker mirroring remoteClickSequence (press then release, both encodings, nil when !tracksMouse).
b. Add a UILongPressGestureRecognizer on HeelerTerminalView (direct touches, 1 touch, 0.5s, allowableMovement 10) that, when tracksMouse: maps the point to a cell with TerminalGridPointMapper (same as clickTouch/tapAction), sends remoteRightClickSequence through the same path clickTouch uses, gives a medium haptic, and marks the gesture as handled. When !tracksMouse it must not fire (gestureRecognizerShouldBegin returns false for it), so plain-shell long-press keeps Ghostty's text selection.
c. In the existing gestureRecognizerShouldBegin override, when tracksMouse return false for Ghostty's UILongPressGestureRecognizer (any long-press recogniser that is not ours) so the selection sheet does not also pop.
d. Text selection while herdr owns the mouse: add a two-finger long press (numberOfTouchesRequired 2, direct) that reads `session.readViewportText()` (see how Ghostty's handleLongPressForSelection does it; `configuration.backend` is `.inMemory(session)`) and calls the same `terminalDidRequestTextSelection` path with anchorRange nil and sourcePoint at the gesture location. If readViewportText is not reachable from the subclass, say so in notes and skip this sub-item rather than hack around it.

### 3. Trackpad / mouse-wheel scrolling on iPad
Add a UIPanGestureRecognizer on HeelerTerminalView for scroll events: allowedScrollTypesMask = [.continuous, .discrete], allowedTouchTypes = [.indirectPointer], cancelsTouchesInView false, delaysTouchesBegan false, delegate allowing simultaneous recognition. In the handler ignore any event with numberOfTouches > 0 (that is a pointer drag, which Ghostty's own indirect-pointer pan owns for selection). On .changed take translation, reset it to zero, and feed `scrollTouch(translationY:)` exactly like the direct-touch pan does, so local scrollback vs remote wheel-report selection is reused. Use the same sign convention as the finger pan (natural scrolling: content follows the fingers). Handle .began by stopping momentum like Ghostty does if that helper is reachable, else skip. Wrap in `#if !targetEnvironment(macCatalyst)`.

### 4. iPad layout: terminal is the screen
- On regular horizontal size class, when an agent terminal (AgentTerminalView) or shell terminal is open, the terminal must fill the detail column edge to edge (no extra horizontal padding, background matching the terminal background under the safe areas). Check for any padding/inset around TerminalScreenView in AgentTerminalView / ShellTerminalView and remove it for regular width only.
- Default the NavigationSplitView columnVisibility to `.detailOnly` while a terminal is open on regular width, and `.automatic` otherwise, so herdr is full-bleed and the agent list is one toolbar tap away (the standard sidebar toggle). Keep iPhone behaviour identical.
- Ensure the terminal's onSizeChanged resize fires when the sidebar is shown/hidden and on rotation (it should already via Ghostty's viewport callback; verify by reading, note the anchor).
- Keyboard accessory / control pad: on regular width, if it is fixed to a phone-width layout, let it stretch (single row, buttons spread). Only change if it currently looks wrong at 1180pt width; describe in notes.

### 5. Hardware keyboard sanity (read-only unless broken)
Read Ghostty's UITerminalView+Keyboard.swift and Heeler's pressesBegan override. Confirm Ctrl+B (herdr prefix), arrows, Esc, Tab reach the PTY on a hardware keyboard, and that Cmd+C/Cmd+V map to copy/paste. Only fix if something in Heeler's override swallows a key. Note findings.

### 6. Tests
Add unit tests (same test target and style as existing Tests/) for: Button.right raw value 2; remoteRightClickSequence SGR bytes `ESC[<2;C;RM` + `ESC[<2;C;Rm`; legacy encoding for the right button; nil when mouse tracking is off. Run the existing unit test scheme on the iPad simulator ('platform=iOS Simulator,name=iPad Pro 11-inch (M5)'); tee output to your scratch folder and only read the tail. Build the app for the iPad simulator the same way. All tests pass and the build is clean before you finish.

### 7. Housekeeping
- CHANGELOG.md: one "Kelpie" section at the top listing the iPad changes in the file's existing style.
- docs/adr: add 0016-ipad-pointer-input.md (short: decision, the Ghostty override points, why long-press maps to right-click when the remote tracks the mouse).
- Commit on branch `kelpie` in logical commits. End every commit message with:
Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01UCKuKzzfLucRJEGyMbdvrR
- Never push, never add a remote.

Swift 6 strict concurrency is on; keep new code @MainActor where the surrounding code is. Match the existing code style and comment voice. Concise code, no speculative options or feature flags.

## Build recipe that works on this Mac (use exactly this; the plain `xcodebuild` without these flags can hang on package resolution)
cd /Users/anthonytopalides/Developer/Kelpie
xcodebuild build -project Heeler.xcodeproj -scheme Heeler -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)' -configuration Debug -clonedSourcePackagesDirPath /private/tmp/claude-501/-Users-anthonytopalides-Developer/92b1adb6-9c52-4a55-9bde-f6a341d45ac6/scratchpad/kelpie-spm2 -derivedDataPath /private/tmp/claude-501/-Users-anthonytopalides-Developer/92b1adb6-9c52-4a55-9bde-f6a341d45ac6/scratchpad/kelpie-dd CODE_SIGNING_ALLOWED=NO 2>&1 | tee <your folder>/build.log | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
Same flags with `test` instead of `build` for the unit tests (add `-only-testing:HeelerTests` if the suite is slow). The GhosttyTerminal package is vendored under Packages/GhosttyTerminal (do not edit it; override from HeelerTerminalView). Baseline at commit HEAD of branch `kelpie` builds clean.
Never run `xcodegen generate` unless you add a new target; new Swift files under Sources/Heeler are picked up automatically only after regeneration, so if you add a file, run `xcodegen generate` and commit the regenerated Heeler.xcodeproj too.
