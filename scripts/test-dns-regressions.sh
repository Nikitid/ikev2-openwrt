#!/bin/sh

set -eu

root="$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)"
client="$root/luci-ikev2-manager/client.js"
system="$root/ikev2-manager-runtime/ikev2-manager-system.sh"
config="$root/openwrt/files/etc/config/ikev2-manager"
tmp="$(mktemp -d)"
snapshot="/tmp/ikev2-manager-dns-rollback-test-$$"
trap 'rm -rf "$tmp" "$snapshot"' EXIT INT TERM

grep -Fq "configuredDnsValue(dnsValue, 'fallback', 'current_fallback', '')" "$client"
if grep -Fq "dnsValue.fallback || dnsValue.current_fallback" "$client"; then
	printf '%s\n' 'empty managed fallback can still inherit the dnsproxy package default' >&2
	exit 1
fi
grep -Eq "^[[:space:]]*option fallback ''$" "$config"
grep -Eq "^[[:space:]]*option wan_fallback '0'$" "$config"
grep -Fq "dnsWanFallback.checked ? '1' : '0'" "$client"
grep -Fq 'set_uci_list dnsproxy servers fallback "$effective_fallback"' "$system"
grep -Fq "uci set \"\$config.dns.wan_fallback=\$wan_fallback\"" "$system"
grep -Fq "jsonfilter -e '@[\"dns-server\"][*]'" "$system"

# The primary group accepts mixed transports, so the page validates each
# endpoint by its own scheme instead of one protocol chosen for the group.
grep -Fq "throw new Error(_('Invalid DNS upstream'))" "$client"
grep -Fq 'upstream.every(validDnsEndpointAny)' "$client"
grep -Fq 'function validDnsEndpointAny(value)' "$client"
grep -Fq "throw new Error(_('Bootstrap DNS must contain IPv4:port entries or DoH/DoT/DoQ endpoints with a literal IPv4 address'))" "$client"
grep -Fq "throw new Error(_('Invalid fallback DNS endpoint'))" "$client"
# Each segment is edited in its own block, so the three endpoint editors are
# built per block rather than shared by a picker.
grep -Fq 'function segmentBlock(item)' "$client"
segment_block="$(sed -n '/^\t\tfunction segmentBlock(item)/,/^\t\t}$/p' "$client")"
for field in upstream bootstrap fallback; do
	printf '%s\n' "$segment_block" | grep -Fq "var $field = dnsEndpointEditor(" || {
		printf 'segment block does not build its own %s editor\n' "$field" >&2
		exit 1
	}
done
# Presets are offered inside the field being filled, not by a separate picker
# that belonged to a different section.
grep -Fq 'function presetEndpoints(protocol)' "$client"
grep -Fq 'suggest: function(items)' "$client"
grep -Fq "'list': suggestId" "$client"
if grep -Fq 'ikev2-dns-preset-picker' "$client"; then
	printf '%s\n' 'the separate preset picker is back' >&2
	exit 1
fi
grep -Fq "upstream.values().join(' ')" "$client"
grep -Fq "bootstrap.values().join(' ')" "$client"
grep -Fq "fallback.values().join(' ')" "$client"
grep -Fq "httpsCompat.checked ? '1' : '0'" "$client"
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
grep -Fq 'ikev2-domain-router snapshot "$rollback/domain-router"' "$system"
grep -Fq 'ikev2-domain-router restore-snapshot' "$system"
grep -Fq '/tmp/ikev2-manager-dns-disable-rollback-*/domain-router)' \
	"$root/ikev2-manager-runtime/ikev2-domain-router.sh"
grep -Fq 'cp "$destination/config.json" "$destination/config.verified"' \
	"$root/ikev2-manager-runtime/ikev2-domain-router.sh"
grep -Fq 'cmp -s "$source/rules.json" "$source/rules.verified"' \
	"$root/ikev2-manager-runtime/ikev2-domain-router.sh"
grep -Fq '0:1)' "$system"
grep -Fq "uci set dnsproxy.cache.enabled='0'" "$system"
grep -Fq "uci set dnsproxy.cache.cache_optimistic='0'" "$system"

