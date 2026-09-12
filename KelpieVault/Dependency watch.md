---
note: What Kelpie depends on, what the daily watch checks at 05:45, and what to do when one of them moves.
---

# Dependency watch

[[Kelpie]] is a fork balanced on top of things that move without asking.
[[herdr]] ships a release most weeks and says plainly that its API has no
stability guarantee. [[Heeler upstream]] moves daily. The terminal engine is a
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

## Where things live

- Reports, state and logs: `~/.kelpie/depwatch/` — never in the repo.
- Latest report: `~/.kelpie/depwatch/reports/latest.md`.
- Morning-brief handoff: `~/.memoryos/kelpie-depwatch-briefing.json` (written
  every run; nothing reads it yet).

## Last run

Everything between the markers below is rewritten by the watcher on every run.
Prose above and below them survives, so notes here are safe.

<!-- depwatch:begin -->
_Last run: 2026-09-12T02-30-51Z UTC._

| Check | Severity | State | Headline |
| --- | --- | --- | --- |
| `herdr-release` | info | repeat | herdr v0.9.0, snapshot current |
| `herdr-mini` | info | repeat | mini_host not configured |
| `heeler-upstream` | info | repeat | level with upstream/main |
| `libghostty-spm` | low | repeat | libghostty upstream.1.3.1 pinned, upstream.82938b633ba6 available |
| `heeler-ssh-pins` | low | repeat | OpenSSL 3.6.3 pinned, openssl-3.6.4 in line |
| `node` | info | repeat | npm audit: 0 vulnerabilities |
| `toolchain` | info | repeat | Xcode 26.4.1, MomentRender2 26.4.1 |
| `ci-fork` | high | repeat | no successful CI run on the fork |
| `relay` | info | repeat | push relay healthy (HTTP 404) |
| `review-host` | info | repeat | review host reachable |

### Needs attention

- **no successful CI run on the fork** — Enable Actions on the fork: Settings -> Actions -> Allow all actions, or `gh api -X PUT repos/Getterbetter/Kelpie/actions/permissions -f enabled=true`.
<!-- depwatch:end -->
