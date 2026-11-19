#!/usr/bin/env bash
# LibreOuya tweaks: permanent network adb, init.d support, USB swap.

# ---- network adb ------------------------------------------------------------

cmd_netadb() {
	local action=${1:-} cur new md5
	need_ouya
	need_su
	case $action in
	on)
		heading "Permanent network adb"
		say "Adds service.adb.tcp.port=5555 to /system/build.prop so adb over the network"
		say "survives reboots. Anyone on your LAN can then reach adb on the OUYA."
		ask "Turn it on?" || return 0
		cur=$(mktemp "${TMPDIR:-/tmp}/libreouya-bp.XXXXXX") || die "mktemp failed"
		new=$cur.new
		dsh 'cat /system/build.prop' >"$cur" || die "could not read build.prop"
		if grep -q '^service\.adb\.tcp\.port=' "$cur"; then
			ok "build.prop already sets service.adb.tcp.port"
			rm -f -- "$cur"
			return 0
		fi
		{ cat "$cur"; printf '\n# libreouya: network adb\nservice.adb.tcp.port=5555\n'; } >"$new"
		md5=$(md5_of "$new")
		push_device_lib
		dpush "$new" "$LO_DEV_TMP/build.prop.new" || return 1
		rm -f -- "$cur" "$new"
		root_job "update /system/build.prop" <<EOF || return 1
lo_install $LO_DEV_TMP/build.prop.new /system/build.prop 0644 0.0 $md5 build_prop
rm $LO_DEV_TMP/build.prop.new
EOF
		ok "Takes effect after a reboot. Then: ./LibreOuya.sh connect <ouya-ip>"
		;;
	off)
		ask "Restore /system/build.prop from before LibreOuya changed it?" || return 0
		root_job "restore /system/build.prop" <<'EOF'
lo_restore build_prop /system/build.prop 0644 0.0 orig
EOF
		;;
	*) die "usage: LibreOuya.sh netadb on|off" ;;
	esac
}

# ---- init.d -----------------------------------------------------------------
# Android 4.1 runs /system/etc/install-recovery.sh once at boot, as root, from
# the flash_recovery service in init.rc. LibreOuya puts a small hook there that
# runs /system/etc/init.d/* scripts. No helper app needed.

initd_supported() {
	local out
	out=$(root_job "look for the flash_recovery service in init.rc" <<'EOF'
case "$(cat /init.rc /init.*.rc 2>/dev/null)" in
*install-recovery.sh*) lo_say "HOOK=yes" ;;
*) lo_say "HOOK=no" ;;
esac
EOF
	) || return 1
	# Match the reported line, not the echoed job body.
	printf '%s\n' "$out" | grep -q '^    HOOK=yes$'
}

initd_active() {
	dsh 'cat /system/etc/install-recovery.sh 2>/dev/null' | grep -q 'libreouya init.d hook'
}

cmd_initd() {
	local action=${1:-} hook had_orig md5 keep=0
	need_ouya
	need_su
	case $action in
	on)
		heading "init.d support"
		if initd_active; then
			ok "init.d hook is already installed"
			return 0
		fi
		if [ "$LO_DRY" != 1 ] && ! initd_supported; then
			err "this firmware's init.rc has no install-recovery.sh service, so the hook would never run."
			say "Things that need boot-time start (DNS, swap) can still be started by hand: ./LibreOuya.sh dns start"
			return 1
		fi
		say "Puts a hook in /system/etc/install-recovery.sh that runs /system/etc/init.d/* at boot."
		had_orig=$(dsh 'ls /system/etc/install-recovery.sh 2>/dev/null') || had_orig=''
		if [ -n "$had_orig" ]; then
			say "The OUYA already has an install-recovery.sh. On stock firmware it usually rewrites the"
			say "stock recovery on every boot, which would undo a flashed CWM recovery."
			ask "Keep running the original from the hook?" && keep=1
		fi
		ask "Install the init.d hook? (the original file is backed up and './LibreOuya.sh initd off' restores it)" || return 0
		hook=$(mktemp "${TMPDIR:-/tmp}/libreouya-hook.XXXXXX") || die "mktemp failed"
		{
			printf '#!/system/bin/sh\n'
			printf '# libreouya init.d hook. Runs /system/etc/init.d/* once at boot, as root.\n'
			if [ "$keep" = 1 ]; then
				printf 'if [ -f /system/etc/install-recovery-libreouya-orig.sh ]; then\n'
				printf '\t/system/bin/sh /system/etc/install-recovery-libreouya-orig.sh\n'
				printf 'fi\n'
			fi
			# The $f below is for the device shell, not this one.
			# shellcheck disable=SC2016
			printf 'for f in /system/etc/init.d/*; do\n'
			# shellcheck disable=SC2016
			printf '\t[ -f "$f" ] && /system/bin/sh "$f" >/dev/null 2>&1 &\n'
			printf 'done\n'
		} >"$hook"
		md5=$(md5_of "$hook")
		push_device_lib
		dpush "$hook" "$LO_DEV_TMP/hook.sh" || return 1
		rm -f -- "$hook"
		if [ "$keep" = 1 ]; then
			root_job "keep a copy of the original install-recovery.sh" <<'EOF' || return 1