# Rollback restores the saved application model and segment listeners before
# rendering FakeIP, then validates the recovered resolver path.
rollback_body="$tmp/dns-rollback.body"
sed -n '/^rollback_dns_transaction()/,/^}/p' "$system" >"$rollback_body"
app_line="$(grep -n 'uci import "\$config"' "$rollback_body" | head -n1 | cut -d: -f1)"
state_line="$(grep -n 'restore_dns_state "\$rollback" 0' "$rollback_body" | head -n1 | cut -d: -f1)"
segment_line="$(grep -n 'restore_dns_segment_service_state' "$rollback_body" | head -n1 | cut -d: -f1)"
fakeip_line="$(grep -n 'ikev2-domain-router refresh' "$rollback_body" | head -n1 | cut -d: -f1)"
probe_line="$(grep -n 'dns_query_ok' "$rollback_body" | head -n1 | cut -d: -f1)"
[ "$app_line" -lt "$state_line" ] && [ "$state_line" -lt "$segment_line" ] &&
	[ "$segment_line" -lt "$fakeip_line" ] && [ "$fakeip_line" -lt "$probe_line" ]
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
grep -Fq "die 'Bootstrap DNS must contain IPv4:port entries or DoH/DoT/DoQ endpoints with a literal IPv4 address'" "$system"
# A bootstrap entry must never need a resolver of its own: only literal IPv4
# authorities are accepted, so the ladder does not rest on plaintext UDP/53.
grep -Fq 'valid_dns_bootstrap_literal()' "$system"
grep -Fq 'valid_dns_ipv4 "$host" || return 1' "$system"
# The recovery path is proven before it is committed to.
grep -Fq 'dns_group_answers()' "$system"
grep -Fq "die 'The fallback resolver group did not answer; it cannot recover a failed primary group'" "$system"
# Ordinary names may be resolved through the tunnel-bound resolver instead of
# the WAN one. It is opt-in, refuses to engage without the outbound client, and
# rolls back when the refreshed runtime cannot resolve.
grep -Fq 'final_server=ikev2-upstream' \
	"$root/ikev2-manager-runtime/ikev2-domain-router.sh"
grep -Fq '"final": "$final_server",' \
	"$root/ikev2-manager-runtime/ikev2-domain-router.sh"
grep -Fq 'set_tunnel_resolve()' "$root/ikev2-manager-runtime/ikev2-domain-router.sh"
grep -Fq "die 'Enable the outbound tunnel before resolving ordinary names through it'" \
	"$root/ikev2-manager-runtime/ikev2-domain-router.sh"
grep -Fq 'tunnel-resolve) init_config; with_lock set_tunnel_resolve' \
	"$root/ikev2-manager-runtime/ikev2-domain-router.sh"
grep -Fq '"/usr/libexec/ikev2-domain-router tunnel-resolve *"' \
	"$root/luci-ikev2-manager/acl.json"
grep -Fq 'tunnel_resolve=' "$root/ikev2-manager-runtime/ikev2-manager-system.sh"
# The flag is reachable from the page, and its consequence is stated there.
grep -Fq "[ 'tunnel-resolve', wanted ]" "$client"
grep -Fq 'Resolve all names through the tunnel' "$client"
grep -Fq 'it also removes the fallback group' "$client"
grep -Fq 'Resolve all names through the tunnel' "$root/luci-ikev2-manager/shared.js"
# The tunnel DNS block applies on its own; an unchanged path is not re-applied.
grep -Fq 'tunnelDnsApply.addEventListener' "$client"
grep -Fq "writeClientInput('save')" "$client"
grep -Fq 'if (wanted === applied)' "$client"
# Segments are their own section and say so when the router resolver is bypassed.
grep -Fq "common.section(_('Destination DNS segments')" "$client"
grep -Fq 'routerDnsBypassNote' "$client"
if grep -Fq "E('summary', {}, [ _('Destination DNS segments') ])" "$client"; then
	printf '%s\n' 'destination segments are still hidden behind a disclosure' >&2
	exit 1
fi

# The stored timeout is a request; the effective one is reported beside it.
grep -Fq 'timeout_effective=' "$system"
grep -Fq 'dns_runtime_timeout "$current_fallback"' "$system"
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
cat >"$tmp/bin/sing-box" <<'EOF'
#!/bin/sh
[ "${1:-}" = check ] && [ "${2:-}" = -c ] && [ -s "${3:-}" ]
EOF
chmod 755 "$tmp/bin/uci"
chmod 755 "$tmp/bin/sing-box"
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

# A DNS transaction captures an independently verified last-known-good runtime.
# Corrupting either saved file must make the fallback reject the snapshot before
# it can replace the active configuration.
PATH="$tmp/bin:$PATH" \
IKEV2_RUNTIME_LIB_DIR="$root/ikev2-manager-runtime/lib" \
IKEV2_DOMAIN_CONFIG="$tmp/domain-router.json" \
IKEV2_DOMAIN_RULESET="$tmp/domain-router-rules.json" \
IKEV2_DOMAIN_LOCK="$tmp/domain-router.lock" \
	sh "$root/ikev2-manager-runtime/ikev2-domain-router.sh" \
		snapshot "$snapshot/domain-router"
