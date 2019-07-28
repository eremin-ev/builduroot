#!/bin/bash

src_busybox="$HOME/src/busybox/"
src_linux="$HOME/src/linux/"

#src_busybox="git://busybox.net/busybox.git"
#src_linux="https://github.com/eremin-ev/linux-stable.git"

mk_inittab()
{
	echo '::sysinit:/bin/busybox --install -s /bin'
	echo '::sysinit:mount -t devtmpfs dev /dev'
	echo '::sysinit:mount -t proc proc /proc'
	echo '::sysinit:mount -t sysfs sys /sys'
	echo '::sysinit:mount -t securityfs securityfs /sys/kernel/security'
	echo '::sysinit:mount /dev/vda /mnt'
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

gen_ima_local_ca()
{
	ca_genkey="keys/config/ima.local-ca.genkey"

	mkdir -pv keys/config

	cat > $ca_genkey << EOF
# Begining of the file
[ req ]
default_bits = 2048
distinguished_name = req_distinguished_name
prompt = no
string_mask = utf8only
x509_extensions = v3_ca

[ req_distinguished_name ]
O = IMA-CA
CN = IMA/EVM certificate signing key
emailAddress = ca@ima-ca

[ v3_ca ]
basicConstraints=CA:TRUE
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid:always,issuer
# keyUsage = cRLSign, keyCertSign
# EOF
EOF

	openssl req -new -x509 -utf8 -sha1 -days 3650 -batch -config $ca_genkey \
		-outform DER -out keys/ima-local-ca.x509 \
		-keyout keys/ima-local-ca.priv
}

gen_ima_x509_cert()
{
	mkdir -pv keys/config

	openssl x509 -inform DER -in keys/ima-local-ca.x509 \
		-out keys/ima-local-ca.pem
}

gen_ima_genkey()
{
	mkdir -pv keys/config

	ima_genkey="keys/config/ima.genkey"

	cat > $ima_genkey << EOF
# Begining of the file
[ req ]
default_bits = 1024
distinguished_name = req_distinguished_name
prompt = no
string_mask = utf8only
x509_extensions = v3_usr

[ req_distinguished_name ]
O = `hostname`
CN = `whoami` signing key
emailAddress = `whoami`@`hostname`

[ v3_usr ]
basicConstraints=critical,CA:FALSE
#basicConstraints=CA:FALSE
keyUsage=digitalSignature
#keyUsage = nonRepudiation, digitalSignature, keyEncipherment
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid
#authorityKeyIdentifier=keyid,issuer
# EOF
EOF

	openssl req -new -nodes -utf8 -sha1 -days 365 -batch \
		-config $ima_genkey \
		-out keys/csr_ima.pem -keyout keys/privkey_ima.pem

	openssl x509 -req -in keys/csr_ima.pem -days 365 -extfile $ima_genkey \
		-extensions v3_usr \
		-CA keys/ima-local-ca.pem -CAkey keys/ima-local-ca.priv \
		-CAcreateserial \
		-outform DER -out keys/x509_ima.der
}

linux_build()
{
	mkdir -vp boot &&
	git clone $src_linux &&
	cd linux/ &&
	git checkout v4.19 &&
	cp -v ../config/linux-4.19.config .config &&
	cp -v ../keys/ima-local-ca.pem certs/signing_key.pem &&
	make -j8
}

linux_install()
{
	INSTALL_PATH=../boot make install
}

mk_lib()
{
	mkdir -vp out/usr/lib
	ln -sv usr/lib out/lib
	ln -sv usr/lib out/lib64
}

fix_libs()
{
	bin="$1"
	ldd $bin | awk '$2 == "=>" {print($3)} $2 != "=>" {print($1)}' | while read l; do
		if [[ -n "$l" ]]; then
			p=${l%/*}
			if [[ -n "$p" && "$p" != "$l" ]]; then
				mkdir -vp out/$p
				cp -vu $l out/$p
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

mk_disk()
{
	dd if=/dev/zero of=disk.img bs=512 count=$[2*50*1000]
	mkfs.ext4 disk.img
}

mk_sh_history()
{
	echo "#evmctl ima_sign -a sha256 --key keys/privkey_ima.pem system/init"
	echo "evmctl ima_sign --key keys/privkey_ima.pem system/init"
	echo "echo 'appraise func=BPRM_CHECK appraise_type=imasig' > /sys/kernel/security/integrity/ima/policy"
}

mk_initrd()
{
	mk_lib
	mkdir -vp out/{bin,dev,etc/keys,home/{user1,user2},root,proc,sys,mnt}
	ln -sv bin out/sbin
	cp -v busybox/busybox_unstripped out/bin/busybox
	for b in strace evmctl cal dmesg date getfattr setfattr; do
		p=`type -p $b`
		cp -v "$p" out/bin
		fix_libs "out/bin/$b"
	done
	cp -v keys/x509_ima.der out/etc/keys/
	cp -v keys/privkey_ima.pem out/root/
	strip -d out/bin/busybox
	ln -sv ../bin/busybox out/sbin/init
	ln -sv bin/busybox out/init
	mk_sh_history > out/.ash_history
	mk_inittab > out/etc/inittab
	mk_passwd > out/etc/passwd
	mk_group > out/etc/group
	mk_profile > out/etc/profile
	cd out/
	find . | cpio -o -H newc > ../initrd.cpio
	cd ..
	ls -sh initrd.cpio
}

mk_disk()
{
	dd if=/dev/zero of=disk.img bs=512 count=$[2*50*1000]
	mkfs.ext4 disk.img
}

dir=$PWD
#build_busybox &&
cd $dir
gen_ima_local_ca
gen_ima_x509_cert
gen_ima_genkey
#cd $dir
#linux_build &&
#linux_install &&
#mk_disk
#cd $dir
#mk_initrd

#qemu-system-x86_64 -kernel boot/vmlinuz -initrd initrd.cpio
