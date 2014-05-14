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


set -e

export LC_ALL=C
DB="ubuntu.db"
UENV="uEnv"
SKEL="skel"

BOARD=
DISTRO=
BOOTLOADERS=
UBOTPREF=
KEEP=

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

        chroot $ROOT mount -t proc proc /proc
        chroot $ROOT mount -t sysfs sys /sys
        chroot $ROOT $CMD
        chroot $ROOT umount /sys
        chroot $ROOT umount /proc
}

cleanup()
{
	if [ -e "$ROOTFSDIR" ]; then
		umount $ROOTFSDIR/sys >/dev/null 2>&1 || true
		umount $ROOTFSDIR/proc >/dev/null 2>&1 || true
		[ -z "$KEEP" ] && rm -rf $BOOTDIR $ROOTFSDIR >/dev/null 2>&1 || true
	fi
}

install_bootloader()
{
	local SRC="$1"
	local DEST="$2"
	local PREFIX="usr/lib/u-boot/$3"
	shift 3
	local LOADERS=$@

	for i in $LOADERS; do
		a="$(echo $i | cut -f1 -d'>')"
		b="$(echo $i | cut -f2 -d'>')"
		echo "cp $SRC/$PREFIX/$a $DEST/$b"
		cp $SRC/$PREFIX/$a $DEST/$b
	done
}

BOARDS="$(get_all_fields "board")"
DISTROS="14.04"
ARCH="armhf"

usage()
{
	echo "usage: $(basename $0) -b \$BOARD -d \$DISTRO [options...]

Available values for:
\$BOARD: $BOARDS
\$DISTRO: $DISTROS

Other options:
-k 	keep the chroot around"
	exit 1
}

while [ $# -gt 0 ]; do
	case "$1" in
		-b)
			[ -n "$2" ] && BOARD=$2 shift || usage
			;;
		-d)
			[ -n "$2" ] && DISTRO=$2 shift || usage
			;;
		-k)
			KEEP=1
			;;
		*|h)
			usage
			;;
	esac
	shift	
done

[ -z "$BOARD" -o -z "$DISTRO" ] && usage
UBOOTPREF=$(get_field "$BOARD" "uboot-prefix")
BOOTLOADERS=$(get_field "$BOARD" "bootloaders")
[ -z "$BOOTLOADERS" -o -z "$UBOOTPREF" ] && echo "Error: unknown board $BOARD" && exit 1
[ ! $(which qemu-arm-static) ] && echo "Error: install the qemu-user-static package" && exit 1
QEMU=$(which qemu-arm-static)
[ $(id -u) -ne 0 ] && echo "Error: run me with sudo!" && exit 1

trap cleanup 0 1 2 3 9 15

ROOTFSDIR=$(mktemp -d /tmp/embedded-rootfs.XXXXXX)
BOOTDIR=$(mktemp -d /tmp/embedded-boot.XXXXXX)

echo $BOARD
echo $DISTRO
echo $BOOTDIR
echo $ROOTFSDIR
echo $UBOOTPREF
echo $BOOTLOADERS

#exit

# download ubuntu core/rootfs
CORE="http://cdimage.ubuntu.com/ubuntu-core/releases/$DISTRO/release/ubuntu-core-$DISTRO-core-$ARCH.tar.gz"
wget -qO- $CORE | tar zxf - -C $ROOTFSDIR

# bare minimal system setup
cp $QEMU $ROOTFSDIR/usr/bin
cp /etc/resolv.conf $ROOTFSDIR/etc
do_chroot $ROOTFSDIR "adduser --system --shell /bin/bash ubuntu"
do_chroot $ROOTFSDIR "adduser ubuntu adm"
do_chroot $ROOTFSDIR "adduser ubuntu sudo"
do_chroot $ROOTFSDIR "echo ubuntu:ubuntu | chpasswd"

# install kernel & u-boot
do_chroot $ROOTFSDIR "apt-get update"
# XXX don't run flash-kernel when installing kernel in chroot()
export FLASH_KERNEL_SKIP=1
do_chroot $ROOTFSDIR "apt-get -y install linux-image-generic u-boot"
unset FLASH_KERNEL_SKIP

# install uEnv.txt and bootloader
cp "$UENV.$SKEL" $BOOTDIR/$UENV
install_bootloader $ROOTFSDIR $BOOTDIR $UBOOTPREF "$BOOTLOADERS"
