# Spec: Kelpie dependency watch ("depwatch")

Repo: `/Users/anthonytopalides/Developer/Kelpie`, branch `kelpie`. **Another Claude session is working in this directory right now.** Rules that follow from that:

- Create new files only. The only existing files you may edit are `Makefile` (add one target at the end) and `.gitignore` (if needed). Do not touch `resume.md`, `CLAUDE.md`, `project.yml`, `Heeler.xcodeproj`, `Sources/`, `Tests/`, `scripts/herdr-schema.json`, or anything under `Packages/`.
- Do not run `xcodebuild`, `xcodegen`, `git checkout`, `git rebase`, `git stash`, `git commit`, or `git push` in the repo working tree. Every git operation the watcher performs on branches happens in a **temporary worktree** under the state directory, never in the checkout. `git fetch upstream` in the repo is allowed (it only updates remote-tracking refs).
- Never call `launchctl`. Never create GitHub issues, labels, or comments during the build; `--publish` is tested only in dry-run form (`--dry-run --publish` prints what it would do).

Conventions in force: `CLAUDE.md` at the repo root (read the Kelpie section and the "Load-bearing herdr facts"). Scripts in `scripts/` are the house style; look at `scripts/run-with-timeout.py`, `scripts/generate-wire-types.py` and `scripts/test-run-with-timeout.sh` for tone and test shape. Python must run on **`/usr/bin/python3` (3.9.6)** with the standard library only: no walrus-free-only worries, but no `match`, no `X | Y` type unions at runtime, no `tomllib`, no third-party packages. Shell is `/bin/bash` or `/bin/sh` as the existing scripts do.

## Why this exists

Kelpie is a fork of Heeler that talks to herdr over SSH. It can break when any of these move: herdr's socket API and CLI behaviour, Heeler upstream (rebased onto periodically), the vendored libghostty-spm package, the pinned libssh2/OpenSSL builds, the Node plugin and Cloudflare push relay, the Xcode toolchain, and two live pieces of infrastructure (the relay Worker and a temporary App Review host). Anthony wants a routine that runs on a schedule, notices change, turns it into tracked work, prepares the mechanical fixes, and makes sure a fix cannot land without passing the checks that already exist. His other headless jobs are launchd agents that run a bash wrapper (lock + log + env) around a Python or Claude job; copy that pattern.

## Deliverables

1. `scripts/depwatch.py` — the watcher. Stdlib only.
2. `scripts/depwatch.sh` — launchd wrapper: lock, `PATH`, `HOME`, log, then `depwatch.py` with the configured flags, then `depwatch-analyse.sh` when there are new high findings.
3. `scripts/depwatch-analyse.sh` — the headless-Claude analysis lane (see Stage B).
4. `scripts/launchd/com.kelpie.depwatch.plist` — the launchd agent, **not loaded**. Daily at 05:45 local (before his 06:05 morning-brief build). `RunAtLoad` false, `ProcessType` Background, stdout/stderr to `~/.kelpie/depwatch/launchd.{out,err}.log`, `EnvironmentVariables` PATH `/Users/anthonytopalides/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin`, HOME set. Program: `/bin/bash /Users/anthonytopalides/Developer/Kelpie/scripts/depwatch.sh`.
5. `scripts/test-depwatch.sh` — runs `python3 -m unittest` over `scripts/depwatch_test.py` (pure-function tests, see Tests). Both files.
6. `scripts/fixtures/depwatch/` — the fixtures the tests need (a schema variant, sample `gh api` JSON captured or hand-written, a sample state file).
7. `docs/guides/dependency-watch.md` — the guide: what is watched, how each finding is responded to (the lanes), how to run by hand, how to install the launchd job, how to read the state and reports, how to add a check.
8. `KelpieVault/Dependency watch.md` — plain-English vault note (Obsidian; frontmatter `note:` line like the other vault notes, wikilinks to `[[Kelpie]]`, `[[herdr]]`, `[[Heeler upstream]]`, `[[Build and deploy]]`). The watcher rewrites the section between `<!-- depwatch:begin -->` and `<!-- depwatch:end -->` with the last-run table and leaves the prose above it alone.
9. One `Makefile` target appended at the end: `depwatch: ## Run the dependency watch once (dry run: DRY=1)` that calls the script (`DRY=1` adds `--dry-run`). Keep the `##` help comment style used by the other targets.

