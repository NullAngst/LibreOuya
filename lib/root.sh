#!/usr/bin/env bash
# LibreOuya: status, root/unroot, backups, logs.

LO_SU_STOCK=450f57ac1700be5387bc76d01f59dd40
LO_SU_COMMUNITY=8e9262aeae3382849acf3da2f82663d5
LO_SU_REROOT=15813da48f2e7f33b6faa3220eebd7fe
LO_FW_LATEST=1.2.1427

su_md5() {
	{ dsh 'md5sum /system/xbin/su 2>/dev/null' || true; } | sed -n 's/^\([0-9a-f]\{32\}\).*/\1/p' | head -n 1
}

su_kind() {
	case $1 in
	"$LO_SU_STOCK") printf 'stock OUYA su (shell-only root, apps cannot ask for root)' ;;
	"$LO_SU_COMMUNITY") printf 'community su (ConnectYA)' ;;
	"$LO_SU_REROOT") printf 'Koush su (LibreOuya / OUYA-ReRoot)' ;;
	'') printf 'no su found' ;;
	*) printf 'unknown su build' ;;
	esac
}

# ---- status -----------------------------------------------------------------

cmd_status() {
	local su cfg hosts port free
	need_device
	identify
	heading "OUYA status ($LO_SERIAL)"
	if is_ouya; then ok "Model: $LO_MODEL ($LO_DEVICE)"; else warn "Model: $LO_MODEL ($LO_DEVICE), does not look like an OUYA"; fi
	say "Build: $LO_BUILD, Android API $LO_SDK"
	if [ -z "$LO_FW" ]; then
		warn "Firmware: could not read a version. Check Manage > System on the OUYA."
	elif [ "$LO_FW" = "$LO_FW_LATEST" ]; then
		ok "Firmware: $LO_FW (latest)"
	else
		warn "Firmware: $LO_FW, latest is $LO_FW_LATEST. See: ./libreouya firmware"
	fi
	say "Kernel: $(dsh 'cat /proc/version' | cut -c 1-60)"
	su=$(su_md5)
	say "su: $(su_kind "$su")${su:+ ($su)}"
	if detect_su; then ok "Root from adb shell: works ($LO_SU_METHOD)"; else warn "Root from adb shell: not working"; fi
	if { dsh 'pm path com.koushikdutta.superuser' || true; } | grep -q package:; then
		say "Superuser app: installed"
	else
		say "Superuser app: not installed"
	fi
	cfg=$(dsh 'cat /sdcard/ouya_config.properties 2>/dev/null') || cfg=''
	case $cfg in
	*OUYA_SERVER_URL=*) say "Store server: $(printf '%s\n' "$cfg" | sed -n 's/^OUYA_SERVER_URL=//p' | head -n 1)" ;;
	*) say "Store server: none set (store toggle is off)" ;;
	esac
	hosts=$(dsh 'cat /system/etc/hosts' | grep -E 'devs\.ouya\.tv|status\.ouya\.tv|ouya-updates' || true)
	if [ -n "$hosts" ]; then
		say "hosts entries:"
		printf '%s\n' "$hosts" | sed 's/^/    /'
	else
		say "hosts entries: none for OUYA servers (the setup wizard check will fail on a fresh box)"
	fi
	port=$(getprop_dev service.adb.tcp.port)
	say "Network adb: ${port:-off}"
	free=$({ dsh 'df /data' || true; } | tail -n 1)
	say "Space on /data: $free"
}

# ---- root -------------------------------------------------------------------

