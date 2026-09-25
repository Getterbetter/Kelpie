# Round 33 — rules every builder follows

Round 33 (2026-09-25) builds Open item 55 (Kelpie is a hard fork since round 32 and takes upstream Heeler's fixes by `git cherry-pick -x`, never by rebase) and Open items 49, 53 and 52. Four builders work in parallel, each in its own git worktree; the orchestrator integrates their branches onto `kelpie` afterwards. Read `CLAUDE.md` at the repo root first (the load-bearing herdr facts and conventions still apply).

Paths:

- Main checkout: `/Users/anthonytopalides/Developer/Kelpie` (branch `kelpie`). **Do not edit, check out, stash, rebase or commit anything in it**, except writing your report file under `KelpieVault/Archive/round33/`. Never push anywhere.
- Scratchpad: `SP=/private/tmp/claude-501/-Users-anthonytopalides-Developer-Kelpie/2d9637df-511d-4b7e-b3d0-e029a1dd4bde/scratchpad`.
- Your worktree: `git -C /Users/anthonytopalides/Developer/Kelpie worktree add $SP/wt-<X> -b round33-<X> kelpie` (your letter is in your brief). All your commits go on `round33-<X>` there.
- Upstream is the `upstream` remote, already fetched. `upstream/main` holds the commits you pick.

Cherry-picking:

- `git cherry-pick -x <sha>` one commit at a time, in the order your brief gives (it is upstream's topological order). Resolve every conflict so **Kelpie's behaviour survives and upstream's fix lands**; read Kelpie's commits on the conflicting file (`git log b384847..kelpie -- <file>`) before resolving. Never resolve by taking one side wholesale unless that side is provably a superset.
- `CHANGELOG.md`: upstream's entries go under Kelpie's `## [Unreleased]` section (the headings `### Added` / `### Changed` / `### Fixed` exist there), as upstream wrote them. Leave the `## Kelpie` section alone.
- `Heeler.xcodeproj/project.pbxproj`: never hand-merge. Take Kelpie's side, then `xcodegen generate` in the worktree and include the regenerated project in the commit.
- `scripts/run-ci-ios-tests.sh` asserts executed test counts per CI lane. Merge by applying upstream's **delta** (the number of tests the commit adds) to Kelpie's current numbers, not by taking upstream's absolute numbers.
- A commit that turns out to be already covered by Kelpie, or that only touches Console features Kelpie hides, may be skipped: `git cherry-pick --skip`, and say why in your report.
- Keep upstream's commit message and the `-x` trailer. If you had to adapt code beyond a mechanical merge, append one line to the message saying what (`git commit --amend` right after the pick is fine). Do not add attribution trailers.

Building (Swift work only):

- The Mac has 8 GB and four builders share it. **Every `xcodebuild` goes through the lock wrapper**: `python3 $SP/locked.py xcodebuild ...`. It waits for the lock (up to an hour) and releases it when the command ends. Run long builds with `run_in_background` if a call might exceed 10 minutes, and log to a file, reading only the tail.
- Before the first build, give the worktree the gitignored Ghostty binary: `mkdir -p $SP/wt-<X>/Packages/GhosttyTerminal/Artifacts && cp -cR /Users/anthonytopalides/Developer/Kelpie/Packages/GhosttyTerminal/Artifacts/GhosttyKit.xcframework $SP/wt-<X>/Packages/GhosttyTerminal/Artifacts/`.
- Build in your own paths: `-derivedDataPath $SP/dd-<X> -clonedSourcePackagesDirPath $SP/spm-<X>`. Never use `~/Library/Caches/kelpie-build` (the orchestrator's) or another builder's paths.
- Compile check: `python3 $SP/locked.py xcodebuild build-for-testing -project Heeler.xcodeproj -scheme Heeler -destination 'generic/platform=iOS' -derivedDataPath $SP/dd-<X> -clonedSourcePackagesDirPath $SP/spm-<X> > $SP/build-<X>.log 2>&1`.
- Targeted unit tests on the physical iPad (`id=09D7738D-2173-55EF-8966-A9C3EA1D0514`), never the simulator: `python3 $SP/locked.py xcodebuild test -project Heeler.xcodeproj -scheme Heeler -destination 'platform=iOS,id=09D7738D-2173-55EF-8966-A9C3EA1D0514' -derivedDataPath $SP/dd-<X> -clonedSourcePackagesDirPath $SP/spm-<X> -resultBundlePath $SP/tests-<X>.xcresult -allowProvisioningUpdates -only-testing:HeelerTests/<SuiteType> ... > $SP/test-<X>.log 2>&1`, then `rm -rf $SP/tests-<X>.xcresult`. Run only the suites your commits touch or add; the orchestrator runs the full suite on both devices at the end. Tests that read the checkout or need the software keyboard skip on the device with a reason (`TestHostConditions`); a skip is fine, a recorded issue is not. The `Packages/HeelerSSH` package suites cannot run on a device (no host app) and the simulator does not work on this Mac: compile them with `python3 $SP/locked.py xcodebuild build-for-testing -scheme HeelerSSH -destination 'generic/platform=iOS' -derivedDataPath $SP/dd-<X>-pkg` from `Packages/HeelerSSH`, and CI runs them later.
- Swift 6 strict concurrency, no force unwraps or `try!` outside tests. After adding a Swift file, `xcodegen generate` and commit the project.

Reporting:

- Write your report to `/Users/anthonytopalides/Developer/Kelpie/KelpieVault/Archive/round33/report-<X>.md` **after every commit** (you stop at about 80 tool calls whatever the brief says, so a report written only at the end can be lost). For each commit: picked or skipped, conflicts and how resolved, new short hash on your branch, build and test results with counts. End with: what is left, anything you were unsure about, and the tests the orchestrator should look at.
- When done: delete `$SP/dd-<X>*`, `$SP/spm-<X>`, any `.xcresult`, but **leave the worktree and branch** (the orchestrator merges from it).
- Your final message: the branch name, the commit list (`git log --oneline kelpie..round33-<X>`), and the verdict in three lines.
