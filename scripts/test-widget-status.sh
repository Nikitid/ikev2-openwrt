#!/bin/sh

set -eu

repo="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM

mkdir -p \
	"$tmp/root/etc/config" \
	"$tmp/root/etc/ikev2-manager" \
	"$tmp/root/etc/init.d" \
	"$tmp/root/sys/class/net/ipsec-out/statistics" \
	"$tmp/root/usr/libexec/ikev2-manager.d" \
	"$tmp/root/var/run" \
	"$tmp/bin"
cp "$repo/ikev2-manager-runtime/lib/actions.sh" \
	"$tmp/root/usr/libexec/ikev2-manager.d/actions.sh"
cp "$repo/ikev2-manager-runtime/lib/devices.sh" \
	"$tmp/root/usr/libexec/ikev2-manager.d/devices.sh"

cat >"$tmp/bin/uci" <<'EOF'
#!/bin/sh
while [ "${1:-}" = -q ] || [ "${1:-}" = -c ]; do
	case "$1" in -c) shift ;; esac
	shift
done
command="${1:-}"
[ "$#" -eq 0 ] || shift
key="${1:-}"
case "$command:$key" in
	'show:pbr') echo 'pbr.legacy_exclude=policy' ;;
	'show:ikev2-manager') ;;
	'get:pbr.legacy_exclude.name') echo 'VPN Exclude: 192.168.1.90' ;;
	'get:pbr.legacy_exclude.enabled') echo 1 ;;
	'get:pbr.legacy_exclude.src_addr') echo '192.168.1.90' ;;
	'get:ikev2-manager.globals.device_schema') exit 1 ;;
	'get:ikev2-manager.globals.configured') echo 1 ;;
	'get:ikev2-manager.client.enabled') echo 1 ;;
	'get:ikev2-manager.server.enabled') echo 1 ;;
	'get:ikev2-manager.domains.engine') echo fakeip ;;
	*) exit 0 ;;
esac
EOF
cat >"$tmp/bin/ipcalc.sh" <<'EOF'
#!/bin/sh
case "$1" in 192.168.1.90/32) exit 0 ;; *) exit 1 ;; esac
EOF
cat >"$tmp/bin/swanctl" <<'EOF'
#!/bin/sh
case "$1" in
	--list-conns) echo 'ikev2-in: IKEv2' ;;
	--list-pools) echo 'router_pool4' ;;
	*) exit 1 ;;
esac
EOF
cat >"$tmp/bin/ip" <<'EOF'
#!/bin/sh
[ "$*" = '-4 route show table pbr_ikev2out' ] &&
	echo 'unreachable default metric 32767'
EOF
cat >"$tmp/bin/nft" <<'EOF'
#!/bin/sh
[ "$*" = 'list ruleset' ] || exit 1
case "${TEST_MTPROTO_FIREWALL:-accept}" in
	accept) echo 'tcp dport 1443 counter packets 1 bytes 64 accept' ;;
	dnat) echo 'tcp dport 1443 counter packets 1 bytes 64 dnat ip to 192.0.2.2:1443' ;;
	missing) echo 'tcp dport 443 counter packets 1 bytes 64 accept' ;;
esac
EOF
cat >"$tmp/bin/lsmod" <<'EOF'
#!/bin/sh
exit 0
EOF
cat >"$tmp/root/etc/init.d/pbr" <<'EOF'
#!/bin/sh
[ "$1" = running ]
EOF
cat >"$tmp/root/usr/libexec/ikev2-domain-router" <<'EOF'
#!/bin/sh
[ "$1" = status ] || exit 1
cat <<'STATUS'
service=running
healthy=yes
state=active
STATUS
EOF
chmod 755 \
	"$tmp/bin/uci" \
	"$tmp/bin/ipcalc.sh" \
	"$tmp/bin/swanctl" \
	"$tmp/bin/ip" \
	"$tmp/bin/nft" \
	"$tmp/bin/lsmod" \
	"$tmp/root/etc/init.d/pbr" \
	"$tmp/root/usr/libexec/ikev2-domain-router"

