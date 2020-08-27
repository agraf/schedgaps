# SPDX-License-Identifier: GPL-2.0

l1/initrd: ./mkinitramfs.sh l1/run.sh src/hwlat l2/initrd l2/bzImage
	./mkinitramfs.sh l1/initrd l1 "lscpu qemu-system-x86_64 src/hwlat l2/initrd l2/bzImage"

l2/initrd: ./mkinitramfs.sh l2/run.sh
	./mkinitramfs.sh l2/initrd l2 ""
	chmod +x l2/initrd

src/hwlat:
	gcc -O2 src/hwlat.c -o src/hwlat -lpthread -Wall -Werror

clean:
	rm -f l1/initrd
	rm -f l2/initrd
	rm -f src/hwlat
