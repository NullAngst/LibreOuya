#!/usr/bin/env bash
# LibreOuya menus. One table of every option, drawn two ways:
#   LibreOuya.sh     numbered list in the terminal
#   LibreOuyaTUI.sh  whiptail/dialog menu
# Adding a line to LO_MENU adds it to both.

# command|section|label
LO_MENU=(
	"status|Start here|Show OUYA status"
	"setup|Start here|Guided setup, one question per step"
	"doctor|Start here|Check this PC for the tools LibreOuya uses"
	"get-platform-tools|Start here|Download Google's adb and fastboot"
	"connect|Start here|Connect to an OUYA over the network"
	"pick-device|Start here|Choose which device to use"
	"toggle-dry-run|Start here|Turn dry run on or off"
	"firmware|Firmware|Check firmware, offer the update to 1.2.1427"
	"flash-stock|Firmware|Install official firmware 1.2.1427 (recovery sideload)"
	"oobe|Setup wizard|Get past the setup wizard network check"
	"root|Root|Root (Superuser su and app)"
	"unroot|Root|Unroot (put the original su back)"
	"retroarch|Apps and games|Install RetroArch"
	"bundle|Apps and games|Install an app bundle from F-Droid"
	"install|Apps and games|Install APK files from this PC"
	"push-roms|Apps and games|Copy your games to RetroArch's folder"
	"push-bios|Apps and games|Copy BIOS files to RetroArch's folder"
	"netadb on|Tweaks|Network adb: on"
	"netadb off|Tweaks|Network adb: off (restore build.prop)"
	"initd on|Tweaks|Boot-time scripts (init.d): on"
	"initd off|Tweaks|Boot-time scripts (init.d): off"
	"swap on|Tweaks|USB swap file: on (needs BusyBox)"
	"swap off|Tweaks|USB swap file: off"
	"hosts show|Tweaks|Show /system/etc/hosts"
	"hosts restore|Tweaks|Restore a saved /system/etc/hosts"
	"backup|Backup and logs|Back up device info, boot and recovery images"
	"logs|Backup and logs|Save a log snapshot to this PC"
	"logcat|Backup and logs|Live logcat (Ctrl+C to stop)"
	"shell|Backup and logs|adb shell (type exit to come back)"
	"reboot|Backup and logs|Reboot the OUYA"
	"reboot recovery|Backup and logs|Reboot into recovery"
	"reboot bootloader|Backup and logs|Reboot into the bootloader (fastboot)"
	"store on|Optional: community store|Store on (cweiske, louyapi or your own server)"
	"store off|Optional: community store|Store off"
	"dns setup|Optional: DNS blocker|Set up the DNS blocker"
	"dns update|Optional: DNS blocker|Rebuild and push the blocklist"
	"dns start|Optional: DNS blocker|Start dnsmasq"
	"dns stop|Optional: DNS blocker|Stop dnsmasq"
	"dns restart|Optional: DNS blocker|Restart dnsmasq"
	"dns status|Optional: DNS blocker|dnsmasq status"
	"dns test|Optional: DNS blocker|Test the OUYA's DNS from this PC"
	"dns remove|Optional: DNS blocker|Remove the DNS blocker"
	"recovery boot|RISKY|Boot a recovery image (nothing written)"
	"recovery flash|RISKY|Flash a custom recovery"
	"recovery restore|RISKY|Restore the stock recovery"
	"rom|RISKY|Install custom ROM zips through CWM"
	"pmos-boot|DANGEROUS|Boot a postmarketOS image (nothing written)"
	"uboot|DANGEROUS|Notes on replacing the bootloader (not automated)"
)

menu_label() {
	# menu_label "<cmd|section|label>" -> label, with live state where useful
	local e=$1 cmd label
	cmd=${e%%|*}
	label=${e##*|}
	case $cmd in
	toggle-dry-run) label="Dry run is $([ "$LO_DRY" = 1 ] && printf ON || printf off), switch it" ;;
	pick-device) label="Choose device (now: ${LO_SERIAL:-automatic})" ;;
	esac
	printf '%s\n' "$label"
}

