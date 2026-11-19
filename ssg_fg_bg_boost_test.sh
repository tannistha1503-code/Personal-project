#!/system/bin/sh
# Run as root:
# sh /data/ssg_fg_bg_boost_test.sh
#
# FG and normal BG fio jobs stay in their inherited/current cgroups.
# ONLY the selected BG BOOST fio threads are added to background/tasks.

BG_CG=/dev/blkio/background
BG_TASKS=$BG_CG/tasks
BOOST_FILE=$BG_CG/blkio.ssg.boost_on

DIR=/data/ssg_fg_bg_boost
LOG=/data/ssg_fg_bg_boost_logs
SIZE=512M
RUNTIME=60
QD=32
BS=4k
PIDS=""

if [ "$(id -u)" != "0" ]; then
    echo "ERROR: Run as root (su)."
    exit 1
fi

command -v fio >/dev/null 2>&1 || {
    echo "ERROR: fio not found."
    exit 1
}

[ -e "$BG_TASKS" ] || {
    echo "ERROR: $BG_TASKS not found."
    exit 1
}
[ -e "$BOOST_FILE" ] || {
    echo "ERROR: $BOOST_FILE not found."
    exit 1
}

mkdir -p "$DIR" "$LOG" || exit 1

echo "Preparing six independent 512M files..."
for n in fg_read fg_write bg_read bg_write bg_boost_read bg_boost_write; do
    fio --name=prep --filename="$DIR/$n.bin" --rw=write --bs=1M \
        --size="$SIZE" --ioengine=psync --iodepth=1 --direct=1 \
        --group_reporting --output="$LOG/prep_$n.log" || exit 1
done

# Enable boost on the existing background cgroup.
echo 1 > "$BOOST_FILE" || {
    echo "ERROR: Failed to enable SSG boost."
    exit 1
}
echo "SSG boost value: $(cat "$BOOST_FILE")"

stop_jobs() {
    for p in $PIDS; do
        kill "$p" 2>/dev/null
    done
}
trap 'stop_jobs' INT TERM

add_and_verify_boost_threads() {
    pid="$1"
    tries=0

    while [ "$tries" -lt 5 ] && [ ! -d "/proc/$pid/task" ]; do
        sleep 1
        tries=$((tries + 1))
    done

    [ -d "/proc/$pid/task" ] || {
        echo "ERROR: Cannot find threads for PID $pid."
        return 1
    }

    # Add every thread belonging to this boosted fio process.
    for t in /proc/"$pid"/task/*; do
        [ -d "$t" ] || continue
        tid=${t##*/}
        echo "$tid" > "$BG_TASKS" || return 1
    done

    # Verify every current thread is present in background/tasks.
    for t in /proc/"$pid"/task/*; do
        [ -d "$t" ] || continue
        tid=${t##*/}
        grep -qx "$tid" "$BG_TASKS" || {
            echo "VERIFY FAIL: TID $tid not found in $BG_TASKS"
            return 1
        }
    done

    echo "VERIFY PASS: BOOST PID $pid threads found in $BG_TASKS"
    return 0
}

start_job() {
    name="$1"
    rw="$2"
    type="$3"

    fio --name="$name" --filename="$DIR/$name.bin" --rw="$rw" \
        --bs="$BS" --size="$SIZE" --ioengine=libaio --iodepth="$QD" \
        --direct=1 --time_based --runtime="$RUNTIME" --startdelay=5 \
        --group_reporting --output="$LOG/$name.log" &
    pid=$!
    PIDS="$PIDS $pid"

    case "$type" in
        FG)
            echo "Started FG $name PID=$pid (left in existing cgroup)"
            ;;
        BG)
            echo "Started normal BG $name PID=$pid (left in existing cgroup)"
            ;;
        BOOST)
            add_and_verify_boost_threads "$pid" || {
                echo "ERROR: Could not assign boosted workload."
                stop_jobs
                exit 1
            }
            echo "Started BG BOOST $name PID=$pid"
            ;;
    esac
}

echo
echo "Starting six concurrent workloads: 4K, QD=$QD, runtime=${RUNTIME}s"
echo "FG and normal BG remain in their existing cgroups."
echo "Only BG BOOST threads are added to $BG_TASKS."

start_job fg_read         randread  FG
start_job fg_write        randwrite FG
start_job bg_read         randread  BG
start_job bg_write        randwrite BG
start_job bg_boost_read   randread  BOOST
start_job bg_boost_write  randwrite BOOST

echo
echo "All workloads started. Waiting for completion..."
wait

echo
echo "Test completed. SSG boost remains ON."
echo "Disable manually after testing with:"
echo "echo 0 > $BOOST_FILE"
echo
echo "Performance summary:"
for f in "$LOG"/*.log; do
    case "$f" in *prep_*) continue ;; esac
    echo "----- $f"
    grep -E 'IOPS=|BW=|clat' "$f"
done
echo "Logs: $LOG"