## Layout of state (never inside the repo)

`~/.kelpie/depwatch/` — `state.json` (fingerprints per check + run history, last 30 runs), `reports/<UTC timestamp>.md` and `reports/latest.md`, `reports/latest.json`, `depwatch.log` (one line per run, plus one per finding), `worktrees/` (temporary git worktrees; pruned at start), `cache/` (downloaded schemas, keyed by tag), `build/` (SPM clones + derived data for the compile check, so no path is shared with an interactive session), `lock/` (mkdir lock with pid, stale after 180 minutes, same logic as `~/.memoryos/territory-refresh.sh` lines 40–60: a live pid wins, a dead pid or an old lock is cleared).

Handoff for the morning brief: `~/.memoryos/kelpie-depwatch-briefing.json`, shape `{"date": "<YYYY-MM-DD local>", "items": [{"title": "<80 chars>", "headlines": ["<220 chars>", …up to 3], "act": ["<300 chars>", …]}]}`. Written every run (empty `items` when nothing is new). The brief does not read it yet; the guide says one consumer function in `~/.memoryos/briefing_build.py` (modelled on `territory_update`) is the follow-up.

## CLI

```
depwatch.py [--dry-run] [--publish] [--prepare] [--check ID ...] [--json] [--state-dir PATH] [--repo PATH]
```

- Default: run every check, write state, reports, the vault note section and the briefing file. No issues, no branches.
- `--dry-run`: run checks, print the report to stdout, write nothing (no state, no reports, no vault, no briefing), and print each publish/prepare action it *would* take.
- `--publish`: create or update GitHub issues for new findings of severity medium or high (see Publishing).
- `--prepare`: prepare fix branches for findings that have a mechanical lane (see Stage A2). Pushes only when `--publish` is also given.
- `--check`: run only the named checks.
- `--json`: emit the findings JSON to stdout as well.
- Exit code 0 unless the script itself fails (a check raising is caught and reported as a finding of severity `error` for that check, never a crash).

Every `gh`, `git`, `ssh`, `curl`/`urllib`, `npm` call goes through one helper with a timeout (default 60 s, network calls 30 s, the compile check 20 min) and captured output; a timeout is a finding of severity `error`, not a hang.

## Findings

A finding is `{"check": id, "severity": "high|medium|low|info|error", "fingerprint": str, "new": bool, "title": str, "summary": str, "evidence": [str], "lane": "manual|mechanical|infra|none", "actions": [str]}`. `fingerprint` is the value that identifies "this state of the world" for the check (a tag, a commit count + head sha, a run status). `new` is true when the fingerprint differs from the one in `state.json` from the last run; unchanged findings are still reported but flagged `repeat` and never republished. The state records `first_seen` and `last_seen` per fingerprint.

Severity rules are per check below. General: `high` = Kelpie is or will be broken or a security advisory applies; `medium` = a change that needs work but nothing is broken today; `low` = newer version available, no known impact; `info` = state recorded, nothing to do; `error` = the check could not run.

## The checks (Stage A)

Each is a function `check_<id>(ctx) -> Finding`. `ctx` carries the repo path, state, a `run()` helper, and a `gh_json(path)` helper (`gh api <path>` parsed). Use `gh api` for everything GitHub; it is logged in as `Getterbetter`. Keep every check independent; one failing must not stop the others.

### `herdr-release` (lane: mechanical for the schema, manual for behaviour)

