# Round 15 builder report (opus-builder, 2026-09-15)

Returned by the worker; it did not write its own report file. Build logs stayed in the session scratchpad.

**Files changed**: `Sources/Heeler/Terminal/TerminalKeyBar.swift` (180 +/-), `Sources/Heeler/Terminal/TerminalKeyboard.swift` (8 +/-), `Tests/HeelerTests/TerminalKeysKeyboardTests.swift` (10 +/-).

**Built**: `TerminalControlKey.shiftTab` (⇧Tab, "Shift Tab", non-repeating, `1B 5B 5A` in both cursor modes), kept out of `rows`; all exhaustive switches updated. Key bar gained a `⇧tab` key after `tab` and a pinned `keyboard.chevron.compact.down` button outside the scroll view behind a 1 pt `.separator` hairline at 60% key height, wired through the new `keyBarDidRequestDismiss(_:)` → `_ = dismissKeyboard()`. Restyle: `TerminalKeyBarButton` replaced by `TerminalKeyBarPillView` (capsule radius = height/2, shadow 0.12/(0,1)/3 with explicit path, 12 pt margins, height = key height + 8, `systemBackground` / `UIColor(white: 0.30)`); keys are plain `.label` glyphs, sticky state tints and underlines the caption instead of the cap; `endGroup`/`groupSpacing` gone; paste control `.capsule` + clear background; stack `.equalSpacing` with a `.defaultLow` width tie to the scroll view's frame layout guide. 44 pt minimums and the Dynamic Type path intact (pill and divider heights now update in `applyTextSizeMetrics()`).

**Choices beyond spec**: scroll inset is a flat `pillPadding/2`; divider sits 6 pt left of the dismiss button, which is 8 pt from the pill edge.

**Build**: `BUILD SUCCEEDED` on `generic/platform=iOS` (the iPad destination refused while the device was locked). The manager installed that product on both devices.

**Flagged, fixed by the manager**: `terminalControlKeyboardContainsOnlyUsefulMobileKeys` in `TerminalAttachTests.swift` asserted `rows` covers every case; it now excludes `.shiftTab`. `build-for-testing` on the iPad destination then succeeded.
