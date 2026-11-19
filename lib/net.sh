#!/usr/bin/env bash
# LibreOuya: setup wizard (OOBE), hosts file, community store toggle.

LO_SERVER_HOST=ouya.cweiske.de
LO_SERVER_IP_DEFAULT=159.195.22.112
LO_OOBE_NAMES='devs.ouya.tv'
LO_STORE_NAMES='devs.ouya.tv status.ouya.tv ouya-updates.s3.amazonaws.com'

# Look up the community server's address now, since it has moved three times
# (83.169.45.222, then 178.254.13.17, then 159.195.22.112 in January 2026).
resolve_ipv4() {
	local ip=''
	if command -v getent >/dev/null 2>&1; then
		ip=$(getent ahostsv4 "$1" 2>/dev/null | sed -n '1s/[[:space:]].*//p')
	fi
	if [ -z "$ip" ] && command -v dig >/dev/null 2>&1; then
		ip=$(dig +short A "$1" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n 1)
	fi
	if [ -z "$ip" ] && command -v host >/dev/null 2>&1; then
		ip=$(host -t A "$1" 2>/dev/null | sed -n 's/.* has address //p' | head -n 1)
	fi
	if [ -z "$ip" ] && command -v nslookup >/dev/null 2>&1; then
		ip=$(nslookup "$1" 2>/dev/null | sed -n 's/^Address: *\([0-9.]*\)$/\1/p' | tail -n 1)
	fi
	printf '%s\n' "$ip"
}

pick_server_ip() {
	local ip
	ip=$(resolve_ipv4 "$LO_SERVER_HOST")
	if [ -z "$ip" ]; then
		warn "could not resolve $LO_SERVER_HOST from this PC"
		ask "Use the last known address $LO_SERVER_IP_DEFAULT?" || return 1
		LO_SERVER_IP=$LO_SERVER_IP_DEFAULT
	elif [ "$ip" != "$LO_SERVER_IP_DEFAULT" ]; then
		warn "$LO_SERVER_HOST now resolves to $ip, not $LO_SERVER_IP_DEFAULT (it has moved before)"
		ask "Use $ip?" || return 1
		LO_SERVER_IP=$ip
	else
		LO_SERVER_IP=$ip
		ok "$LO_SERVER_HOST resolves to $ip"
	fi
}

# hosts_build <names> <ip> : stdin is the current hosts file, stdout the new
# one. Drops every line naming an OUYA server and our comment, keeps the rest,
# makes sure localhost is there, then appends the requested mappings.
hosts_build() {
	local names=$1 ip=$2 body n
	body=$(tr -d '\r' | awk -v drop="$LO_STORE_NAMES" '
		BEGIN { n = split(drop, d, " "); for (i = 1; i <= n; i++) skip[d[i]] = 1 }
		/^[[:space:]]*#.*libreouya/ { next }
		{ keep = 1; for (i = 2; i <= NF; i++) if ($i in skip) keep = 0; if (keep) print }
	')
	case $body in
	*127.0.0.1*localhost*) ;;
	*) printf '127.0.0.1 localhost\n' ;;
	esac
	[ -n "$body" ] && printf '%s\n' "$body"
	if [ -n "$names" ]; then
		printf '# libreouya: OUYA server names\n'
		for n in $names; do
			printf '%s %s\n' "$ip" "$n"
		done
	fi
	return 0
}

# hosts_write <names> <ip> : rebuild /system/etc/hosts with these names
# mapped to ip. Lines for any OUYA name are dropped first, localhost is kept,
# everything else on the box is left as it was.
hosts_write() {
	local names=$1 ip=$2 cur new md5
	cur=$(mktemp "${TMPDIR:-/tmp}/libreouya-hosts.XXXXXX") || die "mktemp failed"
	new=$cur.new
	dsh 'cat /system/etc/hosts 2>/dev/null' >"$cur" || true
	hosts_build "$names" "$ip" <"$cur" >"$new"
	say "New /system/etc/hosts:"
	say_lines '    ' <"$new"
	if ! ask "Write this to the OUYA? (the current file is backed up first)"; then
		rm -f -- "$cur" "$new"
		return 1
	fi
	md5=$(md5_of "$new")
	push_device_lib
	dpush "$new" "$LO_DEV_TMP/hosts.new" || return 1
	rm -f -- "$cur" "$new"
	root_job "replace /system/etc/hosts" <<EOF
lo_install $LO_DEV_TMP/hosts.new /system/etc/hosts 0644 0.0 $md5 etc_hosts
rm $LO_DEV_TMP/hosts.new
EOF
}

hosts_restore() {
	local which
	which=$(choose "Restore which copy of /system/etc/hosts?" \
		"orig: the file from before LibreOuya first changed it" \
		"prev: the file from before the last change") || return 0
	which=${which%%:*}
	root_job "restore /system/etc/hosts ($which)" <<EOF
lo_restore etc_hosts /system/etc/hosts 0644 0.0 $which
EOF
}

cmd_hosts() {
	need_ouya
	need_su
	case ${1:-} in
	restore) hosts_restore ;;
	show) dsh 'cat /system/etc/hosts' | say_lines '    ' ;;
	*) die "usage: LibreOuya.sh hosts show|restore" ;;
	esac
}

