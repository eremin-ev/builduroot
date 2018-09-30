all: initrd.cpio

initrd.cpio:
	./builduroot.sh

clean:
	rm -Rf boot busybox linux-stable out initrd.cpio