menu_section() {
	local e=${1#*|}
	printf '%s\n' "${e%%|*}"
}

# ---- actions that need arguments ---------------------------------------------

menu_pick_bundle() {
	local f names=() labels=() pick i
	for f in "$LO_ROOT"/bundles/*.list; do
		names+=("$(basename -- "$f" .list)")
		labels+=("$(basename -- "$f" .list): $(sed -n 's/^# //p' "$f" | head -n 1)")
	done
	pick=$(choose "Which bundle?" "${labels[@]}") || return 1
	for i in "${!labels[@]}"; do
		[ "${labels[$i]}" = "$pick" ] && printf '%s\n' "${names[$i]}"
	done
	return 0
}

menu_pick_device() {
	local list choice
	find_adb
	list=$(adb_list)
	if [ -z "$list" ]; then
		warn "adb sees no devices"
		LO_SERIAL=''
		return 0
	fi
	# Word splitting is intended: one option per line.
	local IFS=$'\n'
	# shellcheck disable=SC2086
	choice=$(choose "Use which device?" "automatic (only one attached)" $list) || return 0
	case $choice in
	automatic*) LO_SERIAL='' ;;
	*) LO_SERIAL=${choice%% *} ;;
	esac
	ok "Device: ${LO_SERIAL:-automatic}"
}

# Runs one menu command. Called in a subshell so a failed step cannot take
# the menu down with it.
menu_action() {
	local cmd=$1 a b z zips=() n
	case $cmd in
	install)
		a=$(prompt_value "APK file or folder of APKs on this PC" '') || return 0
		[ -n "$a" ] && cmd_install "$a"
		;;
	bundle)
		a=$(menu_pick_bundle) || return 0
		[ -n "$a" ] && cmd_bundle "$a"
		;;
	push-roms)
		a=$(prompt_value "Folder of games on this PC" '') || return 0
		b=$(prompt_value "System folder name on the OUYA (nes, snes, gb, gba, megadrive, psx, n64, ...)" psx) || return 0
		cmd_push_roms "$a" "$b"
		;;
	push-bios)
		a=$(prompt_value "Folder of BIOS files on this PC" '') || return 0
		cmd_push_bios "$a"
		;;
	"recovery boot" | "recovery flash")
		a=$(prompt_value "Recovery image path (leave empty for the bundled CWM 6.0.3.2)" '') || return 0
		cmd_recovery "${cmd#recovery }" "$a"
		;;
	rom)
		n=1
		while :; do
			z=$(prompt_value "ROM zip #$n in install order (leave empty when done)" '') || return 0
			[ -n "$z" ] || break
			zips+=("$z")
			n=$((n + 1))
		done
		[ "${#zips[@]}" -gt 0 ] || { say "No zips given."; return 0; }
		cmd_rom "${zips[@]}"
		;;
	pmos-boot)
		a=$(prompt_value "Path to the postmarketOS boot.img" '') || return 0
		cmd_pmos_boot "$a"
		;;
	*)
		# Word splitting is intended: "dns setup" -> dns setup
		# shellcheck disable=SC2086
		dispatch $cmd
		;;
	esac
}

# Handles the entries that change menu state; returns 1 for everything else.
menu_local() {
	case $1 in
	toggle-dry-run)
		if [ "$LO_DRY" = 1 ]; then LO_DRY=0; else LO_DRY=1; fi
		return 0
		;;
	pick-device)
		menu_pick_device
		return 0
		;;
	esac
	return 1
}

# ---- plain list (LibreOuya.sh) ------------------------------------------------

menu_list() {
	local reply i e sec last n
	while :; do
		printf '\n%sLibreOuya %s%s   device: %s   dry run: %s\n' "$C_BLD" "$LO_VERSION" "$C_OFF" \
			"${LO_SERIAL:-automatic}" "$([ "$LO_DRY" = 1 ] && printf ON || printf off)"
		last=''
		n=0
		for e in "${LO_MENU[@]}"; do
			n=$((n + 1))
			sec=$(menu_section "$e")
			if [ "$sec" != "$last" ]; then
				printf '\n %s%s%s\n' "$C_BLD" "$sec" "$C_OFF"
				last=$sec
			fi
			printf '  %2d) %s\n' "$n" "$(menu_label "$e")"
		done
		printf '\n   q) Quit\nChoose a number: '
		read_tty reply || return 0
		case $reply in
		q | Q) return 0 ;;
		'' | *[!0-9]*) continue ;;
		esac
		[ "$reply" -ge 1 ] && [ "$reply" -le "$n" ] || continue
		i=$((reply - 1))
		e=${LO_MENU[$i]}
		menu_local "${e%%|*}" && continue
		log "menu: ${e%%|*}"
		# Ctrl+C stops the running step (logcat, shell, a download), not the menu.
		trap 'printf "\n"' INT
		(menu_action "${e%%|*}") || true
		trap - INT
		printf '\n'
		pause "Back to the list" || true
	done
}

# ---- TUI (LibreOuyaTUI.sh) ----------------------------------------------------

menu_tui() {
	local items=() e sec last n pick status label current=1 keep
	while :; do
		items=()
		last=''
		n=0
		for e in "${LO_MENU[@]}"; do
			n=$((n + 1))
			sec=$(menu_section "$e")
			if [ "$sec" != "$last" ]; then
				items+=("~$n" "== $sec ==")
				last=$sec
			fi
			items+=("$n" "$(printf '%2d. %s' "$n" "$(menu_label "$e")")")
		done
		items+=("q" " q. Quit")
		LO_TUI_BUF=''
		tui_size
		pick=$(tui_run --title "LibreOuya: pick a step" "$(tui_notags_flag)" --default-item "$current" --menu \
			"Device: ${LO_SERIAL:-automatic}    Dry run: $([ "$LO_DRY" = 1 ] && printf ON || printf off)
Every step asks before it changes anything." \
			"$TUI_H" "$TUI_W" "$((TUI_H - 9))" "${items[@]}") || return 0
		case $pick in
		q) return 0 ;;
		'~'* | '') continue ;;
		esac
		current=$pick
		e=${LO_MENU[$((pick - 1))]}
		label=$(menu_label "$e")
		menu_local "${e%%|*}" && continue
		log "menu: ${e%%|*}"
		command -v clear >/dev/null 2>&1 && clear
		printf '%s== %s ==%s\n' "$C_BLD" "$label" "$C_OFF"
		LO_ACTION_LOG=$(mktemp "${TMPDIR:-/tmp}/libreouya-action.XXXXXX") || die "mktemp failed"
		status=0
		trap 'printf "\n"' INT
		(menu_action "${e%%|*}") || status=$?
		trap - INT
		keep=0
		case ${e%%|*} in
		shell | logcat) ;;
		*)
			if [ "$status" != 0 ]; then
				printf '\nThis step stopped with an error. The full log is in %s\n' "$LO_LOG" >>"$LO_ACTION_LOG"
				label="$label: stopped"
			else
				label="$label: finished"
			fi
			tui_show_file "$label" "$LO_ACTION_LOG" || keep=1
			;;
		esac
		rm -f -- "$LO_ACTION_LOG"
		LO_ACTION_LOG=''
		[ "$keep" = 1 ] && return 0
	done
}
