#!/usr/bin/env bash
# LibreOuya RISKY and DANGEROUS steps: custom recovery, custom ROM zips,
# postmarketOS boot. Each one sits behind a typed gate and asks again before
# anything is written.

to_bootloader() {
	need_fastboot
	if [ "${LO_STATE_NOW:-}" = device ]; then
		ask "Reboot the OUYA into its bootloader (fastboot) now?" || return 1
		act adb_dev reboot bootloader
	else
		say "Put the OUYA in fastboot mode, then continue."
		pause "OUYA in fastboot" || return 1
	fi
	[ "$LO_DRY" = 1 ] && { LO_FB_SERIAL=DRYRUN; return 0; }
	wait_fastboot
}

# Make sure a copy of the stock recovery partition exists on this PC before
# anything replaces it.
need_recovery_backup() {
	local b
	b=$(latest_part_backup SOS)
	if [ -n "$b" ]; then
		ok "Recovery backup on this PC: $b"
		LO_SOS_BACKUP=$b
		return 0
	fi
	warn "No backup of this OUYA's recovery partition (SOS) on this PC yet."
	ask "Take one now? (needs a booted OUYA with working su)" || return 1
	cmd_backup || return 1
	if [ "$LO_DRY" = 1 ]; then
		say "(dry run: the real run stops here unless the SOS image was saved)"
		LO_SOS_BACKUP=dry-run
		return 0
	fi
	b=$(latest_part_backup SOS)
	[ -n "$b" ] || { err "recovery backup still missing"; return 1; }
	LO_SOS_BACKUP=$b
}

pick_recovery_img() {
	local img=${1:-}
	if [ -n "$img" ]; then
		[ -f "$img" ] || die "no file: $img"
		say "Using $img (sha256 $(sha256_of "$img"))"
		ask "Is this the recovery image you meant?" || return 1
		LO_FETCHED=$img
		return 0
	fi
	say "No image given, using the bundled ClockworkMod 6.0.3.2 for OUYA."
	fetch_entry cwm_6032
}

cmd_recovery() {
	local action=${1:-} img=${2:-}
	case $action in
	boot)
		heading "Boot a recovery image (nothing is written)"
		pick_device_soft
		gate RISKY \
			"a bad image just fails to boot; nothing is flashed" \
			"hold the power button to turn the OUYA off, then power it on normally" || return 0
		pick_recovery_img "$img" || return 0
		to_bootloader || return 1
		ask "Boot $LO_FETCHED now?" || return 0
		fb boot "$LO_FETCHED"
		;;
	flash)
		heading "Flash a custom recovery"
		need_ouya
		gate RISKY \
			"a broken recovery leaves you without the stock firmware install path until it is restored" \
			"./LibreOuya.sh recovery restore (flashes the backup of your stock recovery taken first)" || return 0
		need_recovery_backup || return 1
		pick_recovery_img "$img" || return 0
		to_bootloader || return 1
		ask "Write $LO_FETCHED to the recovery partition?" || return 0
		fb flash recovery "$LO_FETCHED" || return 1
		if ask "Boot straight into the new recovery to check it?"; then
			fb boot "$LO_FETCHED" || true
		elif ask "Reboot to Android?"; then
			fb reboot || true
		fi
		say "On stock firmware, install-recovery.sh can rewrite the stock recovery on every boot."
		say "If CWM disappears after a reboot, see ./LibreOuya.sh initd on (it offers to stop that)."
		;;
	restore)
		heading "Restore the stock recovery"
		pick_device_soft
		gate RISKY \
			"flashing the wrong file leaves recovery unusable" \
			"flash any known-good recovery image the same way" || return 0
		LO_SOS_BACKUP=$(latest_part_backup SOS)
		[ -n "$LO_SOS_BACKUP" ] || LO_SOS_BACKUP=$(prompt_value "Path to the recovery backup image" '')
		[ -f "$LO_SOS_BACKUP" ] || die "no recovery backup found"
		say "Image: $LO_SOS_BACKUP (sha256 $(sha256_of "$LO_SOS_BACKUP"))"
		to_bootloader || return 1
		ask "Write it back to the recovery partition?" || return 0
		fb flash recovery "$LO_SOS_BACKUP" || return 1
		ask "Reboot to Android?" && fb reboot
		;;
	*) die "usage: LibreOuya.sh recovery boot|flash|restore [image]" ;;
	esac
}

