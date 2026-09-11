# iPad vs Mac gap map for Kelpie's herdr client screen

Sources: repo grep across `Sources/`, `Packages/GhosttyTerminal/`, `project.yml`, `KelpieVault/Open items.md`;
herdr 0.9.0 docs fetched live (`config-reference.json`, `persistence-remote.mdx`).

## 1. Clipboard OUT (herdr copy_on_select / copy_mode)
- Mac: `ui.copy_on_select` (default true) or `keys.copy_mode` (`prefix+[`) copies to the Mac clipboard, usually via the terminal emulator receiving an OSC 52 write from herdr.
- iPad today: Ghostty's own OSC 52 handling **is wired end-to-end to UIPasteboard** — `write_clipboard_cb` → `TerminalController+Callbacks.swift:59-76` (`writeClipboard`) sets `UIPasteboard.general.string = string` on iOS. So if herdr writes real OSC 52 bytes down the PTY, they should already land on the iPad clipboard.
- Caveat found in herdr's own docs (`persistence-remote.mdx`): "If you SSH into the server first and run herdr there, Herdr runs entirely on the server and cannot access your local desktop clipboard beyond normal terminal text paste" — this is exactly Kelpie's `exec herdr` path, and it's unclear whether that line describes copy-out (OSC52) too or only the image-paste bridge; not resolved by grep alone, needs an on-device check (select text in herdr, see if it lands on iPad pasteboard).
- Fix idea: verify empirically on device; if OSC52 doesn't fire in the SSH-exec path, no app fix is possible (herdr-side), only a doc note. Effort: S (verification only).

## 2. OSC 9/777 desktop notifications dropped (new finding, not in the brief's list explicitly)
- Mac: `ui.toast.delivery = "terminal"` makes herdr ask the outer terminal for a desktop notification (OSC 9 / OSC 777); a real terminal app shows a macOS notification.
- iPad today: Ghostty's vendored package defines `TerminalSurfaceDesktopNotificationDelegate` / `terminalDidRequestDesktopNotification(title:body:)` (`Packages/GhosttyTerminal/Sources/GhosttyTerminal/Surface/TerminalSurfaceViewDelegate.swift:144-148`) — but `grep -rn "desktopNotification\|didRequestNotification" Sources` found **no conformance anywhere in Sources/Heeler**. The signal is decoded by the vendored library and silently discarded.
- Why: nobody in the app adopts that delegate protocol.
- Fix idea: implement the delegate on the client's terminal host, post a local `UNNotificationRequest` (or a toast) when it fires. Effort: S.

## 3. herdr's own toast/sound (ui.toast, ui.sound) and Kelpie's push relay
- Mac: in-app toasts and mp3 sounds render on the Mac itself, independent of any terminal.
- iPad: no path at all — these are herdr-process-local UI, invisible over any transport. Separately, Kelpie's own Agent Notification push path is explicitly non-functional: `KelpieVault/Open items.md:14,44` — "Push notifications do not work in Kelpie until item 4 is done" (deploying the `relay/` Cloudflare Worker). Gap stated plainly, not fixable via terminal.
- Fix idea: deploy `relay/`; unrelated to the terminal itself. Effort: M (already scoped, outward-facing, needs Anthony's sign-off).

## 4. Kitty/iTerm2 inline images (`terminal.kitty_graphics`)
- Mac: `terminal.kitty_graphics` (default true) renders pane images (agent screenshots, plots) inline via Kitty graphics protocol; herdr's `pane.graphics.*` API backs it.
- iPad: grep for `kitty.?graphic|sixel|iterm2|inline.?image|graphics_command` across all of `Packages/GhosttyTerminal/Sources` found no graphics-protocol implementation — only iTerm2 **color theme** name matches (`Themes_I.swift`), which are unrelated. Not implemented, confirmed by absence.
- Why: vendored libghostty-spm build presumably doesn't include (or Kelpie hasn't wired) the graphics escape-sequence path.
- Fix idea: check whether libghostty itself supports the protocol before assuming app-side work; if not, this is an upstream Ghostty limitation. Effort: L (unknown scope, possibly not fixable client-side at all).

## 5. Mouse: drag-resize, scroll-wheel in non-terminal chrome, middle click
- Mac: herdr is mouse-first — drag pane borders to resize, wheel-scroll the sidebar, middle-click paste, click sidebar tabs.
- iPad: `Sources/Heeler/Terminal/TerminalMouseReporting.swift` only encodes cell-level mouse *reports into the PTY* (legacy/SGR click + wheel) for whatever the remote TUI enables — it has no concept of a specific held-button drag or a sidebar outside the grid. `docs/adr/0016-ipad-pointer-input.md` documents which pointer/trackpad decisions were made; no mention of drag-hold-and-move or middle-click three-finger equivalents found via the same file.
- Fix idea: verify herdr sidebar/pane-border drag actually needs a `1;M` press+move+release sequence and check `TerminalTouchScroll.swift`/pointer code sends that on a trackpad click-drag; add if missing. Effort: M.

## 6. Files/links beyond `open <url>`
- Mac: `open <file>` opens PDFs/images in Preview/Quick Look.
- iPad: grep for `QLPreviewController|NSFileProviderExtension|UIActivityViewController|ShareLink` across `Sources` returned **nothing** — not implemented. Only URL taps are intercepted (`TerminalLinkDetector`, per CLAUDE.md); no file-open, no Quick Look, no share-out path exists for agent-produced files.
- Fix idea: SFTP-read the path when a pane or agent references a local file, present via `QLPreviewController`. Effort: M.

## 7. Multi-window / Stage Manager
- `project.yml` sets `INFOPLIST_KEY_UIApplicationSceneManifest_Generation: YES` but grep found **no** `UIApplicationSupportsMultipleScenes` key — Xcode's auto-generated manifest defaults this off, so no second herdr window/Stage Manager instance.
- Fix idea: add the key + a scene delegate for a second `HerdrClientRootView`. Effort: M/L (state sharing across scenes needed).

## What already works better than expected
- Background/resume is handled deliberately, not missing: `Sources/Heeler/Client/HerdrClientStore.swift:114-133` (`didBecomeActive(afterPossibleSuspension:)`) drives `rejoin()`/`replaceTerminal()`/`activationRecovery` on wake.
- Autocorrect/smart quotes/smart dashes are already disabled for the terminal surface: `Sources/Heeler/Terminal/TerminalScreenView.swift:685,700,705`.
- Ghostty's OSC 52 clipboard write callback is fully wired to `UIPasteboard` (`TerminalController+Callbacks.swift:59-76`) — clipboard-out may already work better than assumed; needs on-device confirmation, not further coding.
- Bracketed paste is threaded through many layers already (`TerminalInputController.swift`, `TerminalScreenView.swift`, `HerdrClientStore.swift`) — text paste is solid.

Not verified due to scope/budget: items 8 (Nerd Font glyph coverage on device), 10 (dictation, IME/CJK, emoji picker), 12 (BEL/haptics) — no code found either way beyond what's cited; recommend on-device spot checks rather than further grep.

Full detail: /private/tmp/claude-501/-Users-anthonytopalides-Developer-Kelpie/2beb8609-5f8f-488c-8847-4514dad12a4b/scratchpad/delegate-20260911/scout-gap/gap.md