cat /system/etc/install-recovery.sh > /data/local/tmp/libreouya/orig-hook.sh || lo_fail "copy failed"
lo_install /data/local/tmp/libreouya/orig-hook.sh /system/etc/install-recovery-libreouya-orig.sh 0755 0.0 "$(lo_md5 /data/local/tmp/libreouya/orig-hook.sh)" install_recovery_orig_copy
rm /data/local/tmp/libreouya/orig-hook.sh
EOF
		fi
		root_job "install the init.d hook" <<EOF || return 1
lo_sys_mkdir /system/etc/init.d 0755
lo_install $LO_DEV_TMP/hook.sh /system/etc/install-recovery.sh 0755 0.0 $md5 install_recovery
rm $LO_DEV_TMP/hook.sh
EOF
		ok "init.d hook installed. Scripts in /system/etc/init.d run at the next boot."
		;;
	off)
		ask "Restore the original install-recovery.sh (or remove it if there was none)?" || return 0
		root_job "remove the init.d hook" <<'EOF'
lo_restore install_recovery /system/etc/install-recovery.sh 0755 0.0 orig
if [ -e /system/etc/install-recovery-libreouya-orig.sh ]; then lo_sys_rm /system/etc/install-recovery-libreouya-orig.sh; fi
EOF
		say "/system/etc/init.d is left in place; its scripts no longer run at boot."
		;;
	*) die "usage: LibreOuya.sh initd on|off" ;;
	esac
}

# Install or remove one init.d script. initd_script <name> <file|-remove>
initd_script() {
	local name=$1 src=$2 md5
	if [ "$src" = -remove ]; then
		root_job "remove /system/etc/init.d/$name" <<EOF
lo_sys_rm /system/etc/init.d/$name
EOF
		return
	fi
	md5=$(md5_of "$src")
	push_device_lib
	dpush "$src" "$LO_DEV_TMP/$name" || return 1
	root_job "install /system/etc/init.d/$name" <<EOF
lo_sys_mkdir /system/etc/init.d 0755
lo_install $LO_DEV_TMP/$name /system/etc/init.d/$name 0755 0.0 $md5 initd_$name
rm $LO_DEV_TMP/$name
EOF
}

# ---- swap -------------------------------------------------------------------

cmd_swap() {
	local action=${1:-} mnt size f
	need_ouya
	need_su
	case $action in
	on)
		heading "Swap file on a USB stick"
		if ! dsh 'busybox mkswap --help 2>&1; busybox swapon --help 2>&1' | grep -qi 'usage'; then
			err "this needs BusyBox on the OUYA (mkswap and swapon are not in the stock toolbox)."
			say "Install a BusyBox build you trust, then run this again."
			return 1
		fi
		mnt=$(prompt_value "Where is the USB stick mounted on the OUYA?" /mnt/usbdrive) || return 0
		safe_value "$mnt" || die "unusual path: $mnt"
		size=$(prompt_value "Swap size in MB" 512) || return 0
		case $size in '' | *[!0-9]*) die "not a number: $size" ;; esac
		say "Swap on flash wears the stick and is slow; it helps only when RAM runs out (RetroArch, PSP)."
		ask "Create $mnt/libreouya.swap ($size MB) and turn it on?" || return 0
		root_job "create swap" <<EOF || return 1
[ -d $mnt ] || lo_fail "$mnt does not exist; is the stick plugged in?"
dd if=/dev/zero of=$mnt/libreouya.swap bs=1048576 count=$size 2>/dev/null || lo_fail "dd failed (stick full or read-only?)"
busybox mkswap $mnt/libreouya.swap >/dev/null || lo_fail "mkswap failed"
busybox swapon $mnt/libreouya.swap || lo_fail "swapon failed (kernel may lack swap support)"
lo_say "swap on: $mnt/libreouya.swap"
EOF
		if initd_active && ask "Turn it on at every boot (init.d script)?"; then
			f=$(mktemp "${TMPDIR:-/tmp}/libreouya-swap.XXXXXX") || die "mktemp failed"
			printf '#!/system/bin/sh\n# libreouya swap\nsleep 20\n[ -f %s/libreouya.swap ] && busybox swapon %s/libreouya.swap\n' "$mnt" "$mnt" >"$f"
			initd_script 50libreouya-swap "$f"
			rm -f -- "$f"
		fi
		;;
	off)
		mnt=$(prompt_value "Where is the USB stick mounted on the OUYA?" /mnt/usbdrive) || return 0
		safe_value "$mnt" || die "unusual path: $mnt"
		ask "Turn swap off and delete $mnt/libreouya.swap?" || return 0
		root_job "remove swap" <<EOF
busybox swapoff $mnt/libreouya.swap 2>/dev/null
rm $mnt/libreouya.swap 2>/dev/null
lo_say "swap removed"
EOF
		initd_script 50libreouya-swap -remove || true
		;;
	*) die "usage: LibreOuya.sh swap on|off" ;;
	esac
}
