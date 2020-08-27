#!/bin/bash
# SPDX-License-Identifier: GPL-2.0

BZIMAGE="$1"
shift

if [ ! "$BZIMAGE" ]; then
    echo "Syntax: $0 <bzImage of kernel> [target]

  Where [target] can be any of the following:

  user: Run a simple user space test that mimics hwlat (default)
  kvm: Run the hwlat trace target inside a nested virtual machine
" >&1
    exit 1
fi

set -e

function vcpu2pcpu()
{
    VCPU="$1"
    PCPU_T0=$(( 1 + (VCPU / 2) )) # Start at pCPU1, pCPU0 may be too noisy
    THREADID=$(( VCPU % 2 + 1 ))
    SIBLINGS=$(cat /sys/bus/cpu/devices/cpu${PCPU_T0}/topology/thread_siblings_list)

    echo "$SIBLINGS" | cut -d , -f $THREADID
}

QEMU=$(realpath ${QEMU:-/usr/bin/qemu-system-x86_64})
NR_CPUS=4

# Create an output file for ftrace logs
rm -f /dev/shm/log
qemu-img create -f raw /dev/shm/log 10G

timeout 30s 										\
qemu-system-x86_64 -cpu host,+vmx							\
		   -m 4G								\
		   -enable-kvm								\
		   -name hwlat,debug-threads=on						\
		   -kernel ~/linux/arch/x86/boot/bzImage				\
		   -initrd l1/initrd							\
		   -append "console=ttyS0 cosched_max_level=1 idle=poll $@"		\
		   -nographic								\
		   -smp $NR_CPUS,threads=2						\
		   -drive file=/dev/shm/log,cache=unsafe,id=d,format=raw,if=none	\
		   -device nvme,drive=d,serial=1234					\
		   > ./vm.log &

# Wait for QEMU to start
timeout_pid=$!
while [ ! -d /proc/$(cat /proc/${timeout_pid}/task/*/children) ]; do sleep 0.01; done
for i in $(cat /proc/${timeout_pid}/task/*/children); do
    qemu_pid=$i
done
while [ "$(ls /proc/${qemu_pid}/task/ | wc -l)" != $(( $NR_CPUS + 2 )) ]; do sleep 0.01; done

# Find vCPU thread tids and pin them to their host counterparts
for t in `ls /proc/${qemu_pid}/task/`; do
    NAME="$(cat /proc/${qemu_pid}/task/$t/comm)"
    case "$NAME" in
    CPU*)
        echo "$NAME: $t"
        ID=$(echo "$NAME" | sed 's/^CPU\(.*\)\/KVM$/\1/')
        taskset -p -c $(vcpu2pcpu $ID) $t
    esac
done

tail -f vm.log &
tail_pid=$!

wait -n ${timeout_pid}
kill ${tail_pid}
