#!/system/bin/sh
# LibreOuya device-side helpers.
# Runs ON the OUYA as root, under its mksh /system/bin/sh with the Android 4.1
# toolbox. No grep, sed, awk, cut or cp is assumed to exist, so everything here
# sticks to shell builtins plus cat, chmod, chown, mv, rm, mkdir, ln, mount,
# sync, dd, md5sum and ls.
#
# The PC side pushes this file to /data/local/tmp/libreouya/lib.sh, then pushes
# a small job file that sources it and calls one or more lo_* functions. Every
# job ends with lo_ok. The PC treats a run as good only if it sees LO_OK and no
# LO_FAIL line, because adb on this Android version does not pass exit codes.

# Scratch directory the PC pushes jobs and staged files into.
# shellcheck disable=SC2034
LO_TMP=/data/local/tmp/libreouya
LO_SD=/sdcard/libreouya
LO_BK=$LO_SD/backup
LO_ST=$LO_SD/state
LO_SYSDEV=/dev/block/platform/sdhci-tegra.3/by-name/APP
LO_RW=0

lo_say() {
	echo "LO_INFO: $*"
}

lo_fail() {
	echo "LO_FAIL: $*"
	if [ "$LO_RW" = 1 ]; then
		lo_ro
	fi
	exit 1
}

lo_ok() {
	echo "LO_OK"
}

lo_prepare() {
	mkdir -p "$LO_BK" "$LO_ST" || lo_fail "cannot create $LO_SD"
}

# Print the md5 of a file, or nothing if it cannot be read.
lo_md5() {
	[ -r "$1" ] || return 1
	# Word splitting is intended: md5sum prints "<hash>  <file>".
	# shellcheck disable=SC2046
	set -- $(md5sum "$1" 2>/dev/null)
	[ -n "$1" ] || return 1
	echo "$1"
}

lo_rw() {
	if ! mount -o remount,rw /system 2>/dev/null; then
		mount -o rw,remount -t ext4 "$LO_SYSDEV" /system ||
			lo_fail "could not remount /system read-write"
	fi
	LO_RW=1
	if ! echo x >/system/.libreouya_rw 2>/dev/null; then
		lo_fail "/system is still read-only after remount"
	fi
	rm /system/.libreouya_rw
}

lo_ro() {
	sync
	if ! mount -o remount,ro /system 2>/dev/null; then
		if ! mount -o ro,remount -t ext4 "$LO_SYSDEV" /system 2>/dev/null; then
			echo "LO_INFO: warning: could not remount /system read-only, a reboot will do it"
		fi
	fi
	LO_RW=0
}

# Record whether a target existed before LibreOuya first touched it, and keep
# a pristine copy (.orig, written once) plus the copy from right before the
# latest change (.prev). Both live on /sdcard so they survive a reflash of
# /system and can be pulled to the PC.
# Plain sh has no local variables, so every function uses its own prefix.
lo_backup() {
	bk_src=$1
	bk_name=$2
	lo_prepare
	if [ ! -e "$LO_ST/$bk_name.existed" ]; then
		if [ -e "$bk_src" ]; then
			echo 1 >"$LO_ST/$bk_name.existed"
		else
			echo 0 >"$LO_ST/$bk_name.existed"
		fi
	fi
	if [ -e "$bk_src" ]; then
		if [ ! -e "$LO_BK/$bk_name.orig" ]; then
			cat "$bk_src" >"$LO_BK/$bk_name.orig" || lo_fail "backup of $bk_src failed"
			lo_say "saved original $bk_src as $LO_BK/$bk_name.orig"
		fi
		cat "$bk_src" >"$LO_BK/$bk_name.prev" || lo_fail "backup of $bk_src failed"
	fi
}

# lo_install <staged file> <target> <mode> <owner.group> <md5> <backup name>
# Atomic replace of a file under /system with backup and verification.
lo_install() {
	in_src=$1
	in_dst=$2
	in_mode=$3
	in_owner=$4
	in_want=$5
	in_name=$6
	in_have=$(lo_md5 "$in_src") || lo_fail "cannot read staged file $in_src"
	[ "$in_have" = "$in_want" ] || lo_fail "staged $in_src md5 $in_have, expected $in_want"
	lo_backup "$in_dst" "$in_name"
	lo_rw
	cat "$in_src" >"$in_dst.lotmp" || {
		rm "$in_dst.lotmp" 2>/dev/null
		lo_fail "could not write $in_dst.lotmp (out of space?)"
	}
	chown "$in_owner" "$in_dst.lotmp" || lo_fail "chown $in_owner on $in_dst.lotmp failed"
	chmod "$in_mode" "$in_dst.lotmp" || lo_fail "chmod $in_mode on $in_dst.lotmp failed"
	mv "$in_dst.lotmp" "$in_dst" || lo_fail "rename into $in_dst failed"
	lo_ro
	in_have=$(lo_md5 "$in_dst") || lo_fail "cannot read $in_dst after install"
	[ "$in_have" = "$in_want" ] || lo_fail "$in_dst md5 $in_have after install, expected $in_want"
	lo_say "installed $in_dst ($in_want)"
}

