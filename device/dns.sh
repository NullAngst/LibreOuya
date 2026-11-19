#!/system/bin/sh
# LibreOuya DNS blocker, runs ON the OUYA as root.
# Uses the dnsmasq binary Android ships for Wi-Fi tethering, fed a hosts-format
# blocklist. Settings live in dns.conf next to this script.
#
# Usage: sh /data/local/libreouya/dns/dns.sh start|stop|restart|reload|status

D=/data/local/libreouya/dns
PID=$D/dnsmasq.pid
LIST=$D/blocklist.hosts

UPSTREAMS="9.9.9.9 149.112.112.112"
CACHE=2000
EXTRA="--user=root --group=root"
BIN=/system/bin/dnsmasq
# dns.conf is written by ./libreouya dns setup.
# shellcheck source=/dev/null
[ -f "$D/dns.conf" ] && . "$D/dns.conf"

running() {
	[ -f "$PID" ] || return 1
	p=$(cat "$PID" 2>/dev/null)
	[ -n "$p" ] && [ -d "/proc/$p" ]
}

start() {
	if running; then
		echo "dnsmasq already running (pid $(cat "$PID"))"
		return 0
	fi
	[ -x "$BIN" ] || { echo "no dnsmasq at $BIN"; return 1; }
	[ -f "$LIST" ] || : >"$LIST"
	servers=""
	for u in $UPSTREAMS; do
		servers="$servers --server=$u"
	done
	# Word splitting is intended for $servers and $EXTRA.
	# shellcheck disable=SC2086
	"$BIN" --no-resolv --no-hosts --addn-hosts="$LIST" --cache-size="$CACHE" \
		--domain-needed --bogus-priv --pid-file="$PID" $servers $EXTRA
	sleep 1
	if running; then
		echo "dnsmasq started (pid $(cat "$PID"))"
	else
		echo "dnsmasq did not stay up. Try EXTRA=\"\" in $D/dns.conf, or check port 53 is free (tethering off)."
		return 1
	fi
}

stop() {
	if running; then
		kill "$(cat "$PID")"
		rm -f "$PID" 2>/dev/null || rm "$PID"
		echo "dnsmasq stopped"
	else
		echo "dnsmasq not running"
	fi
}

case "$1" in
start) start ;;
stop) stop ;;
restart) stop; sleep 1; start ;;
reload)
	# SIGHUP makes dnsmasq re-read the addn-hosts file and clear its cache.
	if running; then kill -1 "$(cat "$PID")" && echo "blocklist reloaded"; else start; fi
	;;
status)
	if running; then echo "running (pid $(cat "$PID"))"; else echo "not running"; fi
	;;
*) echo "usage: $0 start|stop|restart|reload|status"; exit 1 ;;
esac
