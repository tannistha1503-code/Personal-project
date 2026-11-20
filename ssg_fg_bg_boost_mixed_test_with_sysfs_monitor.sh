#!/system/bin/sh
# Run as root: sh /data/ssg_fg_bg_boost_mixed_test_with_sysfs_monitor.sh
# FG mixed randrw is foreground. Normal BG jobs stay in inherited cgroups.
# Only boosted BG threads are added to /dev/blkio/background/tasks.
# Samples three blk_sec_wb sysfs entries every 5 seconds.

BG_CG=/dev/blkio/background
BG_TASKS=$BG_CG/tasks
BOOST_FILE=$BG_CG/blkio.ssg.boost_on
WB_SYSFS=/sys/kernel/blk_sec_wb
DIR=/data/ssg_fg_bg_boost
LOG=/data/ssg_fg_bg_boost_logs
SYSFS_LOG=$LOG/blk_sec_wb_sysfs.log
SIZE=512M
RUNTIME=60
QD=32
BS=4k
PIDS=""
MON_PID=""

[ "$(id -u)" = "0" ] || { echo "ERROR: Run as root (su)."; exit 1; }
command -v fio >/dev/null 2>&1 || { echo "ERROR: fio not found."; exit 1; }
[ -e "$BG_TASKS" ] || { echo "ERROR: $BG_TASKS not found."; exit 1; }
[ -e "$BOOST_FILE" ] || { echo "ERROR: $BOOST_FILE not found."; exit 1; }
[ -d "$WB_SYSFS" ] || { echo "ERROR: $WB_SYSFS not found."; exit 1; }
mkdir -p "$DIR" "$LOG" || exit 1

stop_monitor() {
    if [ -n "$MON_PID" ]; then
        kill "$MON_PID" 2>/dev/null
        wait "$MON_PID" 2>/dev/null
        MON_PID=""
        echo "Sysfs monitor stopped."
    fi
}
stop_jobs() {
    for p in $PIDS; do kill "$p" 2>/dev/null; done
}
cleanup() {
    stop_monitor
    stop_jobs
}
trap 'cleanup' INT TERM
trap 'stop_monitor' EXIT

# Monitor starts before preparation and runs until all test workloads finish.
(
    while :; do
        echo "===== $(date '+%Y-%m-%d %H:%M:%S') ====="
        for attr in auto_wb_disable_ms enable_ms state; do
            if [ -r "$WB_SYSFS/$attr" ]; then
                printf '%s=' "$attr"
                cat "$WB_SYSFS/$attr"
            else
                echo "$attr=NOT_READABLE_OR_MISSING"
            fi
        done
        sleep 5
    done
) >> "$SYSFS_LOG" 2>&1 &
MON_PID=$!
echo "Sysfs monitor PID=$MON_PID; log=$SYSFS_LOG"

echo "Preparing five independent files..."
for n in fg_mixed bg_read bg_write bg_boost_read bg_boost_write; do
    fio --name=prep --filename="$DIR/$n.bin" --rw=write --bs=1M \
        --size="$SIZE" --ioengine=psync --iodepth=1 --direct=1 \
        --group_reporting --output="$LOG/prep_$n.log" || exit 1
done

cat > "$DIR/fg_mixed.fio" <<EOF
[global]
filename=$DIR/fg_mixed.bin
size=$SIZE
bs=$BS
ioengine=libaio
iodepth=$QD
direct=1
time_based=1
runtime=$RUNTIME
ramp_time=5
group_reporting=1

[fg_mixed]
rw=randrw
rwmixread=70
EOF

echo 1 > "$BOOST_FILE" || { echo "ERROR: Cannot enable boost."; exit 1; }
echo "SSG boost value: $(cat "$BOOST_FILE")"

add_and_verify_boost_threads() {
    pid="$1"
    tries=0
    while [ "$tries" -lt 5 ] && [ ! -d "/proc/$pid/task" ]; do
        sleep 1
        tries=$((tries + 1))
    done
    [ -d "/proc/$pid/task" ] || { echo "ERROR: PID $pid disappeared."; return 1; }
    for t in /proc/"$pid"/task/*; do
        [ -d "$t" ] || continue
        tid=${t##*/}
        echo "$tid" > "$BG_TASKS" || return 1
    done
    for t in /proc/"$pid"/task/*; do
        [ -d "$t" ] || continue
        tid=${t##*/}
        grep -qx "$tid" "$BG_TASKS" || {
            echo "VERIFY FAIL: TID $tid not found in $BG_TASKS"; return 1;
        }
    done
    echo "VERIFY PASS: BOOST PID $pid threads found in $BG_TASKS"
}

start_bg_job() {
    name="$1"; rw="$2"; type="$3"
    fio --name="$name" --filename="$DIR/$name.bin" --rw="$rw" \
        --bs="$BS" --size="$SIZE" --ioengine=libaio --iodepth="$QD" \
        --direct=1 --time_based --runtime="$RUNTIME" --ramp_time=5 \
        --group_reporting --output="$LOG/$name.log" &
    pid=$!
    PIDS="$PIDS $pid"
    if [ "$type" = "BOOST" ]; then
        add_and_verify_boost_threads "$pid" || {
            echo "ERROR: Failed to assign boosted workload."
            stop_jobs
            exit 1
        }
        echo "Started BG BOOST $name PID=$pid"
    else
        echo "Started normal BG $name PID=$pid (cgroup unchanged)"
    fi
}

echo "Starting normal BG read/write..."
start_bg_job bg_read randread BG
start_bg_job bg_write randwrite BG
echo "Starting boosted BG read/write..."
start_bg_job bg_boost_read randread BOOST
start_bg_job bg_boost_write randwrite BOOST

echo "Starting FG mixed I/O (70% read / 30% write)..."
fio "$DIR/fg_mixed.fio" --output="$LOG/fg_mixed.log"
FG_STATUS=$?

echo "FG complete. Waiting for BG workloads..."
for p in $PIDS; do wait "$p"; done

stop_monitor
echo "Test complete. SSG boost remains ON."
echo "Disable manually: echo 0 > $BOOST_FILE"
echo "Performance summary:"
for f in "$LOG"/*.log; do
    case "$f" in *prep_*) continue ;; esac
    echo "----- $f"
    grep -E 'IOPS=|BW=|clat' "$f"
done
echo "Sysfs samples: $SYSFS_LOG"
exit "$FG_STATUS"