cmp -s "$snapshot/domain-router/config.json" \
	"$snapshot/domain-router/config.verified"
printf '\n' >>"$snapshot/domain-router/rules.json"
if PATH="$tmp/bin:$PATH" \
   IKEV2_RUNTIME_LIB_DIR="$root/ikev2-manager-runtime/lib" \
   IKEV2_DOMAIN_CONFIG="$tmp/domain-router.json" \
   IKEV2_DOMAIN_RULESET="$tmp/domain-router-rules.json" \
   IKEV2_DOMAIN_LOCK="$tmp/domain-router.lock" \
	sh "$root/ikev2-manager-runtime/ikev2-domain-router.sh" \
		restore-snapshot "$snapshot/domain-router"; then
	printf '%s\n' 'corrupt FakeIP runtime snapshot was accepted' >&2
	exit 1
fi
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
	([.outbounds[] | select(.tag == "ikev2-out") | .domain_resolver] ==
	 [{"server":"ikev2-upstream","strategy":"ipv4_only"}]) and
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

# A resolver-specific alternate success is not enough to restart sing-box when
# unrelated HTTPS traffic cannot cross the tunnel. This is a tunnel outage, not
# a reason to change DNS provider.
cat >"$tmp/probe-bin/curl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$IKEV2_TEST_CURL_LOG"
case "$*" in *dns.cloudflare.com/dns-query*) exit 0 ;; *) exit 1 ;; esac
EOF
chmod 755 "$tmp/probe-bin/curl"
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
grep -Fq 'checkip.amazonaws.com' "$tmp/curl.log"

# A recently abandoned endpoint needs stronger evidence before switching back,
# preventing alternating transient successes from repeatedly restarting active
# proxied connections.
now="$(date +%s)"
cat >"$tmp/tunnel-dns.state" <<EOF
selected=https://dns.google/dns-query
failures=1
bootstrap=8.8.8.8:53
candidate=0
switched_at=$now
previous=https://dns.cloudflare.com/dns-query
configured=https://dns.google/dns-query https://dns.cloudflare.com/dns-query
configured_bootstrap=8.8.8.8:53 8.8.4.4:53 1.1.1.1:53 1.0.0.1:53
EOF
: >"$tmp/curl.log"
PATH="$tmp/probe-bin:$PATH" \
IKEV2_TEST_CURL_LOG="$tmp/curl.log" \
IKEV2_RUNTIME_LIB_DIR="$root/ikev2-manager-runtime/lib" \
IKEV2_DOMAIN_LOCK="$tmp/probe-domain.lock" \
IKEV2_TUNNEL_DNS_STATE="$tmp/tunnel-dns.state" \
	sh "$root/ikev2-manager-runtime/ikev2-domain-router.sh" tunnel-dns-check
grep -Fxq 'selected=https://dns.google/dns-query' "$tmp/tunnel-dns.state"
grep -Fxq 'failures=2' "$tmp/tunnel-dns.state"
if grep -Fq 'dns.cloudflare.com/dns-query' "$tmp/curl.log"; then
	printf '%s\n' 'tunnel DNS cooldown probed the previous endpoint too early' >&2
	exit 1
fi
grep -Fq 'bounded_nslookup "$host" "$resolver"' \
	"$root/ikev2-manager-runtime/ikev2-domain-router.sh"
grep -Fq 'IKEV2_DOMAIN_LOCK_WAIT_SECONDS:-5' \
	"$root/ikev2-manager-runtime/ikev2-domain-router.sh"
grep -Fq 'if action_lock_busy; then' \
	"$root/ikev2-manager-runtime/ikev2-health.sh"
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

# The public DNS-buffer diagnostic combines the bounded nftables source
# counters with sing-box's current log-ring count without changing runtime.
cat >"$tmp/bin/device-routing" <<'EOF'
#!/bin/sh
[ "${1:-}" = dns-malformed-stats ] || exit 2
printf '%s\n' 'state=active' 'packets=5' 'bytes=80' \
	'source=192.0.2.20 packets=5 bytes=80'
EOF
cat >"$tmp/bin/logread" <<'EOF'
#!/bin/sh
printf '%s\n' \
	'user.notice unrelated: entry' \
	'daemon.err sing-box: dns: buffer size too small' \
	'daemon.err sing-box: dns: buffer size too small'
