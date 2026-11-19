# LibreOuya

LibreOuya is a set of bash scripts that turn an OUYA into an open Android box from your Linux PC over adb: rooted, sideloading APKs, running RetroArch and light games, with the old store, custom recovery and custom ROMs as opt-in extras.

Every step asks before it does anything. Steps that can brick the box sit behind a typed `RISKY` or `DANGEROUS`. Nothing runs on its own.

## What it does

| Tier | What | Default |
| --- | --- | --- |
| Core | Status, firmware check and update to 1.2.1427, getting a fresh box past the setup wizard, root and unroot, APK installs, F-Droid app bundles, RetroArch, network adb, init.d, USB swap, backups, logs | Each step asks |
| Optional | Community store (ouya.cweiske.de, louyapi on the box, or your own stouyapi), LAN DNS blocker on the OUYA's built-in dnsmasq | Off |
| RISKY | Boot, flash and restore a custom recovery (CWM 6.0.3.2 bundled), sideload ROM zips through CWM | Typed `RISKY` |
| DANGEROUS | `fastboot boot` a postmarketOS image (nothing written), notes on replacing the bootloader | Typed `DANGEROUS` |

What it does not do: unlock purchased games, download ROMs or games for you, or run GameCube. The Tegra 3 is too slow and its GPU too old for GameCube emulation.

## Prerequisites

- An OUYA, powered on, plugged into a TV.
- A micro USB cable that carries data. Plenty of cables only charge, and adb will just see nothing.
- A USB keyboard for the OUYA, only for firmware installs and recovery menus.
- Ethernet on the OUYA if you can. Its Wi-Fi works, but people have far fewer problems wired.
- A PC with bash 4.4 or newer, `adb`, `fastboot`, `curl`, `jq` and `unzip`.

I'm on Kubuntu, so in my case that's:

```
sudo apt install adb fastboot curl jq unzip
```

It depends on your system: `android-tools` on Arch and Fedora, `android-tools` from Homebrew on macOS (plus `brew install bash`, since macOS ships bash 3.2), or whichever your package manager calls it. No adb package at all? `bash libreouya get-platform-tools` downloads Google's into the cache.

## Install

1. Get the files: `git clone` the repo, or download and unpack the release tarball.
2. `cd LibreOuya`
3. `bash libreouya doctor` to check the PC side. (`chmod +x libreouya` once if you'd rather type `./libreouya`; uploads through GitHub's web UI drop the exec bit.)

### Linux USB permissions

If `adb devices` says `no permissions`, add a udev rule so your user can talk to the OUYA:

```
sudo tee /etc/udev/rules.d/51-ouya.rules >/dev/null <<'EOF'
SUBSYSTEM=="usb", ATTR{idVendor}=="2836", MODE="0660", TAG+="uaccess"
SUBSYSTEM=="usb", ATTR{idVendor}=="0955", MODE="0660", TAG+="uaccess"
EOF
sudo udevadm control --reload-rules
```

`2836` is the OUYA's vendor ID in Android, `0955` is NVIDIA's, which the Tegra uses in fastboot. Check yours with `lsusb` with the OUYA plugged in, since I couldn't confirm both on real hardware.

## First run on a fresh OUYA

1. Plug in the cable and power the OUYA on. adb is enabled on an OUYA out of the box. If not, it's under Manage > System > Development.
2. `bash libreouya status` to see what you've got: firmware, su, store config, hosts entries.
3. `bash libreouya setup` walks through the rest one question at a time, or do the steps by hand:
4. `bash libreouya firmware` checks for 1.2.1427 and offers the update if it's older, since anything below 1.0.138 ignores the store config file entirely.
5. `bash libreouya oobe` gets a freshly reset box past the setup wizard's network screen. Do this BEFORE pairing a controller on a fresh flash; people who pair first report setup going sideways.
6. `bash libreouya root` swaps in a Superuser-compatible su so apps can ask for root, and installs the Superuser app.
7. `bash libreouya retroarch`, then `bash libreouya bundle essentials`, `bundle media`, `bundle games` for a file manager, launcher, browser, VLC and some light games.
8. `bash libreouya backup` saves device info and the boot and recovery partitions to your PC. Worth doing before anything RISKY.

