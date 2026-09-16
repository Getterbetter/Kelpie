# Rebase review 3 — Areas C and D
Worktree /Users/anthonytopalides/Developer/Kelpie-rebase, head f31c4a1, tag kelpie-pre-rebase-20260915.
Read-only. Files read at the commit with `git show`. `Sources/Heeler/Terminal/TerminalScreenView.swift` not read (builder active).

## Area C — pairing sync and notification registration port

Head composition root: `Sources/Heeler/HeelerAppModel.swift` (new, 343 lines), built lazily by
`PushRegistrationDelegate` (`Sources/Heeler/Notifications/PushRegistrationStore.swift:238`), one per process.
`HeelerApp.swift:47` forwards the app-aggregate scene phase to it; `ContentView.swift:93` calls `app.start()`,
guarded once by `isStarted`.

### Wiring table (tag ContentView.swift line → head line)

| Wiring | Tag | Head | Status |
|---|---|---|---|
| `PairingSyncSettings` created | 108–109 | HeelerAppModel.swift:125–126 | present, once per app |
| `PairingSync` created | 110–117 | HeelerAppModel.swift:127–133 | present, once per app |
| `NetworkPathObserver` created | 31 | HeelerAppModel.swift:45 | present |
| reconcile on start | 249–259 (`.task`) | HeelerAppModel.swift:191 (in `start()`) | present; now once per *app* (was once per ContentView) |
| reconcile on scene `.active` | 274–284 | HeelerAppModel.swift:197–207 via HeelerApp.swift:43–48 | present; cadence unchanged for Kelpie's single window, now driven by the aggregate phase |
| reconcile on `hostStore.hosts` | 271–273 | HeelerAppModel.swift:235 | present (merged into the one hosts observer) |
| reconcile on `pairingSyncSettings.isEnabled` | 262–264 | HeelerAppModel.swift:277–280 | present |
| `pairingSync.hostsDidConnect` on connect | 216–221 | HeelerAppModel.swift:268–273 | present |
| `hostsDidConnect` on deviceToken | 238–243 | HeelerAppModel.swift:297–302 | present |
| `notificationPreferences.refresh` + `reregisterChangedDevices` on `hostStatuses` | 203–211 | HeelerAppModel.swift:256–263 | present |
| same on `deviceToken` | 229–237 | HeelerAppModel.swift:289–296 | present |
| `hostWasRemoved` + `hostWasDeleted` on Host removal | 253–257 | HeelerAppModel.swift:186–190 | present |
| `registrationNotes:` on `HostLiveActivityCoordinator` | 103 | HeelerAppModel.swift:120 | present |
| `registrationNotes:` on `PairingSync` | 116 | HeelerAppModel.swift:133 | present |
| `TerminalDesktopNotificationRelay.connect` | 311 | ContentView.swift:145 | present; now per scene (see N1) |
| `.hostKeyConfirmation()` | 151 | ContentView.swift:56 | present |
| `.environment(pairingSyncSettings)` | 147 | ContentView.swift:52 | present |
| `console.setHosts` / `notificationPreferences.setHosts` / `console.resume` | 161–165 | HeelerAppModel.swift:154–158 | present |
| same trio on `hostStore.hosts` | 166–170 | HeelerAppModel.swift:224–236 | present |
| `ConsoleActivityDriver` task | 299–301 | HeelerAppModel.swift:167–169 | present, one consumer per process |
| `pushRegistration.refresh` task | 302 | HeelerAppModel.swift:170 | present |
| `pushRegistration.refresh` on `.active` | 284 | HeelerAppModel.swift:204 | present |
| `networkPaths.run` | 303–307 | HeelerAppModel.swift:171–175 | present |
| `NotificationKeyStore().refreshMirror()` + `liveActivities.start()` | 312–317 | HeelerAppModel.swift:178–179 | present |
| `liveActivities.agentsDidChange` (initial + change) | 175–179 | HeelerAppModel.swift:151–152, 237–240 | present; initial baseline now explicit in `start()` |
| `bannerStore.agentsDidChange` (initial + change) | 175–179 | HeelerAppModel.swift:151, 237–240 | present |
| `notificationRouter.agentsDidChange` initial+change | 175–177 | ContentView.swift:109–112 | present; correctly per scene (the router is per window now) |
| `layoutsDidChange` on rowLayouts / sidebarSnapshots / hosts | 166–185 | HeelerAppModel.swift:228, 241–246 | present |
| `pinsDidChange` | 186–188 | HeelerAppModel.swift:247–249 | present |
| `connectionsDidChange` on hostStatuses / hostsAwaitingSnapshot | 212, 223–225 | HeelerAppModel.swift:264, 281–283 | present |
| `liveActivities.reconcile` on `activity.activationCount` | 226–228 | HeelerAppModel.swift:284–286 | present |
| `activity.didBecomeActive` / `didEnterBackground` | 277, 286 | HeelerAppModel.swift:200, 209 | present |
| `.onOpenURL` → `land(onHostID:)` | 195–198 | ContentView.swift:129–132 | present (per scene, correct) |
| hardware-keyboard → `inputMode` | 154–156 | ContentView.swift:63–65 | present, per scene (see N2) |
| `.preferredColorScheme` | 160 | ContentView.swift:69 | present |

