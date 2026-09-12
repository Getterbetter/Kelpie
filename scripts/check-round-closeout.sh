#!/bin/bash
#
# Round close-out guard. Run by .githooks/pre-push and by `make closeout-check`.
#
# Three checks, in order:
#
#   1. Upstream ancestry — the branch must still descend from the upstream base
#      commit. A `git filter-repo` rewrites the shared history too, which leaves
#      `kelpie` with no common object with upstream (round 11b, 2026-09-12).
#      Runs on every push.
#   2. Vault reconciliation — every round in resume.md's "Where things stand"
#      must have a section in KelpieVault/Changelog.md and one in
#      KelpieVault/Decisions.md (CLAUDE.md, "Definition of done for a round").
#      Runs only when the push carries the `kelpie` branch.
#   3. Open items numbering — no duplicate item numbers in
#      KelpieVault/Open items.md. Same gate as 2.
#
# Usage:
#   scripts/check-round-closeout.sh            # run every check (manual / make)
#   scripts/check-round-closeout.sh --hook     # pre-push: read refs on stdin
#
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

# The upstream Heeler commit `kelpie` is parented on. Pinned deliberately: every
# future upstream tip descends from it, so the pin never goes stale, while a
# `git filter-repo` is exactly what makes it vanish from the branch.
UPSTREAM_BASE="375267c"

# How far ahead of upstream/main the branch may be. The round-11 purge produced
# 1252 (it had replayed upstream's own history as Kelpie commits); a healthy
# branch is under 100. Only checked when upstream/main is fetched here.
MAX_AHEAD=400

RESUME="resume.md"
CHANGELOG="KelpieVault/Changelog.md"
DECISIONS="KelpieVault/Decisions.md"
OPEN_ITEMS="KelpieVault/Open items.md"

# Rounds deliberately exempt from the vault check. Add a round here only with a
# reason; the default answer is to write the missing section, not to allow it.
# (Empty today: every round in resume.md is reconciled.)
ALLOW=()

failed=0
fail() { printf '\n  %s\n' "$1" >&2; failed=1; }

hook_mode=0
[ "${1:-}" = "--hook" ] && hook_mode=1

# --- which checks to run, and which commits to check -------------------------
# Manual runs check HEAD. In the hook we read the refs git puts on stdin
# (<local ref> <local sha> <remote ref> <remote sha>) and check the local sha of
# each pushed ref, so pushing a branch that is not checked out, or pushing part
# way through a rebase, tests the commit actually going to the remote.
run_vault=1
commits=()
if [ "$hook_mode" = 1 ]; then
  run_vault=0
  while read -r local_ref local_sha remote_ref _; do
    [ -z "${local_ref:-}" ] && continue
    case "$local_sha" in
      *[!0]*) ;;                      # a real sha
      *) continue ;;                  # all zeroes: this ref is being deleted
    esac
    commits+=("$local_sha")
    case "$local_ref$remote_ref" in
      *refs/heads/kelpie*) run_vault=1 ;;
    esac
  done
else
  commits=("$(git rev-parse HEAD)")
fi

# --- 1. upstream ancestry ----------------------------------------------------
base="$(git rev-parse --verify --quiet "$UPSTREAM_BASE^{commit}" 2>/dev/null)"
upstream_tip="$(git rev-parse --verify --quiet upstream/main 2>/dev/null)"

if [ -z "$base" ]; then
  fail "The pinned upstream base commit $UPSTREAM_BASE is not in this repository.
  Either the history was rewritten out from under it, or this is not the Kelpie
  checkout. Fetch upstream (git fetch upstream) and check the branch's parentage
  before pushing."
else
  for commit in ${commits+"${commits[@]}"}; do
    short="$(git rev-parse --short "$commit" 2>/dev/null || echo "$commit")"
    if ! git merge-base --is-ancestor "$base" "$commit" 2>/dev/null; then
      fail "The branch shares no commit with upstream — re-parent with git rebase --onto
  before pushing (see KelpieVault/Decisions.md, round 11b).
  Commit checked: $short; base: $UPSTREAM_BASE.
  This is what a git filter-repo does: it rewrites the shared history as well as
  your own commits, so every future rebase would replay upstream's own commits."
      continue
    fi
    [ -n "$upstream_tip" ] || continue
    ahead="$(git rev-list --count "upstream/main..$commit" 2>/dev/null || echo 0)"
    if [ "$ahead" -gt "$MAX_AHEAD" ]; then
      fail "$short is $ahead commits ahead of upstream/main, over the $MAX_AHEAD limit — the
  branch has probably replayed upstream's own history as its own commits.
  Re-parent with git rebase --onto (see KelpieVault/Decisions.md, round 11b).
  If the fork has genuinely grown this far, raise MAX_AHEAD in this script."
    fi
  done
