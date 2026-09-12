# Round 10 review — depwatch (Opus reviewer, fresh context, 2026-09-12)

Cold runs: 45 unit tests pass on `/usr/bin/python3`; `--dry-run` completes all ten checks with no `error`, leaves no `~/.kelpie`, no worktree. Forced herdr drift (state tag set to v0.8.2): the v0.9.0 schema was downloaded, drift computed as identical, severity `low`, regen worktree created and removed; with a doctored cached schema (protocol 23, `pane.read` removed, `agent.list` changed) the finding went `high` and `--prepare --dry-run` printed the full would-do list without creating anything.

Must-fix: none. Should-fix, all applied by Fable before commit `bef44c7`:

1. Worktree cleanup had no `try/finally`; a raise in prepare or publish leaked a worktree.
2. `snapshot_tag` never advanced, so `herdr-release` could never return to `info` and its issue never closed.
3. `ci-fork` counted `CI (Node)` as the iOS lane (`startswith("ci")`).
4. `toolchain` took the first iOS device devicectl listed (an iPhone) and fingerprinted on its name; now prefers the Kelpie iPad by UDID and fingerprints on the OS version only.
5. `--prepare` branched even when regeneration had failed.
6. A non-identical schema with zero method drift scored `low`; now `medium`.

Nits taken later in PR #2: shell-quoted compile paths; `npm audit` on the network timeout. Nits left: only `info` closes issues (per spec); the repo advisory feeds return `[]` for both OpenSSL and libssh2, which the guide records as a real limit.
