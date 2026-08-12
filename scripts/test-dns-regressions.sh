#!/bin/sh

set -eu

root="$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)"
client="$root/luci-ikev2-manager/client.js"
system="$root/ikev2-manager-runtime/ikev2-manager-system.sh"
config="$root/openwrt/files/etc/config/ikev2-manager"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM

grep -Fq "configuredDnsValue(dnsValue, 'fallback', 'current_fallback', '')" "$client"
if grep -Fq "dnsValue.fallback || dnsValue.current_fallback" "$client"; then
	printf '%s\n' 'empty managed fallback can still inherit the dnsproxy package default' >&2
	exit 1
fi
grep -Eq "^[[:space:]]*option fallback ''$" "$config"

grep -Fq "throw new Error(_('Invalid DNS upstream for the selected protocol'))" "$client"
grep -Fq "throw new Error(_('Bootstrap DNS must contain IPv4:port entries'))" "$client"
grep -Fq "throw new Error(_('Invalid fallback DNS endpoint'))" "$client"
grep -Fq "segmentUpstream = dnsEndpointEditor" "$client"
grep -Fq "segmentBootstrap = dnsEndpointEditor" "$client"
grep -Fq "rebuildSegmentProviders('yandex')" "$client"
grep -Fq "segmentUpstream.values().join(' ')" "$client"
grep -Fq "segmentBootstrap.values().join(' ')" "$client"
grep -Fq "segmentHttpsCompat.checked ? '1' : '0'" "$client"
grep -Fq "segmentAddProvider.addEventListener('click'" "$client"
grep -Fq "dns_error_file=\"/tmp/ikev2-dns-action-\$id.error\"" "$system"
grep -Fq '[ "$managed" = 0 ] || valid_name "$provider"' "$system"
grep -Fq "_dns-apply-inner 0 '' '' '' '' '' ''" "$system"
grep -Fq '127.0.0.42 | 127.0.0.42#53) uses_fakeip=1' "$system"
grep -Fq 'repair_dns_original_snapshot ||' "$system"
grep -Fq "die 'Saved original DNS state is incomplete; managed DNS remains configured'" "$system"

grep -Fq "dot) prefix='tls://'" "$system"
if grep -Fq "prefix='tls:'" "$system"; then
	printf '%s\n' 'malformed DoT endpoints are accepted' >&2
	exit 1
fi

# The outbound IKEv2 path currently has only IPv4 traffic selectors. Keep DNS
# bootstrap transport on IPv4, suppress AAAA in Reliable mode, and retain the
# IPv6 PBR terminal route so selected AAAA cannot fall through to WAN.
grep -Fq '"strategy": "ipv4_only"' \
	"$root/ikev2-manager-runtime/ikev2-domain-router.sh"
grep -Fq "die 'Bootstrap DNS must contain IPv4:port entries'" "$system"
grep -Fq "uci set pbr.config.ipv6_enabled='1'" "$system"
grep -Fq 'ip -6 route replace unreachable default metric 32767' \
	"$root/ikev2-manager-runtime/pbr.user.ikev2out"

grep -Fq "field in engine service dnsmasq_upstream dnsmasq_cache nft rule healthy state message" "$system"
grep -Fq "Reliable-mode nftables rules are missing." \
	"$root/luci-ikev2-manager/setup.js"

# Keep shell control functions outside the nftables heredoc. A function body in
# this payload is syntactically valid shell but makes every nft-start fail.
sed -n '/if ! nft -f - <<EOF/,/^EOF$/p' \
	"$root/ikev2-manager-runtime/ikev2-domain-router.sh" >"$tmp/nft-payload"
grep -Fq 'table inet $nft_table {' "$tmp/nft-payload"
if grep -Eq '^(set_router_traffic|set_log_level|resolver_diagnostic)\(\)' \
	"$tmp/nft-payload"; then
	printf '%s\n' 'domain-router shell function leaked into nftables input' >&2
	exit 1
