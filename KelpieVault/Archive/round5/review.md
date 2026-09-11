# Reviewer 4 — round 5A/5B merged working tree on 0df2239

Reviewed by reading only; no build, no edits. Build log not re-run (spec says merged build succeeded).

## MUST-FIX

### 1. A path tap is swallowed in the Console terminals — `Sources/Heeler/Terminal/TerminalScreenView.swift:2328-2334`, `:1623-1626`, `:1594-1600`
`handleTap` now claims any `linkMatch`, including `.hostPath`, and returns. `onHostPathTap` is only set by
`HerdrClientView.swift:36`; `Console/AgentTerminalView.swift:316` and `Console/ShellTerminalView.swift:31` build
`TerminalScreenView` without it, so `open(.hostPath)` calls a nil closure and the tap is consumed: no keyboard
raise, no `tapAction`, and no left-click forwarded to herdr. `gestureRecognizerShouldBegin` (`:1626`) claims the
tap for the same reason, and the pointer claim (`:1594`) swallows the corresponding mouse click.
Any line of agent output containing `/x/y.ext` becomes a dead zone in the Console.
Fix: treat a `.hostPath` match as a match only when `onHostPathTap != nil` (all three sites).
Confidence: high (read-verified call sites; not run on device).

## SHOULD-FIX

### 2. Mid-token URLs are no longer detected — `Sources/Heeler/Terminal/TerminalLinkDetector.swift:70-80`
The old `span(covering:)` found a `http(s)://…` match anywhere inside the tapped run. `match` now takes the whole
whitespace-delimited token, strips a fixed leading-punctuation set, and requires the scheme at offset 0. Tokens
like `](https://…)`, `url=https://…`, `→https://…`, `see:https://…` no longer resolve. Existing
`TerminalLinkDetectorTests` still pass (they only cover leading `(`), so the regression is untested.
Confidence: high on behaviour, medium on how often terminal output produces it.

### 3. No tests for the new `.hostPath` detection — `Tests/HeelerTests/TerminalLinkDetectorTests.swift` (unmodified)
The whole of spec 5B item 5's detector rule — `~/`, `//`, `://`, `/dev/null`, trailing punctuation, extension
length, URL precedence — ships with zero coverage, in a file the spec told the builder to read. `/dev/null`,
`//`, and URL precedence do read as correct on inspection; `file.swift:12:3` (the commonest path shape in agent
output) is *not* matched because the trailing `:12:3` is kept in the extension check (`:1 46-150`).
Confidence: high.

### 4. The 64 MB cap is not enforced during transfer — `Sources/Heeler/Transport/HeelerSSHTransport.swift:1352-1370`
The cap is checked against `attributes.size` before the read, which is correct for a regular file, but
`SSHSFTPAttributes.size` is optional and `readSFTPFileIfPresent`
(`Packages/HeelerSSH/Sources/HeelerSSH/SessionDriver.swift`) accumulates the whole file in memory with no bound.
A nil size, or a FIFO/`/dev/`-style node that stats as 0 and streams, reads unbounded until the 300 s
`downloadTimeout` — a memory-pressure kill on an iPad. The post-read check at `:1364` is too late.
Fix: fail when `attributes.size == nil`, or add a byte budget to the read loop.
Confidence: medium-high (cap logic read; no runtime test).

### 5. A coalesced size can be dropped by a freeze with nothing to forward — `Sources/Heeler/Terminal/TerminalScreenView.swift:421`, `:449`
`beginSizeReportDeferral` and `cancelSizeReportDeferral` both call `cancelCoalescedSizeReport()`, discarding the
pending trailing size. The comment assumes the thaw forwards the settled grid, but `forwardDeferredSize()`
(`:498`) returns nil when `deferredSize` was never set, and `cancelSizeReportDeferral` clears `deferredSize`
outright. If a freeze starts (or is cancelled) inside the 80 ms window and no further layout pass follows, the
Host stays at the leading-edge size while the view is at the later one, until the next unrelated resize.
Everything else in D checks out: leading edge fires, trailing fires at 80 ms of quiet, the generation counter
makes cancellation safe, `isSizeReportCurrent` (`:469`, `:1020`) is untouched, and a drag ending inside the
window still delivers its last size.
Confidence: medium (reachability of "freeze with no following resize report" not proven).

