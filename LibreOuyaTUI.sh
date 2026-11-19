#!/usr/bin/env bash
# LibreOuya TUI: the same options as LibreOuya.sh, in whiptail or dialog menus.
# Needs whiptail (newt) or dialog installed. Options and commands are the same
# as LibreOuya.sh, for example: ./LibreOuyaTUI.sh -n   (dry run)
set -euo pipefail
dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) || exit 1
# Called through bash so a lost exec bit on LibreOuya.sh does not matter.
exec bash "$dir/LibreOuya.sh" -t "$@"
