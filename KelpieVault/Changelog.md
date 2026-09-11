---
note: Every Kelpie commit on branch `kelpie`, oldest first, grouped by round.
---

# Changelog

17 commits on branch `kelpie` on top of upstream Heeler `90e01a9`. Remote `upstream` only; **nothing has ever been pushed**. For the user-facing version of this, see the "Kelpie" section at the top of `CHANGELOG.md` in the repo.

## Fork and rebrand — 2026-09-10

| Commit | |
| --- | --- |
| `9437b1f` | **rebrand: Kelpie identifiers** — team, bundle IDs under `TME.Kelpie`, `PRODUCT_NAME` Kelpie with an explicit `PRODUCT_MODULE_NAME` Heeler, app group `group.TME.Kelpie.shared` in all three entitlements and the one shared Swift constant, device family `"1,2"`, indirect input events on. No Swift logic changed. |
| `0058d3c` | **build: regenerate `Heeler.xcodeproj`** from the rebranded `project.yml`. The build itself could not be run — every `xcodebuild` invocation hung at "Resolve Package Graph". |
| `98cb6b6` | **build: vendor GhosttyTerminal** with a local libghostty binary. Pinned commit `356f730b` under `Packages/GhosttyTerminal`; `scripts/fetch-ghostty-artifact.sh` fetches and checksum-verifies the xcframework, which stays untracked. This is what unblocked the build. |

## Round 1 — iPad pointer, touch and layout — 2026-09-10

| Commit | |
| --- | --- |
| `bb1aece` | **feat(terminal): iPad pointer and touch input reach herdr** — right click from a trackpad or mouse (by nulling `selectionMenuPoint` while the remote tracks the mouse), one-finger long press encoding a button-2 report itself with its release suppressed, two-finger selection sheet, and a scroll-type pan giving trackpad and wheel scrolling. Plus `TerminalMouseReportingTests`. |
| `b1c0fe4` | **feat(console): an open terminal fills the iPad window** — split-view column visibility driven by the router's path; `.detailOnly` with a terminal open on regular width. iPhone unchanged. |
| `b81f3c8` | **docs: record the iPad pointer decisions** — ADR 0016, and the Kelpie section at the top of `CHANGELOG.md`. |
| `aab7149` | **build: point the unit-test host at `Kelpie.app`** — `TEST_HOST` in `project.yml`; XcodeGen derives it from the target name (Heeler) while the product is `Kelpie.app`. |
| `01a7923` | **fix(terminal): own the right-button pointer touch while herdr tracks the mouse** — review fix. Ghostty arms its copy menu on `.began` from a stale drag-selection rect *before* consulting `selectionMenuPoint`, so the click was swallowed entirely. Now the whole right-button sequence is claimed. Also gates the two-finger selection gesture on the remote owning the mouse. |

## Between rounds — 2026-09-11

| Commit | |
| --- | --- |
| `d7ba148` | **docs: Kelpie section in `CLAUDE.md`** — device-only runs and the build quirks. |
| `40c0682` | **build: scheme as Xcode rewrote it** after the first device run. |

## Round 2 — herdr's client is the screen — 2026-09-11

| Commit | |
| --- | --- |
| `454fee5` | **feat(client): attach herdr's own client to a Host** — a `.client(session:)` attach target running `exec herdr` (or `--session "<name>"`, never `--takeover`); `COLORTERM` and `LANG` exported on every attach; `HerdrClientStore` (generation replacement, suspension recovery, explicit leave/rejoin) and the full-screen `HerdrClientView`. |
| `7dba133` | **feat(client): herdr's client is the root screen** — `HerdrClientRootView`, the floating menu, `PrimaryHostStore`, the Agents `fullScreenCover`, notification deep links. Every store the console needs stays on `ContentView`, above the cover. |
| `69d4b32` | **feat(terminal): tapping a URL opens it on the iPad** — `TerminalLinkDetector` resolves the URL under a cell from the viewport text (libghostty has no link-at-point query on iOS), including one wrapped onto the next row; the tap and the primary-button pointer click both open it through `onOpenLink`. |
| `376aa92` | **feat(input): keyboard mode follows the hardware keyboard** — `HardwareKeyboardObserver` over GameController; an `automatic` agent-input preference as the new default; Direct Input also claims first responder while a keyboard is attached. |
| `00ce790` | **docs: record why herdr's client became the screen** — ADR 0017, plus `CHANGELOG.md` and `CLAUDE.md`. |
| `1c4747e` | **test: cover the client attach, link detection and the new defaults** — exact attach strings, `TerminalLinkDetectorTests`, `PrimaryHostStoreTests`, the automatic-mode resolution. |
| `58199a7` | **fix(client): review fixes for the herdr client screen** — six: the foreground banner is drawn at the new root; a wrapped URL is joined only when the match reaches the grid's last column; a pointer press that moves 8 pt is released back to Ghostty so a selection drag starting on a link works; the Agents cover is presented only after the client's channel has actually closed; the client leaves when its screen goes away; `project.yml` names the product Kelpie so a regenerated scheme stops pointing Run and Test at a `Heeler.app` that is never built. |

> Commit trailers name `Co-Authored-By: Claude Opus 5 (1M context)` rather than the specs' `Claude Fable 5.1`, on both rounds — the session's harness attribution instruction supersedes the spec's. `aab7149` is the one exception and carries the spec's line.

Related: [[Kelpie]] · [[Decisions]] · [[Architecture]] · [[Testing status]]
