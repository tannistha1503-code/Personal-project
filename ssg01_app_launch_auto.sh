#!/system/bin/sh
# SSG-01: Install APK and measure app launch with background writes ON/OFF.
#
# Usage:
#   sh ssg01_app_launch.sh on|off <apk_path> [cgroup] [4k|128k]
#
# Example:
#   sh ssg01_app_launch.sh on /data/local/tmp/driving-school-evo-mod_1.96.0-an1.com.apk /dev/blkio/background 4k
#   sh ssg01_app_launch.sh off /data/local/tmp/driving-school-evo-mod_1.96.0-an1.com.apk
#
# Package name and launcher activity are detected automatically.
# APK metadata extraction requires aapt/aapt2 on the device. If unavailable,
# the script can identify a newly installed package by comparing package lists,
# but an already-installed APK requires aapt/aapt2.

MODE="$1"
APK="$2"
CGROUP="${3:-/dev/blkio/background}"
BS="${4:-4k}"

OUT="/data/ssg01_logs"
DATA="/data/ssg01_bg"
WRITERS=8
QD=32
RUNTIME=300
LAUNCHES=10
GAP=3

FIO="$(command -v fio)"
AAPT="$(command -v aapt)"
AAPT2="$(command -v aapt2)"

usage() {
    echo "Usage: sh $0 on|off <apk_path> [cgroup] [4k|128k]"
    exit 2
}

[ "$MODE" = "on" ] || [ "$MODE" = "off" ] || usage
[ -n "$APK" ] && [ -f "$APK" ] || { echo "ERROR: APK not found: $APK"; usage; }
case "$BS" in
    4k|128k) ;;
    *) echo "ERROR: block size must be 4k or 128k"; exit 2 ;;
esac
[ "$MODE" != "on" ] || [ -n "$FIO" ] || { echo "ERROR: fio not found"; exit 1; }

mkdir -p "$OUT" "$DATA" || exit 1
RESULT="$OUT/${MODE}_${BS}_launch_times.csv"
FIO_LOG="$OUT/${MODE}_${BS}_fio.log"

# Try to obtain package and launcher activity directly from APK metadata.
PKG=""
ACTIVITY=""
if [ -n "$AAPT" ]; then
    BADGING="$("$AAPT" dump badging "$APK" 2>/dev/null)"
elif [ -n "$AAPT2" ]; then
    BADGING="$("$AAPT2" dump badging "$APK" 2>/dev/null)"
else
    BADGING=""
fi

if [ -n "$BADGING" ]; then
    PKG="$(echo "$BADGING" | sed -n "s/^package: name='\\([^']*\\)'.*/\\1/p" | head -n 1)"
    ACTIVITY="$(echo "$BADGING" | sed -n "s/^launchable-activity: name='\\([^']*\\)'.*/\\1/p" | head -n 1)"
fi

# Fallback: detect a package newly installed by this APK.
if [ -z "$PKG" ]; then
    BEFORE="$OUT/packages_before.txt"
    AFTER="$OUT/packages_after.txt"
    pm list packages | sed 's/^package://' | sort > "$BEFORE"

    echo "aapt/aapt2 not found or could not read APK metadata."
    echo "Installing APK, then checking for a newly added package..."
    pm install -r "$APK" || { echo "ERROR: APK installation failed"; exit 1; }

    pm list packages | sed 's/^package://' | sort > "$AFTER"
    PKG="$(comm -13 "$BEFORE" "$AFTER" | head -n 1)"

    if [ -z "$PKG" ]; then
        echo "ERROR: Could not determine package automatically."
        echo "Install aapt/aapt2 on the device, or provide package/activity manually."
        exit 1
    fi
else
    echo "Detected package: $PKG"
    pm install -r "$APK" || { echo "ERROR: APK installation failed"; exit 1; }
fi

[ -n "$PKG" ] || { echo "ERROR: package name detection failed"; exit 1; }