cat >"$tmp/root/var/run/ikev2-health.status" <<'EOF'
state=up failures=0
EOF
printf '%s\n' 123456 >"$tmp/root/sys/class/net/ipsec-out/statistics/rx_bytes"
printf '%s\n' 654321 >"$tmp/root/sys/class/net/ipsec-out/statistics/tx_bytes"
cat >"$tmp/root/etc/pbr-ikev2-domains.txt" <<'EOF'
# generated
example.com
example.net
EOF
cat >"$tmp/root/etc/pbr-ikev2-addresses.manual.txt" <<'EOF'
203.0.113.0/24
EOF
cat >"$tmp/root/etc/pbr-ikev2-community-selected.txt" <<'EOF'
discord
telegram
EOF

if ! PATH="$tmp/bin:$PATH" \
	IKEV2_ROOT="$tmp/root" \
	IKEV2_UCI_BIN="$tmp/bin/uci" \
	IKEV2_RUNTIME_LIB_DIR="$tmp/root/usr/libexec/ikev2-manager.d" \
		sh "$repo/luci-ikev2-manager/ikev2-manager.sh" widget-status \
		>"$tmp/status" 2>"$tmp/error"
then
	cat "$tmp/error" >&2
	exit 1
fi

for expected in \
	'health=up' \
	'configured=1' \
	'pbr=running' \
	'client_enabled=1' \
	'server_enabled=1' \
	'interface_present=1' \
	'interface_bytes_in=123456' \
	'interface_bytes_out=654321' \
	'inbound_conn_loaded=1' \
	'inbound_pool_loaded=1' \
	'pbr_domains=2' \
	'manual_addresses=1' \
	'community_services=2' \
	'device_excluded=1' \
	'device_dns_passthrough=0' \
	'device_dpi_passthrough=0' \
	'device_excluded_packets=0' \
	'device_excluded_bytes=0' \
	'killswitch=active' \
	'domain_engine=fakeip' \
	'domain_service=running' \
	'domain_healthy=yes' \
	'domain_state=active'
do
	grep -qx "$expected" "$tmp/status" || {
		printf 'missing widget status field: %s\n' "$expected" >&2
		cat "$tmp/status" >&2
		exit 1
	}
done

for firewall_mode in accept dnat; do
	TEST_MTPROTO_FIREWALL="$firewall_mode" \
	PATH="$tmp/bin:$PATH" \
	IKEV2_ROOT="$tmp/root" \
	IKEV2_UCI_BIN="$tmp/bin/uci" \
	IKEV2_RUNTIME_LIB_DIR="$tmp/root/usr/libexec/ikev2-manager.d" \
		sh "$repo/luci-ikev2-manager/ikev2-manager.sh" overview \
		>"$tmp/overview-$firewall_mode"
	grep -qx 'mtproto_firewall=active' "$tmp/overview-$firewall_mode" || {
		printf 'MTProto %s firewall rule was not detected\n' "$firewall_mode" >&2
		exit 1
	}
done

TEST_MTPROTO_FIREWALL=missing \
PATH="$tmp/bin:$PATH" \
IKEV2_ROOT="$tmp/root" \
IKEV2_UCI_BIN="$tmp/bin/uci" \
IKEV2_RUNTIME_LIB_DIR="$tmp/root/usr/libexec/ikev2-manager.d" \
	sh "$repo/luci-ikev2-manager/ikev2-manager.sh" overview \
	>"$tmp/overview-missing"
grep -qx 'mtproto_firewall=missing' "$tmp/overview-missing" || {
	printf 'missing MTProto firewall rule was reported active\n' >&2
	exit 1
}

grep -Fq '"/usr/libexec/ikev2-manager widget-status": [ "exec" ]' \
	"$repo/luci-ikev2-manager/acl.json"

printf '%s\n' 'status widget runtime tests OK'
