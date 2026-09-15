# The dependency watch

Kelpie is a fork sitting on top of things that move without asking. herdr ships
a release most weeks and its API has no stability guarantee. Heeler upstream
moves daily. The terminal engine is a vendored prebuilt binary, libssh2 and
OpenSSL are pinned by commit and tarball hash, the plugin and the relay are
Node, Xcode updates itself, and two pieces of live infrastructure — the push
relay Worker and a temporary App Review host — can simply stop answering.

`scripts/depwatch.py` looks at all of that once a day, turns what moved into a
finding, and makes sure a fix cannot land without climbing the verification
ladder. It is a watcher, not a fixer: it prepares exactly one mechanical change
(the herdr schema snapshot) and hands everything else to a person with the
commands already written out.

## What it watches, and why it matters

| Dependency | Where the pin lives | What moving it breaks | Lane |
| --- | --- | --- | --- |
| herdr API schema | `scripts/herdr-schema.json` (protocol 22) | Wire types, the protocol floor, every load-bearing fact in `CLAUDE.md` | mechanical + manual |
| herdr on the Mac mini | nothing — brew upgrades it | The live server runs ahead of the snapshot Kelpie was built against | manual |
| Heeler upstream | the `upstream` remote, branch `kelpie` | The next rebase; collisions in files both sides touched | manual |
| libghostty-spm | `URL` / `SHA` in `scripts/fetch-ghostty-artifact.sh` | Terminal rendering, iPad pointer and scroll behaviour | manual |
| libssh2 + OpenSSL | `Packages/HeelerSSH/Sources.lock` | SSH transport; a published advisory means a security fix, not a chore | manual |
| `plugin/` and `relay/` npm trees | `plugin/package-lock.json` (relay has none, by design) | Pairing Codes and Agent Notifications | mechanical |
| Xcode and iPadOS | local install; `runs-on: macos-26` in `.github/workflows/ci.yml` | Device builds, and whether CI compiles what the device compiles | infra |
| Actions on the fork | `Getterbetter/Kelpie` repository settings | The verification lane every fix depends on | infra |
| Push relay Worker | `NotificationRelayEndpoint.productionBaseURLString` | Notifications stop, and nothing in the app says so | infra |
| App Review host | `Host kelpie-review` in `~/.ssh/config` | App Review has no herdr Host to connect to | infra |

## Running it once

```sh
make depwatch          # full run: writes state, reports, the vault note, the brief handoff
make depwatch DRY=1    # report to stdout, write nothing at all
```

Straight to the script when you want the options:

```sh
/usr/bin/python3 scripts/depwatch.py --dry-run
/usr/bin/python3 scripts/depwatch.py --check herdr-release heeler-upstream
/usr/bin/python3 scripts/depwatch.py --publish            # open/update GitHub issues
/usr/bin/python3 scripts/depwatch.py --prepare --publish  # and push the mechanical fix branch
/usr/bin/python3 scripts/depwatch.py --json               # findings JSON on stdout as well
```

It must run on `/usr/bin/python3` (3.9.6), the interpreter launchd gets, and it
uses nothing outside the standard library. `--dry-run` writes nothing anywhere:
no state, no reports, no vault edit, no briefing file, and its temporary git
worktrees go to `$TMPDIR`, not the state directory.

Exit status is 0 unless the script itself fails. A check that raises or times
out is reported as a finding of severity `error` for that check, and the other
checks still run.

## Installing the schedule

The plist is in the repo but deliberately not loaded. To install it:

```sh
cp scripts/launchd/com.kelpie.depwatch.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.kelpie.depwatch.plist
launchctl kickstart -k gui/$(id -u)/com.kelpie.depwatch   # run it once, now
```

To stop it: `launchctl bootout gui/$(id -u)/com.kelpie.depwatch`.

It runs daily at 05:45 local, twenty minutes before the 06:05 morning-brief
build, with `RunAtLoad` false so installing it does not start a run. Logs:

- `~/.kelpie/depwatch/launchd.{out,err}.log` — whatever launchd catches.
- `~/.kelpie/depwatch/depwatch.log` — one line per run plus one per finding.
- `~/.kelpie/depwatch/depwatch.{out,err}.log` — the watcher's own stdout/stderr.

