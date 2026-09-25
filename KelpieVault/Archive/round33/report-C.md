# Round 33 — Builder C report (plugin and build group, dependency watch)

Branch `round33-C`, worktree `$SP/wt-C`.

## Part 1 — cherry-picks

1. `84c30cf8` devicectl JSON discovery — **picked** as `5cf52018`. Conflict in `Makefile` device discovery: took upstream's `find-ios-device.py` and kept Kelpie's fallback (0396c09a): when no iPhone is found, `DEVICE` falls back to the first physical iPad via the same script. Message amended with that line. `python3 scripts/test-find-ios-device.py`: 5/5 OK. `make -n install` expands (picked the paired iPhone); a stub devicectl with only a physical iPad made `make -n install` target the iPad. `scripts/device-tests.sh` still parses the devicectl table (not in scope, untouched).
2. `912b007b` configurable pairing SSH port — **picked** as `971964aa`. Conflict only in `CHANGELOG.md`: added the #355 entry under Kelpie [Unreleased] / Added (dropped unrelated upstream #325/#349/0.1.9 context in the hunk). `npm test` 327/327 (fresh worktree needed `npm ci` in `plugin/` first).
3. `1cf22db5` report an unhonorable pair.json — **picked** clean as `9741f48e`. `npm test` 330/330.
4. `d30c60b2` Tailscale SSH warning — **picked** clean as `47ed5078`. `npm test` 343/343.
5. `9e736ae8` pair.json edit reaches the open checklist — **picked** clean as `a439db07`. `npm test` 344 pass, 5 fail — all five `spawnSync ... ETIMEDOUT` in subprocess tests (pair-accept, sidebar hook process boundary) while the Mac load average was 36 (other builders compiling); re-run below.
   Re-run of `pair-accept` and `sidebar-hook` alone at the next commit: 19/19.
6. `910b0d1f` warn only for addresses tailscaled answers for — **picked** clean as `cfdf1471`. `npm test` 351/351.
7. `3428640f` plugin release 0.5.0 — **picked** clean as `b9d53895`. Version chosen: **0.5.0**. Kelpie never moved its plugin off 0.4.0 (the manifest and `package.json` both read 0.4.0 before this round), so upstream's 0.5.0 is strictly greater and keeps the README's "Starting with plugin 0.5.0" line true. Caveat: Kelpie's 0.5.0 is not byte-identical to upstream's 0.5.0 (Kelpie's relay URL, foreground lease, device-entry replacement). As in upstream, the sidebar-hook version test fails between this commit and the next.
8. `88413185` test follows manifest to 0.5.0 — **picked** clean as `2867ce0f`. `npm test` 351/351. (`package-lock.json` still says 0.4.0, as upstream left it.)
9. `41c2d417` anchor the bump parse — **picked** as `9f1eec0c`. Conflict in `Makefile` `bump:` against Kelpie's `14f3e652` fix (`/CURRENT_PROJECT_VERSION: "/`). Upstream's side is a superset (anchored parse, integer guard, all-targets rewrite check), so took it; Kelpie's trailing `$(MAKE) generate` block and the `distribute`/`review-state` targets above it are kept. Verified by running `make bump` on a temp copy of Makefile + project.yml (generate stubbed): 5 -> 6 in all three targets, no error.
10. `d6e9a998` skip container/VM bridges — **picked** clean as `57799f02`. `npm test` 352/352.
11. `a305fddd` demote Docker addresses — **picked** as `9c91df08`. Conflict only in `CHANGELOG.md`: upstream rewrote a #356 entry Kelpie never had (`d6e9a998` carried no CHANGELOG change), so its new #357 text went in as a new bullet under Kelpie's `[Unreleased]` / `### Fixed`. `npm test` 355/355.

Shared vectors in `plugin/test-vectors/`: **unchanged** by all eleven picks. Kelpie plugin changes (relay URL in notification-config.js, foreground lease, BadDeviceToken prune) are in files no pick touched.

## Part 2 — dependency watch

`e1517868` depwatch: heeler-upstream reports unreviewed upstream commits, not a rebase (Open item 55).

- New `scripts/heeler-upstream-reviewed`: `53b1c6ae07bfc3c29f5844546cd02779c7816241` plus `#` comment lines.
- `scripts/depwatch.py`: `check_heeler_upstream` now fetches, reads the reviewed file, runs `git log --no-merges --name-only <reviewed>..upstream/main`, and builds the finding in a new pure `upstream_finding()` (helpers `parse_reviewed_file`, `parse_upstream_log`, `touches_kelpie_paths`, `KELPIE_RUN_PATHS`, `REVIEWED_FILE`). `upstream_severity(total, kelpie_count)`: info at 0, low with only Console/docs, medium from 1 in Kelpie paths, high from 10. Headline `N upstream commits to review (M in paths Kelpie runs)` / `no upstream commits to review`. Actions: review for `git cherry-pick -x`, then move the recorded sha forward. Fingerprint `<reviewed>..<head>`, so moving the file forward is a new finding. Missing/malformed file, or a sha git cannot range from, is a medium finding with a fix action, not a crash. Removed `dry_run_rebase` and the unused `HEELER_REPO` constant (it only fed the upstream release line, dropped with the rebase framing).
- Tests (`scripts/depwatch_test.py`, run by `scripts/test-depwatch.sh`): new `HeelerUpstreamTests` (nothing new, only Console, path-matching incl. `Makefile` exact vs `Makefile.bak`, high at 10, reviewed-file parsing, missing/malformed reported, committed file parses) and a rewritten `test_upstream_severities`. 51 tests: 49 pass, **2 fail, both pre-existing on `kelpie`** (confirmed in a throwaway worktree of `kelpie`): `SchemaDriftTests.test_snapshot_shape_matches_the_documented_counts` (103 != 102) and `CrossReferenceTests.test_real_sources_declare_the_eighteen_methods` (19 != 18) — the tests lag the 0.9.1 schema snapshot and the sources; out of scope, not touched.
- Against real git: with the recorded sha, `info` / "no upstream commits to review"; with `b384847` as the base, `high` / "114 upstream commits to review (63 in paths Kelpie runs)".
- Docs: `docs/guides/dependency-watch.md` (table row and the `heeler-upstream` section rewritten for cherry-picks) and the prose paragraph of `KelpieVault/Dependency watch.md` (outside the depwatch markers; the generated block still shows the old rebase finding until the next run).

## Left, unsure, and what the orchestrator should look at

- Nothing left in the spec. No xcodebuild needed; no Swift touched.
- `package-lock.json` still reads 0.4.0 for the plugin (upstream left it too).
- Kelpie's plugin now calls itself 0.5.0 while differing from upstream's 0.5.0.
- `scripts/device-tests.sh` still parses the devicectl table, unlike `make install` now; not in scope.
- `plugin/node_modules` exists in the worktree (from `npm ci`); it is gitignored.
- Tests to look at: `cd plugin && npm test` (355/355 at `9c91df08`), `python3 scripts/test-find-ios-device.py` (5/5), `sh scripts/test-depwatch.sh` (2 pre-existing failures above). Under heavy Mac load, subprocess plugin tests can time out (`spawnSync ETIMEDOUT`); re-run before reading them as red.
