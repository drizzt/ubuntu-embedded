#!/bin/sh
#
#  Copyright (c) 2014 Canonical
#
#  Author: Paolo Pisati <p.pisati@canonical.com>
#
#  This program is free software; you can redistribute it and/or
#  modify it under the terms of the GNU General Public License as
#  published by the Free Software Foundation; either version 2 of the
#  License, or (at your option) any later version.
#
#  This program is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
#  You should have received a copy of the GNU General Public License
#  along with this program; if not, write to the Free Software
#  Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA 02111-1307
#  USA
#

# TODO:
#
# -image size selection
# -ppa support
# -arch support (armhf vs arm64)
# -vexpress support
# -additional pkgs support
# -kernel and bootloader selection support
# -autoresize at first boot
# -user/pwd support
# -check if we can slim uenv.txt some more
# -kernel installation on old installs? flash-kernel execution looks for
#  /lib/firmware/...

set -e

export LC_ALL=C
DB="ubuntu.db"
KERNELCONF="kernel-img.conf"
IMGSIZE="1024"
BOOTSIZE="32"
USER="ubuntu"
PASSWD="ubuntu"

BOARD=
DISTRO=
BOOTLOADERS=
UBOTPREF=
BOOTDEVICE=
ROOTDEVICE=

rm -f build.log && touch build.log
tail -f build.log &
TAILPID=$!

exec 3>&1 4>&2 >build.log 2>&1

get_all_fields() {
	local field="$1"
	local all

	cat "$DB" | {
		while read key value; do
			#echo "a: $all"
			[ "$key" = "${field}:" ] && all="$all $value"
		done
		echo "$all"
	}
}



get_field() {
	local board="$1"
	local field_name="$2"
	local state="block"
	local key
	local value

	cat "$DB" | {
		while read key value; do
			case "$state" in
				"block")
					[ "$key" = "board:" ] && [ "$value" = "$board" ] && state="field"
				;;
				"field")
					case "$key" in
						"${field_name}:")
							echo "$value"
						;;
						"")
							echo ""
							return
						;;
					esac
				;;
			esac
		done
		echo ""
	}
}

do_chroot()
{
		local ROOT="$1"
		local CMD="$2"
		shift 2

		chroot $ROOT mount -t proc proc /proc
		chroot $ROOT mount -t sysfs sys /sys
		#echo "cmd: $CMD args: $@"
		chroot $ROOT $CMD "$@"
		chroot $ROOT umount /sys
		chroot $ROOT umount /proc
}

cleanup()
{
	echo "== Cleanup =="
	sync
	[ -n "$TAILPID" ] && kill -9 $TAILPID
	if [ -e "$ROOTFSDIR" ]; then
		umount $ROOTFSDIR/sys >/dev/null 2>&1 || true
		umount $ROOTFSDIR/proc >/dev/null 2>&1 || true
		tac $MOUNTFILE | while read line; do
			umount $line >/dev/null 2>&1 || true
		done
		$KPARTX -d "$DEVICE" >/dev/null 2>&1  || true
		rm -f "$BOOTDIR" "$ROOTFSDIR" >/dev/null 2>&1 || true
	fi
	rm -f $FSTABFILE
	rm -f $MOUNTFILE
}

