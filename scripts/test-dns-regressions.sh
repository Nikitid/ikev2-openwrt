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
grep -Fq "segmentFallback = dnsEndpointEditor" "$client"
grep -Fq "rebuildSegmentProviders('yandex')" "$client"
grep -Fq "segmentUpstream.values().join(' ')" "$client"
grep -Fq "segmentBootstrap.values().join(' ')" "$client"
grep -Fq "segmentFallback.values().join(' ')" "$client"
grep -Fq "segmentHttpsCompat.checked ? '1' : '0'" "$client"
grep -Fq "segmentAddProvider.addEventListener('click'" "$client"
grep -Fq "tunnelDnsUpstream = dnsEndpointEditor" "$client"
grep -Fq "tunnelDnsBootstrap = dnsEndpointEditor" "$client"
grep -Fq "tunnelUpstream.join(' ')" "$client"
grep -Fq "tunnelBootstrap.join(' ')" "$client"
grep -Fq 'tunnel-dns-check)' "$root/ikev2-manager-runtime/ikev2-domain-router.sh"
grep -Fq 'refresh-rules)' "$root/ikev2-manager-runtime/ikev2-domain-router.sh"
grep -Fq '"type": "local"' "$root/ikev2-manager-runtime/ikev2-domain-router.sh"
grep -Fq 'ikev2-domain-router tunnel-dns-check' "$root/ikev2-manager-runtime/ikev2-health.sh"
grep -Fq "dns_error_file=\"/tmp/ikev2-dns-action-\$id.error\"" "$system"
grep -Fq '[ "$managed" = 0 ] || valid_name "$provider"' "$system"
grep -Fq "_dns-apply-inner 0 '' '' '' '' '' ''" "$system"
grep -Fq '127.0.0.42 | 127.0.0.42#53) uses_fakeip=1' "$system"
grep -Fq 'repair_dns_original_snapshot ||' "$system"
grep -Fq "die 'Saved original DNS state is incomplete; managed DNS remains configured'" "$system"
grep -Fq '0:1)' "$system"
grep -Fq "uci set dnsproxy.cache.enabled='0'" "$system"
grep -Fq "uci set dnsproxy.cache.cache_optimistic='0'" "$system"
if grep -Fq -- '--cache-optimistic' \
	"$root/ikev2-manager-runtime/ikev2-dns-segments.init"; then
	printf '%s\n' 'destination DNS segments still enable an optimistic cache' >&2
	exit 1
fi

grep -Fq "dot) prefix='tls://'" "$system"
if grep -Fq "prefix='tls:'" "$system"; then
	printf '%s\n' 'malformed DoT endpoints are accepted' >&2
	exit 1
fi

# The outbound IKEv2 path currently has only IPv4 traffic selectors. IPv4-only
# is allowed for the tunnel DNS bootstrap, but never as the global DNS policy.
# Selected AAAA is suppressed by a narrow rule and direct domains retain normal
# IPv6 resolution.
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
	'get:ikev2-manager.domains.cache_capacity') echo 8192 ;;
	'get:ikev2-manager.domains.dns_saved') echo 1 ;;
	'get:ikev2-manager.domains.prev_server') echo 1.1.1.1#53 ;;
	'get:ikev2-manager.domains.prev_noresolv') echo 1 ;;
	'get:ikev2-manager.globals.source_include_vpn') echo 0 ;;
	'get:ikev2-manager.server.enabled') echo 0 ;;
	'get:ikev2-manager.client.enabled') echo 1 ;;
	'get:ikev2-manager.client.tunnel_dns_upstream') echo 'https://dns.google/dns-query https://dns.cloudflare.com/dns-query' ;;
	'get:ikev2-manager.client.tunnel_dns_bootstrap') echo '8.8.8.8:53 8.8.4.4:53 1.1.1.1:53 1.0.0.1:53' ;;
	'get:ikev2-manager.dns.managed') echo 1 ;;
	'get:ikev2-manager.dnsseg_national.enabled') echo 1 ;;
	'get:ikev2-manager.dnsseg_national.https_compat') echo 1 ;;
	'get:ikev2-manager.dnsseg_national.domains') echo 'ru su xn--p1ai' ;;
	'get:ikev2-manager.dnsseg_national.port') echo 5550 ;;
	'get:ikev2-manager.dnsseg_private.enabled') echo 1 ;;
	'get:ikev2-manager.dnsseg_private.https_compat') echo 0 ;;
	'get:ikev2-manager.dnsseg_private.domains') echo 'internal.example' ;;
	'get:ikev2-manager.dnsseg_private.port') echo 5551 ;;
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
IKEV2_TUNNEL_DNS_STATE="$tmp/tunnel-dns.state" \
	sh "$root/ikev2-manager-runtime/ikev2-domain-router.sh" render
