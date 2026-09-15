#!/usr/bin/env bash
# Run the full HeelerTests suite on the physical iPad, the iPhone, or both,
# and print a verdict a person can act on. This is the gate at the end of
# every change (Open item 39, Decisions 2026-09-15): a change is not done
# until this is green on both devices, where "green" means every recorded
# issue is zero and skips carry a reason.
#
#   scripts/device-tests.sh            # both, iPad first
#   scripts/device-tests.sh ipad
#   scripts/device-tests.sh iphone
#
# Waits up to DEVICE_WAIT seconds (default 900) for each device to be paired
# and connected, so it can be started before the device is plugged in. Builds
# in the fixed warm path (KELPIE_BUILD_DIR, default ~/Library/Caches/kelpie-build)
# and deletes the result bundle afterwards; the log stays at
# $KELPIE_BUILD_DIR/device-tests-<kind>.log, overwritten on every run.
set -u

S="${KELPIE_BUILD_DIR:-$HOME/Library/Caches/kelpie-build}"
WAIT="${DEVICE_WAIT:-900}"
PROJECT="${PROJECT:-Heeler.xcodeproj}"
SCHEME="${SCHEME:-Heeler}"
mkdir -p "$S"

kinds=("$@")
[ ${#kinds[@]} -eq 0 ] && kinds=(ipad iphone)

device_id() {
    # devicectl's table: Name  Hostname  Identifier  State  Model  Reality
    xcrun devicectl list devices 2>/dev/null | awk -v pat="$1" '
        $0 ~ pat && /physical *$/ && /available/ {
            for (i = 1; i <= NF; i++) if ($i ~ /^[0-9A-Fa-f-]{36}$/) { print $i; exit }
        }'
}

wait_for_device() {
    local kind="$1" pat="$2" waited=0 id
    id="$(device_id "$pat")"
    if [ -z "$id" ]; then
        echo "device-tests: waiting for the $kind (plug it in and unlock it; up to ${WAIT}s)"
    fi
    while [ -z "$id" ] && [ "$waited" -lt "$WAIT" ]; do
        sleep 10; waited=$((waited + 10))
        id="$(device_id "$pat")"
    done
    echo "$id"
}

overall=0
for kind in "${kinds[@]}"; do
    case "$kind" in
        ipad)   pat='iPad' ;;
        iphone) pat='iPhone' ;;
        *) echo "device-tests: unknown device kind '$kind' (ipad|iphone)"; exit 2 ;;
    esac
    id="$(wait_for_device "$kind" "$pat" | tail -n 1)"
    if [ -z "$id" ]; then
        echo "device-tests: no $kind connected after ${WAIT}s; skipping it"
        overall=1
        continue
    fi
    log="$S/device-tests-$kind.log"
    result="$S/device-tests-$kind.xcresult"
    rm -rf "$result"
    echo "device-tests: $kind ($id), log $log"
    start=$(date +%s)
    xcodebuild test -project "$PROJECT" -scheme "$SCHEME" \
        -destination "platform=iOS,id=$id" \
        -only-testing:HeelerTests \
        -clonedSourcePackagesDirPath "$S/kelpie-spm" -derivedDataPath "$S/kelpie-dd" \
        -resultBundlePath "$result" -allowProvisioningUpdates > "$log" 2>&1
    status=$?
    rm -rf "$result"
    elapsed=$(( $(date +%s) - start ))

    summary=$(grep -E '^[^a-zA-Z]*(✔|✘) Test run with' "$log" | tail -n 1)
    failures=$(grep -E '✘ Test .* recorded an issue' "$log" | sed -E 's/^[^✘]*✘ //' | cut -c1-220)
    skips=$(grep -cE '➜ (Test|Suite) .* skipped' "$log")
    echo
    echo "== $kind: ${summary:-no test summary in the log (exit $status)} [${elapsed}s]"
    echo "   skipped: $skips (grep '➜' $log for the reasons)"
    if [ -n "$failures" ]; then
        echo "   failures:"
        printf '     %s\n' "$failures"
        overall=1
    elif [ "$status" -ne 0 ]; then
        echo "   xcodebuild exited $status with no recorded test issue; read the log tail:"
        tail -n 15 "$log" | sed 's/^/     /'
        overall=1
    else
        echo "   green"
    fi
    echo
done
exit $overall
