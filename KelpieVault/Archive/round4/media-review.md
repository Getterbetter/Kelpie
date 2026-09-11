# Review — Kelpie media intake (paste / drop / pickers)

Reviewed: `git diff` (CHANGELOG, pbxproj, HerdrClientRootView, HerdrClientView, TerminalScreenView) plus the
three new files, against the spec and against `ComposerStagingStore.swift` / `AgentTerminalView.swift`.
Not run: build, tests, device. Not checkable by reading: whether UIKit dispatches `paste(_:)` for ⌘V on this
responder, and the exact SwiftUI layout of the staging bar under `safeAreaInset` — both flagged with the
uncertainty stated.

## Must-fix

1. **`Sources/Heeler/Client/MediaIntake.swift:130`** — `copyIntoIntakeDirectory` writes every dropped/pasted
   file to `tmp/kelpie-intake/<uuid>/<name>` and nothing ever deletes it. `FilePreparer.prepare` *copies*
   again into its own protected store (`FilePreparer.swift:109`) and only removes *its* copy, so each intake
   leaves a permanent third copy in tmp with no `FileProtectionType.complete` and no backup exclusion — unlike
   every other local copy this app makes. The spec asked for the directory to be "cleaned or at least
   bounded". Fix: delete the per-uuid directory after staging (or sweep `kelpie-intake` on client appear).
   Confidence: high.

2. **`Sources/Heeler/Terminal/TerminalScreenView.swift:2010`** — the ⌘V interception calls `paste(nil)` with
   no guard against UIKit's own dispatch of `paste(_:)` for the same key event. `HeelerTerminalView` is a
   `UITextInput` responder and `canPerformAction(paste:)` returns true (now also for image/URL pasteboards,
   line 1346), which is exactly the condition under which UIKit installs and fires the built-in editing
   shortcut. If it fires, the text — or the staged path — is inserted twice, and for a staged file that means
   two SFTP uploads and two paths typed. The spec explicitly asked for a dedupe; there is none. Cheapest fix
   is an in-flight flag or a monotonic-time stamp set in `paste(_:)` and checked in `isPasteShortcut`'s
   branch, or verify on device that the press really does reach `pressesBegan` (the spec's key trace covered
   ⌘+letter generally, not ⌘V specifically). Confidence: medium — the code path is certainly unguarded; the
   double dispatch is unverified.

## Should-fix

3. **`Sources/Heeler/Client/HerdrMediaStagingStore.swift:105`** — `staging.begin` silently no-ops when the
   wrapped store is busy (`ComposerStagingStore.swift:199`), and `drainQueue` never checks that it took. The
   item has already been `removeFirst`ed, and `awaitOutcome` then waits on whatever operation *is* running and
   reads its `.completed` as this item's success: the queued item is dropped without ever being staged, with
   no error shown. Reachable today: tap **Retry** on a failed upload, then drop or paste something while the
   retry uploads (`stage()` sees `queueTask == nil` and starts a drain). Fix: `while !staging.canBegin { await
   nextStateChange() }` before `begin`, or assert the state moved to `.preparing`. Confidence: high that the
   path exists; medium on how often a user hits it.

4. **`Sources/Heeler/Client/HerdrMediaStagingStore.swift:57`** — `perform` clears the whole queue on `.dismiss`
   before forwarding, but `ComposerStagingStore.dismiss()` is a no-op while busy. The staging bar's
   auto-dismiss (`HerdrClientView.swift:274`) fires `.dismiss` 2 s after a completion; if the next item's
   `.preparing` has not yet re-rendered the bar (the `.task(id:)` cancel is what saves it today), the
   remaining items in a multi-item drop vanish silently. Clear the queue only for `.cancel`, or only when the
   forwarded command actually changed the state. Confidence: medium (the id-change cancel makes it a race,
   not a certainty).

5. **`Sources/Heeler/Client/HerdrClientView.swift:87`** — the staging bar overlay is applied to
   `terminalScreen` *before* `.safeAreaInset(edge: .bottom)` (line 88) and before
   `.padding(.bottom, keyboardLayout.contentInset)` (line 101), so it aligns to the un-inset content frame and
   will sit behind `ShellTerminalInputRow` whenever the software keyboard chrome is up. The keys dock — the
   one piece of existing keyboard-relative chrome — is deliberately in an overlay *after* that padding (line
   102). Move the bar there. Confidence: medium (SwiftUI `safeAreaInset` does not resize its content, so an
   inner bottom overlay overlaps the inset view).

6. **`Sources/Heeler/Terminal/TerminalScreenView.swift:1344-1347`** — `canPerformAction(paste:)` gained the
   `hasImages || hasURLs` clause on the shared `HeelerTerminalView`, which is also the Console's Agent
   terminal, where `onStageItems` is nil. There the edit-menu **Paste** now enables for an image-only
   clipboard and `stageMedia` returns silently (line 1322). Gate the new clause on `onStageItems != nil`.
   Confidence: high.

