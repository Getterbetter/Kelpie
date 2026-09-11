---
source: "delegate-20260910-191536/r2-build/notes.md — round 2 build notes, 2026-09-11 09:47"
---

# Kelpie round 2 — build notes

Branch `kelpie`, from 40c0682. Never pushed.

## Per spec item

### 1. HerdrClientView + HerdrClientStore (commit 454fee5)
- `TerminalAttachTarget.client(session: String?)`; `identifier` is the session name or
  "" (the Client names no remote object). `attachExecCommand` grew a per-target argument
  branch: `exec herdr` / `exec herdr --session "$1"`, never `--takeover`, with the empty
  positional argument still passed (`attach '' <socket>`) so `$2` stays the socket path.
  Command word is `SSHTransportSettings.defaultClientCommand` = `herdr`, so exit 127 still
  classifies as `herdrBinaryNotFound`.
- `export COLORTERM=truecolor; export LANG="${LANG:-en_US.UTF-8}";` added to the sh -c
  preamble for ALL targets, before the socket export and the handshake marker.
- `HerdrClientStore` mirrors `ShellTerminalStore`'s lower class (generation replacement,
  `TerminalRecoveryGenerationLatch`, `didBecomeActive(afterPossibleSuspension:)`,
  leave/rejoin). Difference: stage is an explicit flag (`setPresented(_:)`) rather than a
  closure, because the Console cover — not SwiftUI appear/disappear — is what decides.
  `reconnect()` is the visible affordance ("Reconnect" in the ended dialog + the menu).
- **Why leave/rejoin at all:** one Transport serves one Attach channel
  (`terminalChannelAlreadyOpen`). The Client holds it, so it must close before an Agent
  Attach inside the Console cover can open one.
- `HerdrClientView`: full-screen TerminalScreenView, nav bar hidden, status bar visible,
  `.ignoresSafeArea(.container, edges: .horizontal)`, keyboard inset respected. Chrome is
  the shell terminal's (`ShellTerminalInputRow` + `ShellTerminalKeysDock`, which hosts
  `TerminalControlPadView`), hidden entirely while a hardware keyboard is attached.
- Font: `TerminalZoomSettings.defaultFontSize(for: idiom)` — 12 on `.pad`, 8 elsewhere,
  read only when nothing is stored. Persisted-value semantics unchanged; `idiom` is
  injectable so tests do not depend on the host device.

### 2. Root navigation (commit 7dba133)
- Root is `HerdrClientRootView` (ContentView.swift). No hosts → it shows `ConsoleView`
  itself, which is where the "No Hosts / Add Host" onboarding already lives — mirroring
  that empty state by hand would have duplicated the Hosts sheet too.
- `PrimaryHostStore` persists `kelpie.primary-host`, defaults to the first Host, and
  drops a stored id whose Host was deleted (`hostsDidChange`).
- Floating 36pt `ellipsis.circle`, top-trailing, 12pt inset, 0.55 opacity resting / 1 on
  hover. Menu: Agents (fullScreenCover), Hosts (sheet), Switch Host (submenu picker, only
  with >1 Host), Settings (sheet), Reconnect (via `HerdrClientCommands`, a weak handle set
  by the Client screen — the `TerminalKeyboardControl` pattern).
- ConsoleView gained one optional property, `onClose`, rendering a "Done" cancellation
  toolbar item when it is presented as a cover. Nothing else in it changed; round 1's
  `columnVisibility` logic is untouched and now applies inside the cover.
- Deep links: `.onChange(of: notificationRouter.path, initial: true)` presents the cover
  whenever the path is non-empty; the cover's `.onDisappear` clears the path.
- **Where the Console's stores stay alive (spec asks):** `ContentView.swift` — `console`
  (`ConsoleStore`), `liveActivities`, `bannerStore`, `notificationPreferences` and
  `pushRegistration` are all `@State`/properties of ContentView, and the
  `ConsoleActivityDriver` `.task`, the `console.resume()` `.task`, the Live Activity
  `.task` and every `.onChange` that feeds them are attached to ContentView's body, above
  `HerdrClientRootView`. None of it is inside ConsoleView, so a lowered cover changes
  nothing about push or Live Activities.

### 3. Automatic keyboard mode (commit 376aa92)
- `HardwareKeyboardObserver` (@Observable, @MainActor): `GCKeyboard.coalesced != nil` at
  init, `.GCKeyboardDidConnect` / `.GCKeyboardDidDisconnect` after; a disconnect re-reads
  `coalesced` so a second attached keyboard still counts. Injected with `.environment()`
  from ContentView and passed explicitly to the Client screen.