fi
grep -Eq '^set_router_traffic\(\)' "$root/ikev2-manager-runtime/ikev2-domain-router.sh"
grep -Eq '^resolver_diagnostic\(\)' "$root/ikev2-manager-runtime/ikev2-domain-router.sh"

# DNS interception and DoT blocking use the project's atomic nftables runtime.
# fw4 redirect `src_ip` is scalar, so rendering one negated list item per
# excluded device makes fw4 silently discard the whole redirect.
device_runtime="$root/ikev2-manager-runtime/ikev2-device-routing.sh"
if grep -Eq 'firewall\.ikev2pbr_dns_|add_list .*src_ip=!' "$system"; then
	printf '%s\n' 'legacy list-valued fw4 DNS redirects are still rendered' >&2
	exit 1
fi
grep -Fq 'write_set dns_bypass_ipv4 "$dns"' "$device_runtime"
grep -Fq "printf '%s\\n' 'ipsec-in' >>\"\$sources\"" "$device_runtime"
grep -Fq 'iifname @source_ifaces ip saddr != @dns_bypass_ipv4' "$device_runtime"
grep -Fq 'redirect to :53 comment "ikev2-device:dns-enforce"' "$device_runtime"
grep -Fq 'oifname @wan_ifaces ip saddr != @dns_bypass_ipv4' "$device_runtime"
grep -Fq 'reject comment "ikev2-device:dot-block"' "$device_runtime"
grep -Fq 'must not be a list|skipped due to invalid options|Section .* skipped' "$system"
grep -Fq 'device_policy_runtime=missing' "$system"
grep -Fq 'IKEV2_DOCTOR_ALLOW_RUNTIME_REPAIR=1' "$system"
grep -Fq 'nft list chain inet ikev2_device_policy dns_prerouting' \
	"$root/luci-ikev2-manager/ikev2-manager.sh"
grep -Fq 'nft list chain inet ikev2_device_policy dot_forward' \
	"$root/luci-ikev2-manager/ikev2-manager.sh"

mkdir -p "$tmp/bin" "$tmp/work"
mkdir -p "$tmp/state-bin" "$tmp/uci-state"
cp "$root/scripts/uci-stub.sh" "$tmp/state-bin/uci"
chmod 755 "$tmp/state-bin/uci"
cat >"$tmp/uci-state/ikev2-manager" <<'EOF'
domains=domains
domains.engine=nftset
domains.log_level=warn
domains.route_router_traffic=0
EOF
PATH="$tmp/state-bin:$PATH" UCI_STUB_DIR="$tmp/uci-state" \
IKEV2_RUNTIME_LIB_DIR="$root/ikev2-manager-runtime/lib" \
IKEV2_DOMAIN_LOCK="$tmp/domain-router.lock" \
	sh "$root/ikev2-manager-runtime/ikev2-domain-router.sh" router-traffic 1
grep -Fxq 'domains.route_router_traffic=1' "$tmp/uci-state/ikev2-manager"
PATH="$tmp/state-bin:$PATH" UCI_STUB_DIR="$tmp/uci-state" \
IKEV2_RUNTIME_LIB_DIR="$root/ikev2-manager-runtime/lib" \
IKEV2_DOMAIN_LOCK="$tmp/domain-router.lock" \
	sh "$root/ikev2-manager-runtime/ikev2-domain-router.sh" log-level error
grep -Fxq 'domains.log_level=error' "$tmp/uci-state/ikev2-manager"

