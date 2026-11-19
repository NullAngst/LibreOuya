#!/usr/bin/env bash
# LibreOuya: optional LAN DNS blocker on the OUYA's built-in dnsmasq.

LO_DNS_DIR=/data/local/libreouya/dns
LO_DNS_DEFAULT_LISTS='https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts'

dns_lists_file() {
	local f=$LO_CONFIG/blocklists.txt
	if [ ! -f "$f" ]; then
		{
			printf '# One blocklist URL per line. Hosts files, plain domain lists and\n'
			printf '# adblock-style ||domain^ lists all work. Lines starting with # are skipped.\n'
			printf '%s\n' "$LO_DNS_DEFAULT_LISTS"
		} >"$f"
		printf 'Created %s with a default list.\n' "$f" >&2
		log "created $f"
	fi
	printf '%s\n' "$f"
}

dns_allow_file() {
	local f=$LO_CONFIG/allowlist.txt
	if [ ! -f "$f" ]; then
		printf '# One domain per line that should never be blocked.\n' >"$f"
	fi
	printf '%s\n' "$f"
}

# Turn hosts files, plain domain lists and adblock ||domain^ lines into
# "0.0.0.0 domain" lines. Reads stdin, writes stdout.
blocklist_convert() {
	tr -d '\r' | tr '[:upper:]' '[:lower:]' | awk '
		{ sub(/#.*/, ""); sub(/!.*/, "") }
		NF == 0 { next }
		/^\|\|/ { d = $1; sub(/^\|\|/, "", d); sub(/\^.*$/, "", d); print d; next }
		NF >= 2 && ($1 == "0.0.0.0" || $1 == "127.0.0.1" || $1 == "::" || $1 == "::1") {
			for (i = 2; i <= NF; i++) print $i
			next
		}
		NF == 1 { print $1 }
	' | awk '
		/^[a-z0-9_]([a-z0-9_.-]*[a-z0-9_])?\.[a-z0-9-]+$/ &&
		$0 != "localhost" && $0 != "localhost.localdomain" && $0 != "local" &&
		$0 != "broadcasthost" && $0 != "0.0.0.0" { print "0.0.0.0 " $0 }
	'
}

dns_device_ip() {
	{ dsh 'netcfg' || true; } | awk '$2 == "UP" && $1 != "lo" { split($3, a, "/"); if (a[1] != "0.0.0.0") { print $1 " " a[1] } }'
}

cmd_dns() {
	local action=${1:-}
	case $action in
	setup) dns_setup ;;
	update) dns_update ;;
	start | stop | restart | status) dns_ctl "$action" ;;
	test) dns_test ;;
	remove) dns_remove ;;
	*) die "usage: libreouya dns setup|update|start|stop|restart|status|test|remove" ;;
	esac
}

dns_ctl() {
	need_ouya
	need_su
	root_job "dns $1" <<EOF
[ -f $LO_DNS_DIR/dns.sh ] || lo_fail "DNS is not set up; run ./libreouya dns setup"
sh $LO_DNS_DIR/dns.sh $1 | while IFS= read -r l; do lo_say "\$l"; done
EOF
}

dns_setup() {
	local ver ups cache conf
	need_ouya
	need_su
	heading "DNS blocker on the OUYA"
	say "Runs the dnsmasq that ships with Android (for tethering) as a LAN DNS server with a blocklist."
	say "If the OUYA hangs or reboots, every device using it loses DNS until it is back."
	say "Keep a second DNS server on your router, and never forward port 53 from the internet."
	ver=$(dsh '/system/bin/dnsmasq --version 2>&1' | head -n 1) || ver=''
	case $ver in
	*Dnsmasq* | *dnsmasq*) ok "Found: $ver" ;;
	*) err "no working /system/bin/dnsmasq on this firmware ($ver)"; return 1 ;;
	esac
	ask "Set it up?" || return 0
	ups=$(prompt_value "Upstream DNS servers (space separated)" "9.9.9.9 149.112.112.112") || return 0
	for u in $ups; do
		case $u in *[!0-9a-fA-F.:]*) die "not an IP address: $u" ;; esac
	done
	cache=$(prompt_value "Cache size (entries)" 2000) || return 0
	case $cache in '' | *[!0-9]*) die "not a number: $cache" ;; esac
	conf=$(mktemp "${TMPDIR:-/tmp}/libreouya-dns.XXXXXX") || die "mktemp failed"
	printf 'UPSTREAMS="%s"\nCACHE=%s\nEXTRA="--user=root --group=root"\nBIN=/system/bin/dnsmasq\n' "$ups" "$cache" >"$conf"
	push_device_lib
	dpush "$LO_ROOT/device/dns.sh" "$LO_DEV_TMP/dns.sh" || return 1
	dpush "$conf" "$LO_DEV_TMP/dns.conf" || return 1
	rm -f -- "$conf"
	root_job "install DNS files to $LO_DNS_DIR" <<EOF || return 1
