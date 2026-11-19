# Mirrored files

Copies kept here so LibreOuya keeps working if the original hosts go away. Every file is checked against `manifest.tsv` before use. All three were taken from the [OUYA-ReRoot](https://github.com/EldonMcGuinness/OUYA-ReRoot) repository (GPL-2.0), which bundled them in 2015.

| File | What it is | Original project and license | sha256 |
| --- | --- | --- | --- |
| `su/su-koush-reroot` | `su` binary for ARM, Koush Superuser protocol (md5 `15813da48f2e7f33b6faa3220eebd7fe`) | [koush/Superuser](https://github.com/koush/Superuser), Apache-2.0 | `c6b3879e7e72f06a6bda80bfcb171ccbfb9595133b4bb539d371f7a82c5a84b8` |
| `apk/com.koushikdutta.superuser-1.0.3.0.apk` | Superuser manager app 1.0.3.0, the same version ConnectYA installs | [koush/Superuser](https://github.com/koush/Superuser), Apache-2.0 | `8bbe1c0aa307a0c689d0b97ea5123f6d74d42bb9f91cbeaac2583b23de3a77ab` |
| `recovery/OuyaCWMrecovery6.0.3.2.img` | ClockworkMod Recovery 6.0.3.2 boot image for the OUYA | ClockworkMod recovery (Apache-2.0, AOSP based) with the OUYA Linux kernel (GPL-2.0; source: the OUYA kernel trees on GitHub, for example milaq/android_kernel_boxer8_ouya) | `8bc31f6a2fbda0a6c3ab1ece095c05553ee011811679862b13eb95ea8a3958d7` |

Not mirrored, downloaded on demand and checked against the hashes in `manifest.tsv`: ConnectYA's community `su` and the stock OUYA `su` (statics.ouya.world, md5 only), and firmware 1.2.1427 (archive.org).

If a rights holder objects to a file here, it will be removed and LibreOuya will fall back to the upstream URLs in `manifest.tsv`.
