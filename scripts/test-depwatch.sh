#!/bin/bash
# Unit tests for scripts/depwatch.py (pure functions only: no network, no git,
# no gh). Same shape as scripts/test-run-with-timeout.sh: run it, it exits
# nonzero when something is wrong.
#
#   sh scripts/test-depwatch.sh

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
python_bin="${DEPWATCH_PYTHON:-/usr/bin/python3}"

[ -x "$python_bin" ] || {
    echo "depwatch must run on the system python: $python_bin is missing" >&2
    exit 1
}

# 3.9.6 is what launchd gets; a newer python on PATH would hide a syntax
# feature the scheduled run cannot use.
"$python_bin" -c 'import sys; sys.exit(0 if sys.version_info[:2] >= (3, 9) else 1)' || {
    echo "python at $python_bin is older than 3.9" >&2
    exit 1
}

for script in "$repo_root/scripts/depwatch.py" "$repo_root/scripts/depwatch_test.py"; do
    [ -f "$script" ] || { echo "missing: $script" >&2; exit 1; }
    "$python_bin" -m py_compile "$script"
done

"$python_bin" -c "
import sys
sys.argv = ['depwatch.py', '--help']
sys.path.insert(0, '$repo_root/scripts')
import depwatch
depwatch.parse_arguments(['--dry-run'])
" >/dev/null

cd "$repo_root"
"$python_bin" -m unittest discover --start-directory scripts --pattern 'depwatch_test.py' --verbose

echo "depwatch tests passed"