fi

# --- 2 and 3, only for a push that carries `kelpie` --------------------------
if [ "$run_vault" = 1 ]; then

  # Sort key for a round token: 7b -> 07002, 9 -> 09000. The empty suffix sorts
  # first, so "rounds 7b to 9" covers 7b, 7c, 8 and 9 but not plain 7.
  round_key() {
    local token="$1" num suffix key=0 i ch
    num="${token%%[a-z]*}"
    suffix="${token#"$num"}"
    for ((i = 0; i < ${#suffix}; i++)); do
      ch="${suffix:i:1}"
      key=$((key * 26 + $(printf '%d' "'$ch") - 96))
    done
    printf '%05d%03d' "$num" "$key"
  }

  for f in "$RESUME" "$CHANGELOG" "$DECISIONS" "$OPEN_ITEMS"; do
    [ -f "$f" ] || fail "Missing $f — the vault check cannot run."
  done
  [ "$failed" = 1 ] && exit 1

  # Rounds claimed in resume.md's "Where things stand" section.
  rounds="$(awk '
    /^## Where things stand/ { inside = 1; next }
    /^## / { inside = 0 }
    inside && match($0, /^- Round [0-9]+[a-z]?/) {
      token = substr($0, 9, RLENGTH - 8); print token
    }' "$RESUME" | sort -u)"

  if [ -z "$rounds" ]; then
    fail "No '- Round N' bullets found under '## Where things stand' in $RESUME —
  either the section was renamed or the bullets changed shape. Fix the script or
  the file; a silent pass here is how round 11 went unreconciled."
  fi

  # Round headings in Decisions.md, plus any "rounds A to B" ranges they declare.
  decisions_headings="$(grep -i '^## .*rounds\{0,1\} [0-9]' "$DECISIONS" || true)"

  missing_changelog=()
  missing_decisions=()
  for round in $rounds; do
    allowed=0
    for a in ${ALLOW+"${ALLOW[@]}"}; do [ "$a" = "$round" ] && allowed=1; done
    [ "$allowed" = 1 ] && continue

    grep -Eq "^## Round ${round}([^0-9a-z]|$)" "$CHANGELOG" || missing_changelog+=("$round")

    if ! grep -Eqi "^## .*round ${round}([^0-9a-z]|$)" "$DECISIONS"; then
      # Not named directly — is it inside a "rounds A to B" heading?
      covered=0
      key="$(round_key "$round")"
      while read -r from to; do
        [ -z "$from" ] && continue
        [ "$key" \> "$(round_key "$from")" ] || [ "$key" = "$(round_key "$from")" ] || continue
        [ "$key" \< "$(round_key "$to")" ] || [ "$key" = "$(round_key "$to")" ] || continue
        covered=1
      done <<< "$(printf '%s\n' "$decisions_headings" \
        | sed -n 's/.*rounds \([0-9][0-9]*[a-z]*\) to \([0-9][0-9]*[a-z]*\).*/\1 \2/p')"
      [ "$covered" = 1 ] || missing_decisions+=("$round")
    fi
  done

  if [ ${#missing_changelog[@]} -gt 0 ]; then
    fail "$RESUME claims rounds that $CHANGELOG never wrote up: ${missing_changelog[*]}.
  Add a '## Round <n> — <title> — <date>' section with the round's commits before
  pushing. A round is not done until the vault says so (CLAUDE.md, 'Definition of
  done for a round')."
  fi
  if [ ${#missing_decisions[@]} -gt 0 ]; then
    fail "$RESUME claims rounds that $DECISIONS never wrote up: ${missing_decisions[*]}.
  Add a '## <date> — round <n>: <title>' section saying what was decided and why.
  A combined heading ('rounds 7b to 9') covers the rounds in its range."
  fi

  # --- 3. open items numbering ---
  dupes="$(grep -o '\*\*[0-9][0-9a-z]*\.' "$OPEN_ITEMS" \
    | sort | uniq -d | tr -d '*.' | tr '\n' ' ')"
  if [ -n "$dupes" ]; then
    fail "Duplicate item numbers in $OPEN_ITEMS: ${dupes% }.
  Two items sharing a number make 'open item 12' ambiguous in every other note.
  Renumber the later one and fix the references to it."
  fi
fi

if [ "$failed" = 1 ]; then
  printf '\nRound close-out check failed. Run `make closeout-check` after fixing.\n' >&2
  exit 1
fi

echo "Round close-out check passed."