jq -e . "$tmp/domain-router.json" >/dev/null
[ -z "${IKEV2_TEST_SING_BOX:-}" ] ||
	"$IKEV2_TEST_SING_BOX" check -c "$tmp/domain-router.json"
# FakeIP is meaningful only for IPv4 address lookups. Sending NS, SRV, PTR,
# TXT or other record types to it makes sing-box reject valid DNS traffic; an
# AAAA answer for a selected name could bypass the IPv4-only tunnel.
jq -e '
	[.dns.rules[] |
		select(.action == "route" and .server == "fakeip")] ==
	[{"rule_set":["ikev2-domains"],"query_type":["A"],
	  "action":"route","server":"fakeip","rewrite_ttl":60}]
' "$tmp/domain-router.json" >/dev/null
jq -e '
	.dns.cache_capacity == 8192 and
	(.dns.strategy == null) and
	([.dns.servers[] | select(.tag == "ikev2-bootstrap")] ==
	 [{"type":"udp","tag":"ikev2-bootstrap","server":"8.8.8.8",
	   "server_port":53,"bind_interface":"ipsec-out"}]) and
	([.dns.servers[] | select(.tag == "ikev2-upstream")] ==
	 [{"type":"https","tag":"ikev2-upstream","server":"dns.google",
	   "server_port":443,"path":"/dns-query",
	   "tls":{"enabled":true,"server_name":"dns.google"},
	   "bind_interface":"ipsec-out",
	   "domain_resolver":{"server":"ikev2-bootstrap","strategy":"ipv4_only"},
	   "connect_timeout":"5s"}]) and
	([.dns.servers[] | select(.tag == "segment-national")] ==
	 [{"type":"udp","tag":"segment-national","server":"127.0.0.1","server_port":5550}]) and
	([.dns.servers[] | select(.tag == "segment-private")] ==
	 [{"type":"udp","tag":"segment-private","server":"127.0.0.1","server_port":5551}]) and
	([.dns.rules[] | select(.server == "segment-national")] ==
	 [{"domain_suffix":["ru","su","xn--p1ai"],"action":"route","server":"segment-national"}]) and
	([.dns.rules[] | select(.server == "segment-private")] ==
	 [{"domain_suffix":["internal.example"],"action":"route","server":"segment-private"}])
' "$tmp/domain-router.json" >/dev/null
jq -e '
	([.outbounds[] | select(.tag == "direct-out") | .domain_resolver] == ["upstream"]) and
	([.outbounds[] | select(.tag == "ikev2-out") | .domain_resolver] == ["ikev2-upstream"]) and
	(.dns.final == "upstream")
' "$tmp/domain-router.json" >/dev/null
# HTTPS/SVCB suppression prevents selected names from bypassing FakeIP through
# address hints. Segment compatibility also isolates authoritative servers that
# mishandle HTTPS records, while direct domains outside those suffixes retain
# modern HTTPS DNS responses.
jq -e '
	[.dns.rules[] | select(.query_type == ["HTTPS"])] ==
	[{"rule_set":["ikev2-domains"],"query_type":["HTTPS"],
	  "action":"predefined","rcode":"NOERROR"},
	 {"domain_suffix":["ru","su","xn--p1ai"],"query_type":["HTTPS"],
	  "action":"predefined","rcode":"NOERROR"}]
' "$tmp/domain-router.json" >/dev/null
jq -e '
	[.dns.rules[] | select(.query_type == ["AAAA"])] ==
	[{"rule_set":["ikev2-domains"],"query_type":["AAAA"],
	  "action":"predefined","rcode":"NOERROR"}]
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
grep -Fq '"tag": "tproxy-router-in"' "$tmp/domain-router.json"
grep -A4 -F '"inbound": [ "tproxy-router-in" ]' "$tmp/domain-router.json" |
	grep -Fq '"outbound": "ikev2-out"'

# A healthy fallback selected by the runtime state must survive a rules rebuild;
# changing the configured ordered list invalidates this state in production.
cat >"$tmp/tunnel-dns.state" <<'EOF'
selected=https://dns.cloudflare.com/dns-query
failures=0
bootstrap=1.1.1.1:53
candidate=0
configured=https://dns.google/dns-query https://dns.cloudflare.com/dns-query
configured_bootstrap=8.8.8.8:53 8.8.4.4:53 1.1.1.1:53 1.0.0.1:53
EOF
PATH="$tmp/bin:$PATH" \
IKEV2_RUNTIME_LIB_DIR="$root/ikev2-manager-runtime/lib" \
IKEV2_DOMAIN_FILE="$tmp/domains.txt" \
IKEV2_DOMAIN_CONFIG="$tmp/domain-router.json" \
IKEV2_DOMAIN_RULESET="$tmp/domain-router-rules.json" \
IKEV2_DOMAIN_WORK_DIR="$tmp/work" \
IKEV2_TUNNEL_DNS_STATE="$tmp/tunnel-dns.state" \
	sh "$root/ikev2-manager-runtime/ikev2-domain-router.sh" render