cmd_root() {
	local cur choice id md5 out
	need_ouya
	heading "Root"
	cur=$(su_md5)
	say "Current su: $(su_kind "$cur")${cur:+ ($cur)}"
	if ! detect_su; then
		err "su does not work from adb shell, so there is no way in to replace it."
		say "A stock OUYA's su works from adb out of the box. If this one does not, reflash with:"
		say "  ./libreouya flash-stock"
		return 1
	fi
	say "This replaces /system/xbin/su with a Superuser-compatible build so apps can ask for root."
	say "The current su is saved to $LO_DEV_SD/backup/xbin_su.orig first, and ./libreouya unroot puts it back."
	ask "Root this OUYA?" || return 0
	choice=$(choose "Which su binary?" \
		"Koush su bundled with LibreOuya (from OUYA-ReRoot, recommended)" \
		"ConnectYA community su (downloaded from statics.ouya.world)") || return 0
	case $choice in
	Koush*) id=su_reroot ;;
	*) id=su_community ;;
	esac
	fetch_entry "$id" || return 1
	md5=${M_MD5:-$(md5_of "$LO_FETCHED")}
	push_device_lib
	dpush "$LO_FETCHED" "$LO_DEV_TMP/su.new" || return 1
	root_job "replace /system/xbin/su" <<EOF || return 1
lo_install $LO_DEV_TMP/su.new /system/xbin/su 06755 0.0 $md5 xbin_su
rm $LO_DEV_TMP/su.new
EOF
	if ask "Also add /system/bin/su as a link (some apps only look there)?"; then
		root_job "link /system/bin/su" <<EOF || true
lo_su_link
EOF
	fi
	LO_SU_METHOD=''
	if [ "$LO_DRY" != 1 ]; then
		if detect_su; then
			out=$(dsh 'echo id | su' 2>&1) || true
			ok "Root works after the swap: ${out%%$'\n'*}"
		else
			err "su no longer answers. Roll back with: ./libreouya unroot"
			return 1
		fi
	fi
	if ask "Install the Superuser manager app (com.koushikdutta.superuser 1.0.3.0)?"; then
		fetch_entry superuser && install_apk "$LO_FETCHED"
		say "Open it once on the OUYA (MAKE > SOFTWARE > Superuser) and allow updates if it asks."
	fi
	if ask "Copy the device-side backups to this PC now?"; then
		pull_backups
	fi
}

cmd_unroot() {
	local has_bk md5
	need_ouya
	heading "Unroot"
	say "Current su: $(su_kind "$(su_md5)")"
	need_su
	has_bk=$(dsh "ls $LO_DEV_SD/backup/xbin_su.orig 2>/dev/null") || has_bk=''
	if [ -n "$has_bk" ]; then
		say "Found the su that was here before LibreOuya rooted: $LO_DEV_SD/backup/xbin_su.orig"
		ask "Put it back?" || return 0
		root_job "restore original su" <<'EOF' || return 1
lo_restore xbin_su /system/xbin/su 06755 0.0 orig
EOF
	else
		warn "No backup of the original su on this OUYA."
		ask "Install the stock OUYA su (md5 $LO_SU_STOCK) instead?" || return 0
		fetch_entry su_stock || return 1
		md5=${M_MD5:-$(md5_of "$LO_FETCHED")}
		push_device_lib
		dpush "$LO_FETCHED" "$LO_DEV_TMP/su.new" || return 1
		root_job "install stock su" <<EOF || return 1
lo_install $LO_DEV_TMP/su.new /system/xbin/su 06755 0.0 $md5 xbin_su
rm $LO_DEV_TMP/su.new
EOF
	fi
	root_job "remove /system/bin/su link if LibreOuya made it" <<'EOF' || true
lo_su_unlink
EOF
	if ask "Uninstall the Superuser app?"; then
		act adb_dev shell pm uninstall com.koushikdutta.superuser || true
	fi
	ok "Unroot done."
}

# ---- backups ----------------------------------------------------------------

backup_dir() {
	local d
	d=$LO_STATE/backups/$LO_SERIAL/$(date '+%Y-%m-%d_%H%M%S')
	mkdir -p -- "$d"
	printf '%s\n' "$d"
}

pull_backups() {
	local d
	d=$(backup_dir)
	act adb_dev pull "$LO_DEV_SD" "$d/sdcard-libreouya" || warn "nothing to pull from $LO_DEV_SD yet"
	ok "Device backups copied to $d"
}

