#!/system/bin/sh

BOOST=/dev/blkio/background/blkio.ssg.boost_on
CGROUP=/dev/blkio/background
FILE=/data/ssg_boost_test.bin
LOG=/data/ssg_boost_logs

SIZE=256M
DURATION=30
REPEAT=5

mkdir -p "$LOG"

if [ ! -e "$BOOST" ]; then
    echo "Boost control not found: $BOOST"
    exit 1
fi

# Move this script (and normally its child fio process) to the selected cgroup.
if [ -e "$CGROUP/tasks" ]; then
    echo $$ > "$CGROUP/tasks" || exit 1
elif [ -e "$CGROUP/cgroup.procs" ]; then
    echo $$ > "$CGROUP/cgroup.procs" || exit 1
else
    echo "Cgroup task file not found: $CGROUP"
    exit 1
fi

echo "Preparing test file..."
fio --name=prepare --filename="$FILE" --rw=write \
    --bs=1M --size="$SIZE" --ioengine=psync \
    --iodepth=1 --direct=1 --group_reporting \
    --output="$LOG/prepare.log" || exit 1

run_test()
{
    RW=$1
    BOOST_STATE=$2
    COUNT=$3

    echo "$BOOST_STATE" > "$BOOST" || exit 1
    sleep 2

    ACTUAL=$(cat "$BOOST")
    echo "Requested boost=$BOOST_STATE, actual=$ACTUAL"

    if [ "$ACTUAL" != "$BOOST_STATE" ]; then
        echo "Boost state verification failed"
        exit 1
    fi

    NAME="${RW}_boost${BOOST_STATE}_run${COUNT}"
    echo "Running $NAME"

    fio --name="$NAME" --filename="$FILE" \
        --rw="$RW" --bs=4k --size="$SIZE" \
        --ioengine=psync --iodepth=1 --direct=1 \
        --time_based --runtime="$DURATION" \
        --randseed=1234 --group_reporting \
        --output="$LOG/$NAME.log" || exit 1

    sleep 2
}

for RW in randread randwrite
do
    for BOOST_STATE in 0 1
    do
        i=1
        while [ "$i" -le "$REPEAT" ]
        do
            run_test "$RW" "$BOOST_STATE" "$i" || exit 1
            i=$((i + 1))
        done
    done
done

echo 0 > "$BOOST"

echo
echo "Test completed."
echo "Files created in $LOG:"
ls -lh "$LOG"

echo
echo "Performance summary:"
grep -h -E 'IOPS=|BW=|clat|lat' "$LOG"/*.log
