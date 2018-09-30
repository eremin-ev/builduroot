#!/bin/sh

#src_busybox="$HOME/src/busybox"
#src_linux="$HOME/src/linux-stable/"

src_busybox="git://busybox.net/busybox.git"
src_linux="https://github.com/eremin-ev/linux-stable.git"

mk_inittab()
{
	echo '::sysinit:/bin/busybox --install -s /bin'
	echo '::sysinit:mount -t devtmpfs dev /dev'
	echo '::sysinit:mount -t proc proc /proc'
	echo '::sysinit:mount -t sysfs sys /sys'
	echo 'tty1::respawn:-/bin/ash'
	echo 'tty2::respawn:-/bin/ash'
	echo 'tty3::respawn:-/bin/ash'
	echo 'tty4::respawn:-/bin/ash'
}

build_busybox()
{
	git clone $src_busybox &&
	cd busybox/ &&
	git checkout 1_29_3 &&
	cp -v ../config/busybox-1.29.3 .config &&
	make -j8
	#INSTALL_PATH=out make install
}

build_linux()
{
	mkdir -vp boot &&
	git clone $src_linux &&
	cd linux-stable/ &&
	git checkout linux-4.14.y &&
	cp -v ../config/linux-4.14.72.config .config &&
	make -j8 &&
	INSTALL_PATH=../boot make install
}

fix_libs()
{
	bin="$1"
	mkdir -vp out/usr/lib
	ln -sv usr/lib out/lib
	ln -sv usr/lib out/lib64
	ln -sv usr/lib64 lib
	ldd $bin | awk '{print($3)}' | while read l; do
		if [[ -n "$l" ]]; then
			p=${l%/*}
			if [[ -n "$p" && "$p" != "$l" ]]; then
				cp -v $l out/$p
			fi
		fi
	done
}

mk_passwd()
{
	echo 'root:x:0:0::/root:/bin/ash'
	echo 'user1:x:1000:1000:Linux User,,,:/home/user1:/bin/ash'
	echo 'user2:x:1001:1000:Linux User,,,:/home/user2:/bin/ash'
}

mk_group()
{
	echo 'root:x:0:root'
	echo 'users:x:1000:user1,user2'
}

mk_profile()
{
	echo 'alias ps="ps -o pid,tty,rss,user,args"'
	echo 'if [[ $USER != "root" ]]; then'
	echo '	export PS1="\u@\w$ "'
	echo 'else'
	echo '	export PS1="\u@\w# "'
	echo 'fi'
}

# create an initrd
mk_initrd()
{
	#fix_libs out/bin/busybox
	mkdir -vp out/{bin,dev,etc,home/{user1,user2},root,proc,sys}
	ln -sv bin out/sbin
	cp -v busybox/busybox_unstripped out/bin/busybox
	strip -d out/bin/busybox
	ln -sv ../bin/busybox out/sbin/init
	mk_inittab > out/etc/inittab
	mk_passwd > out/etc/passwd
	mk_group > out/etc/group
	mk_profile > out/etc/profile
	cd out/
	find . | cpio -o -H newc > ../initrd.cpio
	cd ..
	ls -sh initrd.cpio
}

dir=$PWD
build_busybox &&
cd $dir
build_linux &&
cd $dir
mk_initrd

#qemu-system-x86_64 -kernel /tmp/build/boot/vmlinuz -initrd /tmp/build/initrd.cpio
