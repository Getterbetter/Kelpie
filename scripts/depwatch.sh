#!/bin/bash
# Kelpie dependency watch. Runs daily at 05:45 via launchd
# (com.kelpie.depwatch), twenty minutes before the 06:05 morning-brief build so
# the brief can pick up ~/.memoryos/kelpie-depwatch-briefing.json.
#
# All the work is in scripts/depwatch.py; this wrapper is env, lock and logging
# only, the same shape as ~/.memoryos/territory-refresh.sh. When the run turns
# up new high findings on a judgement lane it hands them to
# scripts/depwatch-analyse.sh.
#
# Run it by hand with `make depwatch` (or `make depwatch DRY=1`), not this file:
# the lock means a hand run during a scheduled one exits quietly.

set -uo pipefail

# --- Config ---------------------------------------------------------------
export HOME="${HOME:-/Users/anthonytopalides}"
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

REPO="${KELPIE_REPO:-$HOME/Developer/Kelpie}"
STATE_DIR="${DEPWATCH_STATE_DIR:-$HOME/.kelpie/depwatch}"
LOG="$STATE_DIR/depwatch.log"
LOCKDIR="$STATE_DIR/lock"
PYTHON="${DEPWATCH_PYTHON:-/usr/bin/python3}"

# What the scheduled run is allowed to do. `--publish` opens and updates the
# GitHub issues; add `--prepare` here to let it build fix branches too (that
# adds a compile of up to 20 minutes to the run — see the guide before turning
# it on at 05:45).
FLAGS="${DEPWATCH_FLAGS:---publish}"

mkdir -p "$STATE_DIR"
TS="$(date '+%F %T')"

[ -d "$REPO/.git" ] || { echo "$TS  FAIL(no checkout at $REPO)" >>"$LOG"; exit 1; }
[ -x "$PYTHON" ] || { echo "$TS  FAIL(no python at $PYTHON)" >>"$LOG"; exit 1; }

# --- Lock -----------------------------------------------------------------
# A SIGKILL or a power cut skips the EXIT trap and would otherwise wedge every
# future run. Clear the lock when the recorded holder is dead, or when an
# old-format lock with no pid is over 180 min old; a live holder still wins.
# A --prepare run with a compile can legitimately take half an hour.
if [ -d "$LOCKDIR" ]; then
  LOCK_PID="$(cat "$LOCKDIR/pid" 2>/dev/null || true)"
  if [ -n "$LOCK_PID" ] && kill -0 "$LOCK_PID" 2>/dev/null; then
    exit 0  # previous run genuinely still going
  fi
  if [ -n "$LOCK_PID" ] || [ -n "$(find "$LOCKDIR" -maxdepth 0 -mmin +180 2>/dev/null)" ]; then
    rm -rf "$LOCKDIR"
    echo "$(date '+%F %T')  WARN stale depwatch lock cleared (holder gone)" >>"$LOG"
  fi
fi
if ! mkdir "$LOCKDIR" 2>/dev/null; then exit 0; fi
echo $$ >"$LOCKDIR/pid"
trap 'rm -rf "$LOCKDIR" 2>/dev/null' EXIT

# --- Run ------------------------------------------------------------------
# Not exec: exec replaces this shell and skips the EXIT trap, which would leave
# the lock behind after every run.
# shellcheck disable=SC2086
"$PYTHON" "$REPO/scripts/depwatch.py" --state-dir "$STATE_DIR" --repo "$REPO" $FLAGS \
  >>"$STATE_DIR/depwatch.out.log" 2>>"$STATE_DIR/depwatch.err.log"
RC=$?

if [ "$RC" -ne 0 ]; then
  echo "$(date '+%F %T')  FAIL(depwatch.py exited $RC; see depwatch.err.log)" >>"$LOG"
  exit "$RC"
fi

# --- Stage B: judgement lane ----------------------------------------------
# Only when the run produced a NEW high finding whose lane is manual. The
# analysis script re-reads reports/latest.json and does its own selection; this
# is just the cheap gate that keeps a quiet day from starting Claude at all.
LATEST="$STATE_DIR/reports/latest.json"
if [ -f "$LATEST" ]; then
  NEEDS_ANALYSIS="$("$PYTHON" - "$LATEST" <<'PY'
import json, sys
try:
    findings = json.load(open(sys.argv[1]))["findings"]
except Exception:
    print("0")
else:
    print(sum(1 for f in findings
              if f.get("new") and f.get("severity") == "high" and f.get("lane") == "manual"))
PY
)"
  if [ "${NEEDS_ANALYSIS:-0}" -gt 0 ] 2>/dev/null; then
    echo "$(date '+%F %T')  analysis lane: $NEEDS_ANALYSIS new high manual finding(s)" >>"$LOG"
    DEPWATCH_STATE_DIR="$STATE_DIR" KELPIE_REPO="$REPO" DEPWATCH_FLAGS="$FLAGS" \
      /bin/bash "$REPO/scripts/depwatch-analyse.sh" >>"$STATE_DIR/depwatch.out.log" 2>&1 || \
      echo "$(date '+%F %T')  WARN depwatch-analyse.sh exited nonzero" >>"$LOG"
  fi
fi

exit 0