- `AgentInputModePreference { automatic, composer, direct }` is the stored value (same
  `agent-input-mode` key), `AgentInputMode` stays the resolved two-case enum every
  existing call site reads through `settings.mode`. Automatic → `.direct` with a hardware
  keyboard, `.composer` without. Unknown stored values now fall back to `.automatic`.
- The three-way picker went into **SettingsView** ("Agent Input"); there was no input-mode
  picker in Settings before (the only control was the two-way segmented one on the Agent
  screen, which stays two-way and still counts as an explicit choice).
- Bug (a) — Composer centred with no software keyboard — is gone by default: Automatic
  resolves to Direct Input the moment a keyboard is attached.
- Bug (b) — hardware Return not submitting — **partially addressed, cause not confirmed.**
  There is no direct-input text field to attach `onSubmit` to: in Direct Input the system
  keyboard types straight into Ghostty, and the package already routes a semantic Return
  to the core key encoder (`UITerminalView+UITextInput.insertText` →
  `TerminalSoftwareKeyCommitRouter` → `sendSyntheticKey(usage: 0x28)`), so nothing in
  Heeler swallows it. The one real gap found in source: Direct Input only claims first
  responder off *software*-keyboard evidence (`AgentDirectInputPresentation.
  shouldClaimKeyboard`), which never appears with a hardware keyboard — and without first
  responder no key reaches the PTY at all. `armDirectKeyboardClaimIfNeeded` now claims it
  outright while a hardware keyboard is connected, and re-runs when one is docked
  mid-session. If Return still fails on device, the remaining suspect is UIKit loaning
  Return to the IME under the `.naturalLanguage` text-input traits agent terminals use
  (shell terminals use `.terminal` and are reported working) — that needs a device to
  confirm and was out of the ~30-line budget.

### 4. Tappable links (commit 69d4b32)
- `TerminalLinkDetector` (pure): scans `https?://[^\s<>"'`]+` by hand rather than by regex
  so character offsets line up with grid columns; leftmost-first, non-overlapping; strips
  trailing `.,;:!?)]}'"`; joins the next row's leading non-space run when a match reaches
  the last cell of its row; result goes through `TerminalLinkPolicy.url(for:)`.
  Only the forward join is implemented (a tap on the *continuation* row alone returns
  nil) — the spec's wording is "for that match", and the first row is the larger target.
- `HeelerTerminalView.linkURL(at:)` maps point → cell → `session.readViewportText()`.
  - Direct tap: `handleTap` opens the URL and returns before any click or keyboard raise,
    regardless of `tracksMouse`. `gestureRecognizerShouldBegin` also lets the tap gesture
    begin when the point holds a link, or a plain-shell output-area tap would never
    arrive at all.
  - Indirect pointer: `linkTouchToClaim` owns the whole primary-button sequence exactly
    as round 1's right-button claim does (began/moved/ended/cancelled all withheld from
    super), and opens only if the ended cell resolves to the same URL.
- Nothing sent to herdr, so its own `open`-on-the-Mac path is never reached.

### 5. Tests
- `TerminalAttachTests`: client target with and without a session (exact strings), the
  two existing exact-string assertions updated for the new exports, and a parameterised
  test that all four targets export COLORTERM and LANG.
- `TerminalLinkDetectorTests` (new): inside/edges, trailing punctuation, wrapped join,
  no-join when the next row is indented, non-URL cells, ftp/file/javascript ignored,
  viewport-text overload.
- `PrimaryHostStoreTests` (new): first-host default, persistence, healing after deletion,
  survival of an unrelated catalog change.
- `AgentInputModeSettingsTests`: automatic default, automatic resolution against a stubbed
  keyboard flag, explicit choice ignoring the keyboard and persisting as a preference,
  unknown value → automatic, stable preference order.

### 6. Docs and commits
- `docs/adr/0017-herdr-client-is-the-screen.md`, CHANGELOG "Kelpie" entries, a CLAUDE.md
  paragraph on the new root flow.

## Trailer deviation
The harness attribution instruction ("this replaces any earlier attribution guidance")
names `Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>`, so that line
is used instead of the spec's `Claude Fable 5.1`, exactly as in round 1. The
`Claude-Session:` line is the spec's.

## Build / test results

