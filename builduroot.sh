#!/bin/bash

src=$(dirname $0)
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
	if [[ ! -d busybox ]]; then
		git clone $src_busybox
	fi
	cd busybox/ &&
	git checkout a949399 &&
	cp -v ${src}/config/busybox-1.33.git.config .config &&
	make -j8
	#INSTALL_PATH=out make install
}

gen_ima_local_ca()
{
	ca_genkey='keys/ca/config/local-ca.genkey'
	ca_organization='IMA-CA'
	ca_common_name='IMA/EVM certificate signing key'
	ca_email='ca@ima-ca'

	mkdir -pv keys/ca/config

	cat > $ca_genkey << EOF
# Begining of the file
[ req ]
default_bits = 2048
distinguished_name = req_distinguished_name
prompt = no
string_mask = utf8only
x509_extensions = v3_ca

[ req_distinguished_name ]
O = ${ca_organization}
CN = ${ca_common_name}
emailAddress = ${ca_email}

[ v3_ca ]
basicConstraints=CA:TRUE
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid:always,issuer
# keyUsage = cRLSign, keyCertSign
# EOF
EOF

	echo "Generating local CA private key and X509 public key certificate..."

	openssl req -new -x509 -utf8 -sha1 -days 365 \
		-batch -config $ca_genkey \
		-passout 'pass:1234' \
		-outform DER -out keys/ca/local-ca.x509 \
		-keyout keys/ca/local-ca.priv

	echo "Producing PEM encoded local CA cert for building kernel..."

	openssl x509 -inform DER -in keys/ca/local-ca.x509 \
		-out keys/ca/local-ca.pem
}

gen_ima_genkey()
{
	ima_genkey="keys/ima/config/ima.genkey"
	ima_organization='Signing Organization'
	ima_common_name='Organization signing key'
	ima_email='signing.organization@dom'

	mkdir -pv keys/ima/config

	cat > $ima_genkey << EOF
# Begining of the file
[ req ]
default_bits = 1024
distinguished_name = req_distinguished_name
prompt = no
string_mask = utf8only
x509_extensions = v3_usr

[ req_distinguished_name ]
O = ${ima_organization}
CN = ${ima_common_name}
emailAddress = ${ima_email}

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

	echo "Generating IMA signing key and x509 certificate signing request..."

	openssl req -new -nodes -utf8 -sha1 -days 365 -batch \
		-config ${ima_genkey} \
		-out keys/ima/csr_ima.pem \
		-keyout keys/ima/privkey_ima.pem

	echo "Sign x509 certificate signing request with local CA private key..."

	openssl x509 -req -in keys/ima/csr_ima.pem \
		-passin 'pass:1234' \
		-days 365 -extfile $ima_genkey \
		-extensions v3_usr \
		-CA keys/ca/local-ca.pem -CAkey keys/ca/local-ca.priv \
		-CAcreateserial \
		-outform DER -out keys/ima/x509_ima.der

	echo "Convert x509 signed certificate into PEM format..."

	openssl x509 -inform der -in keys/ima/x509_ima.der \
		-outform pem -out keys/ima/x509_ima.pem

	echo "Verify x509 signed certificate..."

	openssl verify -verbose -CAfile keys/ca/local-ca.pem keys/ima/x509_ima.pem
}

linux_build()
{
	mkdir -vp boot
	if [[ ! -d linux ]]; then
		git clone $src_linux
	fi &&
	cd linux/ &&
	git checkout v5.8 &&
	cp -v ${src}/config/linux-5.8.config .config &&
	cp -v ../keys/ca/local-ca.pem certs/signing_key.pem &&
	make -j8
}

linux_install()
{
	make INSTALL_PATH=../boot install
}

mk_lib()
{
	mkdir -vp out/usr/lib
	ln -sv usr/lib out/lib
	ln -sv usr/lib out/lib64
	ln -sv lib out/usr/lib64
}

fix_libs()
{
	bin="$1"
	find "$1" -type f -perm /111 -exec ldd '{}' ';' \
			| awk '$2 == "=>" {print($3)} $2 != "=>" {print($1)}' \
			| sort | uniq | while read l; do
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
	echo "evmctl ima_sign -a sha256 --key /root/privkey_ima.pem system/init"
	echo "evmctl ima_sign --key /root/privkey_ima.pem system/init"
	echo "echo 'appraise func=BPRM_CHECK appraise_type=imasig' > /sys/kernel/security/integrity/ima/policy"
}

mk_initrd()
{
	mk_lib
	mkdir -vp out/{bin,dev,etc/keys,home/{user1,user2},root,proc,sys,mnt}
	if [[ -d "extra" ]]; then
		cp -vR extra/ out/root
	fi
	ln -sv bin out/sbin
	#cp -v busybox/busybox_unstripped out/bin/busybox
	cp -v busybox/busybox out/bin/busybox
	for b in evmctl keyctl getfattr setfattr strace; do
		p=$(type -p $b)
		if [[ -n "$p" ]]; then
			cp -v "$p" out/bin
		else
			echo "Cannot find '$b'"
			exit
		fi
	done

	fix_libs "out/bin"

	cp -v keys/ima/x509_ima.der out/etc/keys/
	cp -v keys/ima/privkey_ima.pem out/root/
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

if [[ $# -gt 0 ]]; then
	t="$@"
else
	t="all"
fi

echo "t: '$t'"

b_busybox="0"
b_initrd="0"
b_key="0"
b_linux="0"

for tt in $t; do
	case "$tt" in
		"busybox")
			echo "busybox"
			b_busybox="1"
			;;
		"initrd")
			b_initrd="1"
			;;
		"key")
			b_key="1"
			;;
		"linux")
			b_linux="1"
			;;
		"all")
			b_busybox="1"
			b_initrd="1"
			b_key="1"
			b_linux="1"
			;;
	esac
done

echo "b_busybox $b_busybox"
echo "b_initrd $b_initrd"
echo "b_key $b_key"
echo "b_linux $b_linux"

dir=$PWD
echo "Using ${dir}"
if [[ ${b_busybox} == "1" ]]; then
	build_busybox || exit
fi
cd $dir
if [[ ${b_key} == "1" ]]; then
	gen_ima_local_ca || exit
	gen_ima_genkey || exit
fi
cd $dir
if [[ ${b_linux} == "1" ]]; then
	linux_build || exit
	linux_install || exit
fi
cd $dir
#if [[ ${b_disk} == "1" ]]; then
#	mk_disk
#fi
cd $dir
if [[ ${b_initrd} == "1" ]]; then
	mk_initrd
fi

#qemu-system-x86_64 -kernel boot/vmlinuz -initrd initrd.cpio -append "vga=792"