# lo_restore <backup name> <target> <mode> <owner.group> <orig|prev>
# Puts back what was there before LibreOuya, or removes the file if nothing was.
lo_restore() {
	rs_name=$1
	rs_dst=$2
	rs_mode=$3
	rs_owner=$4
	rs_which=$5
	rs_bk=$LO_BK/$rs_name.$rs_which
	if [ -e "$rs_bk" ]; then
		rs_want=$(lo_md5 "$rs_bk") || lo_fail "cannot read backup $rs_bk"
		lo_rw
		cat "$rs_bk" >"$rs_dst.lotmp" || lo_fail "could not write $rs_dst.lotmp"
		chown "$rs_owner" "$rs_dst.lotmp" || lo_fail "chown failed"
		chmod "$rs_mode" "$rs_dst.lotmp" || lo_fail "chmod failed"
		mv "$rs_dst.lotmp" "$rs_dst" || lo_fail "rename into $rs_dst failed"
		lo_ro
		rs_have=$(lo_md5 "$rs_dst") || lo_fail "cannot read $rs_dst after restore"
		[ "$rs_have" = "$rs_want" ] || lo_fail "$rs_dst md5 mismatch after restore"
		lo_say "restored $rs_dst from $rs_bk"
		return 0
	fi
	if [ -e "$LO_ST/$rs_name.existed" ] && [ "$(cat "$LO_ST/$rs_name.existed")" = 0 ]; then
		if [ -e "$rs_dst" ]; then
			lo_rw
			rm "$rs_dst" || lo_fail "could not remove $rs_dst"
			lo_ro
			lo_say "removed $rs_dst (it did not exist before LibreOuya)"
		fi
		return 0
	fi
	lo_fail "no $rs_which backup for $rs_dst in $LO_BK"
}

# Symlink /system/bin/su -> /system/xbin/su if nothing is there yet.
lo_su_link() {
	lo_prepare
	if [ -e /system/bin/su ] || [ -L /system/bin/su ]; then
		lo_say "/system/bin/su already exists, left alone"
		return 0
	fi
	lo_rw
	ln -s /system/xbin/su /system/bin/su || lo_fail "symlink /system/bin/su failed"
	lo_ro
	echo 1 >"$LO_ST/bin_su.created"
	lo_say "created /system/bin/su symlink"
}

lo_su_unlink() {
	if [ -e "$LO_ST/bin_su.created" ] && [ -L /system/bin/su ]; then
		lo_rw
		rm /system/bin/su || lo_fail "could not remove /system/bin/su"
		lo_ro
		rm "$LO_ST/bin_su.created"
		lo_say "removed the /system/bin/su symlink LibreOuya created"
	fi
}

# Copy a partition image to /sdcard for the PC to pull.
# lo_dump_part <by-name label> <output file>
lo_dump_part() {
	dp_part=/dev/block/platform/sdhci-tegra.3/by-name/$1
	[ -e "$dp_part" ] || lo_fail "no partition $dp_part"
	mkdir -p "$LO_BK/parts" || lo_fail "cannot create $LO_BK/parts"
	dd if="$dp_part" of="$2" bs=4096 2>/dev/null || lo_fail "dd of $dp_part failed"
	lo_say "dumped $dp_part to $2 (md5 $(lo_md5 "$2"))"
}

# Make sure a directory exists under /system with the given mode.
lo_sys_mkdir() {
	if [ ! -d "$1" ]; then
		lo_rw
		mkdir "$1" || lo_fail "mkdir $1 failed"
		chmod "$2" "$1" || lo_fail "chmod $2 $1 failed"
		lo_ro
		lo_prepare
		echo "$1" >>"$LO_ST/sysdirs.created"
		lo_say "created $1"
	fi
}

lo_sys_rm() {
	if [ -e "$1" ]; then
		lo_rw
		rm "$1" || lo_fail "rm $1 failed"
		lo_ro
		lo_say "removed $1"
	fi
}
