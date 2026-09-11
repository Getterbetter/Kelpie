# Rebase recon: kelpie onto upstream/main

Base (merge-base): 90e01a9. kelpie tip: 0a0b61c (35 commits). upstream/main tip: 375267c (22 commits, incl. PR #297 muse + PR #307 terminal copy/paste).

## 1. CHANGELOG.md — CONFLICT (real)

- Base at line 7-9: blank line, then `## [Unreleased]`, blank, `### Fixed` (no `### Added` section existed).
- Kelpie (115 insertions): inserts a whole new `## Kelpie` top-level section (Added/Changed) directly above `## [Unreleased]` (before old line 7); *and*, inside `## [Unreleased]`, inserts a new `### Added` section (Welcome screen, media paste/drop, resizing, notifications, Open File on Host, touch selection, long-press drag) and a `### Changed` section, both right after `## [Unreleased]`, before the pre-existing `### Fixed`; then appends several new `### Fixed` bullets after the existing mise/#281 entries (line ~20 onward: pairing QR, option+backspace, drop staging, cmd+arrow, terminal bell, split-view resize).
- Upstream (9 insertions): inserts a new `### Added` section (`@@ -9,2 +9,11 @@`, i.e. immediately after `## [Unreleased]`) with two bullets — muse in Start Agent (#297) and the Direct Input Paste key (#307) — before the existing `### Fixed`.
- **Overlap**: both sides insert a new `### Added` block at the *exact same anchor* (right after `## [Unreleased]`, before `### Fixed`). This is a textual conflict a 3-way merge will flag (same insertion point, different content) — not auto-mergeable.
- Kelpie DID add substantial changelog entries (own `## Kelpie` section plus `[Unreleased]` Added/Changed/Fixed bullets).
- **Resolution**: keep the `## Kelpie` section as-is (upstream has no equivalent, no conflict there); for `## [Unreleased]`, merge the two `### Added` blocks into one (kelpie's bullets followed by or interleaved with upstream's muse/paste-key bullets — order doesn't matter semantically), keep kelpie's `### Changed`, and keep the combined `### Fixed` list (existing mise/#281 entries + kelpie's additions; upstream added none to Fixed).

## 2. CLAUDE.md — CLEAN

- Kelpie (37 insertions): touches only line 1 — prepends the whole `# Kelpie` section (root screen, running-it, build quirks) before the existing `# Heeler` line, ending with "The upstream Heeler guidance follows and still applies."
- Upstream (10 lines, 5+/5-): edits deep in the body — the "Load-bearing herdr facts" intro sentence (old line 13), the API-schema/pane-id bullets (old lines ~18-20, 0.8.2→0.9.0 snapshot numbers), and the events.subscribe/replay bullet (old lines ~34-36, 0.7.5 replay → 0.9.0 live-only subscriptions, `dropPaneSubscriptions`→`dropSnapshotSubscriptions`).
- **Overlap**: none — kelpie's only touch is line 1 (a pure prepend), upstream's edits start at old line 13 and run through old line 38. No shared lines.
- **Resolution** (per brief): keep Kelpie's prepended section unchanged; take upstream's new Heeler-guidance body as-is underneath it. Clean auto-merge.

## 3. Sources/Heeler/Console/AgentTerminalView.swift — CLEAN

- Kelpie (15 insertions): two hunks, both far down the file — a new `.onChange(of: inputMode.isHardwareKeyboardConnected)` handler inserted after line 615 (`armDirectKeyboardClaimIfNeeded()` on hardware-keyboard dock/undock), and a hardware-keyboard early-return branch added inside `armDirectKeyboardClaimIfNeeded()` around old line 1217-1221.
- Upstream (1 insertion): single-line addition at old line 905-909 — adds `paste: { text in keyboardControl.paste(text) },` to the Direct Input chrome's argument list (the #307 paste key cap wiring).
- **Overlap**: none — regions 615/1217-1221 vs 905 don't intersect.
- **Resolution**: both hunks apply independently; straightforward auto-merge.

## 4. Sources/Heeler/Console/HostConsoleProjection.swift — CLEAN

- Kelpie (14 insertions): adds a new `fileDownloader()` method after old line 257 (returns a `HostFileDownloader` closure over `transport.downloadFile`).
- Upstream (4 insertions): adds a doc comment above `publish()` inside the event-subscription reconnect path, around old line 517-520 (explaining 0.9.0 subscribe-ack-before-snapshot ordering).
- **Overlap**: none — 257 vs 517, different methods entirely.
- **Resolution**: clean auto-merge.

## 5. Sources/Heeler/Transport/HeelerSSHTransport.swift — CLEAN but one close pair

- Kelpie (185 insertions/5 deletions... actually 185+/5- per earlier stat, effectively large additions): five hunks —
  1. old line ~287-290: adds `static let downloadTimeout = Duration.seconds(300)` right after `maximumResponseBytes`, immediately below the (unmodified-by-kelpie) `generatedProtocolVersion = 20` line.
  2. old line ~1279 onward (159 new lines): adds the whole `downloadFile(remotePath:progress:)` SFTP implementation.
  3-5. old lines ~2157-2210 (attach-command construction): adds a `.client` case to `AgentAttachTarget`-style target switch — optional-argument handling, `COLORTERM`/`LANG` exports, and a `.client` branch in the attach-command-resolution switch (for "herdr's own client" attach path — ties to the root-screen ADR).
- Upstream (2 insertions/2 deletions): two one-line hunks — `generatedProtocolVersion = 20` → `22` (old line 285, directly above kelpie's hunk-1 insertion point), and `WorkspaceTarget` → `WorkspaceCloseParams` in the `workspace.close` request builder (old line 751, far from all kelpie hunks).
- **Overlap**: no line is touched on both sides. Kelpie's hunk-1 insertion sits immediately *below* upstream's modified `generatedProtocolVersion` line, close enough to be worth flagging, but since kelpie's diff carries that line only as unchanged context (not a change), a 3-way merge applies both without a conflict — upstream's `20`→`22` lands, kelpie's new `downloadTimeout` line inserts right after it. The `workspace.close` param-type rename hunk is nowhere near any kelpie hunk.
- **Resolution**: auto-merges cleanly; worth a sanity build check afterward given the close proximity of hunk 1, but no manual conflict resolution expected.

## 6. Sources/Heeler/Transport/Transport.swift — CLEAN

- Kelpie (80 insertions): two hunks — new `downloadFile` protocol requirement inserted after old line 166 (protocol method list), and a large default-implementation + `HostFileDownloadError` enum block appended after old line 310 (the `extension Transport` default-implementations block, near the end of file).
- Upstream (9+/5-): two hunks — rewrites the `subscribeToEvents` doc comment about 0.7.5 replay vs 0.9.0 live-only subscriptions (old lines 137-142, inside the protocol's `subscribeToEvents` doc block, well above kelpie's line-166 insertion), and adds `case muse` to `SupportedAgentKind` plus its display-name switch (old lines 328/356, inside kelpie's second hunk's *general area* but not overlapping — kelpie's block runs 310→380 as one contiguous insertion of new code, while upstream's `muse` case insertions are at the pre-existing enum around 328/356, which sits *inside* the numeric range kelpie's post-166 insertions push down, but git's line-based 3-way diff still resolves this without conflict since the two sides touch disjoint text).
- **Overlap**: none textually — closest gap is upstream's `subscribeToEvents` doc rewrite ending at old line 142 vs kelpie's protocol-method insertion starting at old line 166 (24-line gap); the `SupportedAgentKind` muse-case hunks are inside the numeric span kelpie's late insertion occupies post-merge but are a separate contiguous block in the base file, not a shared line.
- **Resolution**: clean auto-merge.

## PR #307 overlap (terminal copy/paste)

Files #307 (1703d4e, e9a738d, f8e8f66, dd91de3) touches, net vs base:
- `CHANGELOG.md` (covered above)
- `Sources/Heeler/Console/AgentDirectInputChrome.swift` — new file/heavily edited upstream (paste key cap styling). **Kelpie does not touch this file at all** (`git diff --stat 90e01a9 kelpie -- Sources/Heeler/Console/AgentDirectInputChrome.swift` is empty).
- `Sources/Heeler/Console/AgentTerminalView.swift` — covered above (clean, 1-line upstream addition wiring `paste: { keyboardControl.paste($0) }` into Direct Input chrome).
- `Sources/Heeler/Terminal/TerminalTextSelectionPresenter.swift` — 1703d4e added ~84 lines (auto-copy-on-selection UI); e9a738d reverted those 84 lines. **Net upstream diff vs base on this file is empty** (`git diff 90e01a9 upstream/main -- .../TerminalTextSelectionPresenter.swift` produces no output). Kelpie separately modifies this same file (19 lines: splits `present(_:from:)` into a text/anchorRange-parameter overload, for its own touch-selection overlay to call into the same sheet as a fallback). Since upstream's net change here is nil, there is nothing to conflict with — clean.
- `Tests/HeelerTests/TerminalAttachTests.swift` — added then reverted by #307 (net empty); kelpie doesn't touch it.

Kelpie's own touch-selection files (`TerminalTouchSelection.swift`, `TerminalSelectionOverlayView.swift`) did not exist at the merge base (new-in-kelpie files) and are outside upstream's #307 diff entirely — no file-level collision. Grepping those two files for `UIPasteboard`/`copy(` finds **no copy-on-selection logic in kelpie** — kelpie's overlay gives handles/selection but copy goes through the existing sheet (`TerminalTextSelectionPresenter`) or Cmd+C, not an auto-copy path — so there is no double-up with #307's copy behavior (which upstream itself reverted, net zero anyway).

Kelpie's paste plumbing (`Client/MediaIntake.swift`, `Client/HerdrClientView.swift`) already calls `keyboardControl.paste($0)` from two other call sites — `HerdrClientView.swift:94` and `Console/ShellTerminalView.swift:100` — both pre-existing in kelpie, both using the *same* `keyboardControl.paste` API that upstream's one-line #307 hunk newly wires into `AgentTerminalView`'s Direct Input chrome. So #307 is not introducing a competing paste mechanism; it extends an existing kelpie/base API (`keyboardControl.paste`) to a third console surface. No fight expected — this is additive reuse, not duplication. `AgentDirectInputChrome.swift`'s new Paste key cap (styling layer) is purely upstream and untouched by kelpie, so it should just appear.

**Verdict**: #307 does not meaningfully conflict with or duplicate kelpie's own selection/paste systems. The one file both sides edit for real (`AgentTerminalView.swift`) is a clean, disjoint-region merge, and the one file where #307's net diff would have mattered (`TerminalTextSelectionPresenter.swift`) has zero net upstream change because the auto-copy half of #307 was reverted before reaching `main`.

## herdr 0.9.0 / muse overlap

- Files upstream changed under `Sources/Heeler/Transport/Generated/`: **only `HerdrAPITypes.swift`** (57 insertions/18 deletions, `git diff --stat 90e01a9 upstream/main -- Sources/Heeler/Transport/Generated/`).
- Kelpie touches nothing under that directory (`git diff --stat 90e01a9 kelpie -- Sources/Heeler/Transport/Generated/` is empty) — confirms the brief's expectation.
- `minimumProtocolVersion`: not present in either side's diff of `HeelerSSHTransport.swift` (neither kelpie nor upstream's diffstat/hunks mention it) — only `generatedProtocolVersion` changed, `20`→`22`, upstream-only, at old line 285.
- Kelpie's nearest hunk in that file is its `downloadTimeout` constant insertion starting at old line 287-290 — **immediately adjacent** to (3 lines below) the `generatedProtocolVersion` change, though it does not touch the same line. Confirmed no textual conflict (see file 5 above), but flagged as worth a post-rebase sanity check since the two hunks sit back-to-back in the same small `static let` block.

## project.pbxproj / project.yml

- Kelpie changed both: `Heeler.xcodeproj/project.pbxproj` (143+/43-) and `project.yml` (40+/18-), vs base.
- Upstream changed **neither** (`git diff --stat 90e01a9 upstream/main -- Heeler.xcodeproj/project.pbxproj project.yml` produces no output).
- Since upstream made no project-file changes, there's nothing to reconcile beyond kelpie's own regenerate-with-xcodegen step after the rebase lands (per CLAUDE.md convention) — no conflict, but rerun `xcodegen generate` and commit the regenerated pbxproj as usual since new upstream Swift files (if any were added under Generated/ or elsewhere) would need it reflected.
