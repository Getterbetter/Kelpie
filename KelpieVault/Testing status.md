---
note: What has actually been verified, per feature, and by what means.
---

# Testing status

As of 2026-09-11, with the round-2 Release build installed on Anthony's iPad.

The headline: **no automated test has been executed against round 2.** The XCTest suite compiles but the simulator on this Mac cannot launch a host app ([[Build and deploy#2. The iOS simulator does not run reliably|why]]), and the test target cannot compile for a device destination at all. Round 1 got one lucky iPhone-simulator run out of it; round 2 got none.

Legend: **Device** = seen working on the iPad · **Unit** = executed unit tests · **Compiled** = builds, assertions hand-traced only · **Reviewed** = read line-by-line in a fresh context · **Untested** = nobody has seen it run.

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
| Live Activities and push still alive behind the cover | **Reviewed** | Traced: every store and `.task` stays on `ContentView`. Push itself cannot work at all yet — see [[Heeler upstream]]. |
| Return submitting in the console's Keyboard mode | **Partial fix, unconfirmed** | First-responder claim added; the remaining suspect (UIKit loaning Return to the IME under the agent terminal's `.naturalLanguage` traits) needs a device. |

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

The round-2 build is in his hands with a Magic Keyboard. The list to ask about if he does not raise it himself:

- trackpad two-finger scroll inside a pane
- trackpad right-click opening herdr's menu
- one-finger long-press as a right click
- tapping a URL (especially one that ends a line, which is what the grid-width fix was for)
- the keyboard pad appearing when the Magic Keyboard is detached
- Ctrl+B prefix
- the floating menu and the Agents cover
- whether Return submits in the old console's Keyboard mode

Record what comes back in [[Feedback log]] before acting on it. Anything still unverified stays in [[Open items]].

## Build results on record

- iPad-simulator build, round 1 final tree: `BUILD SUCCEEDED`.
- iPad-simulator build, round 2 final tree and again after the review fixes: `BUILD SUCCEEDED`, zero new warnings. (Two `SettingsView.swift` actor-isolation warnings and one `TerminalAgentSwitcher.swift` Sendable warning are pre-existing, in files neither round touched.)
- Test-target compile for the simulator: `TEST BUILD SUCCEEDED` — every suite, including the four added or updated in round 2, builds into `Kelpie.app/PlugIns/HeelerTests.xctest`.
- Device Release build: succeeded, installed, launched.

**Worth re-running** `-only-testing:HeelerTests` on `platform=iOS Simulator,name=iPhone 17` on any machine whose CoreSimulator can install an app. Every suite is platform-independent logic, so no result should differ.

Source: [[Archive/round1/notes|round 1 notes]] · [[Archive/round1/verify-notes|the verification attempt]] · [[Archive/round2/notes|round 2 notes]] · [[Archive/round1/review|round 1 review]] · [[Archive/round2/review|round 2 review]]
