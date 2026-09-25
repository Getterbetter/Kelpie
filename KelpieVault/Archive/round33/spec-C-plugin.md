# Builder C — the plugin and build group, and the dependency watch (Open item 55)

Letter: **C**. Read `spec-common.md` first; it governs worktree, paths and reporting. This group needs no `xcodebuild` at all.

Part 1. Pick these from `upstream/main`, in this order:

1. `84c30cf8` fix(build): discover physical devices from devicectl JSON — Kelpie's Makefile diverges (`0396c09a`: `make install` falls back to any physical device when no iPhone is paired; `scripts/device-tests.sh` parses the devicectl table). Take the JSON discovery if it keeps Kelpie's fallback and targets; otherwise skip and say why. Run `python3 scripts/test-find-ios-device.py` if picked, and `make -n install` to check the recipe still expands.
2. `912b007b` feat: let pairing advertise a configurable SSH port
3. `1cf22db5` fix(plugin): report a pair.json the pairing popup cannot honor
4. `d30c60b2` feat(plugin): warn when Tailscale SSH would answer the pairing port
5. `9e736ae8` fix(plugin): let a pair.json edit reach the open pairing checklist
6. `910b0d1f` fix(plugin): warn only for addresses tailscaled actually answers for
7. `3428640f` chore(plugin): release 0.5.0 for the configurable pairing port — Kelpie's plugin has its own version line; set the manifest version so it is strictly greater than Kelpie's current one and say what you chose.
8. `88413185` test(plugin): follow the manifest version to 0.5.0 (follow whatever version step 7 set)
9. `41c2d417` fix(build): anchor the bump target's version parse (Kelpie fixed `make bump` in `14f3e652`; merge, do not regress it)
10. `d6e9a998` fix: skip container and VM bridges when enumerating pairing candidates
11. `a305fddd` fix(plugin): demote Docker addresses without hiding them

Kelpie's plugin changes to keep: `8f4a4873` (Kelpie's own push relay on workers.dev: the relay default URL), `57da7ba2` (foreground lease), `dfe80220` (replace this device's old push entry; prune on 400 BadDeviceToken). Run `cd plugin && npm test` after every pick; it must stay green. The shared vectors in `plugin/test-vectors/` are consumed by the Swift suites too: if a pick changes them, say so loudly in the report.

Part 2. The dependency watch (`scripts/depwatch.py`, `check_heeler_upstream`, about line 1063; tests in `scripts/test-depwatch.sh`; doc `KelpieVault/Dependency watch.md` and `docs/guides/dependency-watch.md`). Kelpie is a hard fork since 2026-09-23 and no longer rebases, so the check must stop telling Anthony to tag and rebase. Change it to:

- Read a recorded "last reviewed upstream commit" from a small committed file (`scripts/heeler-upstream-reviewed`, one line: the full sha, then optional comment lines starting `#`). Record `53b1c6ae`'s full sha (upstream/main at this round, `git rev-parse 53b1c6ae`).
- Report the upstream commits after it (`<reviewed>..upstream/main`, `--no-merges`), split into the ones that touch paths Kelpie runs — `Packages/HeelerSSH/`, `Sources/Heeler/Transport/`, `Sources/Heeler/Terminal/`, `Sources/Heeler/Pairing/`, `Sources/Heeler/Hosts/`, `plugin/`, `relay/`, `Makefile`, `scripts/` — and the rest (Console and docs). Headline like `N upstream commits to review (M in paths Kelpie runs)`; severity info at 0, low when only the rest, medium when M ≥ 1, high when M ≥ 10. Needs-attention text: review them for cherry-picks (`git cherry-pick -x`), then move the recorded commit forward. No rebase advice, no conflict dry run.
- Keep the check's existing structure, state handling (new/repeat) and output shape; update the tests in `scripts/test-depwatch.sh` to cover: nothing new, only Console commits, a path-matching commit, a missing or malformed reviewed file (report it, do not crash). All tests green.
- Update the prose in both docs to match (outside the watcher's `<!-- depwatch:begin/end -->` markers in the vault note).

Commit Part 2 as its own commit on your branch (`depwatch: heeler-upstream reports unreviewed upstream commits, not a rebase (Open item 55)`).
