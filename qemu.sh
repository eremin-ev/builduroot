#!/bin/bash
qemu-system-x86_64 -drive file=hda.img,if=none,format=raw,id=vd0 \
	-device virtio-blk-pci,drive=vd0 \
	-smp cpus=2 -kernel boot/vmlinuz \
	-initrd initrd.cpio -append "vga=792 init_on_free=1" \
	-display sdl