# Install one or more zips (bootmenu, ROM, gapps-free extras, keylayouts)
# through CWM's sideload, in the order given.
cmd_rom() {
	local z how
	[ "$#" -gt 0 ] || die "usage: LibreOuya.sh rom <zip> [zip...]   (in install order, e.g. bootmenu then ROM)"
	for z in "$@"; do
		[ -f "$z" ] || die "no file: $z"
	done
	heading "Install custom ROM zips"
	pick_device_soft
	gate RISKY \
		"a bad or wrong ROM can bootloop the OUYA; switching ROMs needs a data wipe, which deletes everything" \
		"restore the CWM backup you make in step 1, or restore stock recovery and run ./LibreOuya.sh flash-stock" || return 0
	say "Order matters. Common order for CyanogenMod 11: OUYA bootmenu zip, then the ROM, then keylayouts."
	say "LibreOuya does not download ROMs. Use files you got from the ROM's own page and checked."
	for z in "$@"; do
		say "  $(basename -- "$z")  sha256 $(sha256_of "$z")"
	done
	ask "Is that the right list and order?" || return 0
	if [ "${LO_STATE_NOW:-}" = device ]; then
		need_recovery_backup || return 1
	fi
	how=$(choose "How should CWM start?" \
		"Boot the bundled CWM 6.0.3.2 from fastboot (nothing written to recovery)" \
		"CWM is already flashed: reboot into recovery") || return 0
	case $how in
	Boot*)
		fetch_entry cwm_6032 || return 1
		to_bootloader || return 1
		ask "Boot CWM now?" || return 0
		fb boot "$LO_FETCHED" || return 1
		;;
	*)
		if [ "${LO_STATE_NOW:-}" = device ]; then
			ask "Reboot into recovery now?" || return 0
			act adb_dev reboot recovery
		else
			say "Boot the OUYA into recovery (Alt + PrtScn + i on a USB keyboard if needed)."
		fi
		;;
	esac
	say ""
	say "In CWM (keyboard arrows + Enter):"
	say "  1. backup and restore > backup   (makes a full backup on the OUYA, do not skip)"
	say "  2. If you are switching from stock or another ROM: wipe data/factory reset (WIPES EVERYTHING)"
	pause "Backup done" || return 0
	for z in "$@"; do
		say "In CWM: install zip > install zip from sideload"
		pause "CWM is waiting for $(basename -- "$z")" || return 0
		if [ "$LO_DRY" != 1 ]; then
			wait_adb_state sideload 300 || { err "no sideload mode seen"; return 1; }
		fi
		ask "Send $(basename -- "$z")?" || return 0
		act adb_auto sideload "$z" || { err "sideload of $z failed; read the TV before going on"; return 1; }
	done
	say "All zips sent. In CWM: reboot system now. The first boot can take several minutes."
	say "Back to stock: restore the CWM backup, or ./LibreOuya.sh recovery restore then ./LibreOuya.sh flash-stock."
}

cmd_pmos_boot() {
	local img=${1:-}
	heading "Boot postmarketOS (mainline Linux)"
	[ -f "$img" ] || die "usage: LibreOuya.sh pmos-boot <boot.img built by pmbootstrap for ouya-ouya>"
	pick_device_soft
	gate DANGEROUS \
		"this boots a different operating system kernel; it is not Android and some hardware (Wi-Fi, GPU) may not work. Nothing is written to the OUYA by this command, but anything you do inside postmarketOS (flashing, repartitioning) can wipe Android" \
		"power the OUYA off and on; it boots Android again because nothing was flashed" || return 0
	say "Image: $img (sha256 $(sha256_of "$img"))"
	to_bootloader || return 1
	ask "fastboot boot this image now?" || return 0
	fb boot "$img"
	say "Use an HDMI screen and a USB keyboard. Power-cycle to return to Android."
}

cmd_uboot() {
	heading "Mainline U-Boot (DANGEROUS, not automated)"
	say "Replacing the OUYA's bootloader with mainline U-Boot erases the whole eMMC and stops stock"
	say "Android from booting. It needs your device's SBK, the fusee-tools and re-crypt projects,"
	say "and a testpad on the board to enter APX mode. LibreOuya documents it and stops there."
	say "Read: https://docs.u-boot-project.org/en/latest/board/ouya/ouya.html"
}
