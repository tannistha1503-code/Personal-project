#!/system/bin/sh
# SSG-01: Foreground app launch under background write pressure
# Usage:
#   sh ssg01_app_launch.sh on|off <package> <activity> [cgroup] [4k|128k]
# Example:
#   sh ssg01_app_launch.sh on com.example.app .MainActivity /dev/blkio/background 4k

MODE="$1"
PKG="$2"
ACTIVITY="$3"
CGROUP="${4:-/dev/blkio/background}"
BS="${5:-4k}"

FIO="$(command -v fio)"
AM="$(command -v am)"
OUT="/data/ssg01_logs"
DATA="/data/ssg01_bg"
WRITERS=8
QD=32
RUNTIME=300
LAUNCHES=10
GAP=3

usage() {
    echo "Usage: sh $0 on|off <package> <activity> [cgroup] [4k|128k]"
    exit 2
}

[ "$MODE" = "on" ] || [ "$MODE" = "off" ] || usage
[ -n "$PKG" ] && [ -n "$ACTIVITY" ] || usage
[ -n "$FIO" ] || { echo "ERROR: fio not found"; exit 1; }
[ -n "$AM" ] || { echo "ERROR: am not found"; exit 1; }
case "$BS" in 4k|128k) ;; *) echo "Block size must be 4k or 128k"; exit 2 ;; esac

mkdir -p "$OUT" "$DATA" || exit 1
RESULT="$OUT/${MODE}_${BS}_launch_times.csv"
FIO_LOG="$OUT/${MODE}_${BS}_fio.log"

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
echo "Mode=$MODE BS=$BS Package=$PKG Activity=$ACTIVITY"

if [ "$MODE" = "on" ]; then
    : > "$FIO_LOG"
    echo "Starting $WRITERS background writers: bs=$BS QD=$QD runtime=${RUNTIME}s"
    i=1
    while [ "$i" -le "$WRITERS" ]; do
        FILE="$DATA/bg_${BS}_${i}.bin"
        (
            # Join the low-priority cgroup before starting fio.
            echo "$$" > "$CGROUP/tasks" || exit 1
            exec "$FIO" --name="bg_write_$i" \
                --filename="$FILE" --size=2G \
                --rw=write --bs="$BS" \
                --ioengine=libaio --iodepth="$QD" \
                --direct=1 --time_based --runtime="$RUNTIME" \
                --group_reporting
        ) >> "$FIO_LOG" 2>&1 &
        PIDS="$PIDS $!"
        i=$((i + 1))
    done
    sleep 5
    echo "Writer PIDs: $PIDS"
    echo "Cgroup task IDs (last 20):"
    tail -n 20 "$CGROUP/tasks" 2>/dev/null
else
    echo "Background writes OFF: idle-baseline measurement."
fi

i=1
while [ "$i" -le "$LAUNCHES" ]; do
    echo "App launch $i/$LAUNCHES"
    "$AM" force-stop "$PKG" >/dev/null 2>&1
    sleep 1
    TMP="$OUT/launch_${MODE}_${BS}_${i}.tmp"
    "$AM" start -W -n "$PKG/$ACTIVITY" > "$TMP" 2>&1
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
    echo "Launch measurements complete; stopping background writers."
    cleanup
    PIDS=""
    echo "fio log: $FIO_LOG"
fi

echo "Launch results: $RESULT"
