# Kelpie round 5A — terminal-side fixes (drop, keys, bell, resize, mouse drag)

Project: /Users/anthonytopalides/Developer/Kelpie, branch `kelpie`, clean tree at `0df2239`. Swift 6 strict concurrency, no force unwraps / `try!` outside tests, iOS 18+. Read the Kelpie section of `CLAUDE.md` first. **Never edit `Packages/GhosttyTerminal`**; override its `open` members from `HeelerTerminalView`.

**File ownership (another builder works in parallel — stay inside yours):** you own `Sources/Heeler/Terminal/**`, `Sources/Heeler/Client/MediaIntake.swift`, `Sources/Heeler/Client/HerdrMediaStagingStore.swift`, `Tests/HeelerTests/TerminalHardwareKeyMappingTests.swift`, `Tests/HeelerTests/MediaIntakeTests.swift`, `Tests/HeelerTests/TerminalMouseReportingTests.swift`. Do **not** touch `HerdrClientView.swift`, `HerdrClientRootView.swift`, `HerdrClientStore.swift`, `project.yml`, `Heeler.xcodeproj`, `Sources/Heeler/Settings/`, `Sources/Heeler/Notifications/`, `Sources/Heeler/Transport/`, `Packages/`, `KelpieVault/`, docs. Do **not** run `xcodegen` and do **not** add new files (put new code in files you own). For `CHANGELOG.md`, append your lines at the **end** of the `[Unreleased]` → `### Fixed` section only.

## 1. Drag and drop from Files does nothing (bug, observed on the device)

Dropping a file from the Files app onto the terminal: the item animates away and nothing is staged; pasting the same file works. `UIDropInteraction`'s item providers are only guaranteed valid while the drop session is alive, and today `performDrop` hands the providers to `onStageItems`, which starts a `Task` whose `MediaIntake.loadItems` issues `loadFileRepresentation` only after the first suspension, i.e. after `performDrop` has returned. Fix: start every provider load **synchronously inside `performDrop`** (and in `paste(itemProviders:)`). Restructure `MediaIntake.loadItems` into a synchronous `beginLoading(_ providers:) -> Task<[MediaIntakeItem], Never>` (or an equivalent) that calls `loadDataRepresentation`/`loadFileRepresentation` for every provider before returning and gathers their results with continuations; keep the async result shape the store consumes. Prefer `session.loadObjects`/`itemProvider.loadFileRepresentation(for:)` on the session's items where that is simpler. Also handle `hasItemsConforming(toTypeIdentifiers:)` including `UTType.data`/`.content` so PDFs, text files and archives from Files qualify (a PDF conforms to `public.data`, not `public.file-url`); keep text drops ignored only when the item is *purely* text (`public.plain-text` with no file representation). Update `MediaIntakeTests` for any signature change and add a classify case for `com.adobe.pdf` → `.file` and `public.plain-text` alone → `.text`.

## 2. Keys the Magic Keyboard lacks: Fn+arrows as Home/End/PageUp/PageDown

Extend `TerminalHardwareKeyMapping` with rows for the HID usages iPadOS delivers for **Fn+Left/Right/Up/Down** — on iPadOS these arrive as `UIKeyboardHIDUsage.keyboardHome` (0x4A), `.keyboardEnd` (0x4D), `.keyboardPageUp` (0x4B), `.keyboardPageDown` (0x4E), which Ghostty's own table already encodes; **do not intercept those**. Add instead the fallback where the OS does *not* translate: arrow usages (0x50–0x52, 0x4F) with **Command** (⌘←/⌘→ = Home/End, ⌘↑/⌘↓ = PageUp/PageDown — the macOS Terminal convention) → `1B 5B 48` / `1B 5B 46` / `1B 5B 35 7E` / `1B 5B 36 7E`. Shift+⌘+arrow → nil (leave for Ghostty). Table rows plus tests in `TerminalHardwareKeyMappingTests`. Note in the doc comment that under the Kitty protocol these legacy forms are still accepted by herdr (verified for ESC in round 3).

## 3. Terminal bell → haptic

The vendored view exposes `TerminalSurfaceBellDelegate.terminalDidRingBell()` (`Packages/GhosttyTerminal/Sources/GhosttyTerminal/Surface/TerminalSurfaceViewDelegate.swift:36`, routed through `TerminalViewState+Delegate.swift`). Find how `HeelerTerminalView` (or the app's `TerminalController`) receives view-state delegate callbacks today and adopt the bell: a `UIImpactFeedbackGenerator(style: .light)` impact, throttled to at most one per 300 ms. If the delegate cannot be reached without editing the package, say so in the report and skip.

## 4. Coalesce resize reports during a live window drag

`onSizeChanged` (`TerminalScreenView.swift`, grep `onSizeChanged`, `isSizeReportCurrent`, around lines 340/452/948) fires one PTY resize per layout pass; a Split View divider drag sends dozens, each a serialized SSH round trip. Add trailing-edge coalescing in the UIKit view: report the **first** size change immediately, then while further changes arrive within 80 ms report only the **last** one after 80 ms of quiet (a cancellable `Task` or `DispatchWorkItem`). Keyboard-driven size changes go through the existing freeze/thaw machinery; do not disturb it — apply the coalescing only on the path a bounds change takes. Keep `isSizeReportCurrent` semantics intact.

## 5. Mouse drag for herdr's pane-border resize and sidebar drags

`Sources/Heeler/Terminal/TerminalMouseReporting.swift` encodes SGR click and wheel reports. herdr is "mouse-first": dragging a pane border resizes it, which needs **motion reports while the button is held** (`?1002h` button-event tracking, SGR `CSI < 32 ; x ; y M` for left-drag) and the release. Check the mode tracker for which tracking modes herdr enables (round-2 notes: `?1000/1002/1003/1006h`). If button-event tracking is on and the trackpad press-and-drag currently emits only press/release (or nothing), add motion reporting: on pointer drag with the primary button held, emit one SGR motion report per **cell** change (not per point), then the release at the final cell. Wire it into the existing pointer/gesture handling in `TerminalScreenView.swift` (ADR 0016 describes the pointer decisions — read it first; do not break the right-click, long-press and two-finger selection paths). Unit-test the encoder rows in `TerminalMouseReportingTests`.

## 6. Build and return

Build for the device in the background, log to a file, read only the tail:
```
S=/private/tmp/claude-501/-Users-anthonytopalides-Developer-Kelpie/2beb8609-5f8f-488c-8847-4514dad12a4b/scratchpad/build-5a
mkdir -p $S
xcodebuild build -project Heeler.xcodeproj -scheme Heeler -configuration Release \
  -destination 'platform=iOS,id=09D7738D-2173-55EF-8966-A9C3EA1D0514' \
  -clonedSourcePackagesDirPath $S/kelpie-spm -derivedDataPath $S/kelpie-dd -allowProvisioningUpdates \
  > $S/build.log 2>&1
```
Never the simulator. Fix any error in your files. Do NOT install and do NOT commit. Write `report.md` in your folder as you go. Return at most 300 words: per item what changed (paths), the build tail line, anything skipped and why.
