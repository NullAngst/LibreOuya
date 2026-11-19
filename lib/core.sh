#!/usr/bin/env bash
# LibreOuya core helpers: output, logging, prompts, gates, hashing, paths.
# Sourced by ./libreouya. Not meant to run on its own.

# ---- paths ------------------------------------------------------------------

lo_init_paths() {
	LO_CACHE=${XDG_CACHE_HOME:-$HOME/.cache}/libreouya
	LO_STATE=${XDG_STATE_HOME:-$HOME/.local/state}/libreouya
	LO_CONFIG=${XDG_CONFIG_HOME:-$HOME/.config}/libreouya
	LO_RUN=$LO_STATE/runs/$(date '+%Y-%m-%d_%H%M%S')
	mkdir -p -- "$LO_CACHE" "$LO_STATE" "$LO_CONFIG" "$LO_RUN" || {
		printf 'libreouya: cannot create %s\n' "$LO_STATE" >&2
		exit 1
	}
	LO_LOG=$LO_RUN/libreouya.log
	: >"$LO_LOG"
}

# ---- output -----------------------------------------------------------------

lo_init_colors() {
	if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
		C_RED=$(printf '\033[31m')
		C_GRN=$(printf '\033[32m')
		C_YEL=$(printf '\033[33m')
		C_BLU=$(printf '\033[36m')
		C_BLD=$(printf '\033[1m')
		C_OFF=$(printf '\033[0m')
	else
		C_RED='' C_GRN='' C_YEL='' C_BLU='' C_BLD='' C_OFF=''
	fi
}

log() {
	printf '%s %s\n' "$(date '+%H:%M:%S')" "$*" >>"$LO_LOG"
}

say() {
	printf '%s\n' "$*"
	log "$*"
}

ok() {
	printf '%s%s%s\n' "$C_GRN" "$*" "$C_OFF"
	log "OK: $*"
}

warn() {
	printf '%sWarning:%s %s\n' "$C_YEL" "$C_OFF" "$*" >&2
	log "WARN: $*"
}

err() {
	printf '%sError:%s %s\n' "$C_RED" "$C_OFF" "$*" >&2
	log "ERROR: $*"
}

die() {
	err "$*"
	exit 1
}

heading() {
	printf '\n%s== %s ==%s\n' "$C_BLD" "$*" "$C_OFF"
	log "== $*"
}

# Show a command before it runs. Every command that touches the device or the
# network goes through this, so the log is a full record of what happened.
show_cmd() {
	local q first=$1
	shift
	case $first in
	adb_dev | adb_dev_tty) set -- adb -s "$LO_SERIAL" "$@" ;;
	adb_raw) set -- adb "$@" ;;
	adb_auto) if [ -n "${LO_SERIAL:-}" ]; then set -- adb -s "$LO_SERIAL" "$@"; else set -- adb "$@"; fi ;;
	*) set -- "$first" "$@" ;;
	esac
	q=$(printf '%q ' "$@")
	printf '%s$ %s%s\n' "$C_BLU" "${q% }" "$C_OFF"
	log "\$ ${q% }"
}

# Run a command that changes something. In dry-run mode it is only shown.
act() {
	show_cmd "$@"
	if [ "$LO_DRY" = 1 ]; then
		printf '  (dry run, not executed)\n'
		return 0
	fi
	"$@"
}

# ---- prompts ----------------------------------------------------------------

# All prompts read from the terminal. With no terminal there is nobody to say
# yes, so every ask fails closed.
lo_tty_ok() {
	[ -r /dev/tty ] && { : </dev/tty; } 2>/dev/null
}

read_tty() {
	local __var=$1 __line=''
	if ! lo_tty_ok; then
		printf -v "$__var" '%s' ''
		return 1
	fi
	IFS= read -r __line </dev/tty || __line=''
	printf -v "$__var" '%s' "$__line"
}

# ask "Question" -> 0 on yes. Default is always no.
ask() {
	local reply
	printf '%s%s%s [y/N] ' "$C_BLD" "$1" "$C_OFF"
	if ! read_tty reply; then
		printf '\n'
		log "ASK (no terminal, treated as no): $1"
		return 1
	fi
	log "ASK: $1 -> $reply"
	case $reply in
	y | Y | yes | YES | Yes) return 0 ;;
	*) return 1 ;;
	esac
}

# Pause until Enter. Returns 1 if the user typed q.
pause() {
	local reply
	printf '%s [Enter to continue, q to stop] ' "${1:-Ready?}"
	read_tty reply || return 1
	log "PAUSE: ${1:-} -> $reply"
	case $reply in
	q | Q) return 1 ;;
	esac
	return 0
}