# ---- setup wizard -----------------------------------------------------------

cmd_oobe() {
	local how
	need_ouya
	heading "Get past the setup wizard"
	say "A freshly flashed OUYA's setup wizard opens a connection to devs.ouya.tv port 80 and"
	say "refuses to finish when it fails. That name has been dead since 2019."
	say "This does not turn on the community store; it only satisfies that one check."
	how=$(choose "How?" \
		"hosts entry: point devs.ouya.tv at the community server (permanent, needs su, recommended)" \
		"skip: jump to the home screen now (nothing written, wizard comes back after a reboot)") || return 0
	case $how in
	hosts*)
		need_su
		pick_server_ip || return 1
		hosts_write "$LO_OOBE_NAMES" "$LO_SERVER_IP" || return 1
		ok "Done. On the OUYA, go back and press Continue on the network screen."
		say "Set up the network BEFORE pairing a controller on a fresh flash; people report trouble otherwise."
		;;
	skip*)
		ask "Start the OUYA home screen now?" || return 0
		act adb_dev shell am start -n tv.ouya.console/.launcher.home.HomeActivity
		;;
	esac
}

# ---- community store toggle -------------------------------------------------

store_push_config() {
	local url=$1 f
	f=$(mktemp "${TMPDIR:-/tmp}/libreouya-cfg.XXXXXX") || die "mktemp failed"
	printf 'OUYA_SERVER_URL=%s\nOUYA_STATUS_SERVER_URL=%s/api/v1/status\n' "$url" "$url" >"$f"
	say "ouya_config.properties:"
	say_lines '    ' <"$f"
	if ! ask "Write it to /sdcard/ouya_config.properties? (any existing one is backed up)"; then
		rm -f -- "$f"
		return 1
	fi
	act adb_dev shell "mkdir -p $LO_DEV_SD/backup; if [ -e /sdcard/ouya_config.properties ]; then cat /sdcard/ouya_config.properties > $LO_DEV_SD/backup/ouya_config.properties.prev; fi" >/dev/null
	dpush "$f" /sdcard/ouya_config.properties || { rm -f -- "$f"; return 1; }
	rm -f -- "$f"
	ok "Config written. It applies right away; during first-run setup, reboot once."
}

cmd_store() {
	local action=${1:-} kind url apk
	need_ouya
	case $action in
	on)
		heading "Community store: on"
		say "Points the OUYA's store, login and DISCOVER at a community server."
		say "Account step afterwards: 'Existing account', any username, empty password."
		kind=$(choose "Which server?" \
			"ouya.cweiske.de (public community server)" \
			"louyapi (a server app running on the OUYA itself; you supply the APK)" \
			"Another stouyapi URL (self-hosted)") || return 0
		case $kind in
		ouya.cweiske.de*) url=http://$LO_SERVER_HOST ;;
		louyapi*)
			apk=$(prompt_value "Path to the louyapi APK (github.com/cweiske/louyapi releases)" '') || return 0
			[ -f "$apk" ] || die "no file at $apk"
			ask "Install $apk?" && install_apk "$apk"
			url=http://127.0.0.1:8080
			;;
		*)
			url=$(prompt_value "Server URL (http://, no trailing slash)" 'http://') || return 0
			;;
		esac
		url=${url%/}
		case $url in
		https://*) warn "the OUYA cannot do HTTPS to most servers (no SNI). Use http://" ;;
		http://?*) ;;
		*) die "not a URL: $url" ;;
		esac
		store_push_config "$url" || return 1
		if ask "Also map devs.ouya.tv, status.ouya.tv and ouya-updates.s3.amazonaws.com in /system/etc/hosts (needs su)?"; then
			need_su
			pick_server_ip && hosts_write "$LO_STORE_NAMES" "$LO_SERVER_IP"
		fi
		;;
	off)
		heading "Community store: off"
		if ask "Remove /sdcard/ouya_config.properties? (a copy goes to $LO_DEV_SD/backup)"; then
			act adb_dev shell "mkdir -p $LO_DEV_SD/backup; cat /sdcard/ouya_config.properties > $LO_DEV_SD/backup/ouya_config.properties.prev 2>/dev/null; rm /sdcard/ouya_config.properties"
		fi
		if ask "Cut /system/etc/hosts back to only the setup wizard entry (needs su)?"; then
			need_su
			pick_server_ip && hosts_write "$LO_OOBE_NAMES" "$LO_SERVER_IP"
		elif ask "Or restore a saved hosts file instead?"; then
			need_su
			hosts_restore
		fi
		;;
	*) die "usage: LibreOuya.sh store on|off" ;;
	esac
}

cmd_connect() {
	local ip=${1:-}
	find_adb
	[ -n "$ip" ] || ip=$(prompt_value "OUYA IP address (Manage > Network on the OUYA)" '') || return 0
	case $ip in
	*:*) ;;
	*) ip=$ip:5555 ;;
	esac
	act adb_raw connect "$ip"
	say "If it connected, use -s $ip with other commands when more than one device is attached."
}
