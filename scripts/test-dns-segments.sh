#!/bin/sh

set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM

mkdir -p "$tmp/bin" "$tmp/uci"
cp "$root/scripts/uci-stub.sh" "$tmp/bin/uci"
chmod 755 "$tmp/bin/uci"

cat >"$tmp/uci/ikev2-manager" <<'EOF'
dnsseg_national=dns_segment
dnsseg_national.name=national
dnsseg_national.enabled=1
dnsseg_national.domains=ru su xn--p1ai
dnsseg_national.protocol=udp
dnsseg_national.upstream_mode=parallel
dnsseg_national.upstream=udp://77.88.8.8:53 udp://77.88.8.1:53
dnsseg_national.bootstrap=77.88.8.8:53
dnsseg_national.fallback=https://dns.cloudflare.com/dns-query
dnsseg_national.https_compat=1
dnsseg_national.port=5550
dnsseg_disabled=dns_segment
dnsseg_disabled.name=disabled
dnsseg_disabled.enabled=0
dnsseg_disabled.domains=example.test
dnsseg_disabled.protocol=doh
dnsseg_disabled.upstream_mode=fastest_addr
dnsseg_disabled.upstream=https://dns.example/dns-query
dnsseg_disabled.bootstrap=1.1.1.1:53
dnsseg_disabled.https_compat=0
dnsseg_disabled.port=5551
EOF

cat >"$tmp/bin/nslookup" <<'EOF'
#!/bin/sh
host=''
for argument in "$@"; do
	case "$argument" in -* | 127.0.0.1) ;; *) host="$argument"; break ;; esac
done
[ -z "${DNS_LOOKUP_LOG:-}" ] || printf '%s\n' "$host" >>"$DNS_LOOKUP_LOG"
if [ "${DNS_CHECK_FAIL:-0}" = 1 ]; then
	printf '%s\n' "server can't find $host: SERVFAIL"
	exit 1
fi
printf '%s\n' "server can't find $host: NXDOMAIN"
exit 1
EOF
cat >"$tmp/bin/timeout" <<'EOF'
#!/bin/sh
shift
exec "$@"
EOF
cat >"$tmp/bin/netstat" <<'EOF'
#!/bin/sh
[ "${DNS_LISTENER_FAIL:-0}" = 1 ] && exit 0
printf '%s\n' 'udp 0 0 127.0.0.1:5550 0.0.0.0:*'
EOF
chmod 755 "$tmp/bin/nslookup" "$tmp/bin/timeout" "$tmp/bin/netstat"

run_system() {
	PATH="$tmp/bin:$PATH" \
	DNS_CHECK_FAIL="${DNS_CHECK_FAIL:-0}" \
	DNS_LISTENER_FAIL="${DNS_LISTENER_FAIL:-0}" \
	DNS_LOOKUP_LOG="$tmp/nslookup.log" \
	UCI_STUB_DIR="$tmp/uci" \
	IKEV2_UCI_CONFIG_DIR="$tmp/config" \
	IKEV2_UCI_BIN="$tmp/bin/uci" \
	IKEV2_RUNTIME_LIB_DIR="$root/ikev2-manager-runtime/lib" \
	IKEV2_SYSTEM_ACTION_STATUS="$tmp/action.status" \
	IKEV2_SYSTEM_ACTION_STATUS_DIR="$tmp/actions" \
	IKEV2_ACTION_LOCK="$tmp/action.lock" \
	IKEV2_ACTION_LOCK_STATUS="$tmp/action.lock.status" \
	IKEV2_DNS_SEGMENTS_STATUS="$tmp/segments.status" \
		sh "$root/ikev2-manager-runtime/ikev2-manager-system.sh" "$@"
}

run_system _validate-dns-segments
run_system dns-segments-check
grep -Fxq 'state=up' "$tmp/segments.status"
grep -Fxq 'segments=1' "$tmp/segments.status"
doctor_output="$(run_system _doctor-dns-segments-status)"
printf '%s\n' "$doctor_output" | grep -Fxq 'dns_segments=ok' || {
	printf '%s\n' "$doctor_output" >&2
	printf 'fast doctor did not recognize a healthy DNS segment status\n' >&2
	exit 1
}
[ "$(wc -l <"$tmp/nslookup.log" | tr -d ' ')" = 1 ]
grep -Eq '\.ru$' "$tmp/nslookup.log"
if grep -Eq '\.(su|xn--p1ai)$' "$tmp/nslookup.log"; then
	printf 'DNS segment health check still probes every equivalent suffix\n' >&2
	exit 1
fi
if DNS_CHECK_FAIL=1 run_system dns-segments-check >/dev/null 2>&1; then
	printf 'failed DNS segment probe was reported as healthy\n' >&2
	exit 1
