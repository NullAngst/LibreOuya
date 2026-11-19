#!/usr/bin/env bash
# LibreOuya: firmware check and stock reflash through recovery sideload.

cmd_firmware() {
	need_device
	identify
	heading "Firmware"
	if [ -z "$LO_FW" ]; then
		warn "could not read the firmware version from build props (build: $LO_BUILD)"
		say "Check Manage > System on the OUYA. If it is not $LO_FW_LATEST, run: ./libreouya flash-stock"
		return 0
	fi
	if [ "$LO_FW" = "$LO_FW_LATEST" ]; then
		ok "This OUYA runs $LO_FW, the last official firmware. Nothing to do."
		return 0
	fi
	if ver_ge "$LO_FW" "$LO_FW_LATEST"; then
		warn "This OUYA reports $LO_FW, newer than the last official $LO_FW_LATEST."
		say "Unreleased 1.2.1858 builds exist and break things; stock recovery will not go back down."
		say "Going back needs CWM (see ./libreouya recovery) and is not automated."
		return 0
	fi
	warn "This OUYA runs $LO_FW. The last official firmware is $LO_FW_LATEST."
	if ! ver_ge "$LO_FW" 1.0.138; then
		say "Below 1.0.138 the community server config file is ignored, so updating matters."
	fi
	if ask "Update to $LO_FW_LATEST now through recovery (the next steps explain each part)?"; then
		cmd_flash_stock
	fi
}

cmd_flash_stock() {
	local reply
	pick_device
	heading "Install official firmware $LO_FW_LATEST"
	if [ "$LO_STATE_NOW" = device ]; then
		identify
		is_ouya || [ "$LO_ANY_DEVICE" = 1 ] || die "$LO_SERIAL is not an OUYA ($LO_MODEL)"
		say "Current firmware: ${LO_FW:-unknown}"
	fi
	say "You need a USB keyboard plugged into the OUYA for the recovery menu."
	say "Installing over an older firmware keeps your data. The optional factory reset at the end WIPES"
	say "EVERYTHING ON THE OUYA: apps, saves, settings."
	printf 'Type FLASH to continue: '
	read_tty reply || reply=''
	log "FLASH confirm -> $reply"
	[ "$reply" = FLASH ] || { say "Cancelled."; return 0; }
	if [ "$LO_STATE_NOW" = device ] && ask "Run a backup first (device info, boot/recovery images)?"; then
		cmd_backup || warn "backup had problems, continuing is your call"
		ask "Continue with the firmware install?" || return 0
	fi
	fetch_entry firmware_1427 || {
		err "No verified firmware file. If archive.org's own hashes differ from manifest.tsv, see maintenance.md."
		return 1
	}
	if [ "$LO_STATE_NOW" = device ]; then
		ask "Reboot the OUYA into recovery now?" || return 0
		act adb_dev reboot recovery
	fi
	say ""
	say "On the TV you should see OUYA with a red exclamation mark."
	say "  1. Press the Home key on the keyboard to open the menu."
	say "  2. Arrow keys to 'apply update from ADB', then Enter."
	say "  3. It should say: Now send the package you want to apply..."
	say "No menu? Hold Alt + PrtScn (SysRq) and tap i every couple of seconds until it reboots into recovery."
	pause "When the OUYA is waiting for the package" || return 0
	if [ "$LO_DRY" != 1 ]; then
		say "Waiting for sideload mode (up to 5 minutes)..."
		wait_adb_state sideload 300 || die "OUYA never showed up in sideload mode. Check the cable and the menu choice."
	fi
	ask "Send $LO_FETCHED to the OUYA now? (do not unplug until it finishes)" || return 0
	act adb_dev sideload "$LO_FETCHED" || warn "adb sideload reported an error; read the TV screen before doing anything else"
	say ""
	say "When the TV shows the recovery menu again, the install is done."
	say "Optional, wipes everything: 'wipe data/factory reset' then 'Yes'. Do it if the box was misbehaving."
	say "Then 'reboot system now'."
	say ""
	say "Next on a freshly reset OUYA, in this order:"
	say "  ./libreouya oobe     (get past the network check)"
	say "  then pair the controller, then root and the rest."
}
