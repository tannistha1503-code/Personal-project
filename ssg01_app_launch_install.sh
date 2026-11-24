#!/system/bin/sh
# SSG-01 app launch test with optional APK installation.
# Usage:
# sh ssg01_app_launch_install.sh on|off <apk_path|-> <package> <activity> [cgroup] [4k|128k]
# Use "-" as apk_path to skip installation. APK must already be on the device.

MODE="$1"; APK="$2"; PKG="$3"; ACTIVITY="$4"
CGROUP="${5:-/dev/blkio/background}"; BS="${6:-4k}"
OUT=/data/ssg01_logs; DATA=/data/ssg01_bg
WRITERS=8; QD=32; RUNTIME=300; LAUNCHES=10; GAP=3
FIO="$(command -v fio)"

usage() { echo "Usage: sh $0 on|off <apk_path|-> <package> <activity> [cgroup] [4k|128k]"; exit 2; }
[ "$MODE" = on ] || [ "$MODE" = off ] || usage
[ -n "$PKG" ] && [ -n "$ACTIVITY" ] || usage
[ "$APK" = "-" ] || [ -f "$APK" ] || { echo "APK not found: $APK"; exit 1; }
case "$BS" in 4k|128k) ;; *) echo "Block size must be 4k or 128k"; exit 2 ;; esac
[ "$MODE" != on ] || [ -n "$FIO" ] || { echo "fio not found"; exit 1; }

mkdir -p "$OUT" "$DATA" || exit 1
RESULT="$OUT/${MODE}_${BS}_launch_times.csv"
FIO_LOG="$OUT/${MODE}_${BS}_fio.log"

if [ "$APK" != "-" ]; then
    echo "Installing $APK"
    pm install -r "$APK" || { echo "APK installation failed"; exit 1; }
else
    echo "Skipping installation"
fi

pm path "$PKG" >/dev/null 2>&1 || { echo "Package not installed: $PKG"; exit 1; }
case "$ACTIVITY" in *.*) COMPONENT="$PKG/$ACTIVITY" ;; *) COMPONENT="$PKG/.$ACTIVITY" ;; esac

if [ "$MODE" = on ]; then
    [ -d "$CGROUP" ] || { echo "Cgroup not found: $CGROUP"; exit 1; }
    [ -w "$CGROUP/tasks" ] || { echo "Cannot write $CGROUP/tasks; run as root"; exit 1; }
fi

PIDS=""
cleanup() {
    for p in $PIDS; do kill "$p" 2>/dev/null; done
    for p in $PIDS; do wait "$p" 2>/dev/null; done
}
trap 'cleanup' INT TERM

echo "Timestamp,LaunchNumber,ThisTime,TotalTime,WaitTime" > "$RESULT"
echo "Mode=$MODE Package=$PKG Component=$COMPONENT BS=$BS"

if [ "$MODE" = on ]; then
    : > "$FIO_LOG"
    i=1
    while [ "$i" -le "$WRITERS" ]; do
        "$FIO" --name="bg_write_$i" --filename="$DATA/bg_${BS}_${i}.bin" \
            --size=2G --rw=write --bs="$BS" --ioengine=libaio --iodepth="$QD" \
            --direct=1 --time_based --runtime="$RUNTIME" --group_reporting \
            >> "$FIO_LOG" 2>&1 &
        p=$!
        echo "$p" > "$CGROUP/tasks" || { echo "Failed to assign fio PID $p"; kill "$p" 2>/dev/null; exit 1; }
        PIDS="$PIDS $p"
        i=$((i + 1))
    done
    sleep 5
    echo "Background fio PIDs: $PIDS"
else
    echo "Background writes OFF: idle baseline"
fi

i=1
while [ "$i" -le "$LAUNCHES" ]; do
    echo "Launch $i/$LAUNCHES"
    am force-stop "$PKG" >/dev/null 2>&1
    sleep 1
    TMP="$OUT/launch_${MODE}_${BS}_${i}.tmp"
    am start -W -n "$COMPONENT" > "$TMP" 2>&1
    THIS_TIME="$(grep '^ThisTime:' "$TMP" | tail -n 1 | awk '{print $2}')"
    TOTAL_TIME="$(grep '^TotalTime:' "$TMP" | tail -n 1 | awk '{print $2}')"
    WAIT_TIME="$(grep '^WaitTime:' "$TMP" | tail -n 1 | awk '{print $2}')"
    echo "$(date '+%Y-%m-%d_%H:%M:%S'),$i,${THIS_TIME:-NA},${TOTAL_TIME:-NA},${WAIT_TIME:-NA}" >> "$RESULT"
    cat "$TMP"
    sleep "$GAP"
    i=$((i + 1))
done

if [ "$MODE" = on ]; then
    echo "Stopping background fio jobs"
    cleanup
    PIDS=""
    echo "fio log: $FIO_LOG"
fi
echo "Launch results: $RESULT"