7. **`Tests/HeelerTests/MediaIntakeTests.swift`** — covers only `classify`/`pasteText`, exactly as specced,
   but the riskiest new code is the in-order queue (findings 3 and 4), which has no test at all. The repo
   already has the fakes for it (`ComposerStagingStoreTests.swift` stubs `ImageStager`/`FileStager`), so a
   two-item ordering test and a failure-stops-the-batch test are cheap. Confidence: high (judgement).

## Optional / nits

- `Sources/Heeler/Client/HerdrClientRootView.swift:393` — the `bracketedPaste:` argument is inert for this
  use: `TerminalInputController.requestPaste` (`TerminalInputController.swift:152-156`) writes single-line
  text raw and only uses the flag on the multiline review path. A staged path is always single-line, so the
  whole `TerminalKeyboardControl.usesBracketedPaste` addition buys nothing here. Harmless (a raw path plus a
  space is the correct thing to type either way), but the report's framing oversells it.
- `HerdrMediaStagingStore.swift:118` — `suggestedName` is carried through `MediaIntakeItem.image` and then
  discarded; `DataImageSelection` takes only bytes. Dead payload.
- `HerdrMediaStagingStore.swift:73` — nothing calls `leave()`; on a Host switch (`.id(host.id)`) the old
  media store is simply released mid-upload. `ComposerStagingStore`'s `[weak self]` tasks make this safe, but
  the prepared local file can be orphaned, and `.onDisappear` already exists next door for `store.leave()`.
- `HerdrClientRootView.swift:339` — menu pickers route through `commands.media`, which is weak; with no
  primary client attached, "Attach Photo…" silently does nothing. Not reachable today (the menu only exists
  inside `client(for:)`).
- `MediaIntake.swift:98,112` — neither continuation is cancellation-aware; a provider that never calls back
  hangs the `loadItems` task forever.
- `MediaIntake.classify` treats anything conforming to `public.item` as `.file`, while the drop's `canHandle`
  (`TerminalScreenView.swift:2374`) only accepts `public.image`/`public.file-url`. A dragged document that
  registers only its own type would be refused by the drop but accepted by a paste. Minor inconsistency.
- `fileImporter(allowedContentTypes: [.item])` admits folders and packages; `FilePreparer` rejects them as
  "The selected file is no longer available." (`FilePreparer.swift:87`), which is a misleading message.
  Upstream's importer uses `[.data]`.
- A drop or paste of a provider carrying *both* an image and plain text classifies as `.text`
  (`MediaIntake.swift:33`) and is filtered out of `stageMedia`, so such a drop does nothing at all.
- Staging bar: no VoiceOver announcement on completion, and the bar disappears 2 s later — a screen-reader
  user may never hear that the path was inserted.
- ⌘V release handling: if the user lifts ⌘ before V, the V key-up no longer matches `isPasteShortcut`
  (line 2064) and is forwarded to Ghostty as a release for a press it never saw. The pre-existing zoom
  shortcut has the same shape, so this is consistent rather than new.

## Checked and sound

- Weak `ComposerBridge` (`HerdrMediaStagingStore.swift:18-30`) does break the retain cycle;
  `ComposerStagingStore` holds its composer strongly and the bridge holds the owner weakly.
- `HerdrClientHostView.init` builds `store`, `keyboardControl` and `media` from the same locals, so the
  retained `@State` trio is internally consistent; the `insert` closure retains the store but nothing retains
  the closure's owner back — no cycle, no double-staging across a Host switch (`.id(host.id)` rebuilds all
  three).
- `withObservationTracking` re-arms correctly: `nextStateChange()` registers synchronously inside
  `withCheckedContinuation` on the main actor, the loop re-registers after each change, and a
  cancel/background outcome leaves a non-busy state, so the wait cannot hang on cancellation.
- `canPerformAction(paste:)` reads only `hasStrings`/`hasImages`/`hasURLs` — no pasteboard-content read, no
  paste banner.
- `paste(itemProviders:)` keeps the text-first rule; `paste(_:)` prefers pasteboard text and falls through to
  staging, which is the right answer for a photo copied from Photos (no string item) and acceptable for a
  Safari image copy (URL text wins).
- The dropped/loaded file URL is copied inside the `loadFileRepresentation` closure before it returns, with
  the security scope opened and balanced (`MediaIntake.swift:127-128`).
- `.photosPicker` and `.fileImporter` sit on the root `ZStack` chain, not inside the `Menu` label overlay, so
  presentation is from a view that is always in the hierarchy.
- `UIDropInteraction`'s delegate is weak and the vendored Ghostty package installs no competing drop
  interaction, so `installMediaDrop()` neither leaks nor conflicts.
- Swift 6: new types are `@MainActor`; `MediaIntakeItem` is `Sendable` (`ImageSelection` is a `Sendable`
  protocol); `copyIntoIntakeDirectory` is correctly `nonisolated`; no force unwraps or `try!` added.
- `Heeler.xcodeproj/project.pbxproj`: `MediaIntake.swift` and `HerdrMediaStagingStore.swift` are in the app
  target's Sources and the Client group; `MediaIntakeTests.swift` is in the test target. Correct.
- CHANGELOG entry is under `[Unreleased]` → Added, matches the specced wording verbatim, and carries the
  `(Kelpie)` marker.