mkdir -p $LO_DNS_DIR || lo_fail "mkdir failed"
cat $LO_DEV_TMP/dns.sh > $LO_DNS_DIR/dns.sh || lo_fail "copy failed"
cat $LO_DEV_TMP/dns.conf > $LO_DNS_DIR/dns.conf || lo_fail "copy failed"
chmod 0700 $LO_DNS_DIR
chmod 0700 $LO_DNS_DIR/dns.sh
rm $LO_DEV_TMP/dns.sh $LO_DEV_TMP/dns.conf
lo_say "installed to $LO_DNS_DIR"
EOF
	if ask "Build and push the blocklist now?"; then
		dns_update || warn "blocklist step failed; dnsmasq still works without one"
	fi
	if ask "Start dnsmasq now?"; then
		dns_ctl start
	fi
	if initd_active; then
		if ask "Start it at every boot (init.d script)?"; then
			conf=$(mktemp "${TMPDIR:-/tmp}/libreouya-dnsinit.XXXXXX") || die "mktemp failed"
			printf '#!/system/bin/sh\n# libreouya dns\nsleep 15\nsh %s/dns.sh start\n' "$LO_DNS_DIR" >"$conf"
			initd_script 90libreouya-dns "$conf"
			rm -f -- "$conf"
		fi
	else
		say "No init.d hook, so dnsmasq will not start after a reboot. Either ./libreouya initd on"
		say "and run setup again, or ./libreouya dns start after each reboot."
	fi
	say "OUYA addresses:"
	dns_device_ip | sed 's/^/    /'
	say "Give the OUYA a fixed address (DHCP reservation on the router), then point clients or the"
	say "router's DNS at it. Test from this PC with: ./libreouya dns test"
}

dns_update() {
	local lists allow tmp out url n
	need_ouya
	need_su
	lists=$(dns_lists_file)
	allow=$(dns_allow_file)
	heading "Blocklist update"
	say "Lists from $lists:"
	sed -n '/^[^#]/s/^/    /p' "$lists"
	ask "Download these and build the blocklist?" || return 0
	tmp=$(mktemp -d "${TMPDIR:-/tmp}/libreouya-bl.XXXXXX") || die "mktemp failed"
	n=0
	while IFS= read -r url; do
		case $url in '' | '#'*) continue ;; esac
		n=$((n + 1))
		act curl -fsSL --retry 2 --connect-timeout 20 -o "$tmp/list.$n" -- "$url" || warn "failed: $url"
	done <"$lists"
	out=$tmp/blocklist.hosts
	cat "$tmp"/list.* 2>/dev/null | blocklist_convert | sort -u >"$out.all"
	sed -n '/^[^#]/p' "$allow" | tr '[:upper:]' '[:lower:]' | tr -d '\r' | sed 's/^/0.0.0.0 /' >"$tmp/allow"
	if [ -s "$tmp/allow" ]; then
		grep -vxF -f "$tmp/allow" "$out.all" >"$out" || true
	else
		mv -- "$out.all" "$out"
	fi
	say "Blocklist: $(wc -l <"$out" | tr -d ' ') domains"
	ask "Push it to the OUYA and reload dnsmasq?" || { rm -rf -- "$tmp"; return 0; }
	push_device_lib
	dpush "$out" "$LO_DEV_TMP/blocklist.hosts" || { rm -rf -- "$tmp"; return 1; }
	rm -rf -- "$tmp"
	root_job "install blocklist" <<EOF
mkdir -p $LO_DNS_DIR
cat $LO_DEV_TMP/blocklist.hosts > $LO_DNS_DIR/blocklist.hosts || lo_fail "copy failed (space?)"
rm $LO_DEV_TMP/blocklist.hosts
if [ -f $LO_DNS_DIR/dns.sh ]; then sh $LO_DNS_DIR/dns.sh reload | while IFS= read -r l; do lo_say "\$l"; done; fi
EOF
}

dns_test() {
	local ip
	need_device
	ip=$(dns_device_ip | head -n 1 | cut -d ' ' -f 2)
	[ -n "$ip" ] || die "could not find the OUYA's IP"
	say "Querying $ip for example.com (should resolve) and doubleclick.net (should be 0.0.0.0 if listed):"
	if command -v dig >/dev/null 2>&1; then
		dig +short @"$ip" example.com A
		dig +short @"$ip" doubleclick.net A
	elif command -v nslookup >/dev/null 2>&1; then
		nslookup example.com "$ip"
		nslookup doubleclick.net "$ip"
	else
		die "need dig or nslookup on this PC"
	fi
}

dns_remove() {
	need_ouya
	need_su
	ask "Stop dnsmasq and remove $LO_DNS_DIR and its boot script?" || return 0
	root_job "remove DNS blocker" <<EOF
if [ -f $LO_DNS_DIR/dns.sh ]; then sh $LO_DNS_DIR/dns.sh stop >/dev/null; fi
rm -r $LO_DNS_DIR 2>/dev/null
lo_say "removed $LO_DNS_DIR"
EOF
	if dsh 'ls /system/etc/init.d/90libreouya-dns 2>/dev/null' | grep -q 90libreouya; then
		initd_script 90libreouya-dns -remove || true
	fi
}
