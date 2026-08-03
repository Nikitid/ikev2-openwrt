#!/bin/sh
#
# The outbound VIP sync must claim only this application's own virtual IP.
# A router can run a second, unrelated IKEv2 client (a site link, for example);
# adopting its VIP installs a foreign address on ipsec-out and silently breaks
# every route that points at the outbound tunnel.

set -eu

root="$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)"
script="$root/ikev2-manager-runtime/ikev2-sync-vips.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM

fail() {
	printf 'test-sync-vips: %s\n' "$*" >&2
	exit 1
}

# The SA list must be scoped to the owning connection, never scraped wholesale.
grep -Fq "connection='proxy-out'" "$script" ||
	fail 'the owning connection name is not pinned'
grep -Fq 'swanctl --list-sas --ike "$connection" --raw' "$script" ||
	fail 'the SA list is not scoped to the owning connection'

bin="$tmp/bin"
mkdir -p "$bin"

cat >"$bin/uci" <<'STUB'
#!/bin/sh
printf '1\n'
STUB

# Two IKEv2 clients are up. proxy-out is this application's; site-link belongs
# to another package and is listed after it, so an unfiltered scrape that keeps
# the last match would take the wrong address.
cat >"$bin/swanctl" <<'STUB'
#!/bin/sh
ike=''
while [ "$#" -gt 0 ]; do
	case "$1" in
		--ike) ike="$2"; shift 2 ;;
		*) shift ;;
	esac
done
case "$ike" in
	proxy-out) printf 'proxy-out: local-vips=[10.20.20.10]\n' ;;
	site-link) printf 'site-link: local-vips=[10.253.44.2]\n' ;;
	'') printf 'proxy-out: local-vips=[10.20.20.10] site-link: local-vips=[10.253.44.2]\n' ;;
	*) : ;;
esac
STUB

cat >"$bin/ip" <<STUB
#!/bin/sh
case "\$*" in
	*"addr show dev ipsec-out"*) printf '9: ipsec-out    inet 10.253.44.2/32 scope global ipsec-out\n' ;;
	*"link show ipsec-out"*) : ;;
	*) printf '%s\n' "\$*" >>"$tmp/ip-calls" ;;
esac
STUB

chmod 755 "$bin/uci" "$bin/swanctl" "$bin/ip"

# The helper records the result under /var/run; relocate it so the test never
# touches machine state.
sed "s#/var/run/ikev2-vip4#$tmp/ikev2-vip4#g" "$script" >"$tmp/sync-vips"
chmod 755 "$tmp/sync-vips"

: >"$tmp/ip-calls"
PATH="$bin:$PATH" "$tmp/sync-vips" || fail 'sync helper exited non-zero'

recorded="$(cat "$tmp/ikev2-vip4")"
[ "$recorded" = '10.20.20.10' ] ||
	fail "adopted the wrong virtual IP: $recorded"

grep -Fq 'addr add 10.20.20.10/32 dev ipsec-out' "$tmp/ip-calls" ||
	fail 'the owning virtual IP was not installed on ipsec-out'
if grep -Fq '10.253.44.2' "$tmp/ip-calls"; then
	fail 'a foreign virtual IP was installed on ipsec-out'
fi

printf 'sync vips tests OK\n'