cat >"$tmp/bin/uci" <<'EOF'
#!/bin/sh
[ "${1:-}" != -q ] || shift
command="${1:-}"
shift || true
case "$command:$*" in
	'get:ikev2-manager.domains') echo domains ;;
	'get:ikev2-manager.domains.engine') echo fakeip ;;
	'get:ikev2-manager.domains.fakeip_ttl') echo 60 ;;
	'get:ikev2-manager.domains.cache_path') echo /tmp/fakeip-cache.db ;;
	'get:ikev2-manager.domains.dns_saved') echo 1 ;;
	'get:ikev2-manager.domains.prev_server') echo 1.1.1.1#53 ;;
	'get:ikev2-manager.domains.prev_noresolv') echo 1 ;;
	'get:ikev2-manager.globals.source_include_vpn') echo 0 ;;
	'get:ikev2-manager.server.enabled') echo 0 ;;
	'get:ikev2-manager.dnsseg_national.enabled') echo 1 ;;
	'get:ikev2-manager.dnsseg_national.https_compat') echo 1 ;;
	'get:ikev2-manager.dnsseg_national.domains') echo 'ru su xn--p1ai' ;;
	'get:ikev2-manager.dnsseg_private.enabled') echo 1 ;;
	'get:ikev2-manager.dnsseg_private.https_compat') echo 0 ;;
	'get:ikev2-manager.dnsseg_private.domains') echo 'internal.example' ;;
	'get:pbr.ikev2pbr_domains.src_addr') echo 192.168.1.0/24 ;;
	'show:ikev2-manager')
		echo 'ikev2-manager.dnsseg_national=dns_segment'
		echo 'ikev2-manager.dnsseg_private=dns_segment'
		;;
	'show:pbr') ;;
	*) exit 1 ;;
esac
EOF
chmod 755 "$tmp/bin/uci"
printf '%s\n' example.com >"$tmp/domains.txt"
PATH="$tmp/bin:$PATH" \
IKEV2_RUNTIME_LIB_DIR="$root/ikev2-manager-runtime/lib" \
IKEV2_DOMAIN_FILE="$tmp/domains.txt" \
IKEV2_DOMAIN_CONFIG="$tmp/domain-router.json" \
IKEV2_DOMAIN_RULESET="$tmp/domain-router-rules.json" \
IKEV2_DOMAIN_WORK_DIR="$tmp/work" \
	sh "$root/ikev2-manager-runtime/ikev2-domain-router.sh" render
jq -e . "$tmp/domain-router.json" >/dev/null
[ -z "${IKEV2_TEST_SING_BOX:-}" ] ||
	"$IKEV2_TEST_SING_BOX" check -c "$tmp/domain-router.json"
# FakeIP is meaningful only for address lookups. Sending NS, SRV, PTR, TXT or
# other record types to it makes sing-box reject otherwise valid DNS traffic.
jq -e '
	[.dns.rules[] |
		select(.action == "route" and .server == "fakeip")] ==
	[{"rule_set":["ikev2-domains"],"query_type":["A","AAAA"],
	  "action":"route","server":"fakeip","rewrite_ttl":60}]
' "$tmp/domain-router.json" >/dev/null
# HTTPS/SVCB suppression prevents selected names from bypassing FakeIP through
# address hints. Segment compatibility also isolates authoritative servers that
# mishandle HTTPS records, while direct domains outside those suffixes retain
# modern HTTPS DNS responses.
jq -e '
	[.dns.rules[] | select(.query_type == ["HTTPS"])] ==
	[{"rule_set":["ikev2-domains"],"query_type":["HTTPS"],"action":"reject"},
	 {"domain_suffix":["ru","su","xn--p1ai"],"query_type":["HTTPS"],"action":"reject"}]
' "$tmp/domain-router.json" >/dev/null
if jq -e '.dns.rules[] |
	select(.query_type == ["HTTPS"] and
		(has("rule_set") | not) and (has("domain_suffix") | not))' \
	"$tmp/domain-router.json" >/dev/null; then
	printf '%s\n' 'Reliable mode still rejects HTTPS records globally' >&2
	exit 1
fi
grep -Fq '"tag": "tproxy-direct-in"' "$tmp/domain-router.json"
grep -A4 -F '"inbound": [ "tproxy-direct-in" ]' "$tmp/domain-router.json" |
	grep -Fq '"outbound": "direct-out"'

printf '%s\n' 'DNS and reliable-mode regression checks OK'