# Resolve the launchable activity from Android's package manager.
if [ -z "$ACTIVITY" ]; then
    RESOLVED="$(cmd package resolve-activity --brief "$PKG" 2>/dev/null | tail -n 1)"
    case "$RESOLVED" in
        */*) ACTIVITY="${RESOLVED#*/}" ;;
    esac
fi

if [ -z "$ACTIVITY" ]; then
    echo "ERROR: Could not determine launcher activity for $PKG."
    echo "Check: cmd package resolve-activity --brief $PKG"
    exit 1
fi

case "$ACTIVITY" in
    *.*) COMPONENT="$PKG/$ACTIVITY" ;;
    *) COMPONENT="$PKG/.$ACTIVITY" ;;
esac

echo "Detected package: $PKG"
echo "Detected activity: $ACTIVITY"
echo "Launch component: $COMPONENT"

if [ "$MODE" = "on" ]; then
    [ -d "$CGROUP" ] || { echo "ERROR: cgroup not found: $CGROUP"; exit 1; }
    [ -w "$CGROUP/tasks" ] || { echo "ERROR: cannot write $CGROUP/tasks; run as root"; exit 1; }
fi

PIDS=""
cleanup() {
    for p in $PIDS; do kill "$p" 2>/dev/null; done
    for p in $PIDS; do wait "$p" 2>/dev/null; done
}
trap 'cleanup' INT TERM

echo "Timestamp,LaunchNumber,ThisTime,TotalTime,WaitTime" > "$RESULT"
echo "Mode=$MODE Package=$PKG Component=$COMPONENT BlockSize=$BS"

if [ "$MODE" = "on" ]; then
    : > "$FIO_LOG"
    echo "Starting $WRITERS background fio writers..."
    i=1
    while [ "$i" -le "$WRITERS" ]; do
        "$FIO" --name="bg_write_$i" \
            --filename="$DATA/bg_${BS}_${i}.bin" \
            --size=2G --rw=write --bs="$BS" \
            --ioengine=libaio --iodepth="$QD" \
            --direct=1 --time_based --runtime="$RUNTIME" \
            --group_reporting >> "$FIO_LOG" 2>&1 &
        p=$!
        echo "$p" > "$CGROUP/tasks" || {
            echo "ERROR: failed to assign fio PID $p to $CGROUP/tasks"
            kill "$p" 2>/dev/null
            cleanup
            exit 1
        }
        PIDS="$PIDS $p"
        i=$((i + 1))
    done
    sleep 5
    echo "Background fio PIDs: $PIDS"
else
    echo "Background writes OFF: measuring idle baseline."
fi

i=1
while [ "$i" -le "$LAUNCHES" ]; do
    echo "App launch $i/$LAUNCHES"
    am force-stop "$PKG" >/dev/null 2>&1
    sleep 1

    TMP="$OUT/launch_${MODE}_${BS}_${i}.tmp"
    am start -W -n "$COMPONENT" > "$TMP" 2>&1

    THIS_TIME="$(grep '^ThisTime:' "$TMP" | tail -n 1 | awk '{print $2}')"
    TOTAL_TIME="$(grep '^TotalTime:' "$TMP" | tail -n 1 | awk '{print $2}')"
    WAIT_TIME="$(grep '^WaitTime:' "$TMP" | tail -n 1 | awk '{print $2}')"
    TS="$(date '+%Y-%m-%d_%H:%M:%S')"

    echo "$TS,$i,${THIS_TIME:-NA},${TOTAL_TIME:-NA},${WAIT_TIME:-NA}" >> "$RESULT"
    cat "$TMP"
    sleep "$GAP"
    i=$((i + 1))
done

if [ "$MODE" = "on" ]; then
    echo "App launch measurements complete; stopping background fio writers."
    cleanup
    PIDS=""
    echo "fio log: $FIO_LOG"
fi

echo "Launch results: $RESULT"
