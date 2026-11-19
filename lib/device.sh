#!/usr/bin/env bash
# LibreOuya adb and fastboot plumbing.
# Android 4.1's adbd does not return exit codes and sends CRLF line endings,
# so every remote command here appends a sentinel and strips carriage returns.

LO_DEV_TMP=/data/local/tmp/libreouya
LO_DEV_SD=/sdcard/libreouya
LO_SU_METHOD=''
LO_LIB_PUSHED=0

# ---- adb binary -------------------------------------------------------------

find_adb() {
	if [ -n "${LO_ADB:-}" ]; then
		return 0
	fi
	if command -v adb >/dev/null 2>&1; then
		LO_ADB=$(command -v adb)
	elif [ -x "$LO_CACHE/platform-tools/adb" ]; then
		LO_ADB=$LO_CACHE/platform-tools/adb
	else
		err "adb not found"
		say "Install it from your package manager (android-tools, android-sdk-platform-tools,"
		say "or whichever your distro calls it), or run: ./LibreOuya.sh get-platform-tools"
		exit 1
	fi
	if [ -z "${LO_FASTBOOT:-}" ]; then
		if command -v fastboot >/dev/null 2>&1; then
			LO_FASTBOOT=$(command -v fastboot)
		elif [ -x "$LO_CACHE/platform-tools/fastboot" ]; then
			LO_FASTBOOT=$LO_CACHE/platform-tools/fastboot
		else
			LO_FASTBOOT=''
		fi
	fi
}

need_fastboot() {
	find_adb
	[ -n "$LO_FASTBOOT" ] || die "fastboot not found (same package as adb on most systems, or ./LibreOuya.sh get-platform-tools)"
}

adb_raw() {
	"$LO_ADB" "$@" </dev/null
}

# stdin comes from /dev/null so adb never eats input meant for a read loop.
adb_dev() {
	"$LO_ADB" -s "$LO_SERIAL" "$@" </dev/null
}

# adb_dev when a serial is known, plain adb otherwise (recovery/sideload
# can show up before any serial was picked).
adb_auto() {
	if [ -n "${LO_SERIAL:-}" ]; then
		adb_dev "$@"
	else
		adb_raw "$@"
	fi
}

# For interactive use (adb shell, logcat) where the terminal should pass through.
adb_dev_tty() {
	"$LO_ADB" -s "$LO_SERIAL" "$@"
}

# ---- device selection -------------------------------------------------------

# Prints "serial state" for each device adb knows about.
adb_list() {
	LC_ALL=C adb_raw devices 2>/dev/null | while IFS= read -r line; do
		line=${line%$'\r'}
		case $line in
		'List of devices'* | '' | '*'*) continue ;;
		esac
		# Word splitting is intended: "serial<TAB>state".
		# shellcheck disable=SC2086
		set -- $line
		printf '%s %s\n' "$1" "${2:-unknown}"
	done
}

pick_device() {
	local list count state
	find_adb
	if [ -n "${LO_SERIAL:-}" ]; then
		state=$(adb_list | while IFS=' ' read -r s st; do
			[ "$s" = "$LO_SERIAL" ] && printf '%s' "$st"
		done)
		[ -n "$state" ] || die "device $LO_SERIAL is not connected"
		LO_STATE_NOW=$state
		return 0
	fi
	list=$(adb_list)
	count=0
	[ -n "$list" ] && count=$(printf '%s\n' "$list" | wc -l | tr -d ' ')
	if [ "$count" -eq 0 ]; then
		err "no device found by adb"
		say "Check: OUYA powered on, micro USB DATA cable (not charge-only), and on Linux the udev"
		say "rule from the README. Network adb: ./LibreOuya.sh connect <ouya-ip>"
		exit 1
	fi
	if [ "$count" -gt 1 ]; then
		err "more than one device connected; pick one with -s <serial>:"
		printf '%s\n' "$list" >&2
		exit 1
	fi
	LO_SERIAL=${list%% *}
	LO_STATE_NOW=${list#* }
}

# Like pick_device, but a missing device is fine (it may already be in
# fastboot mode). Sets LO_STATE_NOW empty in that case.
pick_device_soft() {
	local list count
	find_adb
	LO_STATE_NOW=''
	list=$(adb_list)
	[ -n "$list" ] || return 0
	if [ -n "${LO_SERIAL:-}" ]; then
		LO_STATE_NOW=$(printf '%s\n' "$list" | while IFS=' ' read -r s st; do
			[ "$s" = "$LO_SERIAL" ] && printf '%s' "$st"
		done)
		return 0
	fi
	count=$(printf '%s\n' "$list" | wc -l | tr -d ' ')
	[ "$count" -eq 1 ] || die "more than one device connected; pick one with -s <serial>"
	LO_SERIAL=${list%% *}
	LO_STATE_NOW=${list#* }
}

need_device() {
	pick_device
	case $LO_STATE_NOW in
	device) ;;
	unauthorized) die "device $LO_SERIAL is unauthorized; accept the prompt on the TV" ;;
	sideload | recovery) die "device $LO_SERIAL is in $LO_STATE_NOW mode, reboot it normally first" ;;
	*) die "device $LO_SERIAL is in state '$LO_STATE_NOW'" ;;
	esac
}

