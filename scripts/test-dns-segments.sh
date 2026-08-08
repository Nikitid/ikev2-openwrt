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
dnsseg_national.port=5550
dnsseg_disabled=dns_segment
dnsseg_disabled.name=disabled
dnsseg_disabled.enabled=0
dnsseg_disabled.domains=example.test
dnsseg_disabled.protocol=doh
dnsseg_disabled.upstream_mode=fastest_addr
dnsseg_disabled.upstream=https://dns.example/dns-query
dnsseg_disabled.bootstrap=1.1.1.1:53
dnsseg_disabled.port=5551
EOF

run_system() {
	UCI_STUB_DIR="$tmp/uci" \
	IKEV2_UCI_CONFIG_DIR="$tmp/config" \
	IKEV2_UCI_BIN="$tmp/bin/uci" \
	IKEV2_RUNTIME_LIB_DIR="$root/ikev2-manager-runtime/lib" \
	IKEV2_SYSTEM_ACTION_STATUS="$tmp/action.status" \
	IKEV2_SYSTEM_ACTION_STATUS_DIR="$tmp/actions" \
	IKEV2_ACTION_LOCK="$tmp/action.lock" \
	IKEV2_ACTION_LOCK_STATUS="$tmp/action.lock.status" \
		sh "$root/ikev2-manager-runtime/ikev2-manager-system.sh" "$@"
}

run_system _validate-dns-segments
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
EOF
run_system _action-run test-dns-segment dns-segment "$tmp/segment-action.in"
[ ! -e "$tmp/segment-action.in" ]
grep -Fxq 'dnsseg_worker.domains=dev' "$tmp/uci/ikev2-manager"
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
printf '%s\n' "$combined" | grep -Fxq '[/ru/su/xn--p1ai/]udp://127.0.0.1:5550'
if printf '%s\n' "$combined" | grep -q 'example.test'; then
	printf 'disabled DNS segment was included in the primary resolver upstreams\n' >&2
	exit 1
fi

run_system _dns-segment-update set mixed Mixed 1 '.COM, Org' udp load_balance \
	'udp://1.1.1.1:53' '1.1.1.1:53'
grep -Fxq 'dnsseg_mixed.domains=com org' "$tmp/uci/ikev2-manager"
run_system _validate-dns-segments
cp "$tmp/uci/ikev2-manager" "$tmp/before-invalid-update"
if run_system _dns-segment-update set conflict Conflict 1 'RU' udp load_balance \
	'udp://1.1.1.1:53' '1.1.1.1:53' >/dev/null 2>&1; then
	printf 'conflicting DNS segment update was accepted\n' >&2
	exit 1
fi
cmp -s "$tmp/before-invalid-update" "$tmp/uci/ikev2-manager" || {
	printf 'failed DNS segment update was not rolled back\n' >&2
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
grep -Fq 'ikev2-dns-segments.init' "$root/Makefile"

printf 'DNS segment tests OK\n'