EOF
chmod 755 "$tmp/bin/device-routing" "$tmp/bin/logread"
dns_buffer_status="$(PATH="$tmp/bin:$PATH" \
	IKEV2_DEVICE_RUNTIME_HELPER="$tmp/bin/device-routing" \
	IKEV2_RUNTIME_LIB_DIR="$root/ikev2-manager-runtime/lib" \
	sh "$root/ikev2-manager-runtime/ikev2-manager-system.sh" dns-buffer-status)"
printf '%s\n' "$dns_buffer_status" | grep -Fxq 'state=active'
printf '%s\n' "$dns_buffer_status" | grep -Fxq 'packets=5'
printf '%s\n' "$dns_buffer_status" |
	grep -Fxq 'source=192.0.2.20 packets=5 bytes=80'
printf '%s\n' "$dns_buffer_status" | grep -Fxq 'singbox_errors=2'

# The WAN resolvers join the fallback group; they are not a further tier. The
# page said otherwise, which promised a priority the runtime never had.
if grep -Fq 'only when the configured resolver group fails' \
	"$client" "$root/luci-ikev2-manager/shared.js"; then
	printf '%s\n' 'WAN fallback is still described as a separate tier' >&2
	exit 1
fi
grep -Fq 'They are not a further tier' "$client"

# Pause is the reversible counterpart of removing managed mode: it must stop the
# three things that put traffic into the tunnel and delete nothing.
grep -Fq 'pause_routing_impl()' "$system"
grep -Fq 'resume_routing_impl()' "$system"
grep -Fq 'pause_routing()' "$root/ikev2-manager-runtime/ikev2-domain-router.sh"
if sed -n '/^pause_routing_impl()/,/^}/p' "$system" |
	grep -Eq 'uci -q delete|remove_managed|apk del'; then
	printf '%s\n' 'pause must not delete configuration' >&2
	exit 1
fi
sed -n '/^pause_routing_impl()/,/^}/p' "$system" | grep -Fq 'pbr.$policy.enabled=0'
sed -n '/^resume_routing_impl()/,/^}/p' "$system" | grep -Fq 'pbr.$policy.enabled=1'
# The engine setting must survive a pause, or resume would restore a different mode.
if sed -n '/^pause_routing()/,/^}/p' "$root/ikev2-manager-runtime/ikev2-domain-router.sh" |
	grep -Fq 'domains.engine'; then
	printf '%s\n' 'pause must not change the domain routing engine' >&2
	exit 1
fi
grep -Fq '"/usr/libexec/ikev2-manager-system routing-pause-async"' "$root/luci-ikev2-manager/acl.json"
grep -Fq 'Pause tunnel routing' "$root/luci-ikev2-manager/shared.js"
# The page reads the paused flag from show_config, so it has to be emitted there
# and not from some other reporter that happens to share the same first line.
sed -n '/^show_config()/,/^}/p' "$system" | grep -Fq 'routing_paused=%s'

# with_lock runs its first argument as a command. Passing an action label there
# makes the shell look for a program with that name, and the verb fails at run
# time while every static check passes.
router="$root/ikev2-manager-runtime/ikev2-domain-router.sh"
grep -oE 'with_lock [a-z_]+' "$router" | awk '{ print $2 }' | sort -u |
	while IFS= read -r target; do
		[ -n "$target" ] || continue
		grep -q "^${target}() {" "$router" || {
			printf 'with_lock target is not a function: %s\n' "$target" >&2
			exit 1
		}
	done || exit 1

# A failed pause must not leave the policies disabled while interception runs.
grep -Fq 'undo_routing_pause()' "$system"
sed -n '/^pause_routing_impl()/,/^}/p' "$system" | grep -Fq 'undo_routing_pause'

# The health watcher repairs the FakeIP runtime and device policy every cycle.
# Without a pause guard it restores exactly what pause stopped, and the pause
# reports success while traffic keeps using the tunnel.
health="$root/ikev2-manager-runtime/ikev2-health.sh"
grep -Fq 'ikev2-manager.domains.paused' "$health"
paused_line="$(grep -n 'ikev2-manager.domains.paused' "$health" | head -n1 | cut -d: -f1)"
ensure_line="$(grep -n 'ikev2-domain-router ensure' "$health" | head -n1 | cut -d: -f1)"
[ "$paused_line" -lt "$ensure_line" ] || {
	printf '%s\n' 'health watcher repairs FakeIP before checking for a pause' >&2
	exit 1
}

# Resume restarts sing-box; its listener binds before it can answer. A single
# probe there reported failure for a resolver that came up moments later.
sed -n '/^resume_routing()/,/^}/p' "$router" | grep -Fq 'while ! validate_dns_server'

printf '%s\n' 'DNS and reliable-mode regression checks OK'
