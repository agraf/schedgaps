#!/bin/bash
# SPDX-License-Identifier: GPL-2.0

# This script builds a tiny rescue initramfs with bash as init and
# busybox for helper functions. Use it for quick kernel debugging.

OUT="$1"
TARGET="$2"
BINARIES="bash busybox sleep dd taskset $3"

for i in $BINARIES; do
    if ! which $i &>/dev/null; then
        echo "Cound not find '$i', please install it and rerun" >&2
        exit 1
    fi
done

if [ ! "$OUT" ]; then
    echo "Syntax: $0 <output file> <init script dir> <binaries>"
    exit 1
fi

TMPDIR=$(mktemp -d)

(
    set -e

    ROOTDIR=$(pwd)
    cd $TMPDIR

    # Create directory structure
    for dir in bin lib proc sys etc; do
        mkdir $dir
    done
    ln -s lib lib64
    ln -s /lib lib/x86_64-linux-gnu
    ln -s /proc/mounts etc/mtab

    # Install all binaries
    for i in $BINARIES; do
        cp $(cd $ROOTDIR; which $i) bin/
    done

    # Populate the target's execution script
    cp $ROOTDIR/$TARGET/run.sh .

    # Generate helper script to mount helper FSs for the init process
    cat >init <<-EOF
	#!/bin/bash
	mount proc /proc -t proc
	mount sys /sys -t sysfs
	mount devtmpfs /dev -t devtmpfs
	mount debugfs /sys/kernel/debug -t debugfs
	mount tracefs /sys/kernel/debug/tracing -t tracefs
	/run.sh
	exec bash -i
	EOF
    chmod +x init

    # Copy all required libs
    for i in $BINARIES; do
        [[ $i = *bzImage ]] && continue
        [[ $i = *initrd ]] && continue

        for f in $(ldd bin/$(basename $i) | cut -d '(' -f 1 | cut -d '>' -f 2 | grep -v vdso); do
            cp $f lib/
        done
    done

    # Populate busybox helpers
    for f in $(busybox --list); do
        # Use system binaries if available instead
        if [ -f "bin/$f" ]; then
            continue
        fi
        ln -s busybox bin/$f
    done

    # Install QEMU add-ons if needed
    if [[ $BINARIES = *qemu* ]]; then
        mkdir -p usr/share
        ln -s / usr/share/qemu
        for file in bios.bin vgabios.bin bios-256k.bin vgabios-stdvga.bin kvmvapic.bin linuxboot_dma.bin; do
            for dir in /usr/share/qemu /usr/share/seabios; do
                [ -e $dir/$file ] || continue
                cp $dir/$file .
            done
        done
    fi

    # generate cpio archive
    find . | cpio -H newc -o
) > $OUT

# Clean up
rm -rf $TMPDIR
