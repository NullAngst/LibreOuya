#!/usr/bin/env bash
# LibreOuya test suite. Plain bash, no framework. Run: bash tests/run.sh
# shellcheck source-path=SCRIPTDIR/..
set -euo pipefail

T_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P) || exit 1
T_TMP=$(mktemp -d "${TMPDIR:-/tmp}/libreouya-test.XXXXXX")
trap 'rm -rf -- "$T_TMP"' EXIT
export XDG_CACHE_HOME=$T_TMP/cache XDG_STATE_HOME=$T_TMP/state XDG_CONFIG_HOME=$T_TMP/config
export NO_COLOR=1

pass=0
fail=0
check() {
	# check "name" expected actual
	if [ "$2" = "$3" ]; then
		pass=$((pass + 1))
		printf 'ok   %s\n' "$1"
	else
		fail=$((fail + 1))
		printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"
	fi
}

# Globals read by the sourced libraries.
# shellcheck disable=SC2034
LO_ROOT=$T_ROOT
# shellcheck disable=SC2034
LO_DRY=0
# shellcheck disable=SC2034
LO_ANY_DEVICE=0
# shellcheck disable=SC2034
LO_SERIAL=''
# shellcheck disable=SC2034
LO_VERSION='test'
# shellcheck source=lib/ui.sh
. "$T_ROOT/lib/ui.sh"
# shellcheck source=lib/core.sh
. "$T_ROOT/lib/core.sh"
# shellcheck source=lib/device.sh
. "$T_ROOT/lib/device.sh"
# shellcheck source=lib/fetch.sh
. "$T_ROOT/lib/fetch.sh"
# shellcheck source=lib/net.sh
. "$T_ROOT/lib/net.sh"
# shellcheck source=lib/dns.sh
. "$T_ROOT/lib/dns.sh"
lo_init_colors
lo_init_paths

# ---- version compare
r=0; ver_ge 1.2.1427 1.0.138 || r=1; check "ver_ge newer" 0 "$r"
r=0; ver_ge 1.0.138 1.2.1427 || r=1; check "ver_ge older" 1 "$r"
r=0; ver_ge 1.2.1427 1.2.1427 || r=1; check "ver_ge equal" 0 "$r"
r=0; ver_ge 1.22.2 1.9.0 || r=1; check "ver_ge numeric not lexical" 0 "$r"

# ---- shell quoting for device jobs
# The $(reboot) value is a literal test string.
# shellcheck disable=SC2016
for v in "plain" "it's" "a b" '$(reboot)' "x'y'z"; do
	got=$(sh -c "printf '%s' $(shq "$v")")
	check "shq round trip: $v" "$v" "$got"
done
r=0; safe_value '/data/local/tmp/x.apk' || r=1; check "safe_value path" 0 "$r"
r=0; safe_value 'a;reboot' || r=1; check "safe_value rejects ;" 1 "$r"

# ---- manifest and bundled mirror files
for id in su_reroot superuser cwm_6032; do
	manifest_get "$id"
	src=${M_SOURCES%% *}
	r=0; verify_file "$T_ROOT/${src#mirror:}" >/dev/null 2>&1 || r=$?
	check "mirror verifies: $id" 0 "$r"
done
manifest_get su_community
check "md5-only entry has no sha256" "" "$M_SHA256"
check "md5-only entry md5" 8e9262aeae3382849acf3da2f82663d5 "$M_MD5"
manifest_get firmware_1427
check "firmware size" 131807880 "$M_SIZE"

# ---- F-Droid picker
got=$(fdroid_pick org.videolan.vlc "$T_ROOT/tests/fixtures/index-v2.json")
check "fdroid picks newest API16 ARMv7 build" $'/org.videolan.vlc_2.apk\tbbb\t200\t2.0' "$got"
got=$(fdroid_pick fr.neamar.kiss "$T_ROOT/tests/fixtures/index-v2.json")
check "fdroid accepts no native code" $'/fr.neamar.kiss_5.apk\tkkk\t50\t5' "$got"
got=$(fdroid_pick too.new "$T_ROOT/tests/fixtures/index-v2.json")
check "fdroid skips minSdk 21" "" "$got"
got=$(fdroid_pick not.there "$T_ROOT/tests/fixtures/index-v2.json")
check "fdroid missing package" "" "$got"

# ---- blocklist conversion
got=$(blocklist_convert <"$T_ROOT/tests/fixtures/blocklist-in.txt" | sort -u)
check "blocklist convert" "$(cat "$T_ROOT/tests/fixtures/blocklist-out.txt")" "$got"

# ---- hosts builder
in=$(printf '127.0.0.1 localhost\r\n178.254.13.17 devs.ouya.tv\r\n10.0.0.5 nas.lan\r\n# libreouya: OUYA server names\r\n')
got=$(printf '%s\n' "$in" | hosts_build "devs.ouya.tv" 159.195.22.112)
want=$(printf '127.0.0.1 localhost\n10.0.0.5 nas.lan\n# libreouya: OUYA server names\n159.195.22.112 devs.ouya.tv')
check "hosts: replaces old OUYA lines, keeps others" "$want" "$got"
got=$(printf '' | hosts_build "" 1.2.3.4)
check "hosts: empty file gets localhost" "127.0.0.1 localhost" "$got"

