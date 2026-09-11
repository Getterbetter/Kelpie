#!/bin/sh
# drive-ipad.sh — drive Kelpie on Anthony's plugged-in, UNLOCKED iPad and
# bring the screenshots back.
#
#   scripts/drive-ipad.sh "shot;menu;shot;key:escape;shot"
#   scripts/drive-ipad.sh --dump
#
# The arguments are one `;`-separated step script (see
# docs/guides/driving-the-ipad.md for the grammar); it is handed to the
# HeelerUITests/Drive driver through KELPIE_DRIVE_STEPS, which replays the
# steps in order and attaches a screenshot after each. Every attachment is
# exported out of the result bundle as a PNG named after its step.
#
# The run TAKES OVER the iPad for its duration — it launches Kelpie fresh and
# taps its way through the script. The device must be unlocked the whole time.
#
# Env: DEVICE (devicectl identifier), KELPIE_SCRATCH (build + output root).

set -eu

REPO="$(cd "$(dirname "$0")/.." && pwd)"
DEVICE="${DEVICE:-09D7738D-2173-55EF-8966-A9C3EA1D0514}"
SCRATCH="${KELPIE_SCRATCH:-/private/tmp/claude-501/-Users-anthonytopalides-Developer-Kelpie/6918c0d2-ef95-4c15-9608-4b7a2925730c/scratchpad/build}"

TEST="HeelerUITests/Drive/testDrive"
if [ "${1:-}" = "--dump" ]; then
    TEST="HeelerUITests/Drive/testDump"
    shift
fi

STEPS="$*"
if [ "$TEST" = "HeelerUITests/Drive/testDrive" ] && [ -z "$STEPS" ]; then
    echo "usage: $0 \"step;step;...\"   |   $0 --dump" >&2
    echo "steps: shot wait:<s> menu menu:<item> tap:<label> toggle:<label> type:<text> key:<name> back swipe:<dir> dump" >&2
    exit 2
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
RUNS="$SCRATCH/drive"
RESULT="$RUNS/$STAMP.xcresult"
OUT="$RUNS/$STAMP"
LOG="$RUNS/$STAMP.log"
mkdir -p "$RUNS" "$OUT"
rm -rf "$RESULT"

echo "== driving $DEVICE (iPad must be unlocked)"
echo "== steps: ${STEPS:-<dump>}"

export KELPIE_DRIVE_STEPS="$STEPS"

set +e
xcodebuild test \
    -project "$REPO/Heeler.xcodeproj" \
    -scheme HeelerUIDrive \
    -destination "platform=iOS,id=$DEVICE" \
    -clonedSourcePackagesDirPath "$SCRATCH/kelpie-spm" \
    -derivedDataPath "$SCRATCH/kelpie-dd" \
    -resultBundlePath "$RESULT" \
    -allowProvisioningUpdates \
    -only-testing:"$TEST" \
    > "$LOG" 2>&1
STATUS=$?
set -e

echo "== xcodebuild exit $STATUS (log: $LOG)"
tail -n 25 "$LOG"

if [ ! -d "$RESULT" ]; then
    echo "== no result bundle — nothing to export"
    exit "$STATUS"
fi

echo "== export attachments"
xcrun xcresulttool export attachments --path "$RESULT" --output-path "$OUT" >/dev/null

# The exporter writes UUID filenames plus manifest.json; rename them to the
# attachment names the driver chose (01-shot, 02-menu, ...) so the step order
# is readable from the directory listing.
python3 - "$OUT" <<'PYEOF'
import json, os, re, shutil, sys
out = sys.argv[1]
manifest = os.path.join(out, "manifest.json")
if not os.path.exists(manifest):
    print("no manifest.json — files left with exported names")
    sys.exit(0)
data = json.load(open(manifest))

def walk(node):
    if isinstance(node, dict):
        for att in node.get("attachments", []):
            yield att
        for value in node.values():
            if isinstance(value, (list, dict)):
                yield from walk(value)
    elif isinstance(node, list):
        for item in node:
            yield from walk(item)

renamed = 0
for att in walk(data):
    src_name = att.get("exportedFileName") or att.get("fileName")
    nice = att.get("suggestedHumanReadableName") or att.get("name")
    if not src_name or not nice:
        continue
    src = os.path.join(out, src_name)
    if not os.path.exists(src):
        continue
    ext = os.path.splitext(src_name)[1] or ".png"
    # XCTest decorates the attachment name it suggests with an index and a
    # UUID ("01-shot_0_9F3C....png"); the step name alone is the point.
    nice = re.sub(r"_\d+_[0-9A-Fa-f-]{36}", "", nice)
    if not nice.lower().endswith(ext.lower()):
        nice += ext
    stem, suffix = os.path.splitext(nice)
    candidate, bump = nice, 1
    while os.path.exists(os.path.join(out, candidate)):
        candidate = f"{stem}-{bump}{suffix}"
        bump += 1
    shutil.move(src, os.path.join(out, candidate))
    renamed += 1
print(f"renamed {renamed} attachments")
PYEOF

echo "== $OUT"
ls -la "$OUT"
exit "$STATUS"
