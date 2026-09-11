# Rebase of `kelpie` onto `upstream/main` — 2026-09-11

Base before: kelpie tip `76ed711`, merge-base `90e01a9`. upstream/main tip `375267c`.
Backup tag `kelpie-pre-rebase-20260911` untouched. Nothing pushed.

## Rebase

`GIT_EDITOR=true git rebase upstream/main` — 36 commits replayed. Two conflicts, both
in `CHANGELOG.md`, both the anchor the recon predicted (`### Added` inserted right after
`## [Unreleased]` on both sides).

1. **Step 20/36**, commit `77cabda` *feat(client): Escape and Option word keys reach herdr;
   labelled host menu*. HEAD side carried upstream's `### Added` (muse #297, Direct Input
   Paste key #307); Kelpie side carried a `### Changed` block (labelled host-menu capsule).
   Resolved by keeping both, upstream's `### Added` first, then Kelpie's `### Changed`,
   then the pre-existing `### Fixed`.
2. **Step 23/36**, commit `a2d66a2` *feat(onboarding): Welcome screen, paste-first pairing,
   QR fixes*. Both sides were bullets inside the same `### Added` list. Resolved by
   appending Kelpie's Welcome-screen bullet after upstream's two bullets in one list.

No other conflicts. No file the recon called clean conflicted. No Kelpie content dropped.

Resolution helper: `resolve.py` in this folder (concatenates ours-then-theirs for a
conflict hunk, inserting a blank line only when the second side starts a new heading).

## Post-rebase state

- `git log --oneline upstream/main..kelpie | wc -l` → **36** (expected).
- `git diff kelpie-pre-rebase-20260911 kelpie --stat -- Sources/Heeler/Client Sources/Heeler/Terminal`
  → **empty**. Kelpie-only files intact.
- `CLAUDE.md`: Kelpie section still first (line 1 `# Kelpie`), upstream's new Heeler body
  underneath — 0.9.0 / `dropSnapshotSubscriptions` text present. Clean auto-merge as predicted.
- `HeelerSSHTransport.swift`: upstream's `generatedProtocolVersion = 22` (line 287) sits
  directly above Kelpie's `downloadTimeout` (line 292) — the adjacent-hunk risk the recon
  flagged resolved correctly, both present.
- `xcodegen generate` → project regenerated, `git status` **clean**, so **no regen commit
  was needed** (upstream added no files the committed pbxproj was missing).

## Build

`Artifacts/GhosttyKit.xcframework` is absent at the repo root, but
`scripts/fetch-ghostty-artifact.sh` (via `make generate`) reports "already present" —
it lives under the vendored package, not the root path the brief named. `make generate`
left the tree clean.

Device build, Release, physical iPad `09D7738D-2173-55EF-8966-A9C3EA1D0514`:

```
** BUILD SUCCEEDED **   (exit 0, zero `error:` lines)
```

Log: `/private/tmp/claude-501/-Users-anthonytopalides-Developer-Kelpie/6918c0d2-ef95-4c15-9608-4b7a2925730c/scratchpad/build/rebase-build.log`

Notable: the previously-uncompiled `.menuStyle(.button)` in
`Sources/Heeler/Client/HerdrClientRootView.swift` compiled without change, and no
upstream API rename (`workspace.close` → `WorkspaceCloseParams`, `generatedProtocolVersion`
20→22) needed a Kelpie-side adaptation. **No `fix: adapt to upstream after rebase` commit
was required.**

## Final

- Branch `kelpie` rebased, working tree clean, 36 commits ahead of `upstream/main`.
- Tip `98187d3 refactor(terminal, client): take the round-2 reviewer nits`.
- Backup tag `kelpie-pre-rebase-20260911` still points at the old `76ed711`.
- Nothing pushed; nothing installed on the device; `Packages/` untouched.
