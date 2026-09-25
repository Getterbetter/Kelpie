---
note: What Kelpie depends on, what the daily watch checks at 05:45, and what to do when one of them moves.
---

# Dependency watch

[[Kelpie]] is a fork balanced on top of things that move without asking.
[[herdr]] ships a release most weeks and says plainly that its API has no
stability guarantee. [[Heeler upstream]] moves daily; Kelpie is a hard fork of
it since 2026-09-23, so the `heeler-upstream` check lists the upstream commits
nobody has reviewed for a cherry-pick yet (after the one recorded in
`scripts/heeler-upstream-reviewed`), not the cost of a rebase. The terminal engine is a
vendored prebuilt binary, the SSH stack is two C libraries pinned by commit
hash, the notification path runs through a Cloudflare Worker, and Xcode updates
itself whether or not anyone asked.

So there is a watcher. `scripts/depwatch.py` looks at all of it once a day at
05:45, twenty minutes before the morning brief is built, and writes the table
below. It notices; it does not fix. The one exception is herdr's API schema,
where the change is mechanical enough that the watcher can prepare the branch
and let the checks decide.

## How to read it

Each row is one check and the worst thing it found.

- **high** — Kelpie is broken, will be, or a security advisory applies.
- **medium** — real work, but nothing is broken today.
- **low** — a newer version exists with no known impact.
- **info** — state recorded, nothing to do.
- **error** — the check itself could not run, so that dependency is unwatched.

**new** means the situation changed since the last run. **repeat** means the
same thing is still true, which is why the same `high` row can sit there for
days without anyone needing to look at it twice.

## What to do about it

The commands are in `docs/guides/dependency-watch.md`, one section per check.
The two rules worth knowing without opening it:

- A fix that touches `Sources/` never merges on a compile alone. The ladder is
  drift check, compile, CI on a pull request into `kelpie`, then a device build
  and the checklist in [[Open items]]. Build commands live in
  [[Build and deploy]].
- The protocol version is a **floor**, never an equality. Enforcing equality
  once made every 0.8.0 Host unusable.

Findings of medium or high become GitHub issues on the fork, one per check,
labelled `depwatch`. New high findings that need judgement rather than typing
get a short written analysis from a headless Claude run attached to the issue.

## How it was switched on

- 2026-09-12: built, reviewed (six fixes), committed, pushed; `com.kelpie.depwatch` loaded with Anthony's yes, publishing on. First live run opened issue #1 (CI had never run on the fork).
- PR #2, the first into `kelpie`, made CI real: fetch the vendored libghostty artifact on the runner, boot an iPad simulator, drop `libghostty-spm` from the licence inventory's Package.resolved coverage, pin the phone idiom in the zoom tests. Five attempts to green; three were transient real-SSH fixture failures, so a red run is re-run once before it counts.
- The mini is watched through a dedicated key (`~/.ssh/kelpie-depwatch`, `Host mac-mini`); it runs herdr 0.8.2 against a 0.9.0 snapshot, which is behind, not ahead, so info.
- Still open: the morning brief does not read the handoff file yet ([[Open items]] 12).

## Where things live

- Reports, state and logs: `~/.kelpie/depwatch/` — never in the repo.
- Latest report: `~/.kelpie/depwatch/reports/latest.md`.
- Morning-brief handoff: `~/.memoryos/kelpie-depwatch-briefing.json` (written
  every run; nothing reads it yet).

## Last run

Everything between the markers below is rewritten by the watcher on every run.
Prose above and below them survives, so notes here are safe.

<!-- depwatch:begin -->
_Last run: 2026-09-24T19-45-06Z UTC._

| Check | Severity | State | Headline |
| --- | --- | --- | --- |
| `herdr-release` | info | repeat | herdr v0.9.1, snapshot current |
| `herdr-mini` | info | repeat | mini runs herdr 0.9.1 (snapshot v0.9.1) |
| `heeler-upstream` | high | repeat | 156 commits behind upstream, 1 conflicting file |
| `libghostty-spm` | low | repeat | libghostty upstream.82938b633ba6 pinned, upstream.3c47ca159368-2 available |
| `heeler-ssh-pins` | low | repeat | OpenSSL 3.6.3 pinned, openssl-3.6.4 in line |
| `node` | info | repeat | npm audit: 0 vulnerabilities |
| `toolchain` | info | repeat | Xcode 26.4.1, 26.4.1 |
| `ci-fork` | info | repeat | fork CI latest: success |
| `relay` | info | repeat | push relay healthy (HTTP 404) |
| `review-host` | info | repeat | review host reachable |

### Needs attention

- **156 commits behind upstream, 1 conflicting file** — Tag first: `git tag kelpie-pre-rebase-$(date +%Y%m%d)`.
<!-- depwatch:end -->
