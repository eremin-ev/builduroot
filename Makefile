all: initrd.cpio

initrd.cpio:
	./builduroot.sh

clean:
	rm -Rf busybox linux-stable out out.cpio