No wiring missing. No store created in both `HeelerAppModel` and `ContentView`: the only `@State` stores left in
`ContentView` are genuinely per-window (`notificationRouter`, `window`, `activation`, `hardwareKeyboard`, `tipJar`).
No duplicated reconcile: the tag's two separate `onChange(of: hostStore.hosts)` blocks are merged into one observer
(HeelerAppModel.swift:224–236), so a Host save still reconciles exactly once.

Swift 6 / concurrency: `HeelerAppModel` is `@MainActor`; `StoreChangeObserver` (HeelerAppModel.swift:320–343) is
`@MainActor` with `@MainActor` closures and re-arms `withObservationTracking` on a main-actor `Task`, so every store
touch stays on the main actor. `withObservationTracking` is registered *before* `onChange` is invoked
(HeelerAppModel.swift:334–341), so a mutation made from inside a handler is not dropped. `Task { [networkPaths,
console] in … }` (HeelerAppModel.swift:171) inherits main-actor isolation, so the non-Sendable captures are legal.
No force unwraps or `try!` introduced in `HeelerAppModel.swift` or `ContentView.swift`.

Not checked: whether the app builds (no builds permitted); `AppModelActivityDriverTests` existence/content;
`AgentSceneDirectory` internals beyond its API surface; `TerminalScreenView.swift`.

### Findings — Area C

N1 (nit, high confidence) `Sources/Heeler/ContentView.swift:145` — `TerminalDesktopNotificationRelay.shared.connect`
runs in a per-scene `.task` while every other app-wide start-up task moved into `HeelerAppModel.start()`.
Harmless today (the relay just stores one weak reference and Kelpie ships one window), but it is the one piece of
app-wide wiring left outside the composition root, so a second window would re-`connect` it.

N2 (nit, medium confidence) `Sources/Heeler/ContentView.swift:63–65` — the per-scene `HardwareKeyboardObserver`
writes the app-wide `app.inputMode`. Single-window Kelpie is unaffected; with two windows two observers would
write the same setting. Same for the per-scene `tipJar` (`ContentView.swift:28`), which is per window rather than
app-wide as its own comment claims ("Owned here with the other client stores").

N3 (nit, medium confidence) `Sources/Heeler/HeelerAppModel.swift:154–158` — the launch `setHosts`/`resume` moved
from a view `.task` into a `Task {}`, so `liveActivities.start()` (line 179) and `pairingSync.reconcile()` (line 191)
now run *before* the Hosts are handed to the Console, where at the tag the two `.task`s raced. Both paths are
no-ops on an empty Console, so behaviour should be unchanged; noted only because the ordering is now deterministic
in the opposite direction from the common tag ordering.

**Area C verdict: sound.** Every tag wiring is present exactly once, at the right cadence, with no duplicate stores,
no main-actor violations and no new force unwraps. Three nits only.

## Area D — CI and plugin

### scripts/run-ci-ios-tests.sh
Kelpie's default survives upstream's new prefix-match selection: `scripts/run-ci-ios-tests.sh:921`
`ci_simulator_name="${HEELER_CI_SIM_MODEL:-iPad Air 11-inch (M4)}"`. Upstream renamed the variable to
`HEELER_CI_SIMULATOR_NAME` and defaulted to `iPhone 17`; the fork kept its own name and default, and the rename
was applied consistently — the local variable `simulator_model` is gone and all three error messages use
`${ci_simulator_name}`. `git grep HEELER_CI_SIMULATOR_NAME` at head returns nothing outside the vault, so no
caller expects the upstream name. The awk matcher `index($0, name " (")` (line 928) is literal, so the
parenthesised model name is safe; `index(...)` without `> 0` is equivalent in awk.
Variable name the workflow passes: the workflow passes **none** (`.github/workflows/ci.yml:135–136` sets only
`HEELER_CI_LANE` and `HEELER_CI_MANDATORY`), so the script's iPad default is what runs. Consistent — the only
mention of `HEELER_CI_SIM_MODEL` in the workflow is the comment at line 126.

### .github/workflows/ci.yml
Byte-identical to the tag (`git diff kelpie-pre-rebase-20260915 f31c4a1 -- .github/workflows/ci.yml` is empty).
`Fetch the pinned libghostty artifact` (line 119–120) runs before `Build and test` (line 129–137) in the
`build-test` job. The second job, `heelerssh-package` (line 148–165), has no fetch step, which is correct:
`scripts/run-ci-ios-tests.sh:84` notes package-lane builds have no remote SwiftPM deps and never touch
`GhosttyTerminal`. The iPad boot happens inside the script from the default above.

