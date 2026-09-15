#!/bin/bash
# Regression test for scripts/ghostty-override-diff.py against the one
# re-vendor that broke things (round 16, 2026-09-15): the vendored copy and
# Kelpie's sources at tag kelpie-pre-rebase-20260915 against the vendored copy
# at HEAD must name the three collisions that round hit at compile time, and
# the current vendored copy against itself must be clean. No network: both
# sides are read from this repository's history.
#
#   sh scripts/test-ghostty-override-diff.sh

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
python_bin="${DEPWATCH_PYTHON:-/usr/bin/python3}"
script="$repo_root/scripts/ghostty-override-diff.py"
tag="kelpie-pre-rebase-20260915"

cd "$repo_root"
git rev-parse -q --verify "$tag^{commit}" >/dev/null || {
    echo "tag $tag is missing; the round-16 case cannot be replayed" >&2
    exit 1
}

out="$("$python_bin" "$script" --old "kelpie:$tag" --new kelpie:HEAD --kelpie-rev "$tag" --no-fetch)" && rc=0 || rc=$?
[ "$rc" -eq 1 ] || { echo "expected exit 1 (findings) for the round-16 case, got $rc"; echo "$out"; exit 1; }

expect() {
    grep -qF -- "$1" <<<"$out" || { echo "missing from the round-16 report: $1"; echo "$out"; exit 1; }
}
expect "[COLLISION] handleEscapeKeyCommand(_:)"
expect "[CONFORMANCE] UIDropInteractionDelegate"
expect "[COLLISION] dropInteraction(_:performDrop:)"
expect "[COLLISION] gestureRecognizer(_:shouldRecognizeSimultaneouslyWith:)"
expect "[API SIGNATURE] TerminalSurface.sendMousePos(x:y:modifiers:)"
expect "[BODY] keyCommands"

# A private, non-@objc upstream twin is invisible across modules: context, not a finding.
grep -qF -- "[COLLISION] escapeKeyCommands" <<<"$out" && { echo "escapeKeyCommands must not be a collision"; exit 1; }
expect "shadow: Kelpie's escapeKeyCommands"

# Same tree on both sides: nothing to report.
"$python_bin" "$script" --old kelpie:HEAD --new kelpie:HEAD --no-fetch >/dev/null || {
    echo "HEAD against itself must exit 0"; exit 1; }

echo "ghostty-override-diff: round-16 case reproduced, self-diff clean"