Add `-n` to any command for a dry run: it prints every command and every device job, and changes nothing. The only thing it still writes is a small su probe file in `/data/local/tmp/libreouya`.

Logs of every run, including every command and every answer you gave, land in `~/.local/state/libreouya/runs/`.

## Commands

`bash libreouya -h` has the full list. With no command you get a menu.

| Command | Does |
| --- | --- |
| `status` | What's on the OUYA right now |
| `setup` | Guided path, one question per step |
| `firmware`, `flash-stock` | Check the version, install 1.2.1427 through recovery sideload |
| `oobe` | Past the setup wizard's `devs.ouya.tv` check |
| `root`, `unroot` | Superuser su and app, or the original su back |
| `install APK\|DIR` | Install APKs, with plain errors like "needs a newer Android than 4.1" |
| `bundle [NAME]` | F-Droid sets; no name lists them |
| `retroarch`, `push-roms DIR SYSTEM`, `push-bios DIR` | RetroArch and your own content |
| `netadb on\|off`, `initd on\|off`, `swap on\|off` | Tweaks |
| `hosts show\|restore` | View or roll back `/system/etc/hosts` |
| `backup`, `logs`, `logcat`, `shell`, `reboot` | Housekeeping |
| `store on\|off` | Optional community store |
| `dns ...` | Optional DNS blocker |
| `recovery boot\|flash\|restore`, `rom ZIP...` | RISKY |
| `pmos-boot IMG`, `uboot` | DANGEROUS |

Options: `-s SERIAL` picks a device when more than one is attached, `-n` is a dry run, `-a` allows a device that doesn't identify as an OUYA.

## How it works on the box

Android 4.1's adb doesn't pass exit codes back and sends Windows line endings, so every remote command gets a marker that LibreOuya reads instead. Anything that changes `/system` is pushed as a small script that sources `device/lib.sh` and runs as root. That library:

- checks the md5 of the staged file before it touches anything,
- saves the original to `/sdcard/libreouya/backup/<name>.orig` (once) and the version before each change to `<name>.prev`,
- writes to a temp name, sets owner and mode, renames it into place, remounts read-only,
- checks the md5 again afterwards.

Undo commands use those backups. If a file didn't exist before LibreOuya, undoing removes it.

## Root

The OUYA ships with an su that works from adb but that apps can't use. `root` replaces `/system/xbin/su` with Koush's Superuser su (bundled, from OUYA-ReRoot) or ConnectYA's community su, optionally links `/system/bin/su`, and installs the Superuser 1.0.3.0 app. `unroot` puts back the exact su that was there before, or the stock one if no backup exists.

If su doesn't work from adb at all, nothing can replace it; reflash with `flash-stock`.

## Getting past the setup wizard

The OUYA's setup app opens a connection to `devs.ouya.tv` port 80 and won't finish without it. That name has been dead since 2019. `oobe` either adds one hosts line pointing it at the community server (permanent, uses su, which works on a stock box), or jumps to the home screen (nothing written, comes back after a reboot). Neither turns on the store.

## Optional: the community store

`store on` writes `/sdcard/ouya_config.properties` and, if you agree, maps `devs.ouya.tv`, `status.ouya.tv` and `ouya-updates.s3.amazonaws.com` in the hosts file. Choices:

