#!/system/bin/sh
# Run as root. Usage:
# sh ssg_queue_boost_test.sh <SSG_BOOST_CGROUP_PATH>
#
# Normal fio PIDs remain in their existing cgroup.
# Only the two BOOST fio PIDs are moved to the supplied cgroup.
# SSG boost control is enabled once and remains ON after the test.

BOOST=/dev/blkio/background/blkio.ssg.boost_on
BOOST_CGROUP="$1"
DIR=/data/ssg_queue_test
LOG=/data/ssg_queue_test_logs
SIZE=512M
RUNTIME=60
QD=32

if [ "$(id -u)" != "0" ]; then
    echo "Run this script as root."
    exit 1
fi

if [ -z "$BOOST_CGROUP" ] || [ ! -d "$BOOST_CGROUP" ]; then
    echo "Usage: sh $0 <SSG_BOOST_CGROUP_PATH>"
    echo "Supply the actual SSG cgroup directory for boosted tasks."
    exit 1
fi

if [ ! -e "$BOOST" ]; then
    echo "Boost control not found: $BOOST"
    exit 1
fi

if [ -e "$BOOST_CGROUP/tasks" ]; then
    CGROUP_TASKS="$BOOST_CGROUP/tasks"
elif [ -e "$BOOST_CGROUP/cgroup.procs" ]; then
    CGROUP_TASKS="$BOOST_CGROUP/cgroup.procs"
else
    echo "No tasks or cgroup.procs file in $BOOST_CGROUP"
    exit 1
fi

mkdir -p "$DIR" "$LOG"

# Prepare independent files so the four workloads do not overwrite each other.
for f in normal_read normal_write boost_read boost_write; do
    echo "Preparing $f ..."
    fio --name=prep --filename="$DIR/$f.bin" --rw=write \
        --bs=1M --size="$SIZE" --ioengine=psync --iodepth=1 \
        --direct=1 --group_reporting --output="$LOG/prep_$f.log" || exit 1
done

# Enable boost once. Do not toggle it during the workload.
echo 1 > "$BOOST" || exit 1
sleep 2
echo "Boost control value: $(cat "$BOOST")"

PIDS=""

stop_jobs()
{
    for p in $PIDS; do
        kill "$p" 2>/dev/null
    done
}
trap stop_jobs INT TERM

start_normal()
{
    NAME="$1"
    RW="$2"
    FILE="$3"

    fio --name="$NAME" --filename="$FILE" --rw="$RW" \
        --bs=4k --size="$SIZE" --ioengine=libaio --iodepth="$QD" \
        --direct=1 --time_based --runtime="$RUNTIME" \
        --group_reporting --output="$LOG/$NAME.log" &
    PID=$!
    PIDS="$PIDS $PID"
    echo "Started NORMAL $NAME, PID=$PID (not moved to boost cgroup)"
}

start_boost()
{
    NAME="$1"
    RW="$2"
    FILE="$3"

    # Delay I/O briefly so the PID can be assigned before fio starts issuing I/O.
    fio --name="$NAME" --filename="$FILE" --rw="$RW" \
        --bs=4k --size="$SIZE" --ioengine=libaio --iodepth="$QD" \
        --direct=1 --time_based --runtime="$RUNTIME" \
        --startdelay=5 --group_reporting \
        --output="$LOG/$NAME.log" &
    PID=$!
    PIDS="$PIDS $PID"

    # Only BOOST workload PIDs are assigned to the SSG cgroup.
    echo "$PID" > "$CGROUP_TASKS" || {
        echo "Failed to add BOOST PID $PID to $CGROUP_TASKS"
        stop_jobs
        exit 1
    }
    echo "Started BOOST $NAME, PID=$PID, cgroup=$BOOST_CGROUP"
}

echo
echo "Starting four concurrent queue workloads (4K, QD=$QD)..."

# Normal workloads: leave their PIDs in the current/default cgroup.
start_normal normal_read randread "$DIR/normal_read.bin"
start_normal normal_write randwrite "$DIR/normal_write.bin"

# Boost workloads: only these PIDs are moved into the supplied SSG cgroup.
start_boost boost_read randread "$DIR/boost_read.bin"
start_boost boost_write randwrite "$DIR/boost_write.bin"

echo
echo "All four workloads are running concurrently for $RUNTIME seconds."
echo "Boost remains ON. Waiting for fio jobs..."
wait

echo
echo "Test finished. Boost remains ON (value=$(cat "$BOOST"))."
echo "Generated logs:"
ls -lh "$LOG"

echo
echo "Performance lines:"
grep -h -E 'IOPS=|BW=|clat|lat' "$LOG"/*.log
