#!/bin/sh

set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM

mkdir -p "$tmp/bin" "$tmp/config"
cat >"$tmp/bin/uci" <<'EOF'
#!/bin/sh
while [ "$#" -gt 0 ]; do
	case "$1" in
		-c) shift 2 ;;
		-q) shift ;;
		*) break ;;
	esac
done
command="${1:-}"
[ "$#" -eq 0 ] || shift

zone_at() {
	printf '%s\n' "${TEST_ZONES:-}" | awk -v wanted="$1" '
		{
			for (i = 1; i <= NF; i++)
				if (i - 1 == wanted) { print $i; found = 1 }
		}
		END { exit found ? 0 : 1 }
	'
}

case "$command" in
	get)
		key="${1:-}"
		case "$key" in
			firewall.@zone\[*\])
				index="${key#firewall.@zone[}"
				index="${index%]}"
				zone_at "$index" >/dev/null && printf '%s\n' zone
				;;
			firewall.@zone\[*\].name)
				index="${key#firewall.@zone[}"
				index="${index%].name}"
				zone_at "$index"
				;;
			firewall.@zone\[*\].network)
				index="${key#firewall.@zone[}"
				index="${index%].network}"
				zone="$(zone_at "$index")" || exit 1
				case "$zone" in
					wan) printf '%s\n' "${TEST_WAN_NETWORKS:-wan}" ;;
					*) printf '%s\n' "$zone" ;;
				esac
				;;
			firewall.ikev2pbr_in)
				[ -n "${TEST_IN_OWNER:-}" ] && printf '%s\n' zone
				;;
			firewall.ikev2pbr_in.name)
				[ -n "${TEST_IN_OWNER:-}" ] && printf '%s\n' "$TEST_IN_OWNER"
				;;
			firewall.ikev2pbr_out)
				[ -n "${TEST_OUT_OWNER:-}" ] && printf '%s\n' zone
				;;
			firewall.ikev2pbr_out.name)
				[ -n "${TEST_OUT_OWNER:-}" ] && printf '%s\n' "$TEST_OUT_OWNER"
				;;
			network.wan|network.uplink) printf '%s\n' interface ;;
			network.wan.device) printf '%s\n' eth0 ;;
			network.uplink.device) printf '%s\n' eth1 ;;
			ikev2-manager.globals.wan_interface) printf '%s\n' wan ;;
			ikev2-manager.globals.wan_zone) printf '%s\n' wan ;;
			*) exit 1 ;;
		esac
		;;
	show)
		index=0
		for zone in ${TEST_ZONES:-}; do
			printf "firewall.@zone[%s]=zone\n" "$index"
			printf "firewall.@zone[%s].name='%s'\n" "$index" "$zone"
			index=$((index + 1))
		done
		;;
	*) exit 1 ;;
esac
EOF
chmod 755 "$tmp/bin/uci"

cat >"$tmp/bin/fw4" <<'EOF'
#!/bin/sh
[ "${1:-}" = check ] || exit 1
case "${TEST_FW4_RESULT:-ok}" in
	ok) exit 0 ;;
	warning)
		printf "%s\n" "Section ikev2pbr_dns_lan option 'src_ip' must not be a list" >&2
		printf '%s\n' 'Section ikev2pbr_dns_lan skipped due to invalid options' >&2
		exit 0
		;;
	error) printf '%s\n' 'syntax error' >&2; exit 1 ;;
esac
EOF
chmod 755 "$tmp/bin/fw4"

run_system() {
	PATH="$tmp/bin:$PATH" IKEV2_UCI_CONFIG_DIR="$tmp/config" \
	IKEV2_UCI_BIN="$tmp/bin/uci" \
	IKEV2_RUNTIME_LIB_DIR="$root/ikev2-manager-runtime/lib" \
		sh "$root/ikev2-manager-runtime/ikev2-manager-system.sh" "$@"
}

TEST_FW4_RESULT=ok run_system _firewall-check
if TEST_FW4_RESULT=warning run_system _firewall-check >/dev/null 2>&1; then
	printf 'fw4 skipped-section warning was accepted\n' >&2
	exit 1
fi
if TEST_FW4_RESULT=error run_system _firewall-check >/dev/null 2>&1; then
	printf 'fw4 validation error was accepted\n' >&2
	exit 1
fi

TEST_ZONES=''
TEST_IN_OWNER=''
TEST_OUT_OWNER=''
export TEST_ZONES TEST_IN_OWNER TEST_OUT_OWNER
run_system validate-server-zones ikev2in ikev2out

TEST_ZONES='lan wan'
export TEST_ZONES
if run_system validate-server-zones lan ikev2out >/dev/null 2>&1; then
	printf 'existing firewall zone name was accepted for a managed zone\n' >&2
	exit 1
fi

TEST_ZONES='ikev2in ikev2out'
TEST_IN_OWNER=ikev2in
TEST_OUT_OWNER=ikev2out
export TEST_ZONES TEST_IN_OWNER TEST_OUT_OWNER
run_system validate-server-zones ikev2in ikev2out

TEST_ZONES='ikev2in ikev2in ikev2out'
export TEST_ZONES
if run_system validate-server-zones ikev2in ikev2out >/dev/null 2>&1; then
	printf 'duplicate managed firewall zone name was accepted\n' >&2
	exit 1
fi

TEST_ZONES='lan wan'
TEST_IN_OWNER=''
TEST_OUT_OWNER=''
export TEST_ZONES TEST_IN_OWNER TEST_OUT_OWNER
if run_system set 0 wan wan 1 1 >/dev/null 2>&1; then
	printf 'WAN network was accepted as a protected network\n' >&2
	exit 1
fi

TEST_WAN_NETWORKS='wan uplink'
export TEST_WAN_NETWORKS
if run_system set 0 wan uplink 1 1 >/dev/null 2>&1; then
	printf 'network in the WAN firewall zone was accepted as protected\n' >&2
	exit 1
fi
if run_system coverage-add uplink >/dev/null 2>&1; then
	printf 'coverage-add accepted a network in the WAN firewall zone\n' >&2
	exit 1
fi

for pair in \
	'udp udp://1.1.1.1:53' \
	'dot tls://one.one.one.one' \
	'doh https://dns.cloudflare.com/dns-query' \
	'h3 h3://dns.google/dns-query' \
	'dnscrypt sdns://AQMA_valid-stamp'; do
	set -- $pair
	run_system _validate-dns-endpoint "$1" "$2"
done
for pair in \
	'dot tls:1.1.1.1' \
	'dot tls://' \
	'doh https://dns.example' \
	'doh https:///dns-query' \
	'udp udp://999.1.1.1' \
	'udp udp://bad_host' \
	'dnscrypt sdns://short'; do
	set -- $pair
	if run_system _validate-dns-endpoint "$1" "$2" >/dev/null 2>&1; then
		printf 'invalid DNS endpoint was accepted: %s\n' "$pair" >&2
		exit 1
	fi
done

printf 'system validation tests OK\n'