# ---- remote shell -----------------------------------------------------------

# dsh 'command' : run on the device as the shell user. Prints output without
# the sentinel, returns the remote exit status.
dsh() {
	local out rc
	log "dsh: $1"
	out=$(adb_dev shell "$1; echo __LO_RC=\$?" 2>&1) || {
		log "adb shell failed: $out"
		printf '%s\n' "$out"
		return 255
	}
	out=$(printf '%s\n' "$out" | tr -d '\r')
	rc=$(printf '%s\n' "$out" | sed -n 's/^__LO_RC=\([0-9][0-9]*\)$/\1/p' | tail -n 1)
	out=$(printf '%s\n' "$out" | sed '/^__LO_RC=[0-9]*$/d')
	log "dsh output: $out"
	printf '%s\n' "$out"
	[ -n "$rc" ] || return 255
	return "$rc"
}

getprop_dev() {
	{ dsh "getprop $1" || true; } | head -n 1
}

# Push a local file, logging it. Respects dry run.
dpush() {
	show_cmd adb push "$1" "$2"
	[ "$LO_DRY" = 1 ] && return 0
	adb_dev push "$1" "$2" >/dev/null 2>&1 || {
		err "adb push $1 failed"
		return 1
	}
}

# ---- identification ---------------------------------------------------------

LO_MODEL='' LO_DEVICE='' LO_BUILD='' LO_FW=''

identify() {
	LO_MODEL=$(getprop_dev ro.product.model)
	LO_DEVICE=$(getprop_dev ro.product.device)
	LO_BUILD=$(getprop_dev ro.build.display.id)
	LO_SDK=$(getprop_dev ro.build.version.sdk)
	LO_FW=$(firmware_version)
}

is_ouya() {
	case "$LO_DEVICE $LO_MODEL" in
	*ouya* | *OUYA* | *Ouya*) return 0 ;;
	esac
	return 1
}

# Writes refuse to run on anything that does not identify as an OUYA unless
# --any-device was given.
need_ouya() {
	need_device
	identify
	if ! is_ouya; then
		if [ "$LO_ANY_DEVICE" = 1 ]; then
			warn "$LO_SERIAL reports model '$LO_MODEL' device '$LO_DEVICE', continuing because of --any-device"
		else
			die "$LO_SERIAL reports model '$LO_MODEL' device '$LO_DEVICE', not an OUYA. Use --any-device to override."
		fi
	fi
}

# Firmware like 1.2.1427, found in whichever build prop carries it.
firmware_version() {
	local p v
	for p in ro.build.version.incremental ro.build.display.id ro.build.description ro.build.fingerprint; do
		v=$(getprop_dev "$p" | sed -n 's/.*\(1\.[0-9]\.[0-9][0-9]*\).*/\1/p' | head -n 1) || true
		if [ -n "$v" ]; then
			printf '%s\n' "$v"
			return 0
		fi
	done
	# Some builds only carry the number after the last dot.
	v=$(getprop_dev ro.build.version.incremental)
	case $v in
	'' | *[!0-9]*) ;;
	*) if [ "$v" -ge 1000 ]; then printf '1.2.%s\n' "$v"; else printf '1.0.%s\n' "$v"; fi ;;
	esac
}

