#!/usr/bin/env bash
# LibreOuya: APK installs, bundles, RetroArch, content pushes.

cmd_install() {
	local p f
	need_ouya
	[ "$#" -gt 0 ] || die "usage: LibreOuya.sh install <file.apk|folder> ..."
	for p in "$@"; do
		if [ -d "$p" ]; then
			for f in "$p"/*.apk; do
				[ -f "$f" ] || continue
				ask "Install $(basename -- "$f")?" && install_apk "$f"
			done
		elif [ -f "$p" ]; then
			ask "Install $(basename -- "$p")?" && install_apk "$p"
		else
			err "not found: $p"
		fi
	done
}

# Bundle files: one entry per line, "fdroid <pkg>[|<pkg>...] <label>".
# Alternatives separated by | are tried in order until one has a build
# for Android 4.1.
cmd_bundle() {
	local name=${1:-} file kind pkgs label pkg done_one
	if [ -z "$name" ]; then
		say "Bundles:"
		for file in "$LO_ROOT"/bundles/*.list; do
			say "  $(basename -- "$file" .list): $(sed -n 's/^# //p' "$file" | head -n 1)"
		done
		return 0
	fi
	file=$LO_ROOT/bundles/$name.list
	[ -f "$file" ] || die "no bundle '$name' (run ./LibreOuya.sh bundle to list them)"
	need_ouya
	need_cmds jq
	heading "Bundle: $name"
	while IFS=' ' read -r kind pkgs label; do
		case $kind in
		'' | '#'*) continue ;;
		fdroid) ;;
		*) warn "unknown bundle line: $kind $pkgs"; continue ;;
		esac
		if ! ask "Install $label?"; then
			continue
		fi
		done_one=0
		for pkg in ${pkgs//|/ }; do
			if fdroid_get "$pkg"; then
				install_apk "$LO_FETCHED" && done_one=1
				break
			fi
		done
		[ "$done_one" = 1 ] || warn "$label: no installable build found"
	done <"$file"
}

latest_retroarch_stable() {
	local v best=''
	while IFS= read -r v; do
		if [ -z "$best" ] || ver_ge "$v" "$best"; then
			best=$v
		fi
	done < <(curl -fsL --connect-timeout 20 https://buildbot.libretro.com/stable/ |
		sed -n 's/.*href="\(\/stable\/\)\{0,1\}\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)\/".*/\2/p')
	printf '%s\n' "$best"
}

cmd_retroarch() {
	local src ver
	need_ouya
	heading "RetroArch"
	say "Runs well for 8/16-bit systems, arcade and most PS1. N64 is light games only."
	say "GameCube/Wii are not possible on this hardware."
	src=$(choose "Which build?" \
		"F-Droid build (hash checked against F-Droid's index, recommended)" \
		"libretro's 32-bit build, latest stable (no published hash, you check it)") || return 0
	case $src in
	F-Droid*)
		need_cmds jq
		fdroid_get com.retroarch || return 1
		;;
	*)
		ver=$(latest_retroarch_stable)
		[ -n "$ver" ] || die "could not read the stable list from buildbot.libretro.com"
		say "Latest stable on buildbot: $ver"
		ask "Download RetroArch_ra32.apk $ver?" || return 0
		fetch_url "https://buildbot.libretro.com/stable/$ver/android/RetroArch_ra32.apk" \
			"RetroArch_ra32-$ver.apk" - || return 1
		;;
	esac
	install_apk "$LO_FETCHED" || return 1
	if ask "Create /sdcard/RetroArch/roms and /sdcard/RetroArch/system for your games and BIOS files?"; then
		act adb_dev shell mkdir -p /sdcard/RetroArch/roms /sdcard/RetroArch/system
	fi
	say "In RetroArch: Online Updater > Core Downloader for cores, then point the file browser"
	say "start directory at /sdcard/RetroArch/roms and the System/BIOS directory at /sdcard/RetroArch/system."
}

cmd_push_roms() {
	local dir=${1:-} sys=${2:-} f
	need_ouya
	[ -d "$dir" ] && [ -n "$sys" ] || die "usage: LibreOuya.sh push-roms <local folder> <system name, e.g. psx>"
	safe_value "$sys" || die "system name may only use letters, digits, . _ -"
	ask "Copy everything in $dir to /sdcard/RetroArch/roms/$sys/ on the OUYA?" || return 0
	act adb_dev shell mkdir -p "/sdcard/RetroArch/roms/$sys"
	for f in "$dir"/*; do
		[ -e "$f" ] || continue
		act adb_dev push "$f" "/sdcard/RetroArch/roms/$sys/"
	done
	ok "Copied. Only push games you own."
}

cmd_push_bios() {
	local dir=${1:-} f
	need_ouya
	[ -d "$dir" ] || die "usage: LibreOuya.sh push-bios <local folder>"
	ask "Copy everything in $dir to /sdcard/RetroArch/system/ on the OUYA?" || return 0
	act adb_dev shell mkdir -p /sdcard/RetroArch/system
	for f in "$dir"/*; do
		[ -e "$f" ] || continue
		act adb_dev push "$f" /sdcard/RetroArch/system/
	done
	ok "Copied. Dump BIOS files from hardware you own."
}