# ---- fake device: status and fail-closed prompts
# Web uploads drop the exec bit, so set it here instead of trusting git.
chmod +x "$T_ROOT"/tests/fakebin/*
export PATH=$T_ROOT/tests/fakebin:$PATH
export FAKE_ADB_LOG=$T_TMP/adb.log
out=$(bash "$T_ROOT/LibreOuya.sh" status </dev/null 2>&1) || true
case $out in *'Firmware: 1.2.1427 (latest)'*) r=0 ;; *) r=1 ;; esac
check "status reads firmware through CRLF output" 0 "$r"
case $out in *'stock OUYA su'*) r=0 ;; *) r=1 ;; esac
check "status classifies stock su" 0 "$r"
: >"$FAKE_ADB_LOG"
bash "$T_ROOT/LibreOuya.sh" root </dev/null >/dev/null 2>&1 || true
if grep -q 'su.new' "$FAKE_ADB_LOG"; then r=1; else r=0; fi
check "root without a terminal changes nothing" 0 "$r"
out=$(bash "$T_ROOT/LibreOuya.sh" -n recovery boot </dev/null 2>&1) || true
case $out in *'RISKY'*) r=0 ;; *) r=1 ;; esac
check "RISKY gate shown and refused without a terminal" 0 "$r"

# ---- device library under mksh (the OUYA's shell), with /system faked
if command -v mksh >/dev/null 2>&1; then
	D=$T_TMP/dev
	mkdir -p "$D/sys" "$D/tmp"
	printf 'old su\n' >"$D/sys/su"
	printf 'new su\n' >"$D/tmp/su.new"
	new_md5=$(md5_of "$D/tmp/su.new")
	old_md5=$(md5_of "$D/sys/su")
	run_dev() {
		mksh -c ". '$T_ROOT/device/lib.sh'; LO_SD='$D/sd'; LO_BK='$D/sd/backup'; LO_ST='$D/sd/state'; lo_rw() { LO_RW=1; }; lo_ro() { LO_RW=0; }; $1; lo_ok" 2>&1 || true
	}
	out=$(run_dev "lo_install '$D/tmp/su.new' '$D/sys/su' 06755 $(id -u).$(id -g) $new_md5 xbin_su")
	case $out in *LO_OK*) r=0 ;; *) r=1 ;; esac
	check "mksh lo_install succeeds" 0 "$r"
	check "mksh lo_install wrote new file" "$new_md5" "$(md5_of "$D/sys/su")"
	check "mksh lo_install kept original" "$old_md5" "$(md5_of "$D/sd/backup/xbin_su.orig")"
	out=$(run_dev "lo_install '$D/tmp/su.new' '$D/sys/su' 06755 0.0 0000 xbin_su")
	case $out in *'LO_FAIL: staged'*) r=0 ;; *) r=1 ;; esac
	check "mksh lo_install refuses wrong md5" 0 "$r"
	out=$(run_dev "lo_restore xbin_su '$D/sys/su' 06755 $(id -u).$(id -g) orig")
	check "mksh lo_restore puts original back" "$old_md5" "$(md5_of "$D/sys/su")"
	out=$(run_dev "lo_install '$D/tmp/su.new' '$D/sys/newfile' 0644 $(id -u).$(id -g) $new_md5 newfile")
	out=$(run_dev "lo_restore newfile '$D/sys/newfile' 0644 0.0 orig")
	if [ -e "$D/sys/newfile" ]; then r=1; else r=0; fi
	check "mksh lo_restore removes a file that did not exist before" 0 "$r"
else
	printf 'skip mksh device tests (mksh not installed)\n'
fi

# ---- menus: every entry maps to a real command
# shellcheck source=lib/menu.sh
. "$T_ROOT/lib/menu.sh"
for e in "${LO_MENU[@]}"; do
	c=${e%%|*}
	c=${c%% *}
	case $c in
	toggle-dry-run | pick-device) r=0 ;;
	*) if grep -q "^	$c) " "$T_ROOT/LibreOuya.sh"; then r=0; else r=1; fi ;;
	esac
	check "menu entry '${e%%|*}' has a command" 0 "$r"
done
out=$(bash "$T_ROOT/LibreOuyaTUI.sh" </dev/null 2>&1) || true
case $out in *'needs a terminal'* | *'needs whiptail or dialog'*) r=0 ;; *) r=1 ;; esac
check "TUI refuses to start without a terminal" 0 "$r"
out=$(bash "$T_ROOT/LibreOuya.sh" </dev/null 2>&1) || true
case $out in *'Choose a number'*) r=0 ;; *) r=1 ;; esac
check "plain list draws and exits without a terminal" 0 "$r"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