layout_device()
{
	echo "== Layout device =="
	local BOOTPART=
	local ROOTPART=
	if [ ! -b "$DEVICE" ]; then
		rm -f "$DEVICE"
		dd if=/dev/zero of="$DEVICE" bs=1M count="$IMGSIZE"
	fi

	# 1) create partitions
	echo "1) Creating partitions..."
	local PART=0
	for i in $LAYOUT; do
		PART=$((PART+1))
		echo "part: $PART layout: $i";
		local MPOINT=`echo "$i" | cut -f1 -d","`
		local FS=`echo "$i" | cut -f2 -d","`
		local SIZE=`echo "$i" | cut -f3 -d","`
		echo "mpoint: $MPOINT fs: $FS size: $SIZE"
		[ $SIZE = "FILL" ] && SIZE=""
		[ $MPOINT = "BOOTDIR" ] && BOOTPART=$PART
		[ $MPOINT = "/" ] && ROOTPART=$PART
		echo "mpoint: $MPOINT fs: $FS size: $SIZE"
		/bin/echo -e "n\np\n\n\n+${SIZE}\nw" | fdisk "$DEVICE"
		if [ $FS = "vfat" ]; then 
			if [ $PART = "1" ]; then
				/bin/echo -e "t\nc\nw" | fdisk "$DEVICE"
			else
				/bin/echo -e "t\n${PART}\nc\nw" | fdisk "$DEVICE"
			fi
		fi
		[ $MPOINT = "BOOTDIR" ] && /bin/echo -e "a\n${PART}\nw\n" | fdisk "$DEVICE"
	done
	echo "ROOTPART: $ROOTPART BOOTPART: ${BOOTPART:-null}"

	# 2) make filesystems & assemble fstab
	if [ ! -b "$DEVICE" ]; then
		$KPARTX -a "$DEVICE"
		LOOP=$(losetup -a | grep $DEVICE | cut -f1 -d: | cut -f3 -d/)
		PHYSDEVICE="/dev/mapper/${LOOP}p"
	else
		PHYSDEVICE="${DEVICE}"
	fi
	echo "2) Making filesystems..."
	PART=0
	for i in $LAYOUT; do
		PART=$((PART+1))
		echo "part: $PART layout: $i";
		local MPOINT=`echo "$i" | cut -f1 -d","`
		local FS=`echo "$i" | cut -f2 -d","`
		local SIZE=`echo "$i" | cut -f3 -d","`
		echo "mpoint: $MPOINT fs: $FS size: $SIZE"
		[ $MPOINT = "SKIP" ] && continue
		mkfs.${FS} ${PHYSDEVICE}${PART}
		if [ $MPOINT != "SKIP" -a $MPOINT != "BOOTDIR" ]; then
			MNTOPTS="defaults"
			FSCK="0"
			UUID=`blkid ${PHYSDEVICE}${PART} | cut -f2 -d " " | sed 's/"//g'`
			[ $MPOINT = "/" ] && MNTOPS="errors=remount-ro" && FSCK="1"
			[ $MPOINT = "/boot" ] && FSCK="2"
			echo "$UUID	$MPOINT	$FS	$MNTOPTS	0	$FSCK" >> $FSTABFILE
		fi
	done

	# 3) final assignment
	[ ${BOOTPART} ] && BOOTDEVICE="${PHYSDEVICE}${BOOTPART}"
	ROOTDEVICE="${PHYSDEVICE}${ROOTPART}"
	echo "ROOTDEVICE: $ROOTDEVICE BOOTDEVICE: ${BOOTDEVICE:-null}"
}

do_bootloader()
{
	mount $BOOTDEVICE $BOOTDIR
	[ $? -eq 0 ] && echo $BOOTDEVICE >> $MOUNTFILE
	cp skel/uEnv.txt $BOOTDIR
	if [ ${BOOTLOADERS} ]; then
		local SRC="$ROOTFSDIR"
		local DEST="$BOOTDIR"
		local PREFIX="usr/lib/u-boot/$UBOOTPREF"
		
		do_chroot $ROOTFSDIR apt-get -y install u-boot
		for i in $BOOTLOADERS; do
			a="$(echo $i | cut -f1 -d'>')"
			b="$(echo $i | cut -f2 -d'>')"
			cp $SRC/$PREFIX/$a $DEST/$b
		done
	else
		# no bootloaders to be installed, just copy uImage/uInitrd to BOOTDIR
		cp ${ROOTFSDIR}/boot/uImage ${ROOTFSDIR}/boot/uInitrd ${BOOTDIR}
	fi
}

BOARDS="$(get_all_fields "board")"
DISTROS="14.04"
ARCH="armhf"

usage()
{
cat << EOF
usage: $(basename $0) -b \$BOARD -d \$DISTRO [options...]

Available values for:
\$BOARD: $BOARDS
\$DISTRO: $DISTROS

Other options:
-f  <device>  device installation target
-e <release>  release used for the enablement stack (kernel, bootloader and flask-kernel)
EOF
	exit 1
}

# setup_env_generic
# -prepare all env variables
# -check requisites
# -print summary of env

while [ $# -gt 0 ]; do
	case "$1" in
		-b)
			[ -n "$2" ] && BOARD=$2 shift || usage
			;;
		-d)
			[ -n "$2" ] && DISTRO=$2 shift || usage
			;;
		-f)
			[ -n "$2" ] && DEVICE=$2 shift || usage
			[ ! -b "$DEVICE" ] && echo "Error: $DEVICE is not a real device" && exit 1
			;;
		-e)
			[ -n "$2" ] && BACKPORT=$2 shift || usage
			;;
		*|h)
			usage
			;;
	esac
	shift	
done

# mandatory checks
[ -z "$BOARD" -o -z "$DISTRO" ] && usage
MACHINE=$(get_field "$BOARD" "machine") || true
[ -z "$MACHINE" ] && echo "Error: unknown machine string" && exit 1
LAYOUT=$(get_field "$BOARD" "layout") || true
[ -z "$LAYOUT" ] && echo "Error: unknown media layout" && exit 1
QEMU=$(which qemu-arm-static) || true
[ -z $QEMU ] && echo "Error: install the qemu-user-static package" && exit 1
KPARTX=$(which kpartx) || true
[ -z $KPARTX ] && echo "Error: install the kpartx package" && exit 1
MKPASSWD=$(which mkpasswd) || true
[ -z $MKPASSWD ] && echo "Error: install the whois package" && exit 1
[ $(id -u) -ne 0 ] && echo "Error: run me with sudo!" && exit 1

