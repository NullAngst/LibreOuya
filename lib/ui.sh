#!/usr/bin/env bash
# LibreOuya TUI layer. When LO_UI=tui, every prompt (ask, choose, value,
# typed gates, pauses) becomes a whiptail or dialog box. Output printed
# since the last prompt is shown inside the box, so a question like "Write
# this hosts file?" still shows the file. Each finished action's full output
# opens in a scrollable box.
#
# whiptail ships with newt (Debian, Ubuntu); dialog is the usual alternative.
# Both are used as-is, nothing here draws its own screens.

LO_UI=tty
LO_TUI_BIN=''
LO_TUI_BUF=''
LO_ACTION_LOG=''

tui_init() {
	# LIBREOUYA_TUI=dialog (or whiptail) picks one when both are installed.
	case ${LIBREOUYA_TUI:-} in
	whiptail | dialog)
		command -v "$LIBREOUYA_TUI" >/dev/null 2>&1 || {
			printf 'LIBREOUYA_TUI=%s but it is not installed.\n' "$LIBREOUYA_TUI" >&2
			exit 1
		}
		LO_TUI_BIN=$LIBREOUYA_TUI
		;;
	esac
	if [ -n "$LO_TUI_BIN" ]; then
		:
	elif command -v whiptail >/dev/null 2>&1; then
		LO_TUI_BIN=whiptail
	elif command -v dialog >/dev/null 2>&1; then
		LO_TUI_BIN=dialog
	else
		printf 'The TUI needs whiptail or dialog. Install one (whiptail is in the newt or\n' >&2
		printf 'whiptail package, dialog in dialog), or use ./LibreOuya.sh for the plain list.\n' >&2
		exit 1
	fi
	lo_tty_ok || {
		printf 'The TUI needs a terminal.\n' >&2
		exit 1
	}
	LO_UI=tui
}

# Record a plain-text line for the next prompt and the action log.
ui_note() {
	[ "$LO_UI" = tui ] || return 0
	LO_TUI_BUF=$LO_TUI_BUF$1$'\n'
	if [ -n "$LO_ACTION_LOG" ]; then
		printf '%s\n' "$1" >>"$LO_ACTION_LOG"
	fi
}

tui_size() {
	# Sets TUI_H and TUI_W from the terminal, with sane bounds.
	local sz rows=24 cols=80
	sz=$(stty size </dev/tty 2>/dev/null) || sz=''
	if [ -n "$sz" ]; then
		rows=${sz% *}
		cols=${sz#* }
	fi
	TUI_H=$((rows - 2))
	TUI_W=$((cols - 4))
	[ "$TUI_W" -gt 110 ] && TUI_W=110
	[ "$TUI_H" -lt 10 ] && TUI_H=10
	[ "$TUI_W" -lt 40 ] && TUI_W=40
	return 0
}

# Text for a box: the recent output (last 60 lines), a blank line, the question.
tui_text() {
	local recent
	recent=$(printf '%s' "$LO_TUI_BUF" | tail -n 60)
	LO_TUI_BUF=''
	if [ -n "$recent" ]; then
		printf '%s\n\n%s' "$recent" "$1"
	else
		printf '%s' "$1"
	fi
}

# Run the box program on the terminal; its answer comes back on stdout.
tui_run() {
	"$LO_TUI_BIN" --backtitle "LibreOuya $LO_VERSION$([ "$LO_DRY" = 1 ] && printf '  (DRY RUN)')" "$@" 3>&1 1>/dev/tty 2>&3 </dev/tty
}

tui_scroll_flag() {
	if [ "$LO_TUI_BIN" = whiptail ]; then printf '%s' --scrolltext; else printf '%s' --scrollbar; fi
}

tui_notags_flag() {
	if [ "$LO_TUI_BIN" = whiptail ]; then printf '%s' --notags; else printf '%s' --no-tags; fi
}

tui_yes_no_labels() {
	# tui_yes_no_labels YES NO -> label options for the box program in use
	if [ "$LO_TUI_BIN" = whiptail ]; then
		printf '%s\n' --yes-button "$1" --no-button "$2"
	else
		printf '%s\n' --yes-label "$1" --no-label "$2"
	fi
}

tui_ask() {
	local text
	text=$(tui_text "$1")
	tui_size
	tui_run --title "Confirm" "$(tui_scroll_flag)" --defaultno --yesno "$text" "$TUI_H" "$TUI_W"
}

# whiptail with --scrolltext only takes Enter when focus starts on a button,
# which --defaultno does. So the safe choice is the "no" button here, and the
# yes button is the one you move to.
tui_pause() {
	local text labels=() rc=0
	text=$(tui_text "${1:-Ready?}")
	tui_size
	mapfile -t labels < <(tui_yes_no_labels Stop Continue)
	tui_run --title "Waiting on you" "$(tui_scroll_flag)" --defaultno "${labels[@]}" --yesno "$text" "$TUI_H" "$TUI_W" || rc=$?
	[ "$rc" = 1 ]
}

tui_choose() {
	local prompt=$1 text i=1 opt items=() pick
	shift
	for opt in "$@"; do
		items+=("$i" "$opt")
		i=$((i + 1))
	done
	text=$(tui_text "$prompt")
	tui_size
	pick=$(tui_run --title "Choose" --menu "$text" "$TUI_H" "$TUI_W" "$#" "${items[@]}") || return 1
	printf '%s\n' "${!pick}"
}

tui_input() {
	local text
	text=$(tui_text "$1")
	tui_size
	tui_run --title "Enter a value" --inputbox "$text" "$TUI_H" "$TUI_W" "${2:-}"
}

tui_word() {
	# tui_word WORD text -> 0 only when exactly WORD was typed
	local text reply
	text=$(tui_text "$2")
	tui_size
	reply=$(tui_run --title "Type $1 to continue" --inputbox "$text" "$TUI_H" "$TUI_W" "") || return 1
	[ "$reply" = "$1" ]
}

tui_show_file() {
	# tui_show_file title file : scrollable result box. Enter goes back to the
	# menu; returns 1 only if the user moves to Quit and picks it.
	local text labels=() rc=0
	[ -s "$2" ] || return 0
	text=$(tail -n 300 "$2")
	tui_size
	mapfile -t labels < <(tui_yes_no_labels "Quit" "Back to menu")
	tui_run --title "$1" "$(tui_scroll_flag)" --defaultno "${labels[@]}" --yesno "$text" "$TUI_H" "$TUI_W" || rc=$?
	[ "$rc" != 0 ]
}
