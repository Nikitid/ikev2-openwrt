#!/bin/sh

set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM
mkdir -p "$tmp/bin" "$tmp/uci"

grep -Fq 'if [ "$(defaultv dns managed 0)" = 1 ]; then' \
	"$root/ikev2-manager-runtime/ikev2-manager-system.sh"
grep -Fq 'apply_saved_dns || return 1' \
	"$root/ikev2-manager-runtime/ikev2-manager-system.sh"

cp "$root/scripts/uci-stub.sh" "$tmp/bin/uci"
cat >"$tmp/bin/domain-router" <<'EOF'
#!/bin/sh
[ "${1:-}" = refresh ] || exit 1
printf '%s\n' refresh >>"$TEST_DOMAIN_ROUTER_LOG"
[ "${TEST_DOMAIN_ROUTER_FAIL:-0}" != 1 ]
EOF
cat >"$tmp/bin/device-runtime" <<'EOF'
#!/bin/sh
[ "${1:-}" = sync ] || exit 1
[ "${TEST_DEVICE_SYNC_FAIL:-0}" != 1 ]
EOF
chmod 755 "$tmp/bin/uci" "$tmp/bin/domain-router" "$tmp/bin/device-runtime"

cat >"$tmp/uci/ikev2-manager" <<'EOF'
globals=globals
globals.configured=1
domains=domains
domains.engine=fakeip
EOF
TEST_DOMAIN_ROUTER_LOG="$tmp/domain-router.log"
export TEST_DOMAIN_ROUTER_LOG

write_firewall() {
	cat >"$tmp/uci/firewall" <<'EOF'
ikev2pbr_dns_lan=redirect
ikev2pbr_dns_lan.src=lan
ikev2pbr_dns_in=redirect
ikev2pbr_dns_in.src=ikev2in
ikev2pbr_dot_lan=rule
ikev2pbr_dot_lan.src=lan
ikev2pbr_dot_in=rule
ikev2pbr_dot_in.src=ikev2in
ikev2pbr_in_dns=rule
ikev2pbr_in_dns.src=ikev2in
unrelated=rule
unrelated.name=keep
EOF
}

run_reconcile() {
	PATH="$tmp/bin:$PATH" \
	UCI_STUB_DIR="$tmp/uci" \
	IKEV2_UCI_CONFIG_DIR="$tmp/uci" \
	IKEV2_UCI_BIN="$tmp/bin/uci" \
	IKEV2_DEVICE_RUNTIME_HELPER="$tmp/bin/device-runtime" \
	IKEV2_DOMAIN_ROUTER_HELPER="$tmp/bin/domain-router" \
	IKEV2_RUNTIME_LIB_DIR="$root/ikev2-manager-runtime/lib" \
		sh "$root/ikev2-manager-runtime/ikev2-manager-system.sh" _upgrade-reconcile
}

write_firewall
run_reconcile
[ "$(wc -l <"$TEST_DOMAIN_ROUTER_LOG" | tr -d ' ')" = 1 ]
if grep -Eq '^ikev2pbr_(dns|dot)_' "$tmp/uci/firewall"; then
	printf '%s\n' 'obsolete DNS/DoT firewall sections survived upgrade reconcile' >&2
	exit 1
fi
grep -Fxq 'ikev2pbr_in_dns=rule' "$tmp/uci/firewall"
grep -Fxq 'unrelated.name=keep' "$tmp/uci/firewall"

# A replacement runtime failure must leave the old UCI state intact. This is
# the no-outage guarantee: retirement happens only after the atomic nft load.
write_firewall
if TEST_DEVICE_SYNC_FAIL=1 run_reconcile >/dev/null 2>&1; then
	printf '%s\n' 'failed replacement runtime was reported as reconciled' >&2
	exit 1
fi
grep -Fxq 'ikev2pbr_dns_lan=redirect' "$tmp/uci/firewall"
grep -Fxq 'ikev2pbr_dot_lan=rule' "$tmp/uci/firewall"

# A failed DNS-policy refresh is reported before any obsolete firewall state
# is retired. The domain helper owns restoration of its generated config and
# process, while this reconciler leaves persistent UCI untouched.
write_firewall
if TEST_DOMAIN_ROUTER_FAIL=1 run_reconcile >/dev/null 2>&1; then
	printf '%s\n' 'failed Reliable-mode refresh was reported as reconciled' >&2
	exit 1
fi
grep -Fxq 'ikev2pbr_dns_lan=redirect' "$tmp/uci/firewall"
grep -Fxq 'ikev2pbr_dot_lan=rule' "$tmp/uci/firewall"

printf '%s\n' 'upgrade reconcile tests OK'
