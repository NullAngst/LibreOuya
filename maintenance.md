# Maintenance

A check-up to run every couple of months. Most of what LibreOuya depends on is frozen (the OUYA, its firmware, the su binaries), so the work is mostly confirming the outside world hasn't moved.

## 1. Run the checks

```
bash tests/run.sh
python3 tests/tui_test.py whiptail   # needs pexpect (python3-pexpect)
python3 tests/tui_test.py dialog
python3 tests/tui_test.py list
shellcheck -x LibreOuya.sh LibreOuyaTUI.sh tests/run.sh tests/fakebin/adb tests/fakebin/fastboot
shellcheck -s sh device/lib.sh device/dns.sh
checkbashisms device/lib.sh device/dns.sh
```

All of it should be clean. The same runs in GitHub Actions on every push to main.

## 2. Community server address

The server has moved three times (83.169.45.222, 178.254.13.17 in April 2023, 159.195.22.112 in January 2026).

```
getent ahostsv4 ouya.cweiske.de | head -n 1
```

If it no longer prints `159.195.22.112`, update `LO_SERVER_IP_DEFAULT` in `lib/net.sh` and the IP in `README.md`. LibreOuya already warns users at run time when the two differ, so this only matters for people who can't resolve the name.

Also open https://cweiske.de/tagebuch/ouya-oobe-network.htm; its "IP history" at the bottom is where moves get announced.

## 3. Download sources still alive

```
for u in \
  https://ouya.cweiske.de/api/v1/status \
  https://statics.ouya.world/su_community \
  https://statics.ouya.world/su_stock \
  https://archive.org/download/ouya_firmwarepackages/RC-OUYA-1.2.1427-r1_ota.zip \
  https://raw.githubusercontent.com/EldonMcGuinness/OUYA-ReRoot/master/reroot/bin/su/su \
  https://f-droid.org/repo/index-v2.json \
  https://f-droid.org/archive/index-v2.json \
  https://buildbot.libretro.com/stable/ \
  https://dl.google.com/android/repository/platform-tools-latest-linux.zip \
  https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts; do
  printf '%s %s\n' "$(curl -s -o /dev/null -I -L -w '%{http_code}' "$u")" "$u"
done
```

Anything that isn't 200: find the new location and update `manifest.tsv`, `lib/fetch.sh` or `lib/dns.sh`. If statics.ouya.world goes away for good, the community and stock su become unavailable; the bundled Koush su and on-device backups still cover root and unroot.

## 4. Firmware hashes (first time, then only if archive.org changes)

The firmware hashes in `manifest.tsv` were copied from archive.org's metadata and haven't been checked against a real download yet. Confirm once:

```
curl -s https://archive.org/metadata/ouya_firmwarepackages/files | jq -r '.result[] | select(.name=="RC-OUYA-1.2.1427-r1_ota.zip") | [.size, .md5, .sha1] | @tsv'
```

Compare with the `firmware_1427` line in `manifest.tsv`. After your first real download, also add the sha256 (`sha256sum ~/.cache/libreouya/files/RC-OUYA-1.2.1427-r1_ota.zip`) in the sha256 column.

## 5. F-Droid index format

Bundles and the F-Droid RetroArch build read `index-v2.json`. If F-Droid changes the format, `fdroid_pick` in `lib/fetch.sh` returns nothing and bundles report "no installable build". Check:

```
curl -s https://f-droid.org/repo/index-v2.json | jq '.packages["org.videolan.vlc"].versions | to_entries[0].value | {file, manifest: {versionCode: .manifest.versionCode, usesSdk: .manifest.usesSdk, nativecode: .manifest.nativecode}}'
```

The fields used are `file.name`, `file.sha256`, `file.size`, `manifest.versionCode`, `manifest.versionName`, `manifest.usesSdk.minSdkVersion` and `manifest.nativecode`. Update the jq filter and `tests/fixtures/index-v2.json` together if they move.

## 6. RetroArch

- `curl -s https://buildbot.libretro.com/stable/ | grep -o 'href="[^"]*"' | tail` should still list version folders. If the page layout changes, fix the sed in `latest_retroarch_stable` (`lib/apps.sh`).
- Check whether RetroArch still lists Android 4.1 as its minimum (F-Droid page for `com.retroarch`). When it drops API 16, the F-Droid picker falls back to the archive automatically; the buildbot path will need a version cap.

## 7. adb and platform-tools

New platform-tools releases occasionally change how `adb install` or `adb sideload` talk to old devices. LibreOuya installs with `push` + `pm install` to stay clear of that, but after a platform-tools update, run `./LibreOuya.sh -n status` against a real OUYA and one real `install` to confirm.

## 8. whiptail and dialog

Both change slowly, but after a distro upgrade run `tests/tui_test.py` for each. The two behaviours the TUI depends on: whiptail's `--scrolltext` boxes only take Enter when focus starts on a button (hence `--defaultno` on the result and pause boxes), and item text starting with `--` is read as an option (hence the `== Section ==` headers).

## 9. Hardware checklist (whenever there's a real OUYA to test on)

Run these in order on a box you don't mind reflashing, and note the results in `changes.md` when anything changes:

1. `status`: model, device name, firmware, su md5 all read correctly. Record `ro.product.device` and the firmware props in `tests/fakebin/adb` if they differ from the fake.
2. `flash-stock` from an older firmware, then `oobe` on the fresh box.
3. `root`, confirm `status` shows Koush su, then `unroot` and confirm the stock md5 is back.
4. `store on` / `store off`, and `hosts restore`.
5. `retroarch` and each bundle.
6. `netadb on`, reboot, `connect <ip>`.
7. `initd on`, reboot, check `/system/etc/init.d` scripts ran. If `/init.rc` has no `install-recovery.sh` service, document that here.
8. `dns setup`, `dns test`, reboot, `dns status`.
9. `backup` produces `LNX.img` and `SOS.img`.
10. `recovery boot` (writes nothing), then `recovery flash` and `recovery restore`.
11. `lsusb` in Android and in fastboot mode: confirm the vendor IDs in the README's udev rule (`2836` and `0955`).

## 10. Release

Bump `LO_VERSION` in `LibreOuya.sh` (minor version, 1.0.0 to 1.1.0), add a `changes.md` entry in the usual format, then follow "Making a release" in the README.
