---
source: "delegate-20260910-191536/r2-review/review.md — round 2 fresh-context review, 2026-09-11 09:43"
---

# Kelpie round 2 — fresh-context review (40c0682..1c4747e)

Read: SPEC2.md, notes.md, the full diff over Sources/Tests/docs, plus the
surrounding pre-existing code (AttachTerminalStore, ShellTerminalStore,
TerminalMouseReporting, AttachLinkIndex, HerdrHostPath, ContentView).
Not checked: nothing was built or run here (simulator broken per brief); test
outcomes below are hand-traced, not executed; on-device behaviour of Ghostty's
`ghostty_surface_read_text` (see finding 2) could not be confirmed from source
— libghostty ships as a binary xcframework in this tree.

## Findings

### 1. should-fix — foreground notification banner no longer renders anywhere
`Sources/Heeler/Console/ConsoleView.swift:172-180` is the only place
`bannerStore.banner` is drawn. `Sources/Heeler/ContentView.swift:99-116` now
roots `HerdrClientRootView` instead of `ConsoleView`, so the in-app
Blocked/Done banner (#77) is invisible unless the Agents cover happens to be
up. The store is still fed (`ContentView.swift:143`), so this is silent: the
banner is computed and dropped. The spec asked explicitly to check "whatever
ConsoleView needs alive at root"; notes.md:47-53 enumerate the *stores* but
not the banner's *presentation*. Confidence: high (grep is exhaustive —
`bannerStore` appears nowhere else in a view body).