**iPad-simulator build (the round-1 recipe, final tree): `** BUILD SUCCEEDED **`**
(`build-final.log`; earlier per-item builds in `build1..build4.log`, no new warnings — the
two `SettingsView.swift` actor-isolation warnings and the `TerminalAgentSwitcher.swift`
Sendable one are pre-existing, in files this round did not change).

**Test-target compile for the simulator: `** TEST BUILD SUCCEEDED **`**
(`build-for-testing.log`) — every suite, including the four added/updated ones, compiles
and `Kelpie.app/PlugIns/HeelerTests.xctest` is built.

**Gap: the test runner could not be launched on this Mac.** Five attempts
(`test1..test5.log`, plus `test-device.log`), each wedged after the build with no output,
for 13-21 minutes:
- `xcodebuild test` on the iPhone 17 simulator, twice, including after
  `simctl shutdown all` + an explicit boot and with Simulator.app open.
- `xcodebuild test-without-building` against the built `.xctestrun`, same destination.
- `xcrun simctl install <booted iPhone 17> Kelpie.app` **on its own hung for over five
  minutes** — so this is the CoreSimulator failure CLAUDE.md already documents ("launches
  wedge with Mach error -308"), not anything about this change. Round 1 recorded the same
  problem and got one lucky iPhone run out of it.
- On the **device** destination the whole test target fails to compile, and would for any
  change: `SidebarConsoleIntegrationTests` uses `DemoScreenshotComposition`, which lives
  behind `#if DEBUG && targetEnvironment(simulator)` in `DemoScreenshotMode.swift`. This
  test target is simulator-only, pre-existing.

**What was verified instead.** `TerminalLinkDetector` is pure, so its exact suite
expectations were compiled and run natively with `swiftc` against the real source file
(`detector-check/`): 18/18 checks pass, including the wrapped-URL join, the indented
no-join, trailing punctuation, both span edges and the ftp/file/javascript refusals.
The attach-command assertions are exact-string comparisons against the same interpolation
the builder uses and were re-read side by side.

**Worth re-running** `-only-testing:HeelerTests` on `platform=iOS Simulator,name=iPhone 17`
on a machine whose CoreSimulator can install an app; every suite here is
platform-independent logic, so no result should differ.

## Commits (branch kelpie, never pushed)

- 454fee5 feat(client): attach herdr's own client to a Host (item 1)
- 7dba133 feat(client): herdr's client is the root screen (item 2)
- 69d4b32 feat(terminal): tapping a URL opens it on the iPad (item 4)
- 376aa92 feat(input): keyboard mode follows the hardware keyboard (item 3)
- 00ce790 docs: record why herdr's client became the screen (item 6)
- 1c4747e test: cover the client attach, link detection and the new defaults (item 5)

## Review pass (findings 1-6, commit 58199a7)

1. Banner: `HerdrClientRootView` draws `bannerStore.banner` as a top overlay with the same
   view, dismissal and `.animation(.snappy,)`; ConsoleView's own copy is untouched for
   when the cover is up.
2. Wrapped join now gates on the grid width: `url(in:column:row:width:)`, with
   `linkURL(at:)` passing `gridPointMapper.columns`. No width means no join ever. New test
   `doesNotJoinAUrlThatEndsShortOfTheGridWidth`; the two wrap tests now pass a width.
3. `claimedLinkTouch` carries its origin; past 8pt of movement the claim is released by
   replaying `super.touchesBegan` and forwarding every later phase, so a selection drag
   that starts on a URL works. Ended still opens only under the threshold and on the same
   URL.
4. `presentConsole()` awaits `HerdrClientCommands.prepareForConsole()` (which calls
   `setPresented(false)` and awaits `leave()`) before setting `isShowingConsole`; both the
   menu item and the deep-link `onChange` go through it, guarded by `isPreparingConsole`.
5. `HerdrClientHostView` gained `.onDisappear { store.leave() }`, paired with an
   `.onAppear` `rejoin()` for SwiftUI's spurious disappear/appear pairs.
6. `project.yml` sets `productName: Kelpie` on the Heeler target; the regenerated scheme's
   BuildableName is `Kelpie.app` at all four sites, `PRODUCT_MODULE_NAME` is still Heeler
   and `TEST_HOST` still `$(BUILT_PRODUCTS_DIR)/Kelpie.app/Kelpie`.

Build after the fixes: `** BUILD SUCCEEDED **` (iPad Pro 11-inch M5 simulator, recipe;
`build-review.log`, zero warnings). Detector re-verified natively including the two new
width cases: 20/20 (`detector-check/`). The XCTest runner still cannot launch on this Mac.
