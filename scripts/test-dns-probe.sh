#!/bin/sh

# DNS health was one name: when openwrt.org did not resolve - the domain was
# unreachable, or the Internet blinked - a working configuration was rolled back
# and the watcher switched the router out of reliable mode. Any of several names
# is enough now, and without the Internet nothing is switched over.

set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
router="$root/ikev2-manager-runtime/ikev2-domain-router.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM

fail() {
	printf '%s\n' "$*" >&2
	exit 1
}

mkdir -p "$tmp/bin"
# Answers only the names listed in $STUB_NAMES, for servers in $STUB_SERVERS
# ("any" for every server); $STUB_HANG makes every query hang.
cat >"$tmp/bin/nslookup" <<'EOF'
#!/bin/sh
[ -z "${STUB_HANG:-}" ] || exec sleep 30
case " ${STUB_SERVERS:-any} " in *" $2 "* | *" any "*) ;; *) exit 1 ;; esac
case " ${STUB_NAMES:-} " in
	*" $1 "*) printf 'Server:\t\t%s\nAddress:\t%s:53\n\nName:\t%s\nAddress: 203.0.113.9\n' "$2" "$2" "$1" ;;
	*) printf "** server can't find %s: NXDOMAIN\n" "$1"; exit 1 ;;
esac
EOF
cat >"$tmp/bin/ubus" <<'EOF'
#!/bin/sh
printf '{"dns-server":["192.0.2.53"]}\n'
EOF
cat >"$tmp/bin/uci" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "$tmp/bin/"*
PATH="$tmp/bin:$PATH"
export PATH
. "$root/ikev2-manager-runtime/lib/routing.sh"
jsonfilter() { sed -n 's/.*"dns-server":\["\([^"]*\)"\].*/\1/p'; }
# Assignments before a function call outlive it in a POSIX shell, so each call
# runs in its own subshell: stub NAMES SERVERS HANG COMMAND...
stub() {
	(
		STUB_NAMES="$1" STUB_SERVERS="$2" STUB_HANG="$3"
		export STUB_NAMES STUB_SERVERS STUB_HANG
		shift 3
		"$@"
	)
}

# One name that resolves is enough.
stub yandex.ru any '' dns_probe_answers 127.0.0.1 || fail 'one answering name was not enough'
stub '' any '' dns_probe_answers 127.0.0.1 && fail 'a resolver that answers nothing passed'
stub openwrt.org 198.51.100.1 '' dns_probe_answers 127.0.0.1 &&
	fail 'another server answering made this one pass'

# A resolver that never answers cannot stall the caller.
started="$(date +%s)"
stub '' any 1 dns_probe_answers 127.0.0.1 && fail 'a hanging resolver passed'
[ $(( $(date +%s) - started )) -lt 15 ] || fail 'a hanging resolver stalled the probe'

# The Internet is judged past our resolvers: the WAN's own and public ones.
stub cloudflare.com 192.0.2.53 '' internet_dns_reachable ||
	fail 'the WAN resolver answering did not count as the Internet being up'
stub cloudflare.com 1.1.1.1 '' internet_dns_reachable ||
	fail 'a public resolver answering did not count as the Internet being up'
stub '' any '' internet_dns_reachable && fail 'no resolver answering counted as the Internet being up'

# A failed wait says when the Internet itself is gone.
stub '' any '' wait_for_router_dns 127.0.0.1 1 2>"$tmp/err" && fail 'a dead resolver passed the wait'
grep -q 'WAN connection appears to be down' "$tmp/err" || fail 'an Internet outage was not named'
stub openwrt.org 192.0.2.53 '' wait_for_router_dns 127.0.0.1 1 2>"$tmp/err" &&
	fail 'our dead resolver passed because the WAN one answered'
grep -q 'WAN connection' "$tmp/err" && fail 'a dead resolver with the Internet up was blamed on the WAN'

# No single name is hard-coded as the health check any more.
if grep -n 'nslookup openwrt.org\|wait_for_query 127.0.0.1 openwrt.org\|router_dns_ready 127.0.0.1 openwrt.org' \
	"$root"/ikev2-manager-runtime/*.sh "$root"/ikev2-manager-runtime/lib/*.sh "$root"/luci-ikev2-domains/*.sh; then
	fail 'a health check still depends on one name'
fi

# Without the Internet the watcher's repair keeps its DNS cutover: nothing is
# wrong with the resolver.
awk '
	index($0, "repair_runtime() {") == 1 { body = 1 }
	body { print }
	body && $0 == "}" { exit }
' "$router" | awk '
	/internet_dns_reachable/ { guard = NR }
	/restore_dnsmasq/ { undo = NR }
	END { exit !(guard && undo && guard < undo) }
' || fail 'without the Internet the FakeIP repair undoes its DNS cutover'

printf '%s\n' 'DNS probe tests OK'
