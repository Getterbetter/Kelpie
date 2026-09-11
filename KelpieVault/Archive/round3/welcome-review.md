# Review — Welcome screen / paste-first pairing (uncommitted tree, branch `kelpie`)

Reviewed: `git diff` (CHANGELOG.md, Heeler.xcodeproj, HerdrClientRootView.swift, HostListView.swift,
PairingScanView.swift) plus new `Sources/Heeler/Client/WelcomeView.swift` and
`Sources/Heeler/Pairing/PairingCodeEntryView.swift`, against builder2/spec.md.
No build run (per brief). The builder's `report.md` does not exist in
`…/delegate-20260911/builder2/`, so the build tail could not be cross-checked.

## Must-fix

1. **`Sources/Heeler/Pairing/PairingCodeEntryView.swift:78-89` — background pasteboard read.**
   The `.task` reads `UIPasteboard.general.string` with no user action. This directly contradicts the
   decision already recorded three files over: `Sources/Heeler/Pairing/PairingScanView.swift:141-143`
   — *"User-initiated paste so iOS can show its pasteboard prompt against a tap, not against a
   background read (#204)"*. Since iOS 16 a programmatic read of content copied in another app (which
   is exactly the Universal-Clipboard case the feature is built on) raises the modal "Allow Paste"
   alert; here it fires unbidden the instant the sheet appears, and if the user declines, the read
   returns nothing and the promise silently fails.
   Neither suggested mitigation fully works: `hasStrings` is alert-free but only tells you the
   clipboard is non-empty (it would avoid the alert *only* when the clipboard is empty);
   `detectPatterns(for:)` covers URLs/numbers/web-searches, not a `HERDR-PAIR:` string, so it cannot
   gate on "this looks like a Pairing Code". The banner-free routes are a `UIPasteControl` for the
   Paste button, or dropping auto-submit and keeping one tap. The spec asked for auto-submit, so this
   is a spec-vs-#204 conflict for Anthony to settle, not a silent builder slip.
   Confidence: high (that the alert fires and that it contradicts #204).

2. **`PairingCodeEntryView.swift:83-88` with `PairingScanView.swift:230-232` — "Scan Again" bounces
   straight back into the failed ceremony.** `didCheckClipboard` is `@State` on a view that is
   *destroyed* whenever `store.pairingCode != nil` (PairingScanView.swift:49-57 swaps in
   `PairingCeremonyView`). `Scan Again` calls `store.rescan()` → `pairingCode = nil` →
   `PairingCodeEntryView` is constructed fresh → `didCheckClipboard == false` → the same, still-stale
   clipboard parses and is auto-submitted → `PairingCeremonyView` again (`.task(id: attempt)` restarts
   `pair()` on its own). In `.paste` mode the user can never reach the entry screen to type a
   different code; the only exits are Cancel and "Try Again". Each bounce is also another paste
   alert (finding 1). The same mechanism makes a *stale* clipboard (yesterday's expired code) throw
   the user into a failing ceremony they never asked for. Fix: hoist the one-shot flag to
   `PairingScanView` (or to the store) so it survives the ceremony round trip.
   Confidence: high.

## Should-fix

3. **`Sources/Heeler/Client/HerdrClientRootView.swift:53-80` — the sheet is on a `Group` whose only
   child is a conditional, so it may not survive the branch swap it was moved there to survive.**
   SwiftUI distributes a modifier applied to a `Group` across the group's subviews; with
   `_ConditionalContent` the "subview" is whichever branch is live, so the presentation modifier's
   attachment point changes identity when `primaryHost.host(in:)` goes nil → non-nil. The swap is
   guaranteed on the very first pairing and happens *while the sheet is up*: `PrimaryHostStore`
   (`Sources/Heeler/Client/PrimaryHostStore.swift:25-30`) returns `hosts.first`, and
   `PairingScanStore.pair()` calls `catalog.add(host)` before it sets `pairedHost`, so the Welcome
   branch is replaced mid-ceremony, before `HostListView` pushes the preflight.
   If the modifier is torn down and re-created, `HostListView` is rebuilt: `path` (the preflight the
   user is standing in) is lost, and `didRunInitialAction` resets — which re-fires `initialAction`,
   re-presenting the pairing sheet and re-reading the clipboard (findings 1 and 2 compound).
   I could not verify this on device and the semantics are genuinely ambiguous, so: **medium
   confidence**. The insurance is free — wrap the conditional in a single stable container
   (`ZStack { if … else … }`) and attach `.sheet` to that, which removes the doubt entirely.
   Nothing else in `client(for:)` depended on the sheet's old position: `hostSheet` is written from
   the menu (line 225), the Welcome actions (61-62), the Setup-Guide hand-off (125) and cleared by
   the deep link (149), all of which still resolve. The `fullScreenCover` and the Settings sheet
   stayed on `client(for:)`, and the sheet is never presented while the cover is up (the menu is
   behind the cover), so the ancestor/descendant presentation pairing is unchanged from before.

4. **`WelcomeView.swift:189` — `.accessibilityElement(children: .combine)` on `SetupStep` swallows
   the Copy button.** Combining merges the child elements into one; the `CommandRow` Copy button
   (WelcomeView.swift:210-220) stops being separately focusable/activatable under VoiceOver, so the
   only way to get the command onto the clipboard is gone for VoiceOver users (and the
   `.textSelection(.enabled)` copy route is a fiddly substitute). Either drop `.combine` or keep the
   Copy button outside the combined element.
   Confidence: medium.

5. **`WelcomeView.swift:170-175` — the step numeral sits in a fixed `26×26` frame.** The spec requires
   Dynamic Type with no fixed heights; at the accessibility sizes the `.subheadline` numeral will
   clip or truncate inside the circle. `@ScaledMetric private var badge = 26` fixes it.
   Confidence: high that the frame is fixed; medium on how bad it looks.

## Optional / nits

- `WelcomeView.swift:27` — `let hosts: HostStore` is never read in the view. Spec-mandated, so keep
  it or drop it deliberately; as written it is dead weight (and both call sites pass a live store).
- `WelcomeView.swift:138-140` — `.frame(maxWidth: .infinity)` is applied *outside* `.buttonStyle`, so
  the "Add manually over SSH" hit target is only the label, centred in a full-width frame.
- First pairing starts an SSH attach (`HerdrClientHostView`, line 96-108) to the brand-new Host
  underneath the preflight sheet that is simultaneously probing the same Host. Probably harmless
  (separate transports) but it is new behaviour introduced by the Welcome branch.
- The Setup Guide sheet lives on `client(for:)` (line 117), not on the Group. That is correct today —
  the menu that opens it only exists in the client branch — but it is worth a comment so a later
  reader does not "fix" it by moving it up.
- `CommandRow.copy()` (WelcomeView.swift:227-236) — `Task { @MainActor in … }` is redundant; `Task {}`
  from a `@MainActor` View already inherits the actor. Cancellation and `onDisappear` handling are
  correct.

## Checked and sound

- **Copy**: every string matches the spec verbatim — hero line, the two-sentence intro, all three step
  titles/descriptions, both commands, the "On this iPad" line, the three button titles, the closing
  footnote, and the `PairingCodeEntryView` title/body/"Or type it here"/"Continue"/"Scan QR Code
  instead". The spec's inline red fallback was correctly skipped in favour of the store's existing
  `scanFailureMessage` (PairingCodeEntryView.swift:46-52).
- **CHANGELOG.md:58-62** — Added block under `[Unreleased]`, wording matches the spec exactly.
- **Heeler.xcodeproj/project.pbxproj** — `WelcomeView.swift`, `PairingCodeEntryView.swift` and
  `Sources/Heeler/Terminal/TerminalKeyTrace.swift` all have file refs, group entries and app-target
  `Sources` build-phase entries (pbxproj lines 33/46/60, 445/477/587, 988/1306/1358, 1733/1777/1800).
- **Setup Guide → Host sheet hand-off** (HerdrClientRootView.swift:117-132): the two sheets cannot
  overlap — `onDismiss` fires only after the first is gone — and `pendingHostAction` is cleared before
  `hostSheet` is set, plus again on the notification deep link (151-152). A plain Done/swipe dismiss
  leaves `pendingHostAction` nil, so no stray sheet. Correct.
- **`HostListView.initialAction`** (HostListView.swift:241-247): the `didRunInitialAction` guard makes
  it one-shot for the life of the view, and `presentPairing(entry:)` keeps `pairingEntry` and
  `isScanningToPair` in step. The manual fallback ordering is untouched:
  `manualFallbackRequested` → the pairing sheet's `onDismiss` → `isAddingHost` (lines 190-199).
  (One residual: a `.task` that presents a sheet while the enclosing sheet is still animating in can
  be dropped by UIKit; not observed, just a known hazard — worth a look on device.)
- **Camera path unchanged**: `PairingScanView` only gates `resolveCameraAccess` on `entry == .camera`
  and leaves the scanner, ceremony, `onPaired`/`onAddManually` semantics alone; the default
  `entry: .camera` keeps every existing caller source-compatible.
- **Swift 6 concurrency**: no new cross-actor hops, no force unwraps, no `try!`; `PairingScanStore` is
  `@MainActor` and every new call site is inside a `@MainActor` View body/task. Nothing here should
  trip strict concurrency.

## Not checked

- The build (no report.md; brief says BUILD SUCCEEDED — not verified by me), device run, install.
- Runtime Dynamic Type / phone-width rendering, VoiceOver behaviour: inspection only.
- Tests: none added or run; the spec did not ask for any, and no existing suite touches these files.