- Source: `gh api repos/herdrdev/herdr/releases?per_page=15`. Latest **stable** = first entry with `prerelease` false and `draft` false; also note the latest prerelease tag (info only).
- Kelpie's snapshot: `scripts/herdr-schema.json` (`protocol` is 22 today; the file has no version key, so the state file records the herdr tag the snapshot came from; seed it as `v0.9.0`, which `docs/research/herdr-0.9.0-compatibility.md` documents).
- On a stable tag newer than the recorded one (compare with a semver parse of `vX.Y.Z`): download `docs/next/api/herdr-api.schema.json` at that tag (`gh api repos/herdrdev/herdr/contents/docs/next/api/herdr-api.schema.json?ref=<tag>` with header `Accept: application/vnd.github.raw`; it exists at `v0.9.0`, 275 KB) into `cache/herdr-schema-<tag>.json`. Then compute the drift:
  - `protocol` old vs new.
  - Request methods: the keys of the request schema. Work out the structure from `scripts/generate-wire-types.py` (it already parses this file; import nothing from it, but mirror how it finds methods and event kinds, and cite the functions in a comment). Added / removed / changed (changed = the method's JSON subtree differs).
  - Event kinds: same for events and subscription events.
  - Cross-reference with what Kelpie uses: methods = every `method: "<x>"` string literal under `Sources/` (18 distinct today; `grep -rhoE 'method: *"[a-z_.]+"' Sources`), event kinds = the `case` names in `Sources/Heeler/Transport/Generated/` (read the generated file to learn the shape). A removed or changed method/kind that Kelpie uses is the important set.
  - Regenerate wire types in a temporary worktree: `git worktree add --detach <worktrees/herdr-<tag>> kelpie`, copy the new schema over `scripts/herdr-schema.json` there, run `python3 scripts/generate-wire-types.py --schema scripts/herdr-schema.json` there, and take `git diff --stat` plus the number of changed lines in `Sources/Heeler/Transport/Generated/`. Remove the worktree afterwards (`git worktree remove --force`), unless `--prepare` keeps it as the fix branch (below).
- Severity: `high` when protocol bumps or a used method/kind is removed or changed; `medium` when only unused methods/kinds changed or anything was added; `low` when the schema is byte-identical but the tag is newer (herdr changed behaviour without changing the API: still worth a look, the CLAUDE.md facts are version-stamped); `info` when no newer stable tag.
- Actions text: the mechanical lane (schema snapshot + regenerated wire types + `--check` + compile + CI), then the manual lane: re-verify the CLAUDE.md "Load-bearing herdr facts" that are stamped with an older version, against a live server, and update `HeelerSSHTransport.minimumProtocolVersion` / `generatedProtocolVersion` only per the floor rule in CLAUDE.md (never equality).

### `herdr-mini` (lane: manual)

Optional. If `~/.kelpie/depwatch/config.json` has `"mini_host"` (an ssh destination), run `ssh -o BatchMode=yes -o ConnectTimeout=5 <host> 'herdr --version'`, record the version, and raise `medium` when it is newer than the tag Kelpie's schema came from (the Mac mini runs `brew`, so it can upgrade ahead of the snapshot). Unset or unreachable → `info` with the reason ("mini_host not configured" / the ssh error), never `error`. Today the mini is reachable on Tailscale as `mac-mini` but the Mac has no host key for it, so the config stays unset; the guide explains the one-time `ssh mac-mini` to accept it.

### `heeler-upstream` (lane: manual, with a dry-run result)

- `git fetch upstream` (repo `upstream` remote = `ZingerLittleBee/Heeler`), then: commits `kelpie..upstream/main` (count + `--oneline` list, first 20), new tags/releases from `gh api repos/ZingerLittleBee/Heeler/releases?per_page=5` (latest is `v0.1.6`, 2026-09-08), merge-base, files upstream touched since the merge-base, files Kelpie touched since the merge-base (`git diff --name-only <merge-base>..kelpie`), and their intersection (the collision set).
- Dry-run rebase in a temporary worktree: `git worktree add --detach <worktrees/upstream-<sha>> kelpie`, then `GIT_EDITOR=true git -C <wt> rebase upstream/main`; on failure collect `git diff --name-only --diff-filter=U`, then `git rebase --abort`. Always remove the worktree. Skip the dry run when the commit count is 0.
- Fingerprint: `upstream/main` sha.
- Severity: `info` at 0 commits; `low` when commits exist, no conflicts, collision set empty; `medium` when no conflicts but the collision set is non-empty or `CHANGELOG.md` conflicts only; `high` when conflicts touch `Sources/`, `Packages/`, `project.yml` or `Tests/`.
- Actions text: the rebase recipe from `resume.md` item 5 (`git tag kelpie-pre-rebase-<date>`, `GIT_EDITOR=true git rebase upstream/main`, `CHANGELOG.md` by keeping both `### Added` lists, `xcodegen generate`, device build), the conflict list, and "run as a `/delegate` round".

### `libghostty-spm` (lane: manual)

- Pin: parse the `URL=` line in `scripts/fetch-ghostty-artifact.sh` (`.../releases/download/<tag>/GhosttyKit.xcframework.zip`; today `upstream.1.3.1`) and the `SHA=` line.
- Latest: `gh api repos/Lakr233/libghostty-spm/releases?per_page=10`; report the newest tag of each family (`upstream.*` and the dated `1.x.YYYYMMDD` ones) with dates.
- Severity: `low` when newer; `info` otherwise. Actions: the vendoring rule from CLAUDE.md (never edit the vendored package; re-vendor from the tag, update `URL`/`SHA`, review the Swift sources and the XCFramework checksum, then a device build with the pointer-input checklist in `docs/adr/0016-ipad-pointer-input.md`).

### `heeler-ssh-pins` (lane: manual; high on advisories)

- Pins: parse `Packages/HeelerSSH/Sources.lock` (`LIBSSH2_COMMIT`, `OPENSSL_VERSION`, tags, SHA256s).
- libssh2: latest release (`gh api repos/libssh2/libssh2/releases/latest`, `libssh2-1.11.1` today) and the date of the pinned commit (`gh api repos/libssh2/libssh2/commits/<sha>` → `commit.committer.date`); master head sha/date is info only.
- OpenSSL: releases list; latest **within the pinned major.minor line** (3.6.x today) is the one that matters; newer lines (4.0, 4.1-alpha) are info.
- Advisories: `gh api repos/openssl/openssl/security-advisories?state=published&per_page=20` and the same for `libssh2/libssh2`; a finding is `high` when any advisory was published after the pin's date (OpenSSL release date from the releases list; libssh2 pinned-commit date). Store the advisory `ghsa_id`s seen so repeat runs stay quiet.
- Severity: `high` on a new advisory; `low` when a newer patch release exists in the pinned line; `info` otherwise. Actions: `make ssh-artifacts` / `make verify-ssh-artifacts`, the pin-and-review rule from CLAUDE.md, then `scripts/run-heelerssh-package-tests.sh`.

### `node` (lane: mechanical)

- For `plugin/` and `relay/`: if a `package-lock.json` exists, run `npm audit --json --audit-level=low` there (read-only; do not run `npm install`); summarise counts by severity and the top advisories. If there is no lockfile, report `info` ("no lockfile; dependency-free by design").
- Severity: `high` for high/critical vulnerabilities, `medium` for moderate, `info` otherwise. Actions: `npm audit fix` on a branch, `npm test` in that directory, CI (`ci-node.yml`).

### `toolchain` (lane: infra)

- `xcodebuild -version` (two lines), and, best effort within 15 s, `xcrun devicectl list devices --json-output <tmp>` to record the connected iPad's OS version if any (missing device → skip, info).
- Fingerprint: the Xcode build string + iPadOS version. Severity: `info` when unchanged; `low` when changed, with the action "run a device build and the device checklist in `KelpieVault/Open items.md`". Also flag `medium` if the CI runner pin in `.github/workflows/ci.yml` (`runs-on: macos-26`) and the local Xcode major differ (parse the major from `Xcode 26.4.1`).

### `ci-fork` (lane: infra)

- `gh api repos/Getterbetter/Kelpie/actions/workflows` and `gh run list -R Getterbetter/Kelpie --limit 5 --json name,status,conclusion,headBranch,createdAt`.
- Today Actions has never run on the fork (`gh run list` is empty) and CI only triggers on PRs and pushes to `main`, while Kelpie lives on `kelpie`. That is the gap: the verification lane for every fix depends on CI running on PRs into `kelpie`. Severity `high` while there is no successful `CI` run on the fork; `medium` when the latest run failed; `info` when green. Actions: enable Actions on the fork (Settings → Actions, or `gh api -X PUT repos/Getterbetter/Kelpie/actions/permissions -f enabled=true`), open fix branches as PRs into `kelpie` (the `pull_request` trigger has no branch filter, so they run), and note that a public repo's macOS minutes are free.

### `relay` (lane: infra)

- URL: find the default relay origin in `Sources/` (grep for `workers.dev`; it is `kelpie-apns.getter-tilbury-0m.workers.dev`) rather than hardcoding it. `urllib` GET `https://<host>/depwatch-probe` with a 10 s timeout; the Worker answers 404 for any path other than `/push` (`relay/src/worker.js:261`), which counts as healthy. 5xx, timeout, DNS failure → `high`. Fingerprint: healthy/unhealthy + status code.

### `review-host` (lane: infra)

- Only while `~/.ssh/config` has `Host kelpie-review`: `ssh -o BatchMode=yes -o ConnectTimeout=5 kelpie-review true`. Reachable → `info` with the reminder text from `resume.md` (delete the Hetzner server after App Store approval; `docs/guides/app-review-host.md`). Unreachable → `medium` (App Review may need it). Alias absent → `info`, "no review host configured".

## Stage A2: `--prepare` (mechanical lanes only)

Only `herdr-release` has an automated fix in v1. When its finding is new and severity ≥ medium:

1. Keep the worktree from the check, `git switch -c depwatch/herdr-<tag>` there, commit the schema snapshot + regenerated `Sources/Heeler/Transport/Generated/` with message `chore(wire): herdr <tag> schema snapshot and regenerated wire types\n\nAutomated by scripts/depwatch.py. refs depwatch` (the issue number appended when known).
2. Verify inside the worktree, in order, stopping at the first failure and recording which step failed in the finding: (a) `python3 scripts/generate-wire-types.py --check --schema scripts/herdr-schema.json`; (b) `sh scripts/fetch-ghostty-artifact.sh` (needed for the compile; it is idempotent and downloads once per worktree — copy `Packages/GhosttyTerminal/Artifacts/GhosttyKit.xcframework` from the main checkout when present to avoid the download); (c) `xcodegen generate` in the worktree if `xcodegen` is on PATH, else skip and say so; (d) compile only: `xcodebuild build -project Heeler.xcodeproj -scheme Heeler -configuration Debug -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO -clonedSourcePackagesDirPath ~/.kelpie/depwatch/build/spm -derivedDataPath ~/.kelpie/depwatch/build/dd` with output to `~/.kelpie/depwatch/build/xcodebuild-<tag>.log`, 20-minute timeout, and only the last 40 lines kept in the report. The compile is skipped with a clear note when `--dry-run`.
3. With `--publish`: `git push origin depwatch/herdr-<tag>` and `gh pr create --base kelpie --head depwatch/herdr-<tag> --title "chore(wire): herdr <tag> schema snapshot" --body <file>` where the body lists the drift, the verification steps and their results, and "Merge only after CI is green and a device build has run" — then link the PR in the issue. Without `--publish`, report the branch name and that it lives in the worktree (the worktree is kept in that case so he can inspect it; it is pruned on the next run only if its branch has been merged or deleted).
4. Never `--prepare` twice for the same tag: the state records prepared tags and their PR/branch.

The compile check is the one expensive step; it uses its own SPM clone and derived-data paths so it never locks against an interactive session's build (CLAUDE.md: two builds sharing a derived-data path lock each other out).

## Stage B: `scripts/depwatch-analyse.sh` (headless Claude, judgement lane)

For each **new** `high` finding whose lane is `manual` (upstream conflicts, a used herdr method changed, an advisory), run one bounded `claude -p` job that writes an analysis brief, then post it to the finding's issue (with `--publish`) or save it under `reports/analysis-<check>-<ts>.md` otherwise. At most 2 analyses per run.

- Invocation: `claude -p --model opus --output-format text --permission-mode dontAsk --allowedTools "Read,Grep,Glob,Bash(git *),Bash(gh api *),Bash(gh issue view *)" --max-turns 40 < prompt`, cwd = a fresh detached worktree of `kelpie` under `worktrees/analyse-<ts>` (removed afterwards), 15-minute timeout via `scripts/run-with-timeout.py` (read it to see how it is invoked).
- The prompt (a heredoc in the script) carries the finding JSON and asks for: what changed (with upstream file/line citations), which Kelpie files and CLAUDE.md facts it affects, the smallest safe change, the verification steps in order (drift check, compile, CI, device build, the device checklist), and the risks; 400 words max, plain English, no em-dashes. It must not edit files.
- The script is a thin bash wrapper: reads `reports/latest.json`, selects findings, loops, logs to `depwatch.log`. Locking is the outer `depwatch.sh`'s job.

## Publishing (`--publish`)

- Labels: ensure `depwatch` (colour `1d76db`, "Opened by scripts/depwatch.py") and `dependencies` exist (`gh label create --force`). Severity goes in the title, not a label.
- One open issue per check. Title `depwatch: <check>: <headline>` (e.g. `depwatch: heeler-upstream: 14 commits behind, 2 conflicting files`). Find with `gh issue list --label depwatch --state open --search "depwatch: <check>:" --json number,title`. New fingerprint and an open issue exists → `gh issue comment` with the delta and `gh issue edit --title` to the new headline. No open issue → `gh issue create`. Finding back to `info` → comment "resolved by <fingerprint>" and close.
- Body = the finding rendered as markdown: summary, evidence as a bullet list, the lane, the actions as a numbered list, "Opened by `scripts/depwatch.py` at <ts>; state in `~/.kelpie/depwatch/`". Bodies via a temp file (`--body-file`), never inline.
- `--dry-run --publish` prints each `gh` command it would run, with the body path.

## Report

`reports/<ts>.md`: a header (run time, repo sha, duration), a table (check, severity, new/repeat, headline), then one section per finding with evidence and actions. `latest.md` is a copy. The vault note section is the table plus "last run" line plus, for each medium/high finding, its headline and the first action. `depwatch.log` gets `<ts> run checks=<n> new=<n> high=<n> medium=<n> publish=<yes|no|dry> prepare=<...> duration=<s>` then one `<ts> <check> <severity> <new|repeat> <headline>` per finding.

## Tests (`scripts/depwatch_test.py`, run by `scripts/test-depwatch.sh`)

Pure functions only, no network, no git, no `gh`: semver parse/compare (`v0.9.0`, `preview-2026-09-08-…` is not a version), schema drift on two fixture schemas (a copy of `scripts/herdr-schema.json` and a variant with one method removed, one added, one changed, and `protocol` bumped — generate the variant in the test from the real file so the fixture is not a 275 KB copy), the used-method cross-reference, severity rules for each check given synthetic inputs, fingerprint new/repeat detection against a state dict, the issue-title builder, the vault-section splice (prose above the markers survives), the briefing-file shape (title ≤ 80, headlines ≤ 3), and the `runs` history cap. Structure `depwatch.py` so these are importable: the network/git calls live in small functions the tests never touch. Both test files must pass under `/usr/bin/python3`.

## Guide (`docs/guides/dependency-watch.md`) sections

What it watches and why (a table: dependency, where the pin lives, what moving it breaks, lane). How to run once (`make depwatch`, `DRY=1`). Installing the schedule (copy the plist to `~/Library/LaunchAgents/`, `launchctl bootstrap gui/$(id -u) …`, `launchctl kickstart -k gui/$(id -u)/com.kelpie.depwatch`, where the logs are) — as instructions, not done by the builder. The response lanes, per check, with the exact commands. **The verification ladder every fix climbs before merge:** `generate-wire-types.py --check` → compile (`generic/platform=iOS`) → PR into `kelpie` so CI runs on the fork → device build + the device checklist → merge; and the rule that a fix touching `Sources/` never merges on the compile alone. State and reports. Adding a check (the `Finding` shape, the fingerprint discipline, register in the `CHECKS` table). The morning-brief handoff and its pending consumer. Known limits (the simulator does not run on this Mac, so unit tests only run in CI; `herdr-mini` needs a one-time host-key accept).

## Verification the builder runs before returning

1. `sh scripts/test-depwatch.sh` passes.
2. `python3 scripts/depwatch.py --dry-run` (system python) completes, every check produces a finding, none is `error` except possibly `herdr-mini`/`review-host` (which must be `info`, not `error`). Save the output to `<builder folder>/dry-run.txt`.
3. `python3 scripts/depwatch.py --dry-run --publish --prepare --check herdr-release heeler-upstream` shows the would-do actions. Save to `<builder folder>/dry-run-actions.txt`.
4. `python3 scripts/depwatch.py --state-dir <builder folder>/state` (a real run into a throwaway state dir, no publish/prepare) writes state, reports, the briefing file (**redirect the briefing path too** — add `--briefing-path` for this, default `~/.memoryos/kelpie-depwatch-briefing.json`; in this test point it into the builder folder) and the vault-note section. Then run it a second time and confirm every finding is `repeat`. Save both outputs.
5. `git status --short` shows only new files plus `Makefile` (and the vault note). `git worktree list` shows only the main checkout. `ls ~/.kelpie` does not exist (everything went to the throwaway state dir) — if step 2's dry run created it, that is a bug.
6. `plutil -lint scripts/launchd/com.kelpie.depwatch.plist` passes.

Return (≤ 300 words): the file list, the six verification results with paths to the saved outputs, and anything in this spec you could not do and why. Do not commit.