fi
grep -Fxq 'state=degraded' "$tmp/segments.status"
grep -Fxq 'failure_ids=national' "$tmp/segments.status"
grep -Fxq 'path_failure_ids=national' "$tmp/segments.status"
doctor_output="$(run_system _doctor-dns-segments-status 2>/dev/null || true)"
printf '%s\n' "$doctor_output" | grep -Fxq 'dns_segments=degraded:national' || {
	printf '%s\n' "$doctor_output" >&2
	printf 'fast doctor did not preserve a degraded DNS segment status\n' >&2
	exit 1
}
if DNS_LISTENER_FAIL=1 run_system dns-segments-check >/dev/null 2>&1; then
	printf 'missing DNS segment listener was reported as healthy\n' >&2
	exit 1
fi
grep -Fxq 'direct_failure_ids=national' "$tmp/segments.status"
cat >"$tmp/segment-action.in" <<'EOF'
set
worker
Worker
1
dev
udp
load_balance
udp://1.1.1.1:53
1.1.1.1:53

1
EOF
run_system _action-run test-dns-segment dns-segment "$tmp/segment-action.in"
[ ! -e "$tmp/segment-action.in" ]
grep -Fxq 'dnsseg_worker.domains=dev' "$tmp/uci/ikev2-manager"
grep -Fxq 'dnsseg_worker.https_compat=1' "$tmp/uci/ikev2-manager"
grep -Fxq 'state=ok' "$tmp/actions/test-dns-segment.status"
cat >"$tmp/segment-extra.in" <<'EOF'
set
extra
Extra
1
extra.example
udp
load_balance
udp://1.1.1.1:53
1.1.1.1:53

1
unexpected
EOF
if run_system _action-run test-dns-extra dns-segment "$tmp/segment-extra.in"; then
	printf 'DNS segment input with an extra field was accepted\n' >&2
	exit 1
fi
[ ! -e "$tmp/segment-extra.in" ]
grep -Fxq 'state=error' "$tmp/actions/test-dns-extra.status"
combined="$(run_system _dns-combined-upstreams 'https://dns.cloudflare.com/dns-query')"
printf '%s\n' "$combined" | grep -Fxq 'https://dns.cloudflare.com/dns-query'

dnsmasq_servers="$(run_system _dnsmasq-combined-servers '127.0.0.1#5453')"
printf '%s\n' "$dnsmasq_servers" | grep -Fxq '127.0.0.1#5453'
printf '%s\n' "$dnsmasq_servers" | grep -Fxq '/ru/su/xn--p1ai/127.0.0.1#5550'
if printf '%s\n' "$dnsmasq_servers" | grep -q 'example.test'; then
	printf 'disabled DNS segment was included in the dnsmasq servers\n' >&2
	exit 1
fi
cat >>"$tmp/uci/ikev2-manager" <<'EOF'
domains=domains
domains.engine=fakeip
dns=dns
dns.timeout=10s
EOF
combined="$(run_system _dns-combined-upstreams 'https://dns.cloudflare.com/dns-query')"
[ "$combined" = 'https://dns.cloudflare.com/dns-query' ] || {
	printf 'DNS segments are still nested behind the main resolver\n' >&2
	exit 1
}
[ "$(run_system _dns-runtime-timeout '')" = 8s ]
[ "$(run_system _dns-runtime-timeout 'https://dns.example/dns-query')" = 4s ]
grep -Fq 'for seen in $upstream $inherited' \
	"$root/ikev2-manager-runtime/ikev2-dns-segments.init"

run_system _dns-segment-update set mixed Mixed 1 '.COM, Org' udp load_balance \
	'udp://1.1.1.1:53' '1.1.1.1:53' '' 0
grep -Fxq 'dnsseg_mixed.domains=com org' "$tmp/uci/ikev2-manager"
grep -Fxq 'dnsseg_mixed.https_compat=0' "$tmp/uci/ikev2-manager"
run_system _validate-dns-segments
cp "$tmp/uci/ikev2-manager" "$tmp/before-invalid-compat"
if run_system _dns-segment-update set mixed Mixed 1 'com org' udp load_balance \
	'udp://1.1.1.1:53' '1.1.1.1:53' '' 2 >/dev/null 2>&1; then
	printf 'invalid DNS segment browser compatibility mode was accepted\n' >&2
	exit 1
fi
cmp -s "$tmp/before-invalid-compat" "$tmp/uci/ikev2-manager" || {
	printf 'invalid browser compatibility update was not rolled back\n' >&2
	exit 1
}
cp "$tmp/uci/ikev2-manager" "$tmp/before-invalid-update"
if run_system _dns-segment-update set conflict Conflict 1 'RU' udp load_balance \
	'udp://1.1.1.1:53' '1.1.1.1:53' '' 1 >/dev/null 2>&1; then
	printf 'conflicting DNS segment update was accepted\n' >&2
	exit 1
fi
cmp -s "$tmp/before-invalid-update" "$tmp/uci/ikev2-manager" || {
	printf 'failed DNS segment update was not rolled back\n' >&2
	exit 1
}