### 6. Spec 5A item 5 is not delivered; the encoder additions are dead — `Sources/Heeler/Terminal/TerminalTouchScroll.swift:210-232`, `TerminalMouseReporting.swift:25-53`
`remoteDragPressSequence`/`MotionSequence`/`ReleaseSequence` and `tracksMouseMotion` have unit tests
(`Tests/HeelerTests/TerminalMouseReportingTests.swift:80-135`) but no caller anywhere in `Sources`; herdr's
pane-border drag still does not work. There is no `builder4a/report.md` to explain the omission.
**Recommendation: wire it or delete it, and prefer wiring** — the encoder rows are the easy half, and leaving
three tested-but-unreachable methods invites a future reader to assume the feature exists. If it is not wired
this round, delete the three `remoteDrag*` helpers and their tests and keep only `isMotion` + `tracksMouseMotion`
(both are small, correct, and plausibly useful); do **not** leave the CHANGELOG silent either way — it currently
claims nothing about drags, which is right.
Confidence: high (grep-verified: no call sites).

## OPTIONAL / NITS

- `MediaIntake.beginLoading` (`Sources/Heeler/Client/MediaIntake.swift:80-88`) keys primed loads by
  `ObjectIdentifier` of providers it does not retain. A freed provider's address could be reused and match a
  later, unrelated array of the same length. Unlikely (the claim happens on the next main-actor turn) but
  cheap to remove by retaining the providers in the tuple.
- `MediaIntakeLoadCollector.items()` (`MediaIntake.swift:295-305`) never resumes if a provider's completion
  handler never fires — the staging spinner hangs with no timeout. Pre-existing shape (the old
  `withCheckedContinuation` had it too), not a regression.
- `acceptedDropTypeIdentifiers` includes `public.data`/`public.content`, so a plain-text drag now passes
  `hasItemsConforming`; the second clause `session.items.contains { isStageable }`
  (`TerminalScreenView.swift:2509`) correctly refuses it, so scope is fine.
- Classification is right on every case asked about: `public.plain-text` alone → `.text`
  (`MediaIntake.swift:34`); `["public.plain-text","public.file-url"]` → `.file`; `com.adobe.pdf` → `.file`.
  Tests cover all three (`MediaIntakeTests.swift:27-60`).
- `TerminalDesktopNotificationRelay` has a `LocalNotificationScheduling` protocol written explicitly "so the
  relay's decisions are testable" and then no test file. `didRequestAuthorization` (`:79`) is per-launch and
  set before the await, so the prompt cannot double-fire; foreground/background split at `:112` is single-path,
  so no duplicate posts. Banner surfaces on the client root (`HerdrClientRootView.swift:222-231`) and in
  `ConsoleView.swift:171-178`; `AgentNotificationRouter.open(_:)` already took an optional, so the
  `target` change is safe and its one test was updated correctly.
- `TerminalZoomSettings` migration is correct: an iPad user with a stored absolute size gets
  `offset = stored - 12`, and at full width (`>= 700`) lands on exactly the old size
  (`TerminalZoomSettings.swift:62-70`). Zoom survives width changes (`:96-104`); iPhone short-circuits on idiom
  (`:83`). `TerminalZoomSettingsTests.swift` was not extended — the width ladder and the migration path are
  untested. `windowWidthDidChange` is fed from a `.background { GeometryReader }` with
  `onChange(of:initial:true)` (`HerdrClientRootView.swift:94-103`), so it fires on width change only and
  early-returns when the bucket is unchanged: cheap.
- `project.yml:95` / `pbxproj:2119,2285` add all four iPad orientations in both configurations, iPhone key
  unchanged, `UIRequiresFullScreen` absent. The three new files are each in exactly one group and in the app
  target's Sources phase. Consistent.
- CHANGELOG: 4b's three entries at the end of `### Added` (CHANGELOG.md:69-88), 4a's four at the end of
  `### Fixed` (:114-125). No duplicates, no misplaced lines, no `### Changed` churn.
- Swift 6: no `try!`, no `as!`, no force unwraps in the diff or the new files. `MediaIntakeLoadCollector` and
  the test's `LoadCounter` are `@unchecked Sendable` with an `NSLock`, which is the right shape here.

## What I could not check
- Anything requiring the device: the drop fix end-to-end, the bell haptic firing, whether iPadOS actually
  hands `keyboardHome`/`keyboardPageUp` for Fn+arrow, Split View resize behaviour, Quick Look rendering.
- Test execution. `builder4b/report.md` says `HeelerTests` cannot build for a physical device
  (`SidebarConsoleIntegrationTests.swift:14` needs `DemoScreenshotComposition`, which is
  `#if DEBUG && targetEnvironment(simulator)`), and the simulator is unusable on this Mac. So **none** of the
  new or changed tests in this diff have been run.
- `builder4a/report.md` does not exist, so 5A's own account of items 3 and 5 was unavailable.