### 2. should-fix — the wrapped-URL join can concatenate an unrelated word
`Sources/Heeler/Terminal/TerminalLinkDetector.swift:41`
```swift
if span.upperBound == characters.count, row < rows.count {
```
`characters.count` is the length of the *string* for that row, not the
terminal's column count. The detector has no way to know the width — the API
takes only text. If `readViewportText()` trims trailing spaces per row (which
Ghostty's selection-to-text path does for clipboard copy), then **every** line
that merely *ends* with a URL satisfies the condition, and the next row's
first token is appended:

```
Server running at https://localhost:3000
Press Ctrl-C to quit
        →  https://localhost:3000Press
```

`TerminalLinkPolicy.url(for:)` would accept that string, so a wrong URL opens.
The existing comment at `Sources/Heeler/Console/AttachLinkIndex.swift:35-38`
("newlines remain hard boundaries because the embedding API does not identify
visual soft wraps") says newlines do correspond to visual rows, which is the
half of the assumption that holds; it says nothing about trailing padding.

Concrete fix: `HeelerTerminalView.linkURL(at:)`
(`Sources/Heeler/Terminal/TerminalScreenView.swift:1656-1662`) already has
`gridPointMapper.columns` in hand — pass the width in and gate the join on
`span.upperBound >= width` (or on the row's length reaching the width),
instead of on the string ending.

The new suite cannot catch this: `TerminalLinkDetectorTests.swift:38-46` uses
hand-written rows with no padding, so the trimmed and untrimmed worlds look
identical to it. Confidence: medium-high on the mechanism, medium on whether
Ghostty actually trims — worth 30 seconds on a device (tap a URL that ends a
line and check what opens).

### 3. should-fix — a trackpad selection drag that starts on a URL is eaten, and opens the URL
`Sources/Heeler/Terminal/TerminalScreenView.swift:1387-1412`. `linkTouchToClaim`
claims the whole primary-button sequence whenever the *began* point is on a
URL, and `finishClaimedLinkTouch` opens on `touchesEnded` if the ended cell
resolves to the same URL. There is no movement threshold, so:

- press on a URL, drag two cells right, release still inside the URL → the URL
  opens instead of a selection being made;
- press on a URL, drag off it → the touch is dropped entirely, so no selection
  happens either (began/moved/ended were all withheld from super).

Round 1's right-button claim does not have this problem because a right-drag
is not a selection gesture. Suggest recording the began location and treating
movement beyond ~10pt as "not a click": stop claiming, or at least do not
open. Confidence: high (pure code reading; the withholding is explicit at
:1311-1314 and :1324-1327).

### 4. should-fix — cover ↔ client channel handover is a race, not a handshake
`Sources/Heeler/Client/HerdrClientStore.swift:161-176` (`leave()`) returns a
`Task` so a caller can await the channel actually closing; the only caller,
`HerdrClientRootView.swift:246-248`
(`.onChange(of: isShowingConsole) { store.setPresented(!isShowing) }`),
discards it, and `setPresented` (`HerdrClientStore.swift:62-66`) does not
await either. Meanwhile SwiftUI presents the `fullScreenCover` immediately.

One Transport serves one Attach channel (notes.md:21-23,
`HeelerSSHTransport.swift:2076`), and `AttachTerminalStore` does not retry a
refusal — it surfaces "Another terminal is already open on this Host."
(`AttachTerminalStore.swift:470-472`). So:

- **Deep link** (`HerdrClientRootView.swift:100-106`): the cover comes up with
  `notificationRouter.path` already non-empty, so `AgentDetailView` attaches
  on the same run loop the client's `stop()` was merely *enqueued* on. This is
  the flow the spec singles out, and it is the one most likely to lose the
  race.
- **Dismissal**: the client's `rejoin()` chains only on its own
  `lifecycleTask`, not on the Agent attach's teardown, so returning from the
  cover can land on a stopped terminal. There is at least a visible Reconnect
  here, so this half is degraded rather than broken.

Fix shape: make the cover's presentation await `leave()` (present from the
task's completion), or have the Agent attach retry `terminalChannelAlreadyOpen`
once. Confidence: medium-high — the ordering is clear from the code, the
timing margin is not (SSH channel-close round trip vs. cover transition), and
I could not run it.

### 5. should-fix — the client store is never told to leave on host switch or teardown
`HerdrClientRootView.swift:238-249`: `HerdrClientHostView` has `.onAppear`,
two `.onChange`, and no `.onDisappear`. `.id(host.id)`
(`HerdrClientRootView.swift:70`) tears the view down on a host switch, but
nothing calls `store.leave()`, and `HerdrClientStore` has no `deinit`. The
running attach task retains the store, so the channel is not closed by
deallocation. Switching A → B → A (or deleting the last host, which drops to
the Console branch at `HerdrClientRootView.swift:52`) can therefore return to
a host whose channel is still claimed. Confidence: medium-high (mechanism
certain; whether the transport reaps the channel on its own I did not trace
past `HeelerSSHTransport.swift:2076`).

### 6. should-fix — the regenerated scheme renames the product back to Heeler.app
`Heeler.xcodeproj/xcshareddata/xcschemes/Heeler.xcscheme:19,30,79,98`:
`BuildableName` went `Kelpie.app` → `Heeler.app` in this round's
`xcodegen generate`, while `project.yml:73` and
`Heeler.xcodeproj/project.pbxproj:2082,2247` still set `PRODUCT_NAME = Kelpie`
(and `TEST_HOST` at :2203 still points at `Kelpie.app`). Round 1's scheme had
the fork's name. Collateral from regeneration, unrelated to the six spec
items, and the kind of thing that breaks Run/Test from the Xcode UI. Cheap to
restore by hand. Confidence: high (diff is unambiguous).

## Optional (nits)

- **Viewport read per tap.** `linkURL(at:)`
  (`TerminalScreenView.swift:1656`) does a full `readViewportText()` — a C
  call plus a whole-viewport UTF-8 copy on the main thread. It now runs twice
  per direct tap (`gestureRecognizerShouldBegin` :1437 and `handleTap` :1917)
  and twice per trackpad click (:1314 and :1408). Answering the spec's
  question directly: yes, every tap, and more than once. A short-lived cache
  keyed on the surface's damage/redraw counter would collapse it to one.
- **Wide characters and tabs.** The detector indexes `Array(row)` by grapheme
  (`TerminalLinkDetector.swift:36-38`) while `column` comes from
  `TerminalGridPointMapper.cell(at:)`
  (`TerminalMouseReporting.swift:81-92`), which counts cells. A CJK or wide
  emoji glyph earlier in the row occupies two columns and one Character, so
  everything to its right is off by one per glyph. Rare in herdr's TUI,
  invisible in the tests, worth a line in the doc comment (which currently
  claims wrapping is "the one piece of terminal-specific knowledge").
- **Mapper clamping.** `cell(at:)` clamps to the grid, so a tap in the bottom
  or right padding resolves to an edge cell and can open a URL that is not
  under the finger.
- **`.environment(hardwareKeyboard)` is dead.** `ContentView.swift:117` injects
  it; nothing reads `@Environment(HardwareKeyboardObserver.self)` anywhere
  (grep is clean) — every consumer takes it as an explicit `let`. The spec
  said "Inject via environment"; harmless either way, but it is one of the two
  and should not be both.
- **Font default keys off idiom, not width.** `TerminalZoomSettings.swift:29-45`
  uses `UIUserInterfaceIdiom == .pad`; the spec said "regular-width (iPad)
  window". An iPad in a compact Slide Over still starts at 12pt. Notes admit
  the substitution; flagging only because it is a quiet narrowing.
- **Strong `UITouch` retained.** `TerminalScreenView.swift:628` stores
  `(touch: UITouch, url: URL)` strongly, where round 1's equivalent
  (`:626`) is `weak var claimedRightButtonTouch`. UIKit's guidance is not to
  retain touch objects past the event; a stale claim also never clears (the
  `touches.contains` guard at :1401 makes it inert rather than harmful).
- **`.onDisappear { notificationRouter.path = [] }`** is on `consoleScreen(...)`
  (`HerdrClientRootView.swift:120-121`), which is used both as the cover's
  content *and* as the no-host root (`:52`). Adding the first host clears the
  path as a side effect. Harmless today.
- **Hover only, no press.** The menu button (`HerdrClientRootView.swift:159-167`)
  raises opacity on `.onHover` but not on press; the spec said
  "hover/press". The menu dims the screen anyway.

## Checked and clean

- **Attach command strings.** `HeelerSSHTransport.swift:2174-2196` produces,
  for `.client(session: nil)`:
  `/bin/sh -c '<pathExport>; export COLORTERM=truecolor; export LANG="${LANG:-en_US.UTF-8}"; export HERDR_SOCKET_PATH="$2"; printf "<marker>"; exec herdr' attach '' '<socket>'`
  and with a session, `exec herdr --session "$1"' attach 'work' …`. Order is
  PATH → COLORTERM/LANG → socket → marker → exec, marker last before exec as
  the bootstrap gate requires. `--takeover` is unreachable for `.client`
  (:2179-2182) and the test asserts its absence even with `takeover: true`
  (`TerminalAttachTests.swift:2159`).
- **Quoting.** The session name rides as a single-quoted positional argument
  and is expanded from `"$1"`, so spaces, `"`, `$`, `;`, `&&` and globs are all
  inert. `'` and `\` and control characters are rejected up front
  (:2151-2155, :2162-2167) — a hard failure rather than a mis-quote. The
  `argumentIsOptional` relaxation (:2157-2160) applies only to `.client`, so
  an empty agent/terminal id still throws.
- **Existing command-string tests.** The two exact-string assertions were
  updated (`TerminalAttachTests.swift:2188,2207`);
  `HerdrHostPathTests.swift:117-137` and `WakeCommandTests` use `contains` on
  substrings this change did not touch, so they still pass. `attachCommand`
  gained its `.client` case (:2218-2223) and `SSHTransportSettings.swift:12-14`
  keeps the command word bare, so `isBareHerdrCommand("herdr")` is true
  (`HerdrHostPath.swift:57-59`) and exit 127 still maps to
  `herdrBinaryNotFound`.
- **Client lifecycle basics.** `terminalStatus`
  (`HerdrClientStore.swift:71-75`) matches `ShellTerminalStore.swift:308-312`
  verbatim; `.stopped` folds to `.connecting` only while on stage, and
  `.ended` still reaches the Reconnect dialog
  (`HerdrClientView.swift:180-190`). Resume + cover cannot produce two
  attaches: `rejoin()`/`replaceTerminal()` both stop the current pipeline
  before adopting a replacement and are serialised through
  `enqueueLifecycleTransition` (:262-280); "none" is recoverable via the
  visible Reconnect and the menu item. The remaining exposure is finding 4.
- **Root navigation.** No-host case shows the real `ConsoleView`
  (`HerdrClientRootView.swift:49-53`) rather than a re-drawn empty state —
  broader than "mirror it", which is the right call. `PrimaryHostStore`
  defaults to `hosts.first`, persists on `select`, and heals on
  `hostsDidChange` (`PrimaryHostStore.swift:23-45`). `ConsoleStore`,
  `liveActivities`, `pushRegistration` and the `ConsoleActivityDriver` `.task`
  all remain on ContentView's body (`ContentView.swift:127-203`), above the
  cover. The cover's `ConsoleView` inherits the presenter's environment,
  including `openURL` and `preferredColorScheme`. Round 1's
  `columnVisibility` logic is untouched. The floating button's hit area is the
  36pt label with `.contentShape(.circle)`; the `.padding(12)` is outside the
  `Menu` and is not tappable.
- **Link detection semantics.** Column/row 1-based and bounds-guarded
  (:34-35); leftmost-first non-overlapping spans matching the stated regex
  (:52-68) — I traced the early-out at :64 against an index left of a match, an
  index between two matches, and a nested `http://` inside a query string, and
  it agrees with the regex in each; trailing `.,;:!?)]}'"` stripped after the
  join (:45-47) so `(https://x/y),` resolves; `ftp://`, `file://` and
  `javascript:` never match the scheme scan at all (:71-79). A non-URL tap
  falls through to the unchanged `tapAction` switch
  (`TerminalScreenView.swift:1921`), so the click and the keyboard raise
  behave exactly as before, and `gestureRecognizerShouldBegin` was widened
  (:1433-1440) so a link tap in the plain shell's output area actually
  arrives. Round 1's right-click claim is checked first in `touchesBegan`
  (:1305-1315), so the two never contend.
- **Automatic keyboard mode.** `HardwareKeyboardObserver.swift:24-27` seeds
  from `GCKeyboard.coalesced` at init and observes both notifications on the
  main queue, re-reading `coalesced` on disconnect so a second keyboard still
  counts. `AgentInputModePreference` stores the *preference* under the
  existing `agent-input-mode` key, resolves through `mode`
  (`AgentInputModeSettings.swift:66-69`), keeps existing explicit values, and
  falls back to `.automatic` on an unknown string. The two-way segmented
  control still records an explicit choice
  (`AgentInputModeSettings.swift:82-84`). Settings picker offers
  Automatic/Composer/Keyboard (`SettingsView.swift:193-206`;
  `segmentTitle` at `AgentInputModeSettings.swift:17-19` supplies the last
  two). `HerdrClientView` hides both `ShellTerminalInputRow` and the keys dock
  live off `hardwareKeyboard.isConnected` (:53-56, :66, :138-143) and requests
  the keyboard when one arrives. Bug (b) is partially addressed and honestly
  labelled as unconfirmed in notes.md:69-82, which the spec's ~30-line escape
  hatch permits.
- **Swift 6.** No red flags found. `nonisolated(unsafe)` on the observer array
  is confined to `init`/`deinit`; `MainActor.assumeIsolated` inside a
  `queue: .main` observer is sound (GameController posts on the main thread,
  and OperationQueue.main runs the block there regardless); the
  `@MainActor @Sendable` closures in `HerdrClientStore` match the existing
  `ShellTerminalStore` shape. The builder reports the iPad-simulator build and
  the test-target compile both succeeding, which is consistent with what I
  read.
- **Tests as written.** I evaluated every new assertion by hand against the
  implementation. All eight `TerminalLinkDetectorTests` cases pass — including
  column 17 vs 18 on a 17-character line, `(https://…),` at column 10, and the
  indented no-join. `PrimaryHostStoreTests` uses
  `Host.fixture(name:address:)` (`HostStoreTests.swift:247-256`, unique UUIDs
  per call) and `Host` is `Equatable`, so `host(in: []) == nil` type-checks.
  `TerminalAttachTests`' two exact strings match the interpolation
  character-for-character. `AgentInputModeSettingsTests`' title assertion
  matches `segmentTitle`. `TerminalAttachTarget` is `Sendable`, so the
  parameterised `@Test(arguments:)` is well-formed. I found nothing that would
  fail as written — noting that they also cannot fail on findings 2, 3 or 4,
  none of which is covered.
- **Docs and commits.** ADR 0017 exists and covers all four required points;
  CHANGELOG has Added/Changed entries; CLAUDE.md gained the root-flow
  paragraph. Six logical commits on `kelpie`, nothing pushed, working tree
  clean, `Heeler.xcodeproj` regenerated and committed. The trailer deviation
  (harness attribution over the spec's) is declared in notes.md:118-122 and is
  correct — the harness instruction supersedes.