cmd_backup() {
	local d parts p
	need_ouya
	heading "Backup"
	d=$(backup_dir)
	say "Saving to $d"
	ask "Save device info (getprop, partition list, package list) here?" && {
		dsh 'getprop' >"$d/getprop.txt" || true
		dsh 'cat /proc/partitions' >"$d/partitions.txt" || true
		dsh 'ls -l /dev/block/platform/sdhci-tegra.3/by-name/' >"$d/by-name.txt" || true
		dsh 'pm list packages' >"$d/packages.txt" || true
		ok "Saved device info"
	}
	if detect_su; then
		parts=" $(dsh 'ls /dev/block/platform/sdhci-tegra.3/by-name/' | tr '\n\t' '  ') " || parts=''
		for p in LNX SOS; do
			case $parts in
			*" $p "*) ;;
			*)
				say "No $p partition listed, skipping it"
				continue
				;;
			esac
			if ask "Dump partition $p ($( [ "$p" = LNX ] && printf 'boot/kernel' || printf 'recovery')) to the PC?"; then
				root_job "dump $p" <<EOF || continue
lo_dump_part $p $LO_DEV_SD/backup/parts/$p.img
EOF
				mkdir -p -- "$d/parts"
				act adb_dev pull "$LO_DEV_SD/backup/parts/$p.img" "$d/parts/$p.img" && ok "Saved $d/parts/$p.img"
			fi
		done
	else
		warn "su not working, skipping partition dumps"
	fi
	if ask "Copy $LO_DEV_SD (LibreOuya's on-device backups of changed files) here too?"; then
		act adb_dev pull "$LO_DEV_SD" "$d/sdcard-libreouya" || true
	fi
	ok "Backup folder: $d"
}

latest_part_backup() {
	# latest_part_backup SOS -> path of newest saved image for this OUYA
	local f best=''
	for f in "$LO_STATE"/backups/"$LO_SERIAL"/*/parts/"$1".img; do
		[ -f "$f" ] && best=$f
	done
	printf '%s\n' "$best"
}

# ---- logs -------------------------------------------------------------------

cmd_logs() {
	local d=$LO_RUN/device-logs
	need_device
	mkdir -p -- "$d"
	heading "Log snapshot"
	ask "Save getprop, logcat, dmesg, mounts and package list to $d?" || return 0
	dsh 'getprop' >"$d/getprop.txt" || true
	dsh 'logcat -d' >"$d/logcat.txt" || true
	dsh 'dmesg' >"$d/dmesg.txt" || true
	dsh 'cat /proc/version' >"$d/kernel.txt" || true
	dsh 'mount' >"$d/mount.txt" || true
	dsh 'df' >"$d/df.txt" || true
	dsh 'pm list packages' >"$d/packages.txt" || true
	ok "Saved to $d. Nothing is uploaded anywhere; share it yourself if you want help."
}

# Live logcat with the OUYA framework's DEBUG=1 flag, restored on exit.
cmd_logcat() {
	local cfg f had_cfg=0
	need_device
	f=$LO_RUN/logcat-live.txt
	cfg=$(mktemp "${TMPDIR:-/tmp}/libreouya-cfg.XXXXXX") || die "mktemp failed"
	if dsh 'cat /sdcard/ouya_config.properties' >"$cfg" 2>/dev/null && [ -s "$cfg" ]; then
		had_cfg=1
	fi
	if [ "$had_cfg" = 1 ] && ask "Add DEBUG=1 to ouya_config.properties for more detail while capturing? (removed afterwards)"; then
		{ grep -v '^DEBUG=' "$cfg"; printf 'DEBUG=1\n'; } >"$cfg.debug"
		dpush "$cfg.debug" /sdcard/ouya_config.properties
		# shellcheck disable=SC2064
		trap "grep -v '^DEBUG=' '$cfg' > '$cfg.clean'; '$LO_ADB' -s '$LO_SERIAL' push '$cfg.clean' /sdcard/ouya_config.properties >/dev/null 2>&1; rm -f -- '$cfg' '$cfg.debug' '$cfg.clean'" EXIT INT TERM
	else
		# shellcheck disable=SC2064
		trap "rm -f -- '$cfg'" EXIT
	fi
	say "Capturing to $f. Press Ctrl+C to stop."
	adb_dev logcat -c || true
	adb_dev logcat | tee -a "$f" || true
}
