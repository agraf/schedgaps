#!/bin/bash

set -ex

echo 0 > /proc/sys/kernel/sched_tunable_scaling
# Aspired to maximum latency for a vCPU
echo 30000000 > /proc/sys/kernel/sched_latency_ns
# Minimum time slice a vCPU is guaranteed to receive
echo $(( 30000000 / 16 )) > /proc/sys/kernel/sched_min_granularity_ns
echo 100 > /proc/sys/kernel/sched_cfs_bandwidth_slice_us
echo HRTICK > /sys/kernel/debug/sched_features
#echo NO_LAST_BUDDY > /sys/kernel/debug/sched_features
#echo NO_CACHE_HOT_BUDDY > /sys/kernel/debug/sched_features

mount tmpfs /sys/fs/cgroup -t tmpfs -o nosuid,nodev,noexec,mode=755
mkdir /sys/fs/cgroup/cpuset
mount cgroup /sys/fs/cgroup/cpuset -t cgroup -o rw,nosuid,nodev,noexec,relatime,cpuset
mkdir /sys/fs/cgroup/cpu
mount cgroup /sys/fs/cgroup/cpu -t cgroup -o rw,nosuid,nodev,noexec,relatime,cpu,cpuacct

mkdir /sys/fs/cgroup/cpuset/vcpu0
mkdir /sys/fs/cgroup/cpuset/vcpu1
echo 2,3 > /sys/fs/cgroup/cpuset/vcpu0/cpuset.cpus
echo 0 > /sys/fs/cgroup/cpuset/vcpu0/cpuset.mems
echo 2,3 > /sys/fs/cgroup/cpuset/vcpu1/cpuset.cpus
echo 0 > /sys/fs/cgroup/cpuset/vcpu1/cpuset.mems

for i in {1..8}
do
    cgroup=cosched$i
    mkdir /sys/fs/cgroup/cpu/$cgroup

    if [ -f /sys/fs/cgroup/cpu/$cgroup/cpu.scheduled ]; then
        # Amazon co-scheduling
        echo 1 > /sys/fs/cgroup/cpu/$cgroup/cpu.scheduled
    elif [ -f /sys/fs/cgroup/cpu/$cgroup/cpu.tag ]; then
        # Upstream core-scheduling
        echo 1 > /sys/fs/cgroup/cpu/$cgroup/cpu.tag
        :
    else
        find /sys/fs/cgroup/cpu/$cgroup/
        echo "No core scheduling patches found"
        sleep 1
        echo o > /proc/sysrq-trigger
        sleep 100
    fi
done

function run_user()
{
    # Enable tracing
    echo 1 > /sys/kernel/debug/tracing/events/sched/enable
    echo 1 > /sys/kernel/debug/tracing/events/irq/enable
    echo 1 > /sys/kernel/debug/tracing/events/timer/enable
    echo 1 > /sys/kernel/debug/tracing/events/syscalls/enable
    echo 1 > /sys/kernel/debug/tracing/tracing_on

    # Run the user space tool until it exits
    /bin/hwlat || true

    # When it exits, it found a regression. Give us the trace.
    echo 0 > /sys/kernel/debug/tracing/tracing_on
    taskset -c 0 dd if=/sys/kernel/debug/tracing/trace_pipe of=/dev/nvme0n1 bs=$(( 1024 * 1024 * 10 )) iflag=fullblock oflag=direct
    sync

}

function run_kvm()
{
    set -e

    for i in {1..8}
    do
        sleep 0.1$((RANDOM%20))
        qemu-system-x86_64 -cpu host -enable-kvm -name test$i,debug-threads=on	\
			   -kernel /bin/bzImage -initrd bin/initrd		\
			   -append console=ttyS0\ quiet				\
			   -nographic -smp 2,threads=2 -net none > ./vm$i.log &

        pid=$!
        while [ "$(ls /proc/$pid/task/ | wc -l)" != 4 ]; do sleep 0.01; done

        cgroup=cosched$i

        # Find 2 VCPU thread tids
        for t in `ls /proc/$pid/task/`
        do
            if [ "`cat /proc/$pid/task/$t/comm`" == "CPU 0/KVM" ]; then
                echo "CPU0: $t"
                echo $t >> /sys/fs/cgroup/cpuset/vcpu0/tasks
                echo $t >> /sys/fs/cgroup/cpu/$cgroup/tasks
            fi
            if [ "`cat /proc/$pid/task/$t/comm`" == "CPU 1/KVM" ]; then
                echo "CPU1: $t"
                echo $t >> /sys/fs/cgroup/cpuset/vcpu1/tasks
                echo $t >> /sys/fs/cgroup/cpu/$cgroup/tasks
            fi
        done
    done

    if false; then
        sleep 4
   
        echo 1 > /sys/kernel/debug/tracing/events/sched/enable
        echo 1 > /sys/kernel/debug/tracing/events/irq/enable
        echo 1 > /sys/kernel/debug/tracing/events/timer/enable
        echo 1 > /sys/kernel/debug/tracing/events/kvm/enable
        echo 1 > /sys/kernel/debug/tracing/tracing_on
        taskset -c 0 dd if=/sys/kernel/debug/tracing/trace_pipe of=/dev/nvme0n1 bs=$(( 1024 * 1024 )) iflag=fullblock oflag=direct &
    fi

    tail -f vm1.log
}

if grep -q kvm /proc/cmdline; then
    run_kvm
else
    run_user
fi

echo s > /proc/sysrq-trigger
echo o > /proc/sysrq-trigger