jq -e '(.dns.servers[] | select(.tag == "ikev2-upstream") |
	.server == "dns.cloudflare.com" and .tls.server_name == "dns.cloudflare.com")' \
	"$tmp/domain-router.json" >/dev/null
jq -e '(.dns.servers[] | select(.tag == "ikev2-bootstrap") |
	.server == "1.1.1.1" and .server_port == 53 and .bind_interface == "ipsec-out")' \
	"$tmp/domain-router.json" >/dev/null

# A total resolver outage checks the active endpoint and only one alternate per
# health iteration. This bounds watcher latency and advances a persistent
# cursor instead of rescanning the first failed fallback forever.
mkdir -p "$tmp/probe-bin"
cp "$tmp/bin/uci" "$tmp/probe-bin/uci"
cat >"$tmp/probe-bin/ip" <<'EOF'
#!/bin/sh
exit 0
EOF
cat >"$tmp/probe-bin/timeout" <<'EOF'
#!/bin/sh
shift
exec "$@"
EOF
cat >"$tmp/probe-bin/nslookup" <<'EOF'
#!/bin/sh
printf '%s\n' 'Address 1: 203.0.113.10'
EOF
cat >"$tmp/probe-bin/curl" <<'EOF'
#!/bin/sh
printf 'attempt\n' >>"$IKEV2_TEST_CURL_LOG"
exit 1
EOF
chmod 755 "$tmp/probe-bin"/*
cat >"$tmp/tunnel-dns.state" <<'EOF'
selected=https://dns.google/dns-query
failures=1
bootstrap=8.8.8.8:53
candidate=0
configured=https://dns.google/dns-query https://dns.cloudflare.com/dns-query
configured_bootstrap=8.8.8.8:53 8.8.4.4:53 1.1.1.1:53 1.0.0.1:53
EOF
: >"$tmp/curl.log"
PATH="$tmp/probe-bin:$PATH" \
IKEV2_TEST_CURL_LOG="$tmp/curl.log" \
IKEV2_RUNTIME_LIB_DIR="$root/ikev2-manager-runtime/lib" \
IKEV2_DOMAIN_LOCK="$tmp/probe-domain.lock" \
IKEV2_TUNNEL_DNS_STATE="$tmp/tunnel-dns.state" \
	sh "$root/ikev2-manager-runtime/ikev2-domain-router.sh" tunnel-dns-check || true
grep -Fxq 'selected=https://dns.google/dns-query' "$tmp/tunnel-dns.state"
grep -Fxq 'failures=2' "$tmp/tunnel-dns.state"
grep -Fxq 'candidate=1' "$tmp/tunnel-dns.state"
[ "$(wc -l <"$tmp/curl.log" | tr -d ' ')" -eq 8 ]
grep -Fq 'bounded_nslookup "$host" "$resolver"' \
	"$root/ikev2-manager-runtime/ikev2-domain-router.sh"
if grep -Fq 'timeout 2 nslookup' \
	"$root/ikev2-manager-runtime/ikev2-domain-router.sh"; then
	printf '%s\n' 'tunnel DNS probe still depends on the optional timeout applet' >&2
	exit 1
fi

# A rejected background launch must not be reported as a successfully queued
# action. Otherwise LuCI polls an action id that can never finish while the
# status file remains stuck in `running`.
cat >"$tmp/bin/start-stop-daemon" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod 755 "$tmp/bin/start-stop-daemon"
if PATH="$tmp/bin:$PATH" \
	IKEV2_RUNTIME_LIB_DIR="$root/ikev2-manager-runtime/lib" \
	IKEV2_DOMAIN_STATE="$tmp/domain-router.status" \
	IKEV2_DOMAIN_LOG="$tmp/domain-router.log" \
	IKEV2_DOMAIN_LOCK="$tmp/domain-router.lock" \
	sh "$root/ikev2-manager-runtime/ikev2-domain-router.sh" \
	activate-async >"$tmp/schedule.out" 2>"$tmp/schedule.err"; then
	printf '%s\n' 'failed domain-router background launch was accepted' >&2
	exit 1
fi
[ ! -s "$tmp/schedule.out" ]
grep -Fxq 'state=error' "$tmp/domain-router.status"
grep -Fq 'message=Unable to start domain-routing action: activate' \
	"$tmp/domain-router.status"

printf '%s\n' 'DNS and reliable-mode regression checks OK'
