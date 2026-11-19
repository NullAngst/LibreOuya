# Changes

2026.11.18 - UX overhaul

* `libreouya` is now `LibreOuya.sh`, which shows a numbered list of every option, grouped by section, when run with no arguments
* New `LibreOuyaTUI.sh`: the same options in a whiptail or dialog menu; `LIBREOUYA_TUI=dialog` picks dialog when both are installed
* One shared menu table (`lib/menu.sh`) feeds both front ends, so they always offer the same steps; entries now include every subcommand, the reboot targets, all DNS controls, device selection and a dry run switch
* In the TUI every question, chooser, value prompt and typed RISKY/DANGEROUS word is a dialog box that also shows what the step printed since the last question, and each finished step opens its full output in a scrollable box
* Questions still default to No in both front ends; the TUI starts on the No button and the result box starts on "Back to menu"
* Steps run in a subshell so a failed step returns to the menu instead of exiting
* Tests: every menu entry must map to a real command, both front ends fail closed without a terminal, and a pexpect walk-through drives the TUI under whiptail and dialog in CI

Reasons for changes: running everything from one interactive list or TUI is easier than remembering subcommands, and keeping both front ends on one table stops them drifting apart.

2026.11.18 - Initial release

* Entry script with a menu, a guided `setup` path and subcommands
* Every step asks first; RISKY and DANGEROUS steps need a typed word; `-n` dry run prints every command and device job without running them
* OUYA detection by model, refusal on other devices unless `-a`, `-s` required when more than one device is attached
* adb plumbing for Android 4.1: sentinel exit codes, CRLF stripping, su method detection (stdin, `-c`, AOSP form), device jobs pushed as files
* Device-side library for mksh/toolbox: atomic `/system` writes, md5 verification before and after, `.orig` and `.prev` backups on `/sdcard/libreouya`, restore that also removes files that did not exist before
* Firmware check and update to 1.2.1427 through recovery sideload, with sideload-state polling and hash checks on the 131 MB download
* Setup wizard fix: hosts entry for the `devs.ouya.tv` connectivity check, or the home screen skip
* Root and unroot with bundled Koush su and Superuser 1.0.3.0, or ConnectYA's community su
* APK installs with readable errors, F-Droid bundles (essentials, media, games) picked for API 16 and 32-bit ARM from F-Droid's index with its sha256, RetroArch from F-Droid or libretro's latest stable 32-bit build
* ROM and BIOS pushes to `/sdcard/RetroArch`
* Tweaks: permanent network adb, init.d through the `install-recovery.sh` hook, USB swap when BusyBox is present
* Optional community store toggle: ouya.cweiske.de, louyapi or a custom stouyapi URL, with the server address looked up at run time
* Optional DNS blocker on the OUYA's built-in dnsmasq, blocklists built on the PC from a list of URLs with an allowlist
* Backups of device info and the boot and recovery partitions to the PC, log snapshots, live logcat with temporary `DEBUG=1`
* RISKY: boot, flash and restore a custom recovery (CWM 6.0.3.2 bundled), sideload ROM zips through CWM
* DANGEROUS: `fastboot boot` a postmarketOS image; U-Boot notes only
* Tests with a fake adb and fastboot, device library tests under mksh, GitHub Actions lint and test workflow

Reasons for changes: ConnectYA, the only maintained-looking OUYA tool, is Windows-first, ignores adb results, keeps going after hash mismatches and has a hosts writer its own comments call broken. The community server also moved to a new IP in January 2026, which stale guides still point at.