- `ouya.cweiske.de`, the public community server.
- louyapi, a server app that runs on the OUYA itself. Grab the APK from [cweiske/louyapi releases](https://github.com/cweiske/louyapi/releases) and give LibreOuya its path.
- Your own stouyapi URL.

Then on the OUYA: "Existing account", any username, empty password, skip the card. `store off` removes the config (a copy is kept) and cuts the hosts file back to the wizard entry or restores a saved one.

The server's IP has changed three times, most recently to `159.195.22.112` in January 2026. LibreOuya looks it up when it runs and tells you if it moved. Guides that still say `178.254.13.17` are out of date, and that's behind a lot of "stuck on Unable to connect" posts.

## RetroArch and what runs

`retroarch` installs the F-Droid build (hash checked against F-Droid's index) or libretro's latest stable 32-bit build (no published hash, so it shows you one and asks). Cores come from RetroArch's own Online Updater.

My expectations for a Tegra 3 with OpenGL ES 2.0, not yet measured on hardware:

| System | Expect |
| --- | --- |
| NES, SNES, Game Boy family, Genesis, Master System, PC Engine, arcade | Full speed |
| PlayStation (PCSX ReARMed) | Full speed for most games |
| N64 | Light games only. The GLES3 and Vulkan cores won't run |
| PSP, Dreamcast, DS | Slow, some 2D titles are fine |
| GameCube, Wii | Not possible |

`push-roms ~/roms/psx psx` copies a folder to `/sdcard/RetroArch/roms/psx`. `push-bios` copies to `/sdcard/RetroArch/system`. Point RetroArch's start and System directories there. Only push games and BIOS files you own.

## Streaming

Plex is out: its Android app has needed Android 5.0 or newer for years, and the OUYA has 4.1. The `media` bundle installs the newest VLC that still supports 4.1, which browses DLNA/UPnP shares on your network.

## App bundles

Bundles live in `bundles/*.list`. Each line is `fdroid <package>[|<fallback>...] <label>`. LibreOuya downloads F-Droid's index (repo first, then the archive of old versions), picks the newest build with minSdk 16 or lower and 32-bit ARM or no native code, and checks it against the index's sha256. No versions are pinned, so nothing needs bumping. Add your own `.list` file the same way.

## Optional: DNS blocker

The OUYA can answer DNS for your LAN with a blocklist, using the dnsmasq that Android already includes for Wi-Fi tethering. It's a fun use for an old box.

1. `bash libreouya initd on` if you want it to start at boot (optional, but without it you start it by hand after each reboot).
2. `bash libreouya dns setup` installs it to `/data/local/libreouya/dns`, asks for upstream servers and cache size, builds the blocklist and starts it.
3. Give the OUYA a fixed address with a DHCP reservation on your router, wired if possible.
4. `bash libreouya dns test` queries it from your PC.
5. Point a client, or your router's DNS, at the OUYA's address.

### Adding blocklists

Lists are plain URLs, one per line, in `~/.config/libreouya/blocklists.txt` (created on first run with StevenBlack's unified hosts list):

```
https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts
https://example.org/another-list.txt
```

Hosts-format lists (`0.0.0.0 domain` or `127.0.0.1 domain`), plain domain-per-line lists and adblock-style `||domain^` lines all work. Domains you never want blocked go in `~/.config/libreouya/allowlist.txt`, one per line. After editing either file, run `bash libreouya dns update`; it downloads every list, merges and dedupes them on your PC, pushes the result and tells dnsmasq to reload.

Other controls: `dns start`, `dns stop`, `dns restart`, `dns status`, `dns remove`. Settings are in `/data/local/libreouya/dns/dns.conf` on the OUYA (`UPSTREAMS`, `CACHE`, `EXTRA`). If dnsmasq won't stay up, try `EXTRA=""` there.

Be honest with yourself about the risks: if the OUYA hangs, everything using it loses DNS until it's back, so keep a second DNS server on the router. Its firmware gets no security updates, so it stays LAN-only. Never forward port 53 to it.

Why dnsmasq and not Pi-hole or AdGuard Home: the OUYA's kernel is Linux 3.1.10. Current Go builds (AdGuard Home, Blocky) need 3.2 or newer, and Pi-hole needs a regular Linux distro, which won't run on that kernel either.

## RISKY: custom recovery and ROMs

`recovery boot` starts the bundled CWM 6.0.3.2 straight from fastboot and writes nothing. Try that first.

`recovery flash` writes a recovery image, but only after a backup of your stock recovery partition (`SOS`) is on your PC. `recovery restore` writes that backup back. On stock firmware, `install-recovery.sh` can rewrite the stock recovery at every boot; `initd on` offers to stop that.

`rom bootmenu.zip rom.zip keylayouts.zip` boots CWM, has you make a CWM backup, then sideloads each zip in the order you gave, asking before each one. LibreOuya doesn't download ROMs. Known OUYA ROMs, from the community:

| ROM | Android | Notes |
| --- | --- | --- |
| CyanogenMod 11 (milaq) | 4.4.4 | Install the OUYA bootmenu first; it's the way back if a boot image breaks |
| AOSP 5.0 (XDA) | 5.0 | Same recovery route |
| Android 7.1 (i12bretro image) | 7.1 | Needs a modified TWRP that swaps the cache and system partitions, and a TWRP restore from a USB stick. Manual only, highest brick risk |

A ROM gives you a newer WebView and apps that need API 19 or 21. It costs you the OUYA launcher and store integration. To go back: restore the CWM backup, or `recovery restore` then `flash-stock`.

## DANGEROUS: Linux and the bootloader

`pmos-boot boot.img` boots a postmarketOS image built with `pmbootstrap` for `ouya-ouya` using `fastboot boot`. Nothing is written; power-cycling returns to Android. Older reports say HDMI and a USB keyboard work on it, and Wi-Fi and the GPU don't.

Replacing the bootloader with mainline U-Boot erases the whole eMMC, stops stock Android from booting, and needs your device's secure boot key, a testpad on the board, and the fusee-tools and re-crypt projects. LibreOuya documents it (`bash libreouya uboot`) and stops there. Read the [U-Boot OUYA page](https://docs.u-boot-project.org/en/latest/board/ouya/ouya.html) if you want to go that far.

## Rolling back

| Change | Undo | Backups |
| --- | --- | --- |
| Firmware update | Downgrades need CWM, not automated | n/a |
| Setup wizard hosts entry, store hosts entries | `hosts restore` (original or previous) | `/sdcard/libreouya/backup/etc_hosts.*` |
| Store config | `store off` | `/sdcard/libreouya/backup/ouya_config.properties.prev` |
| Root | `unroot` | `/sdcard/libreouya/backup/xbin_su.orig` |
| Network adb | `netadb off` | `/sdcard/libreouya/backup/build_prop.*` |
| init.d hook | `initd off` | `/sdcard/libreouya/backup/install_recovery.*` |
| Swap, DNS | `swap off`, `dns remove` | n/a |
| Custom recovery | `recovery restore` | `~/.local/state/libreouya/backups/<serial>/*/parts/SOS.img` |
| Custom ROM | CWM backup restore, or `recovery restore` + `flash-stock` | CWM backup on the OUYA |

`backup` copies `/sdcard/libreouya` to the PC too. A factory reset wipes `/sdcard`, so pull it before you reset.

## Troubleshooting

- **No device:** charge-only cable, OUYA not booted, or the udev rule. `adb devices` should list it.
- **unauthorized:** accept the adb prompt on the TV.
- **A Superuser prompt on the TV:** allow it; on a rooted box, the shell has to ask like any app.
- **Stuck on "Unable to connect" during setup:** run `oobe`, then press Continue on the OUYA. If an old guide put `178.254.13.17` in your hosts file, `oobe` replaces it.
- **Store installs nothing:** reboot once after `store on` during first-run setup.
- **Anything else:** `bash libreouya logs` saves a snapshot to your PC. Nothing is uploaded anywhere.

## Credits

Christian Weiske's stouyapi and louyapi keep the OUYA store alive. The OUYA Saviors community runs statics.ouya.world. OUYA-ReRoot (EldonMcGuinness) is the source of the bundled su, Superuser app and CWM image; see `mirror/NOTICE.md`. Koush wrote Superuser, milaq the CyanogenMod port and bootmenu, i12bretro the later ROM images, and the postmarketOS and U-Boot projects did the mainline work. ConnectYA showed which steps people need.

## Making a release

Nothing gets built, so a release is just a tag:

1. Add an entry to `changes.md` and bump `LO_VERSION` in `libreouya` (minor bump, like 1.0.0 to 1.1.0).
2. Push to main and check the `checks` workflow passed.
3. On GitHub, go to Releases, draft a new release, create a new tag (like `v1.1.0`) on main, and publish it. GitHub attaches the source tarballs itself.

## License

GPL-3.0-or-later, see `LICENSE`. Mirrored third-party files keep their own licenses, listed in `mirror/NOTICE.md`.

Now the OUYA is rooted, running RetroArch and whatever else you picked, and everything LibreOuya changed can be put back. Tinker with the bundles and blocklists as you see fit.
