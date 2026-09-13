# Review — Open item 28, taps land on herdr's own client

Review only; no build, no tests run, no edits.

## Correctness

### must-fix

**`Sources/Heeler/Client/HerdrClientRootView.swift:339`** — the
`consoleRequestGeneration` guard abandons the presentation *after*
`prepareForConsole()` (line 334) has already torn the Attach down, and nothing
puts it back.

`prepareForConsole` calls `store.setPresented(false)` + `store.leave()`
(`HerdrClientRootView.swift:641-643`), so the store ends in `lifecycleState ==
.left` with `isPresented == false` while the client view is still on screen.
The recovery routes all fail in that exact state:

- `HerdrClientHostView`'s `.onChange(of: isShowingConsole)`
  (`HerdrClientRootView.swift:739-741`) never fires — `isShowingConsole` went
  `false → false`.
- `HerdrClientStore.needsRejoin` (`HerdrClientStore.swift`, `case .left:
  isOnStage()`) is **false**, because `isOnStage()` returns `isPresented`,
  which the hand-off set to false. So the S3 self-heal does not see it.
- The floating menu's Reconnect → `HerdrClientStore.reconnect()` falls through
  `needsRejoin` and then `guard lifecycleState == .active, isOnStage()` →
  returns. Dead.

Result: a frozen last frame, no spinner, no message, no Reconnect (the exact
S3 dead end the `needsRejoin` doc comment describes), until the user opens and
closes the Console cover again or switches Host.

Reachable in precisely the scenario the guard was written for: tap "Agents",
then tap a notification/banner within the ≤4 s hand-off window, for the Host
already on screen (a tap that *switches* Host is safe — `.id(host.id)` rebuilds
the store). Narrow but not exotic: the hand-off window is up to four seconds
and a notification banner is the likeliest thing to arrive in it.

Fix direction: on the abandoned branch, restore the client's presentation
(`commands.store?.setPresented(true)` / an explicit rejoin) rather than bare
`return`.

Confidence: high on the mechanism (read all four guards), medium on frequency.

### should-fix

**`Sources/Heeler/Client/HerdrClientNotices.swift:66-80` /
`HerdrClientRootView.swift:265`** — `requestsConsole` now has no writer: both
`post` call sites pass `presentingConsole: false`
(`AgentNotificationCenterDelegate.swift:107-108`,
`HerdrClientRootView.swift:341`). Leaving it is safe today (the only reader is
the dead `.onChange` at 265, plus `dismiss()`/`consoleWasPresented()`), but it
carries a latent trap: if anything ever posts with `presentingConsole: true`
and the generation guard abandons that presentation, `consoleWasPresented()`
is skipped, `requestsConsole` stays `true`, and every later
`presentingConsole: true` post is `true → true` — not a change — so the cover
is never presented again from a notice for the rest of the session. Either
delete the flag and its `onChange`, or clear it in the abandoned branch.

Also stale doc: `HerdrClientNotices.swift:7-21` and `:66-69` still describe
`AgentNotificationRouter.open(nil)` and "the root presents the cover on this,
then renders `notice` over it", which is no longer how the unreadable tap
behaves. Confidence: high.

### nits

- `HerdrClientRootView.swift:272` / `:84` — `landing` is never cleared, and
  the `.onChange(..., initial: true)` lives inside the `if let host` branch.
  Deleting every Host and adding one back re-enters that branch and re-fires
  `landOnClient` with a stale tap (re-selecting a Host, lowering the cover).
  Harmless; "retained until consumed" is in practice "retained forever".
- `HerdrClientRootView.swift:178` — the root `noticeStrip` overlay is applied
  inside `client(for:)`, so with zero Hosts (the Welcome branch) an
  unreadable-notification notice has nowhere to draw. Very edge; a push needs
  a paired Host.

## What checks out

- (a) Cold launch: `initial: true` on `landing` covers both orderings — a tap
  recorded before first render is read initially, a later tap arrives as a
  change. `sequence` makes repeat taps for one Host distinct `Landing` values,
  so a repeat tap still lowers the cover; the initial read of `nil` correctly
  no-ops.
- (b) Cover lowering and root-level sheet/settings/tip-jar/setup dismissal are
  all in `landOnClient` (`:286-295`); the Console's own internal sheets go down
  with the cover's subtree. The guard cannot leave the cover un-presentable
  from the menu: `isPreparingConsole = false` is set *before* the guard
  (`:335`), so `presentConsole()`'s entry guard stays clean. (The cost is the
  must-fix above, which is about the client, not the cover.)
- (c) `PrimaryHostStore.land(onHostID:in:)` (`PrimaryHostStore.swift:44-48`)
  is a catalog-membership guard plus `select(hostID)` verbatim — the same call
  the menu's Switch Host makes (`HerdrClientRootView.swift:429`), so the
  `kelpie.primary-host` persistence is identical. Unknown Host returns false
  and touches nothing.
- (d) A tap that switches Host goes through the same `primaryHost.select` →
  `.id(host.id)` rebuild → old view `onDisappear { store.leave() }` / new view
  `onAppear { store.rejoin() }` path as Switch Host. Different Hosts are
  different Transports, so no orphaned Attach; no new race introduced here.
- (f) The root banner landing on the client rather than the Console follows
  from the ask ("notifications and the Live Activity open herdr's own
  screen") — it is the foreground rendering of the same push, and routing it
  differently from the notification itself would be the inconsistency. It does
  remove the foreground banner's only route to the Agent detail; that is the
  intended trade, not a regression to revert.
- (g) `Sources/Heeler/Console/ConsoleView.swift:175` still calls
  `notificationRouter.open(banner.target)` — the Console's own banner is
  untouched, as intended.
- (h) Swift 6 isolation is sound: `Landing` is `Equatable, Sendable` with
  immutable `let`s, `landingSequence` is `@ObservationIgnored` on a
  `@MainActor @Observable` class, and the delegate's call hops via
  `Task { @MainActor [router] in … }` as before. `HerdrClientNoticeStore.shared`
  is touched only inside that MainActor task.
- (i) Tests read as compiling: both suites are `@MainActor`, `land`/`landing`
  are internal and `@testable`, `Landing: Equatable` supports the `!=`
  comparison, `makeHost`/`Host.fixture` and `consoleAgent` helpers are
  pre-existing. `cancelPending()` in `land` really does clear `pendingTarget`,
  which is what `aTapDropsAPendingConsoleTarget` asserts.
- Pane id: carried in the link (`AgentActivityLink.agentURL`), dropped at both
  landing sites with one comment each, as specified.
- CHANGELOG entry present and user-facing.

## Not checked

- No compile or test run (review-only brief); the builder reports
  `swiftc -parse` clean over the edited files.
- Cover lowering, sheet closing and the actual cold-launch tap ordering are
  view state / runtime behaviour with no unit coverage — the builder flags the
  same gap. The must-fix above was derived by reading the store's guards, not
  observed on device.
- Nothing under `Sources/Heeler/Transport` or the EventsSession tests (another
  task's).
