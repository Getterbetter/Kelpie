#!/bin/bash
# Stage B of the dependency watch: the judgement lane.
#
# scripts/depwatch.py answers "what moved". Some findings need a reading of the
# upstream change before anyone can say what Kelpie should do about it — an
# upstream rebase with conflicts in Sources/, a herdr method Kelpie calls that
# changed shape, a security advisory against a pinned library. For each NEW
# `high` finding on the `manual` lane this runs one bounded headless Claude job
# that writes an analysis brief, then posts it to the finding's issue (with
# --publish in DEPWATCH_FLAGS) or saves it under reports/.
#
# At most two analyses per run: this is the expensive lane, and two is as many
# as anyone reads over a coffee. Locking is scripts/depwatch.sh's job — run
# this on its own only when no scheduled run is in flight.

set -uo pipefail

export HOME="${HOME:-/Users/anthonytopalides}"
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

REPO="${KELPIE_REPO:-$HOME/Developer/Kelpie}"
STATE_DIR="${DEPWATCH_STATE_DIR:-$HOME/.kelpie/depwatch}"
LOG="$STATE_DIR/depwatch.log"
LATEST="$STATE_DIR/reports/latest.json"
PYTHON="${DEPWATCH_PYTHON:-/usr/bin/python3}"
RUNNER="$REPO/scripts/run-with-timeout.py"
MAX_ANALYSES="${DEPWATCH_MAX_ANALYSES:-2}"
TIMEOUT_SECONDS="${DEPWATCH_ANALYSIS_TIMEOUT:-900}"   # 15 minutes
TS="$(date '+%Y%m%dT%H%M%SZ')"

PUBLISH=0
case " ${DEPWATCH_FLAGS:-} " in *" --publish "*) PUBLISH=1 ;; esac

mkdir -p "$STATE_DIR/reports"

[ -f "$LATEST" ] || { echo "$(date '+%F %T')  analysis: no $LATEST" >>"$LOG"; exit 0; }
[ -f "$RUNNER" ] || { echo "$(date '+%F %T')  analysis: missing $RUNNER" >>"$LOG"; exit 1; }

CLAUDE_BIN="$(command -v claude || true)"
if [ -z "$CLAUDE_BIN" ]; then
  for p in "$HOME/.local/bin/claude" "$HOME/.claude/local/claude" /opt/homebrew/bin/claude /usr/local/bin/claude; do
    [ -x "$p" ] && CLAUDE_BIN="$p" && break
  done
fi
[ -z "$CLAUDE_BIN" ] && { echo "$(date '+%F %T')  analysis: claude binary not found" >>"$LOG"; exit 1; }

# One line per selected finding: "<check>\t<compact finding JSON>".
SELECTED="$("$PYTHON" - "$LATEST" "$MAX_ANALYSES" <<'PY'
import json, sys
try:
    findings = json.load(open(sys.argv[1]))["findings"]
except Exception:
    sys.exit(0)
limit = int(sys.argv[2])
chosen = [f for f in findings
          if f.get("new") and f.get("severity") == "high" and f.get("lane") == "manual"]
for finding in chosen[:limit]:
    finding.pop("data", None)
    print("%s\t%s" % (finding["check"], json.dumps(finding)))
PY
)"

[ -z "$SELECTED" ] && exit 0

while IFS=$'\t' read -r CHECK FINDING_JSON; do
  [ -z "$CHECK" ] && continue
  WORKTREE="$STATE_DIR/worktrees/analyse-$TS-$CHECK"
  PROMPT="$STATE_DIR/reports/analysis-prompt-$CHECK-$TS.txt"
  OUTPUT="$STATE_DIR/reports/analysis-$CHECK-$TS.md"

  git -C "$REPO" worktree add --detach "$WORKTREE" kelpie >/dev/null 2>&1 || {
    echo "$(date '+%F %T')  analysis($CHECK): could not create a worktree" >>"$LOG"
    continue
  }

  cat >"$PROMPT" <<EOF
You are analysing one finding from Kelpie's dependency watch. Kelpie is
Anthony's iPadOS fork of Heeler, an SSH client for herdr; you are in a detached
worktree of the \`kelpie\` branch. Read CLAUDE.md first.

The finding, verbatim JSON:

$FINDING_JSON

Write a brief, at most 400 words, plain English, no em-dashes, in this order:

1. What actually changed. Cite upstream files and line numbers you verified by
   reading them or by \`gh api\`, not from memory.
2. Which Kelpie files this touches, and which "Load-bearing herdr facts" in
   CLAUDE.md it invalidates or re-stamps.
3. The smallest safe change. Say plainly if the answer is "do nothing yet".
4. The verification steps in order: \`python3 scripts/generate-wire-types.py
   --check --schema scripts/herdr-schema.json\`, compile for
   \`generic/platform=iOS\`, a PR into \`kelpie\` so CI runs on the fork, then a
   device build and the checklist in KelpieVault/Open items.md.
5. The risks, including anything that could only be caught on the device.

Do not edit, create or delete any file. Do not run git commands that write.
Output the brief itself, nothing else.
EOF

  echo "$(date '+%F %T')  analysis($CHECK): starting" >>"$LOG"
  "$PYTHON" "$RUNNER" \
    --timeout-seconds "$TIMEOUT_SECONDS" \
    --label "depwatch-analysis-$CHECK" \
    --diagnostics-dir "$STATE_DIR/reports/analysis-diagnostics-$CHECK-$TS" \
    -- /bin/sh -c "cd '$WORKTREE' && '$CLAUDE_BIN' -p --model opus --output-format text \
       --permission-mode dontAsk \
       --allowedTools \"Read,Grep,Glob,Bash(git *),Bash(gh api *),Bash(gh issue view *)\" \
       --max-turns 40 < '$PROMPT' > '$OUTPUT'"
  RC=$?

  git -C "$REPO" worktree remove --force "$WORKTREE" >/dev/null 2>&1
  git -C "$REPO" worktree prune >/dev/null 2>&1

  if [ "$RC" -ne 0 ] || [ ! -s "$OUTPUT" ]; then
    echo "$(date '+%F %T')  analysis($CHECK): failed (rc=$RC)" >>"$LOG"
    continue
  fi
  echo "$(date '+%F %T')  analysis($CHECK): wrote $OUTPUT" >>"$LOG"

  if [ "$PUBLISH" -eq 1 ]; then
    ISSUE="$("$PYTHON" - "$STATE_DIR/state.json" "$CHECK" <<'PY'
import json, sys
try:
    state = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
entry = (state.get("issues") or {}).get(sys.argv[2]) or {}
print(entry.get("number", ""))
PY
)"
    if [ -n "$ISSUE" ]; then
      gh issue comment "$ISSUE" -R Getterbetter/Kelpie --body-file "$OUTPUT" >/dev/null 2>&1 && \
        echo "$(date '+%F %T')  analysis($CHECK): commented on issue #$ISSUE" >>"$LOG"
    else
      echo "$(date '+%F %T')  analysis($CHECK): no issue recorded; brief kept at $OUTPUT" >>"$LOG"
    fi
  fi
done <<EOF
$SELECTED
EOF

exit 0