cp "$tmp/uci/ikev2-manager" "$tmp/before-overlap-update"
if run_system _dns-segment-update set overlap Overlap 1 'shop.ru' udp load_balance \
	'udp://1.1.1.1:53' '1.1.1.1:53' '' 1 >/dev/null 2>&1; then
	printf 'parent-child DNS suffix overlap was accepted\n' >&2
	exit 1
fi
cmp -s "$tmp/before-overlap-update" "$tmp/uci/ikev2-manager" || {
	printf 'overlapping DNS segment update was not rolled back\n' >&2
	exit 1
}

cat >>"$tmp/uci/ikev2-manager" <<'EOF'
dnsseg_duplicate=dns_segment
dnsseg_duplicate.name=duplicate
dnsseg_duplicate.enabled=1
dnsseg_duplicate.domains=net
dnsseg_duplicate.protocol=udp
dnsseg_duplicate.upstream_mode=load_balance
dnsseg_duplicate.upstream=udp://1.1.1.1:53
dnsseg_duplicate.bootstrap=1.1.1.1:53
dnsseg_duplicate.port=5550
EOF
if run_system _validate-dns-segments >/dev/null 2>&1; then
	printf 'duplicate DNS segment listener port was accepted\n' >&2
	exit 1
fi

sed 's/dnsseg_duplicate.port=5550/dnsseg_duplicate.port=5554/; s/dnsseg_duplicate.domains=net/dnsseg_duplicate.domains=RU/' \
	"$tmp/uci/ikev2-manager" >"$tmp/uci/ikev2-manager.duplicate-suffix"
mv "$tmp/uci/ikev2-manager.duplicate-suffix" "$tmp/uci/ikev2-manager"
if run_system _validate-dns-segments >/dev/null 2>&1; then
	printf 'duplicate DNS suffix was accepted\n' >&2
	exit 1
fi

sed 's/dnsseg_duplicate.domains=RU/dnsseg_duplicate.domains=рф/' \
	"$tmp/uci/ikev2-manager" >"$tmp/uci/ikev2-manager.invalid"
mv "$tmp/uci/ikev2-manager.invalid" "$tmp/uci/ikev2-manager"
if run_system _validate-dns-segments >/dev/null 2>&1; then
	printf 'non-punycode DNS suffix was accepted\n' >&2
	exit 1
fi

: >"$tmp/uci/ikev2-manager"
i=0
while [ "$i" -lt 9 ]; do
	cat >>"$tmp/uci/ikev2-manager" <<EOF
dnsseg_limit_$i=dns_segment
dnsseg_limit_$i.name=limit_$i
dnsseg_limit_$i.enabled=1
dnsseg_limit_$i.domains=segment$i.example
dnsseg_limit_$i.protocol=udp
dnsseg_limit_$i.upstream_mode=load_balance
dnsseg_limit_$i.upstream=udp://1.1.1.1:53
dnsseg_limit_$i.bootstrap=1.1.1.1:53
dnsseg_limit_$i.port=$((5550 + i))
EOF
	i=$((i + 1))
done
if run_system _validate-dns-segments >/dev/null 2>&1; then
	printf 'more than eight enabled DNS segments were accepted\n' >&2
	exit 1
fi

grep -Fq 'config_foreach start_segment dns_segment' \
	"$root/ikev2-manager-runtime/ikev2-dns-segments.init"
grep -Fq 'procd_append_param command --http3' \
	"$root/ikev2-manager-runtime/ikev2-dns-segments.init"
grep -Fq 'procd_append_param command -f' \
	"$root/ikev2-manager-runtime/ikev2-dns-segments.init"
grep -Fq -- '--upstream-mode "$mode" --timeout 3s' \
	"$root/ikev2-manager-runtime/ikev2-dns-segments.init"
grep -Fq 'procd_set_param user dnsproxy' \
	"$root/ikev2-manager-runtime/ikev2-dns-segments.init"
if grep -Fq -- '--cache-optimistic' \
	"$root/ikev2-manager-runtime/ikev2-dns-segments.init"; then
	printf 'segment resolver still enables an optimistic cache\n' >&2
	exit 1
fi
grep -Fq 'ikev2-dns-segments.init' "$root/Makefile"

# An empty segment fallback inherits the global fallback group and then the
# global primary group, so the interface reports the effective list instead of
# leaving an empty field to be read as "no fallback".
grep -Fq 'dns_segment_effective_fallback()' \
	"$root/ikev2-manager-runtime/ikev2-manager-system.sh"
grep -Fq 'fallback_effective=%s' \
	"$root/ikev2-manager-runtime/ikev2-manager-system.sh"
grep -Fq 'inherits_fallback=%s' \
	"$root/ikev2-manager-runtime/ikev2-manager-system.sh"
grep -Fq 'item.fallback_effective' "$root/luci-ikev2-manager/client.js"
grep -Fq 'item.inherits_fallback' "$root/luci-ikev2-manager/client.js"
grep -Fq 'fallbackEffective' "$root/luci-ikev2-manager/client.js"

printf 'DNS segment tests OK\n'