# optional parameters
SERIAL=$(get_field "$BOARD" "serial") || true
UBOOTPREF=$(get_field "$BOARD" "uboot-prefix") || true
BOOTLOADERS=$(get_field "$BOARD" "bootloaders") || true

# final environment setup
trap cleanup 0 1 2 3 9 15
DEVICE=${DEVICE:-disk-$(date +%F)-$DISTRO-$BOARD.img}
ROOTFSDIR=$(mktemp -d /tmp/embedded-rootfs.XXXXXX)
BOOTDIR=$(mktemp -d /tmp/embedded-boot.XXXXXX)
FSTABFILE=$(mktemp /tmp/embedded-fstab.XXXXXX)
MOUNTFILE=$(mktemp /tmp/embedded-mount.XXXXXX)

echo "Summary: "
echo $BOARD
echo $DISTRO
echo $BOOTDIR
echo $ROOTFSDIR
echo $FSTABFILE
echo $MOUNTFILE
echo $UBOOTPREF
echo $BOOTLOADERS
echo $DEVICE
echo $LAYOUT
echo "------------"

# end of setup_env_generic()

# prepare_media_generic()
# prepare the target device/loop-file:
# - create the partitions
# - mkfs
# - create the fstab file
# - properly assign ROOTDEVICE and (optionally) BOOTDEVICE
layout_device

# end of prepare_media_generic()

# init_system_generic()
# - mount ROOTDEVICE to ROOTFSDIR
# - download ubuntu core/rootfs
# - install rootfs
echo "== Init System =="
mount $ROOTDEVICE $ROOTFSDIR
[ $? -eq 0 ] && echo $ROOTDEVICE >> $MOUNTFILE
CORE="http://cdimage.ubuntu.com/ubuntu-core/releases/$DISTRO/release/ubuntu-core-$DISTRO-core-$ARCH.tar.gz"
wget -qO- $CORE | tar zxf - -C $ROOTFSDIR

# end of init_system_generic()

# setup_system_generic()
# - parse fstab and mount it accordingly
# - bare minimal system setup
echo "== Setup System =="
# 1) parse fstab and mount it inside $ROOTFSDIR
while read line; do
	MPOINT=`echo $line | cut -f2 -d " "`
	[ $MPOINT = "/" ] && continue
	UUID=`echo $line | cut -f1 -d " " | cut -f 2 -d =`
	DEV=`blkid -U $UUID`
	mount $DEV $ROOTFSDIR/$MPOINT
	[ $? -eq 0 ] && echo $DEV >> $MOUNTFILE
done < $FSTABFILE

cp $QEMU $ROOTFSDIR/usr/bin
cp /etc/resolv.conf $ROOTFSDIR/etc
cp $FSTABFILE $ROOTFSDIR/etc/fstab
[ -n $SERIAL ] && sed "s/ttyX/$SERIAL/g" skel/serial.conf > $ROOTFSDIR/etc/init/${SERIAL}.conf
do_chroot $ROOTFSDIR useradd $USER -m -p `mkpasswd $PASSWD` -s /bin/bash
do_chroot $ROOTFSDIR adduser ubuntu adm
do_chroot $ROOTFSDIR adduser ubuntu sudo
cp skel/interfaces $ROOTFSDIR/etc/network/
echo "$BOARD" > $ROOTFSDIR/etc/hostname

# end of setup_system_generic()

# install_pkgs_generic()
# - install & setup pkgs (e.g. kernel)
# - apply all custom patches
# - run flash-kernel as last step
echo "== Install pkgs =="
if [ $BACKPORT ]; then
	sed "s/trusty/${BACKPORT}/g" $ROOTFSDIR/etc/apt/sources.list > $ROOTFSDIR/etc/apt/sources.list.d/${BACKPORT}.list
	sed "s/CODENAME/${BACKPORT}/g" skel/apt.preferences > $ROOTFSDIR/etc/apt/preferences.d/enablement-stack.${BACKPORT}
fi
do_chroot $ROOTFSDIR apt-get update
# don't run flash-kernel during installation
export FLASH_KERNEL_SKIP=1
cp skel/$KERNELCONF $ROOTFSDIR/etc
do_chroot $ROOTFSDIR apt-get -y install linux-image-generic u-boot-tools linux-base flash-kernel
unset FLASH_KERNEL_SKIP
# custom flash-kernel patches
for i in fk-patches/*; do
	patch -p1 -d $ROOTFSDIR < "$i"
done
# XXX pin flash-kernel so it won't be updated
do_chroot $ROOTFSDIR  /bin/sh -c 'echo "flash-kernel hold" | dpkg --set-selections'
do_chroot $ROOTFSDIR flash-kernel --machine "$MACHINE"

# end of install_pkgs_generic()

# install_bootloader_vfat()
# - copy bootscript
# - install bootloaders
echo "== Install Bootloader =="
[ -n $BOOTDEVICE ] && do_bootloader