# ---- root -------------------------------------------------------------------

# Push the device library once per run.
push_device_lib() {
	[ "$LO_LIB_PUSHED" = 1 ] && return 0
	[ "$LO_DRY" = 1 ] || dsh "mkdir -p $LO_DEV_TMP" >/dev/null
	dpush "$LO_ROOT/device/lib.sh" "$LO_DEV_TMP/lib.sh" || die "could not push device library"
	LO_LIB_PUSHED=1
}

# Work out how this su takes commands. Stock OUYA su, Koush su and AOSP su
# differ, so try stdin first (works for all of them in practice), then -c,
# then the AOSP "su 0 cmd" form.
detect_su() {
	local out
	[ -n "$LO_SU_METHOD" ] && return 0
	dsh "mkdir -p $LO_DEV_TMP; echo id > $LO_DEV_TMP/probe.sh" >/dev/null
	out=$(dsh "su < $LO_DEV_TMP/probe.sh" 2>&1) || true
	case $out in
	*uid=0*) LO_SU_METHOD=stdin && return 0 ;;
	esac
	out=$(dsh "su -c 'sh $LO_DEV_TMP/probe.sh'" 2>&1) || true
	case $out in
	*uid=0*) LO_SU_METHOD=dashc && return 0 ;;
	esac
	out=$(dsh "su 0 sh $LO_DEV_TMP/probe.sh" 2>&1) || true
	case $out in
	*uid=0*) LO_SU_METHOD=aosp && return 0 ;;
	esac
	return 1
}

need_su() {
	detect_su || die "su does not give root on this OUYA (if a Superuser prompt is on the TV, allow it and retry)"
}

# root_job "description" : reads a job body on stdin, runs it as root.
# The body is plain sh calling lo_* functions from device/lib.sh.
root_job() {
	local desc=$1 body job out
	body=$(cat)
	need_su
	push_device_lib
	job=$(mktemp "${TMPDIR:-/tmp}/libreouya-job.XXXXXX") || die "mktemp failed"
	{
		printf '. %s/lib.sh\n' "$LO_DEV_TMP"
		printf '%s\n' "$body"
		printf 'lo_ok\n'
	} >"$job"
	say "Device job: $desc"
	say_lines '    | ' <"$job"
	log "job body: $(cat "$job")"
	if [ "$LO_DRY" = 1 ]; then
		say "  (dry run, not executed)"
		rm -f -- "$job"
		return 0
	fi
	adb_dev push "$job" "$LO_DEV_TMP/job.sh" >/dev/null || {
		rm -f -- "$job"
		die "could not push job"
	}
	rm -f -- "$job"
	case $LO_SU_METHOD in
	stdin) out=$(dsh "su < $LO_DEV_TMP/job.sh" 2>&1) || true ;;
	dashc) out=$(dsh "su -c 'sh $LO_DEV_TMP/job.sh'" 2>&1) || true ;;
	aosp) out=$(dsh "su 0 sh $LO_DEV_TMP/job.sh" 2>&1) || true ;;
	esac
	printf '%s\n' "$out" | sed -n 's/^LO_INFO: //p' | say_lines '    '
	case $out in
	*LO_FAIL:*)
		err "device job failed: $(printf '%s\n' "$out" | sed -n 's/^LO_FAIL: //p' | head -n 1)"
		return 1
		;;
	*LO_OK*) return 0 ;;
	*)
		err "device job gave no result. Output was:"
		printf '%s\n' "$out" | say_lines '    '
		return 1
		;;
	esac
}

# ---- reboots ----------------------------------------------------------------