# choose "Prompt" option1 option2 ... -> prints the chosen option.
choose() {
	local prompt=$1 i=1 reply opt
	shift
	for opt in "$@"; do
		printf '  %d) %s\n' "$i" "$opt" >&2
		i=$((i + 1))
	done
	printf '%s [1-%d, anything else cancels] ' "$prompt" "$#" >&2
	read_tty reply || return 1
	log "CHOOSE: $prompt -> $reply"
	case $reply in
	'' | *[!0-9]*) return 1 ;;
	esac
	[ "$reply" -ge 1 ] && [ "$reply" -le "$#" ] || return 1
	printf '%s\n' "${!reply}"
}

prompt_value() {
	local reply
	printf '%s%s%s [%s] ' "$C_BLD" "$1" "$C_OFF" "${2:-}" >&2
	read_tty reply || return 1
	[ -n "$reply" ] || reply=${2:-}
	log "VALUE: $1 -> $reply"
	printf '%s\n' "$reply"
}

# gate WORD "what can go wrong" "how to get back"
# For RISKY and DANGEROUS steps. Only the exact word, typed, continues.
gate() {
	local word=$1 risk=$2 back=$3 reply color=$C_YEL
	[ "$word" = DANGEROUS ] && color=$C_RED
	printf '\n%s%s%s\n' "$color" "==== $word ====" "$C_OFF"
	printf 'What can go wrong: %s\n' "$risk"
	printf 'How to get back:   %s\n' "$back"
	printf 'Type %s%s%s to continue, anything else cancels: ' "$C_BLD" "$word" "$C_OFF"
	if ! read_tty reply; then
		printf '\n'
		log "GATE $word refused (no terminal)"
		return 1
	fi
	log "GATE $word -> $reply"
	[ "$reply" = "$word" ]
}

# ---- dependencies -----------------------------------------------------------

need_cmds() {
	local missing='' c
	for c in "$@"; do
		command -v "$c" >/dev/null 2>&1 || missing="$missing $c"
	done
	if [ -n "$missing" ]; then
		err "missing commands:$missing"
		printf 'Install them with your package manager.%s\n' "$(pkg_hint)" >&2
		exit 1
	fi
}

pkg_hint() {
	local pm
	for pm in apt dnf zypper pacman apk emerge brew; do
		if command -v "$pm" >/dev/null 2>&1; then
			printf ' (found %s on this system)' "$pm"
			return 0
		fi
	done
}

# ---- hashing ----------------------------------------------------------------

sha256_of() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum -- "$1" | cut -d ' ' -f 1
	elif command -v shasum >/dev/null 2>&1; then
		shasum -a 256 -- "$1" | cut -d ' ' -f 1
	else
		openssl dgst -sha256 -r -- "$1" | cut -d ' ' -f 1
	fi
}

sha1_of() {
	if command -v sha1sum >/dev/null 2>&1; then
		sha1sum -- "$1" | cut -d ' ' -f 1
	elif command -v shasum >/dev/null 2>&1; then
		shasum -a 1 -- "$1" | cut -d ' ' -f 1
	else
		openssl dgst -sha1 -r -- "$1" | cut -d ' ' -f 1
	fi
}

md5_of() {
	if command -v md5sum >/dev/null 2>&1; then
		md5sum -- "$1" | cut -d ' ' -f 1
	elif command -v md5 >/dev/null 2>&1; then
		md5 -q -- "$1"
	else
		openssl dgst -md5 -r -- "$1" | cut -d ' ' -f 1
	fi
}

size_of() {
	wc -c <"$1" | tr -d ' '
}

need_hash_tools() {
	if ! command -v sha256sum >/dev/null 2>&1 &&
		! command -v shasum >/dev/null 2>&1 &&
		! command -v openssl >/dev/null 2>&1; then
		die "need sha256sum, shasum or openssl"
	fi
	if ! command -v md5sum >/dev/null 2>&1 &&
		! command -v md5 >/dev/null 2>&1 &&
		! command -v openssl >/dev/null 2>&1; then
		die "need md5sum, md5 or openssl"
	fi
}

# ---- small utilities --------------------------------------------------------

# Single-quote a value for the device shell.
shq() {
	local s=${1//\'/\'\\\'\'}
	printf "'%s'" "$s"
}

# Accept only plain path-ish values in anything handed to the device shell.
safe_value() {
	case $1 in
	'' | *[!A-Za-z0-9_./:@+=-]*) return 1 ;;
	esac
	return 0
}

# Compare dotted versions. ver_ge 1.2.1427 1.0.138 -> 0
ver_ge() {
	local a b i
	local IFS=.
	read -r -a a <<<"$1"
	read -r -a b <<<"$2"
	for ((i = 0; i < ${#a[@]} || i < ${#b[@]}; i++)); do
		if ((10#${a[i]:-0} > 10#${b[i]:-0})); then
			return 0
		fi
		if ((10#${a[i]:-0} < 10#${b[i]:-0})); then
			return 1
		fi
	done
	return 0
}

# Files older than N days (POSIX find, no stat or date -d).
older_than_days() {
	[ -e "$1" ] || return 0
	[ -n "$(find "$1" -mtime +"$2" -print 2>/dev/null)" ]
}