`scripts/depwatch.sh` is the wrapper launchd runs: it sets `PATH` and `HOME`,
takes an `mkdir` lock in `~/.kelpie/depwatch/lock` (a live pid wins, a dead pid
or a lock older than 180 minutes is cleared), runs the watcher, and then starts
the analysis lane if the run produced a new high finding on a manual lane. The
scheduled flags are `DEPWATCH_FLAGS`, `--publish` by default. Adding
`--prepare` there is a real decision: it can add a twenty-minute compile to a
05:45 run.

## The response lanes

Every finding carries a lane and its actions. The lanes are:

**mechanical** — the change is mostly typing, and the watcher can do it.
**manual** — a person has to read something before deciding.
**infra** — the fix is a setting or a service, not code.

### `herdr-release`

The mechanical half: take the new schema, regenerate, prove there is no drift.

```sh
cp <new schema> scripts/herdr-schema.json
python3 scripts/generate-wire-types.py --schema scripts/herdr-schema.json
python3 scripts/generate-wire-types.py --check --schema scripts/herdr-schema.json
```

`--prepare` does exactly this in a worktree, on a `depwatch/herdr-<tag>` branch,
and then climbs the ladder as far as it can.

The manual half is the part that actually matters. Re-verify the
"Load-bearing herdr facts" in `CLAUDE.md` that are stamped with a version older
than the new release, against a live server, and re-stamp them. Then, if the
protocol moved, adjust `HeelerSSHTransport.minimumProtocolVersion` — the app
enforces a **floor**, never equality, and `generatedProtocolVersion` only drives
an advisory notice. Equality here made every 0.8.0 Host unusable (#140).

### `herdr-mini`

Optional and off by default. Put an ssh destination in
`~/.kelpie/depwatch/config.json`:

```json
{ "mini_host": "mac-mini" }
```

Set up on 2026-09-12: the mini is reachable over Tailscale as `mac-mini`; a
dedicated passphrase-less key `~/.ssh/kelpie-depwatch` is installed there
(`ssh-copy-id -i ~/.ssh/kelpie-depwatch.pub mac-mini`, run once in Terminal.app
because the session runner cannot answer a password prompt), and a `Host mac-mini`
block in `~/.ssh/config` uses it. The check extends `PATH` with `~/.local/bin`,
Homebrew and Cargo because a non-interactive login has none of them. Redoing it
on another Mac means accepting the host key and installing a key once:

```sh
ssh mac-mini true      # accept the fingerprint, then the watch can use BatchMode
```

Until then the check reports `info`, never `error`.

### `heeler-upstream`

The recipe that worked in round 7, and the one the finding repeats:

```sh
git tag kelpie-pre-rebase-$(date +%Y%m%d)
GIT_EDITOR=true git rebase upstream/main
# resolve CHANGELOG.md by keeping both ### Added lists
xcodegen generate
# then a device build
```

The watcher rehearses this for you in a detached worktree and aborts, so the
finding already knows whether it conflicts and where. Anything beyond a
`CHANGELOG.md` conflict is a round of its own, not a five-minute job.

### `libghostty-spm`

Never edit the vendored package under `Packages/GhosttyTerminal`; override its
`open` members from `HeelerTerminalView`. To move the pin: first
`make ghostty-override-diff NEW=<commit>` (`scripts/ghostty-override-diff.py`),
which names every `UITerminalView` member Kelpie overrides, declares or calls
that the new commit removes, closes, re-signs or collides with; then update
`URL` and `SHA` in `scripts/fetch-ghostty-artifact.sh`, run `make generate` (which fetches
and checksum-verifies), review the package's Swift sources and the XCFramework
checksum, then device build and walk the pointer, long-press and trackpad-scroll
checklist in `docs/adr/0016-ipad-pointer-input.md`.

### `heeler-ssh-pins`

```sh
# after editing Packages/HeelerSSH/Sources.lock
make ssh-artifacts
make verify-ssh-artifacts
scripts/run-heelerssh-package-tests.sh
```

The package suites are a separate test plan; `-only-testing:HeelerTests/...`
does not reach them. Review both the upstream source hashes and the committed
XCFramework checksums before accepting a bump.

### `node`

```sh
cd plugin && npm audit fix && npm test
```

On a branch, never in the checkout from a watch run. The watch itself only ever
runs `npm audit --json`, read-only; it never runs `npm install`. Remember the
vectors in `plugin/test-vectors/` are consumed by both the Node and Swift
suites, so they change in lockstep. `.github/workflows/ci-node.yml` is the lane
that verifies it.

### `toolchain`

A changed Xcode or iPadOS means a device build and the device checklist in
`KelpieVault/Open items.md`. The simulator does not run reliably on this Mac, so
there is no shortcut. A `medium` here means the CI runner image and the local
Xcode major have drifted apart, which makes a green CI a weaker signal than it
looks.

### `ci-fork`

```sh
gh api -X PUT repos/Getterbetter/Kelpie/actions/permissions -f enabled=true
```

or Settings → Actions → Allow all actions. Then open fix branches as PRs into
`kelpie`: `ci.yml`'s `pull_request` trigger has no branch filter, so a PR into
`kelpie` runs it, while its `push` trigger is `main`-only and never will. macOS
minutes are free on a public repository.

### `relay` and `review-host`

Infrastructure, not code. The relay probe fetches `/depwatch-probe`; the Worker
answers 404 for any path but `/push` (`relay/src/worker.js`), so a 404 is a
healthy relay and only a 5xx, a timeout or a DNS failure is a problem. The
review host is a paid Hetzner box that exists only for App Review — delete it
after approval (`docs/guides/app-review-host.md`).

## The verification ladder every fix climbs

No fix merges because one step passed. In order:

1. **Drift check** — `python3 scripts/generate-wire-types.py --check --schema scripts/herdr-schema.json`. Cheap, and it catches a hand-edited generated file.
2. **Compile** — `xcodebuild build -project Heeler.xcodeproj -scheme Heeler -configuration Debug -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO` with its own `-clonedSourcePackagesDirPath` and `-derivedDataPath`. Two builds sharing a derived-data path lock each other out, so the watch uses `~/.kelpie/depwatch/build/` and never the paths an interactive session uses.
3. **CI** — a PR into `kelpie` on the fork. This is the rung that is currently missing: until Actions is enabled on `Getterbetter/Kelpie`, the `ci-fork` finding stays `high`.
4. **Device build** — the real iPad, plus the device checklist in `KelpieVault/Open items.md`. The simulator is not an option on this Mac.
5. **Merge.**

The rule that matters: **a fix touching `Sources/` never merges on the compile
alone.** A compile proves the Swift type-checks. It says nothing about whether
herdr still answers the way the app expects, and every expensive herdr fact in
`CLAUDE.md` was learned from a live server, not a compiler.

## State and reports

Everything lives in `~/.kelpie/depwatch/`, never in the repo:

```
state.json                fingerprints per check, issue numbers, prepared tags, last 30 runs
reports/<UTC stamp>.md    one report per run
reports/latest.md         a copy of the most recent
reports/latest.json       the findings, machine-readable (Stage B reads this)
depwatch.log              one line per run, then one per finding
worktrees/                temporary git worktrees, pruned at the start of every run
cache/                    downloaded herdr schemas, keyed by tag
build/                    SPM clones and derived data for the compile check only
lock/                     the mkdir lock, with the holder's pid
config.json               optional: {"mini_host": "..."}
```

Read a run with `cat ~/.kelpie/depwatch/reports/latest.md`, or the history with
`tail -40 ~/.kelpie/depwatch/depwatch.log`.

The vault note `KelpieVault/Dependency watch.md` carries the same table in plain
English. The watcher only ever rewrites the block between
`<!-- depwatch:begin -->` and `<!-- depwatch:end -->`; prose above and below it
survives every run, so write notes there freely.

## Publishing

`--publish` keeps one open GitHub issue per check, titled
`depwatch: <check>: <headline>`, labelled `depwatch` and `dependencies`. A new
fingerprint on a check that already has an open issue is a comment plus a title
edit, not a second issue. A finding that falls back to `info` gets a "resolved
by `<fingerprint>`" comment and the issue is closed. Findings that repeat
unchanged are reported but never republished — that is what the fingerprint is
for.

`--dry-run --publish` prints every `gh` command it would run, with the path to
the body file, and creates nothing.

## Stage B: the judgement lane

`scripts/depwatch-analyse.sh` runs one bounded headless Claude job per new
`high` finding on a `manual` lane, at most two per run, in a fresh detached
worktree with a 15-minute deadline enforced by `scripts/run-with-timeout.py`.
The job may read and search and call `gh api`; it may not edit files. It writes
a 400-word brief: what changed with citations, which Kelpie files and which
`CLAUDE.md` facts it affects, the smallest safe change, the verification steps
in order, and the risks. With `--publish` the brief is posted to the check's
issue; otherwise it is saved as `reports/analysis-<check>-<stamp>.md`.

## The morning-brief handoff

Every run writes `~/.memoryos/kelpie-depwatch-briefing.json`, even when nothing
is new:

```json
{ "date": "2026-09-12",
  "items": [ { "title": "…", "headlines": ["…"], "act": ["…"] } ] }
```

`items` holds the new medium and high findings only. **Nothing reads it yet.**
The follow-up is one consumer function in `~/.memoryos/briefing_build.py`,
modelled on `territory_update`: read the file, ignore it when `date` is not
today, and fold `items` into the brief the way the territory items already are.

## Adding a check

1. Write `check_<id>(ctx)` returning one finding via `make_finding(...)`. `ctx`
   gives you `ctx.repo`, `ctx.state`, `ctx.run(argv, timeout=…)` and
   `ctx.gh_json(path)`. Use nothing else to reach the outside world: every call
   has to carry a deadline, because a watch that hangs is worse than a watch
   that fails.
2. Choose a **fingerprint** that identifies the state of the world, not the
   moment — a tag, a commit count plus a head sha, a run conclusion. Never a
   timestamp, or every run is "new". Findings whose fingerprint is unchanged are
   reported as `repeat` and never republished.
3. Put the severity decision in a small pure function next to the others
   (`node_severity`, `upstream_severity`, …) so `scripts/depwatch_test.py` can
   test it without a network. General scale: `high` is broken or a security
   advisory, `medium` needs work but nothing is broken today, `low` is a newer
   version with no known impact, `info` is recorded state, `error` is "the check
   could not run".
4. Write the `actions` as commands someone can paste, in the order they run.
5. Register it in the `CHECKS` table at the bottom of the checks section.
6. Add tests to `scripts/depwatch_test.py` and run `sh scripts/test-depwatch.sh`.

The finding shape is
`{check, severity, fingerprint, new, title, summary, evidence[], lane, actions[]}`,
plus a `data` dict the watcher carries into `state.json` for the check's own
bookkeeping (the herdr snapshot tag, advisory ids seen, a prepared worktree
path). Keep `data` small and JSON-serialisable.

## Known limits

- **No unit tests locally.** The iOS simulator does not run reliably on this Mac
  (Mach error -308), so the app suites only run in CI — which is why `ci-fork`
  being `high` matters more than it looks.
- **The advisory feeds are thin.** `gh api repos/<owner>/<repo>/security-advisories`
  lists advisories filed in that repository's GitHub workspace. OpenSSL and
  libssh2 both publish through their own channels, so these endpoints can be
  empty on a day when an advisory exists. Treat a quiet `heeler-ssh-pins` as "no
  advisory *on GitHub*", not "no advisory".
- **`herdr-mini` needs a one-time host-key accept and an installed key** before
  it can do anything (see above), and stays `info` until then.
- **`--prepare` covers one check.** Only `herdr-release` has an automated fix.
  Everything else reports and hands over.
- **The watcher never touches the checkout.** It does not switch branches,
  commit, stash or push there; branch work happens in worktrees under the state
  directory. The one exception is the generated block of the vault note.