wait_boot() {
	local i=0 b=''
	say "Waiting for the OUYA to come back (up to 3 minutes)..."
	act adb_dev wait-for-device || return 1
	[ "$LO_DRY" = 1 ] && return 0
	while [ "$i" -lt 90 ]; do
		b=$(dsh 'getprop sys.boot_completed' 2>/dev/null | head -n 1) || true
		[ "$b" = 1 ] && { ok "Booted."; return 0; }
		sleep 2
		i=$((i + 1))
	done
	warn "boot did not report complete within 3 minutes"
	return 1
}

reboot_device() {
	ask "Reboot the OUYA now?" || return 1
	act adb_dev reboot || return 1
	sleep 5
	wait_boot
}

# Wait for adb to show the device in a given state (sideload, recovery...).
wait_adb_state() {
	local want=$1 secs=${2:-300} i=0 st
	while [ "$i" -lt "$secs" ]; do
		st=$(adb_list | while IFS=' ' read -r s x; do
			if [ -z "${LO_SERIAL:-}" ] || [ "$s" = "$LO_SERIAL" ]; then
				printf '%s' "$x"
			fi
		done)
		case $st in
		*"$want"*) return 0 ;;
		esac
		sleep 2
		i=$((i + 2))
	done
	return 1
}

# ---- fastboot ---------------------------------------------------------------

fastboot_serial() {
	LC_ALL=C "$LO_FASTBOOT" devices 2>/dev/null | tr -d '\r' | while IFS= read -r line; do
		# shellcheck disable=SC2086
		set -- $line
		[ -n "${1:-}" ] && printf '%s\n' "$1"
	done
}

wait_fastboot() {
	local i=0 n list
	say "Waiting for fastboot (up to 2 minutes)..."
	while [ "$i" -lt 60 ]; do
		list=$(fastboot_serial)
		if [ -n "$list" ]; then
			n=$(printf '%s\n' "$list" | wc -l | tr -d ' ')
			if [ "$n" -gt 1 ]; then
				err "more than one fastboot device:"
				printf '%s\n' "$list" >&2
				return 1
			fi
			LO_FB_SERIAL=$list
			ok "fastboot sees $LO_FB_SERIAL"
			return 0
		fi
		sleep 2
		i=$((i + 1))
	done
	err "no fastboot device appeared. On Linux check the udev rule for fastboot mode (README)."
	return 1
}

fb() {
	act "$LO_FASTBOOT" -s "$LO_FB_SERIAL" "$@" </dev/null
}

# ---- apk install ------------------------------------------------------------

# Install an APK the way Android 4.1 likes it: push, then pm install.
install_apk() {
	local apk=$1 name out
	name=$(basename -- "$apk")
	safe_value "$name" || name=libreouya-install.apk
	[ "$LO_DRY" = 1 ] || dsh "mkdir -p $LO_DEV_TMP" >/dev/null
	dpush "$apk" "$LO_DEV_TMP/$name" || return 1
	[ "$LO_DRY" = 1 ] && { show_cmd pm install -r "$LO_DEV_TMP/$name"; return 0; }
	show_cmd adb shell pm install -r "$LO_DEV_TMP/$name"
	out=$(dsh "pm install -r $LO_DEV_TMP/$name") || true
	dsh "rm $LO_DEV_TMP/$name" >/dev/null || true
	case $out in
	*Success*) ok "Installed $name"; return 0 ;;
	*INSTALL_FAILED_OLDER_SDK*) err "$name needs a newer Android than the OUYA's 4.1 (API 16)" ;;
	*INSTALL_FAILED_INSUFFICIENT_STORAGE*) err "not enough space on the OUYA for $name" ;;
	*INSTALL_FAILED_NO_MATCHING_ABIS* | *INSTALL_FAILED_CPU_ABI_INCOMPATIBLE*) err "$name has no 32-bit ARM code" ;;
	*INSTALL_FAILED_UPDATE_INCOMPATIBLE* | *INSTALL_FAILED_INCONSISTENT_CERTIFICATES*)
		err "$name is signed differently from the installed copy; uninstall that first" ;;
	*INSTALL_PARSE_FAILED*) err "$name is not a valid APK for this Android version" ;;
	*) err "install of $name failed: $out" ;;
	esac
	return 1
}