### Makefile
Kelpie's own settings survived: `APP_ID := TME.Kelpie` (line 12), `SIM ?= iPad Air 11-inch (M4)` (line 13),
`generate` runs `./scripts/fetch-ghostty-artifact.sh` before `xcodegen generate` (lines 36–38), and the fork's
`depwatch`, `hooks` and `closeout-check` targets are all present at the tail. Upstream's new
`build-device`, `install-ipad`, `test-ipad`, `sim-ipad`, `check-device-ipad` targets are adopted and all are in
`.PHONY`. `install-ipad` correctly re-enters `install` with `DEVICE="$(DEVICE_IPAD)"`, which satisfies
`check-device`.
(Checked and dismissed: `build-device` omits `-clonedSourcePackagesDirPath`, but so did the tag's `build`, which
`install` depended on — not a rebase regression.)

### project.yml
`TARGETED_DEVICE_FAMILY: "1,2"` on all four targets (lines 124, 194, 242, 292); `MARKETING_VERSION: "1.0"` and
`CURRENT_PROJECT_VERSION: "3"` on app, notification service and widgets (107–108, 191–192, 239–240);
`bundleIdPrefix: TME.Kelpie` (line 3) with `TME.Kelpie`, `.NotificationService`, `.Widgets`, `.tests`, `.uitests`
and the `group.TME.Kelpie.shared` app group; `GhosttyTerminal: path: Packages/GhosttyTerminal` (lines 30–31),
no `url:` anywhere. The new `info:` block (lines 66–83) and the committed
`Sources/Heeler/Info.plist` agree — both carry `UIApplicationSupportsMultipleScenes false`, the
`$(MARKETING_VERSION)`/`$(CURRENT_PROJECT_VERSION)` passthroughs, and `NSUserActivityTypes:
dev.bybee.heeler.agent`, which matches `AgentRoute.activityType` (`Sources/Heeler/Notifications/AgentRoute.swift:13`).
`Heeler.xcodeproj/project.pbxproj` carries `INFOPLIST_FILE = Sources/Heeler/Info.plist` (2 configurations), so the
project was regenerated and committed as CLAUDE.md requires.

### plugin/src/pair-popup.js
Kelpie's QR clamp fix is present as the exported `clampPairingScreen({qrLines, textLines, rows})`
(`plugin/src/pair-popup.js:106–119`), called at line 138, and it keeps the "notice, never a cut QR" behaviour.
It coexists with upstream's changes: the `pair-fatal.js` import, `holdFatal`/`paintFatal`, and the
hide/show-cursor handling are all carried. The export needed the entrypoint guard at lines 510–514
(`import.meta.url === pathToFileURL(process.argv[1]).href`), which is present, so importing the module in a test
does not start the ceremony.
`npm test` still covers it: `plugin/package.json:12` is `"test": "node --test"` (default discovery over
`plugin/test/**/*.test.js`), and `plugin/test/pair-popup-clamp.test.js` imports `clampPairingScreen` and asserts
six cases including the two truncation paths. `.github/workflows/ci-node.yml` runs `npm test` in `plugin` on
`plugin/**` changes.

### CLAUDE.md
`diff` of everything above "The upstream Heeler guidance follows" between tag and head shows exactly one changed
line — line 21, the `KELPIE-PATCHES.md` sentence, replaced by the "no local patch; upstreamed at 7e45d27" wording.
Nothing else differs. The claim is true at head: `Packages/GhosttyTerminal/KELPIE-PATCHES.md` is absent from the
tree, and `project.yml:22–29` records the same 7e45d27 / `sendMousePos` rationale.

### .githooks/pre-push and scripts/check-round-closeout.sh
`git diff kelpie-pre-rebase-20260915 f31c4a1` over both paths is empty. Unchanged.

### Findings — Area D

D1 (should-fix, medium confidence) `Makefile:19` — `DEVICE ?=` now filters devicectl output with
`/iPhone.*physical/`, where the tag matched the first physical device of any kind. On a Mac with only the iPad
paired, `make install` now prints "No physical device found" instead of installing to the iPad, and on a Mac with
both it silently prefers the iPhone. CLAUDE.md names the 11-inch iPad Pro as the run target, so the fork's
shorthand now points at the wrong device; `make install-ipad` is the replacement but nothing says so outside
`make help`. Either re-broaden `DEVICE` for the fork or record the new target name in
`KelpieVault/Build and deploy.md` (which today documents only the raw xcodebuild/devicectl recipe, so nothing in
the vault is currently wrong — that is why this is should-fix and not must-fix).

D2 (nit, high confidence) `Makefile:14` — `SIM_IPAD ?= iPad Pro 13-inch (M5)` is upstream's model, not the fork's
`iPad Air 11-inch (M4)`, so `make test-ipad` / `make sim-ipad` ask for a simulator the fork does not otherwise
name. Moot in practice (CLAUDE.md says the simulator does not run on this Mac), but the two iPad defaults now
disagree.

Not checked: that the macos-26 runner image actually carries an `iPad Air 11-inch (M4)` device (unchanged from the
tag, and unverifiable without a run); that `npm test` passes (no runs permitted); the generated
`Heeler.xcodeproj` beyond the `INFOPLIST_FILE` setting.

**Area D verdict: sound.** Every fork-specific CI, Makefile, project.yml, plugin and doc carry-over survived the
rebase intact, the simulator-model override was correctly re-pointed onto upstream's renamed variable, and the
hooks and close-out script are untouched. Two Makefile device-default nits, no must-fix.
