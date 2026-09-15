---
note: What has actually been verified, per feature, and by what means.
---

# Testing status

As of 2026-09-12, eleven rounds in, with 1.0 submitted for App Review and a TestFlight public beta live on build 2.

The headline through rounds 1 to 9 was that **no automated test could be executed at all**: the simulator on this Mac cannot launch a host app ([[Build and deploy#2. The iOS simulator does not run reliably|why]]), and the test target cannot compile for a device destination. That changed on **2026-09-12**, when round 10's first pull request into `kelpie` turned GitHub Actions on for the fork and the whole suite ran there. The Mac's own simulator still does not run, and that has not changed.

Legend: **Device** = seen working on the iPad · **CI** = executed in GitHub Actions on the fork · **Unit** = executed unit tests locally · **Compiled** = builds, assertions hand-traced only · **Reviewed** = read line-by-line in a fresh context · **Untested** = nobody has seen it run.

## Round 16 — the rebase onto Heeler v0.1.8 (2026-09-15)

| Check | Means | Result |
| --- | --- | --- |
| Release build, `generic/platform=iOS`, and the Debug test target | Compiled | Clean at every step: after the re-vendor, after the rebase, after each review fix. |
| Wire types against the committed schema | Unit (`--check`) | Up to date. |
| `HeelerTests` | Unit | Anthony ran the unit tests himself on the rebased build: "my unit tests passed" (count not recorded). |
| Conflict resolutions | Reviewed | Three fresh-context Opus reviews (`Archive/round16/review-1.md` to `review-3.md`): Console and root, taps and hardware keys, the pairing-sync port and CI. Seven findings taken and rebuilt; the 47 rebase stops the first builder did not log were not individually reviewed. |
| Install and launch | Device | Release build installed and launched on the iPad and the iPhone twice (before and after the fixes). No feature exercised yet: Open item 33 is Anthony's checklist. |
| CI on the fork | CI | Runs on the next pull request; the force push itself does not trigger it. |

## Rounds 3 to 11 — what the device has actually seen

Anthony tests on his 11-inch iPad Pro with a Magic Keyboard — and, since round 11, on his iPhone 16 Pro Max as well — one build per round. The verbatim reports are in [[Feedback log]]; this is the ledger.

### Confirmed on the device

| Feature | Round | Notes |
| --- | --- | --- |
| Escape and Cmd+. reaching herdr | 3b | "escape works, thank you." The first round-3 build failed; `b54a6c3` fixed it the same day. |
| Option+Backspace deleting a word | 3 | Confirmed; Option+arrows were not called out separately. |
| The labelled host capsule, Switch Host and Hosts | 3 | "great stuff". |
| The Welcome screen | 3b | Seen through Setup Guide in the Kelpie menu. "Looks good." |
| Photos and files by copy and paste, and Attach from the menu | 4 | "Media works for copy and paste. Attaching from the menu works." |
| Clipboard out, herdr text into other iPad apps | 4 | Gap closed with no code. |
| Split View | 5 | "Split view works well." The four-orientation fix is what did it. |
| Touch selection handles, dragged | 6b | The first build lost the selection on handle touch; fixed. |
| Selection staying inside the pane | 6b | "The ring works and the selection stays in the pane now." |
| Hold-then-drag resizing herdr's sidebar by touch | 6 | Seen working on the second try, with the trace on. |
| The 64 pt hold ring | 6c | "the ring is good." |
| Return submitting on the **on-screen** keyboard in a shell pane | 9 | 2026-09-12. This closes [[Open items]] 3, open since round 2. |
| The tip sheet listing all three tips | 9 | The earlier capture that showed only Medium and Large was wrong, not the app. |
| Trackpad right-click reaching herdr | 9 | "right-click is working again", after `c23b766`. See below. |
| The iPhone build running herdr's own TUI | 11 | Built and installed on his iPhone 16 Pro Max: "ios version works". The only fault he found was the Kelpie capsule overlapping herdr's mobile header, fixed the same day (`68bc332`) and not re-checked. |

### Not confirmed on the device

| Feature | Round | Why it is still open |
| --- | --- | --- |
| Drag and drop from Files onto the terminal | 4 fixed in 5 | Reported broken in round 4 ("the item just disappears"), fixed in `4480834`, never re-tried. [[Open items]] 1f. |
| Cmd+←/→/↑/↓ as Home/End/Page keys | 5 | [[Open items]] 1f. |
| The bell haptic (`printf '\a'`) | 5 | [[Open items]] 1f. |
| Tapping a file path, Quick Look and share | 5 | [[Open items]] 1f. |
| herdr's desktop notifications | 5 | Gated on `ui.toast.delivery = "terminal"` in the mini's herdr config. |
| The font stepping down as the window narrows | 5 | [[Open items]] 1f. |
| The Welcome root with zero Hosts | 3b | Only the sheet has been seen; the no-Host root needs the Host removed first. [[Open items]] 1b. |
| Paste Pairing Code from the Welcome screen | 3b | Pairing itself is confirmed (round 2, pasted code); this particular entry point is not. |
| The QR scanner | 3b | Deliberate: he will not test it. [[Open items]] 1c. |
| The round-7 nit fixes | 7 | Press-lift on the capsule and padding taps not opening links. Reviewed, never seen by hand. |
| A real push notification arriving on the iPad | 8 | The relay pipeline was verified end to end with a hand-run hook; a delivery to the device has not been watched. |
| A test tip purchase | 7c | The three tips are listed in Settings; nobody has bought one on the device. |
| The keyboard chip row | 9 | `a756361`, built after the round-9 feedback. Superseded unseen: round 11's key bar replaced it. |
| The key bar's look and feel, and sticky ctrl then b reaching herdr | 11 | `4beeecd`. Anthony's verdict is the point of the check. [[Open items]] 12. |
| Paste of a photo from the key bar's `UIPasteControl` | 11 | [[Open items]] 12. The control is the system one, so it should need no clipboard prompt — unwitnessed. |
| Two-device pairing sync | 11 | [[Open items]] 11: pair nothing on the iPhone, open it, and the Host should be there and connect; then a notification to each device. The code is covered by unit tests, the ceremony by nobody. |
| The phone in portrait | 11 | Only the landscape screenshot has been seen. [[Open items]] 10, with the iPhone screenshots for a 1.1 listing. |
| The capsule in its new bottom-trailing corner on a phone | 11 | `68bc332` went in from the screenshot; the fix itself has not been seen. |

### Round 12b — run on the iPad over Wi-Fi

171 tests in 7 suites passed on the iPad (`PairingSyncRecordTests`, `PairingSyncReconcileTests`, `NotificationPreferencesStoreTests`, `TerminalInputControllerTests`, `TerminalTextSafetyTests`, `TerminalTextRewriteTests`, `TerminalAttachTests`) before the robustness fixes landed. Swift Testing suites need their struct names in `-only-testing`; the XCTest "Executed N tests" line ignores them.

### Round 12c — compiled, not run

The robustness fixes (about 90 new tests across notifications, pairing, hosts, client, transport, terminal) compile for a generic iOS device; the full-suite device run was blocked by both devices being locked. First thing next session: unlock both, run `HeelerTests` on the iPad, install and launch with the key trace, then the device checklist in [[Open items]] (double-space in a Claude pane, scroll-to-dismiss, the Tailscale switch with the fingerprint carry-over, the foreground banner, a background push on the TestFlight build).

### Round 12 — compiled, not run

Pairing sync carrying Host edits: app and test targets build for `generic/platform=iOS`; the seven new `PairingSync` tests (coordinate adoption, older/equal records losing, local edit after adoption, unstamped Host, rename not outranking an address, overlapping reconciles coalescing) have never executed — no device was connected and the simulator is off limits. The close-out guard and the Reddit watch were exercised for real (negative cases, dry runs, a seeded state).

### Round 14b — the full suite on the iPad, 2026-09-13 afternoon

`173b356` over Wi-Fi: 1809 tests in 169 suites, 7 issues — the six known source-reading tests, plus `ContentViewActivityDriverTests.backgroundingPastTheGracePeriodSuspendsTheConsoleConnection`, a 5 s poll that passed on the targeted rerun (36 tests in `ContentViewActivityDriver`, `AppForegroundRecovery`, `AppActivityCoordinator`). The three new `EventsSessionTerminalChannelTests` (path change, keepalive failure and healthy end), `HerdrClientStoreTests.anAbandonedHandoffPutsTheClientBackOnStage`, `PrimaryHostStoreTests` and `AgentNotificationRouterTests` pass on the iPad. The HeelerSSH package suites could not run: device destinations refuse tool-hosted tests and the simulator wedged, so `abandonReturnsWhileTheOperationMutexIsHeld` waits for CI. Release 1.0 (3) installed on both devices and relaunched with `-kelpie.connection-trace YES`. Device-confirmed by Anthony today: Open item 24 (tap-to-dismiss on the iPhone), Open item 26 (the Live Activity shows), Open item 20 (a) and (h). Still his: 22 off Wi-Fi with this build, 28 (a notification or activity tap lands on herdr's screen), 20 (g), 20 (f) on a TestFlight install, 23 in a fresh Claude Code session.

### Round 14 — the full suite on the iPad again, 2026-09-13

`f58cae8` over Wi-Fi: 1798 tests in 169 suites, 8 issues, all known from round 13 — the six source-reading tests (`HeelerSSH source policy` ×3, `License notice inventory` ×3) that cannot run on hardware, and `AgentDirectInput`'s `coldPersistedDirectDoesNotRaiseKeyboard`, a 70 ms inset race that passed on the targeted rerun. The four suites this round touches (`ConnectionTrace`, `TerminalAttach`, `EventsSessionTerminalChannel`, `AgentDirectInput`) ran again on the final tree: 134 tests, none failing. Release 1.0 (3) is installed on the iPad and the iPhone; the iPad was relaunched with `-kelpie.connection-trace YES`, so Anthony's next off-Wi-Fi try writes `Documents/connection-trace.log` (pull: `xcrun devicectl device copy from --device <id> --domain-type appDataContainer --domain-identifier TME.Kelpie --source Documents/connection-trace.log --destination <path>`). Hands-on and his: tap-to-dismiss on the iPhone (Open item 24), the Live Activity with the Host toggle on (26), the Open item 20 leftovers.

### Round 13 — the full suite on the iPad, 2026-09-13

Once unlocked, the iPad ran the whole `HeelerTests` target over Wi-Fi: 1776 tests in 167 suites, 13 issues. Six are tests that read Swift sources and licence files from the repo path on the Mac (`HeelerSSH source policy` ×3, `License notice inventory` ×2, `Acknowledgements route identity`); they cannot run on hardware and CI covers them. Of the seven real ones, one was a product gap (a defeated tombstone blocking the republish of a re-paired Host, fixed in `f8201cc`), one a test race, five harness assumptions about a software keyboard, a foreground scene or the iOS 27 accessibility path. After the fixes the six affected suites (`PairingScanStore`, `PairingSyncReconcile`, `PairingSyncRecord`, `HerdrClientStore`, `AgentDirectInput`, `TerminalStatusDialog`) pass on the iPad: 91 tests. Open item 18 (the pairing-sync tests on a device) is closed by this run. The Release build (`8d9234c` code, i.e. 12c plus nothing) is installed on the iPad and the iPhone with the key trace; the hands-on checks in Open item 20 (b) to (h) are still Anthony's. Anthony confirmed (b) double-space and (c) the iPhone scroll dropping the keyboard; (d) the Tailscale edit synced and Host settings connected, but the root screen spun until Wi-Fi returned — fixed in `cab2da6` (21 tests in `HerdrClientStoreTests` and `EventsSessionTerminalChannelTests` on the iPad), installed as a Release build for his retry. Open item 23 (`8834b2a`): the four link suites, 61 tests, pass on the iPad, including the core reporting an OSC 8 link with title text and a bare URL under the probe; a tap on a real pinned artifact link is still Anthony's to confirm. Anthony on `cab2da6` off Wi-Fi: "hangs on reconnecting" — the state surfaces, the session does not recover (Open item 22). 20(f) cannot pass on an Xcode-signed build: its push entitlement is `development`, so 12c's environment-from-profile correctly registers `sandbox`; a `production` entry needs a TestFlight build with the 12c fix — **build 3 uploaded 2026-09-13**, check after it lands on the iPad.

### The regression lesson, 2026-09-12

Trackpad right-click broke and nobody noticed for three rounds. Round 6's touch-selection `UIEditMenuInteraction` answered every trackpad secondary click itself and cancelled the touch before the right click was reported. Anthony found it on a tab, then: "to confirm, looks like its happening everywhere in the app - we lost functionality meaning we lost functionality and we need better testing."

The vault never held a device confirmation for it. Round 1's table below records it as **Reviewed** only, so it either broke in round 6 or never worked on the device, and no round re-ran the earlier checks. The standing rule from that: **every device build re-runs a fixed regression list of previously confirmed behaviour, not only the new feature.** The list is [[Device regression list]].

## Round 2 — herdr's client as the screen

| Feature | Status | Notes |
| --- | --- | --- |
| App builds, installs and launches on the iPad | **Device** | Release build, `devicectl install` + `process launch`. |
| Pairing with the mini | **Device** | Via the pasted Pairing Code; the QR was not recognised. See [[Pairing and setup]]. |
| herdr's TUI as the root screen | **Device** (launch only) | It runs; the detailed interaction list below is what Anthony is checking now. |
| Attach command strings (`.client`, with and without a session) | **Compiled** + **Reviewed** | Exact-string assertions written and hand-traced character by character; quoting audited (spaces, `"`, `$`, `;`, `&&`, globs inert; `'`, `\`, control chars rejected). |
| `COLORTERM` / `LANG` exports on every target | **Compiled** + **Reviewed** | Parameterised test over all four targets, not executed. |
| `TerminalLinkDetector` | **Unit, natively** | The one thing genuinely run this round: it is pure, so its suite's expectations were compiled and run with `swiftc` against the real source — **20/20 checks pass**, including both span edges, trailing punctuation, the wrapped-URL join, the grid-width gate, the indented no-join, and `ftp:`/`file:`/`javascript:` refusals. |
| URL taps opening on the iPad | **Untested on device** | Detection is verified; the tap-to-`openURL` seam is not. |
| Primary host selection (default, persistence, healing) | **Compiled** + **Reviewed** | |
| Automatic keyboard mode resolution | **Compiled** + **Reviewed** | Tests use a stubbed keyboard-connected flag; `GCKeyboard` itself is untested. |
| Floating menu, Agents cover, deep links | **Reviewed** | The channel-handover race was found and fixed in review (`58199a7`); the fix itself is untested. |
| Live Activities and push still alive behind the cover | **Reviewed** | Traced: every store and `.task` stays on `ContentView`. *Push could not work at all until 2026-09-11, when Kelpie's own relay went up; the pipeline is verified, a delivery to the iPad is not. See [[Heeler upstream]].* |
| Return submitting in the console's Keyboard mode | **Device**, 2026-09-12 | Was "partial fix, unconfirmed" for seven rounds. Anthony confirmed on-screen Return in a shell pane after the round-9 build: "return on the on-screen keyboard works now". |

## Round 1 — iPad input

| Feature | Status | Notes |
| --- | --- | --- |
| Right-button SGR encoding (button 2, press + release, both encodings, nil when tracking is off) | **Unit** | `TerminalMouseReportingTests`, 13 tests, run on an iPhone 17 simulator: `TEST SUCCEEDED`. The only real XCTest run either round produced. |
| Trackpad / mouse right click reaching herdr's menu | **Reviewed** | Traced line by line through Ghostty's `handleIndirectPointerTouches`; the stale-drag-rect hole was found in review and closed by claiming the whole touch sequence. |
| Touch long press as right click | **Reviewed** | Including the suppressed release, and that Ghostty's 0.35 s tap window cannot also fire under a 0.5 s press. |
| Two-finger text selection | **Reviewed** | |
| Trackpad and wheel scrolling | **Reviewed** | Simultaneous-recognition delegate confirmed reachable by compiling a reduced case. |
| Split-view collapse with a terminal open | **Untested** | The reviewer's finding 3 — whether the sidebar toggle is even visible over the terminal's deliberately empty nav bar — has never been seen on an iPad. `AgentEdgeBackGesture` is the escape hatch. |
| Hardware keyboard (Ctrl+B, arrows, Esc, Tab, Cmd+C/V) | **Reviewed** | Read-only pass; nothing in Heeler swallows them. |

## What Anthony is checking right now

The open device checks, in [[Open items]] order. Record what comes back in [[Feedback log]] before acting on it.

**1. Round 3 leftovers.** Option+Backspace deleting one word and only one word · Option+Left/Right jumping words · plain Backspace and Return unchanged. (Escape, Cmd+. and the host capsule are confirmed.) If Option+Backspace deletes a word *plus* a character, the UIKit echo arrived after the press ended; see the note in `scheduleHardwareKeyClaimReset`.

**1f. Round 5 on the device.** Drop from Files · Cmd+←/→/↑/↓ in a shell · tapping a file path in Claude's output, then Quick Look and share · Open File on Host… · the bell haptic (`printf '\a'`) · the font stepping down as the window narrows · a desktop notification, once the `ui.toast.delivery = "terminal"` line is in the mini's config.

**1g. Round 6 on the device.** Double-tap a word, handles appear, drag a handle, then Copy or Cmd+C · long-press the sidebar edge until the translucent ring shows under the finger, then drag · long-press without moving, and herdr's menu on lift.

**1a. Media into herdr.** Copy a photo in Photos, then Cmd+V in a Claude Code pane inside herdr, expecting an upload capsule and a staged path typed into the pane · drag a file from Files in Split View onto the terminal · Attach Photo and Attach File in the Kelpie menu · a paste of plain text still pasting as text. Then ask Claude what is in the image.

**1b. The Welcome screen at the root.** Setup Guide shows it as a sheet; the no-Host root needs the Host removed first. Try Paste Pairing Code with a fresh code from the mini, and the typed field.

Anything still unverified stays in [[Open items]].

## Round 15 — the key bar (2026-09-15)

Device-confirmed by Anthony on the iPad: the capsule look, the `⇧tab` key and the hide-keyboard button ("looks good"). Installed on the iPhone the same hour, not yet looked at there (the row scrolls on the phone; the dismiss button is pinned outside the scroll). Not exercised: Shift+Tab actually cycling a Claude pane's mode, sticky ctrl/alt's new tinted-caption states, Dynamic Type resizing the pill. The test target compiles for the iPad with the two `rows` coverage tests excluding `.shiftTab` and the new `shiftTabEncodesBackTab`; no suite was run on the device this round, CI runs them on the next push.

## Build results on record

**Since 2026-09-12, the whole unit suite runs in GitHub Actions on the fork.** `ci.yml` runs on every pull request into `kelpie` (its `pull_request` trigger has no branch filter, while its `push` trigger is `main`-only and never fires here): a `macos-26` runner, an **iPad Air 11-inch (M4)** simulator, **1648 tests in 155 suites**, the real-SSH fixtures included. That is what [[Open items]] 8, "run the unit suite on any machine", now means in practice. It is answered by CI, not by a local simulator.

Three things had to be true before it worked, all in PR #2: the runner fetches the vendored `GhosttyKit.xcframework` (it is gitignored, and only `make generate` used to fetch it), it boots an iPad rather than the iPhone 17 the upstream gate assumed (Kelpie is device family 2), and the licence-inventory and zoom tests were taught Kelpie's iPad defaults.

**The flakiness caveat.** Getting that PR green took five attempts. Two were the real fixes above; three were transient real-SSH fixture failures with a **different test failing each time**, and upstream's own PR runs show the same pattern. So a red real-SSH run gets one re-run before it counts as a regression.

**Round 11's pairing-sync suite ran on the iPad.** The 22 unit tests covering `PairingSync` and `PairingSyncRecord` execute on the device, which is why the simulator-only integration suite is gated out of a device test build. They cover reconciliation, digests, conflict resolution by `updatedAt` and the pending-key handover — not the two-device ceremony, which no test can stand in for.

**This Mac's simulator still does not run.** Nothing about CI changes that: `xcodebuild test` locally still wedges with "Mach error -308, server died", and the test target still cannot compile for a device destination (`SidebarConsoleIntegrationTests` depends on simulator-only demo code, which is pre-existing upstream). Do not spend time on it.

Older results, kept for the record:

- iPad-simulator build, round 1 final tree: `BUILD SUCCEEDED`.
- iPad-simulator build, round 2 final tree and again after the review fixes: `BUILD SUCCEEDED`, zero new warnings. (Two `SettingsView.swift` actor-isolation warnings and one `TerminalAgentSwitcher.swift` Sendable warning are pre-existing, in files neither round touched.)
- Test-target compile for the simulator: `TEST BUILD SUCCEEDED` — every suite, including the four added or updated in round 2, builds into `Kelpie.app/PlugIns/HeelerTests.xctest`.
- Device Release build: succeeded, installed, launched. Every round from 3 to 9 ended with one.
- `TerminalLinkDetector`'s suite was run natively with `swiftc` in round 2 when nothing else could be: 20/20.

Source: [[Archive/round1/notes|round 1 notes]] · [[Archive/round1/verify-notes|the verification attempt]] · [[Archive/round2/notes|round 2 notes]] · [[Archive/round1/review|round 1 review]] · [[Archive/round2/review|round 2 review]]
