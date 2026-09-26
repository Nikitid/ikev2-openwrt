#!/bin/sh
# The application's own policy routing, replacing the pbr package:
#
#   ikev2-routing sync     install or repair; a no-op when nothing changed
#   ikev2-routing check    whether the installed runtime is current
#   ikev2-routing stop     remove everything this owns
#   ikev2-routing status   key=value lines for reports
#
# Selected destinations are marked in an nftables table of their own and
# routed by ip rules on bits no other part of the router uses:
#
#   mark 0x01000000/0x0f000000  table 1601  the tunnel, unreachable without it
#   mark 0x02000000/0x0f000000  table 1602  the WAN, for exclusions
#
# IPv6 destinations of a selected name are marked too, into an IPv6 table
# holding only an unreachable default: the tunnel is IPv4-only, so they fail
# closed and clients fall back to IPv4.
#
# globals.routing_backend chooses who routes: "pbr" (the default) leaves this
# stopped; "overlay" runs it beside PBR at a higher priority, with the domain
# sets copied from PBR's, to compare the two paths on a live router; "native"
# will fill the domain sets from dnsmasq itself; until it does, only overlay
# is accepted.

set -u

config='ikev2-manager'
nft_bin="${IKEV2_NFT:-/usr/sbin/nft}"
ip_bin="${IKEV2_IP:-ip}"
ucode_bin="${IKEV2_UCODE:-ucode}"
table="${IKEV2_ROUTING_TABLE:-ikev2_routing}"
state_file="${IKEV2_ROUTING_STATE:-/var/run/ikev2-routing.state}"
runtime_lib_dir="${IKEV2_RUNTIME_LIB_DIR:-/usr/libexec/ikev2-manager.d}"
service_file="${IKEV2_SERVICE_CIDRS:-/etc/pbr-ikev2-service-cidrs.txt}"
sa_helper="${IKEV2_SA_HELPER:-/usr/libexec/ikev2-sa}"
system_helper="${IKEV2_SYSTEM_HELPER:-/usr/libexec/ikev2-manager-system}"
vip_file="${IKEV2_VIP_FILE:-/var/run/ikev2-vip4}"

mark_mask=0x0f000000
tunnel_mark=0x01000000
# ip prints marks without leading zeros.
rule_mask=0xf000000
rule_tunnel_mark=0x1000000
# The WAN mark, 0x02000000, is for the exclusions moved here next.
rule_wan_mark=0x2000000
tunnel_table=1601
wan_table=1602
# Ahead of PBR (29997-30000), after FakeIP delivery (11000) and every rule the
# system and other VPNs install below 11000.
rule_main=28000
rule_tunnel=28001
rule_wan=28002
# The domain sets are filled by dnsmasq, or copied from PBR in overlay mode.
runtime_volatile_sets='dst4 dst6'

. "$runtime_lib_dir/nft-runtime.sh"
. "$runtime_lib_dir/devices.sh"

die() {
	printf '%s\n' "$*" >&2
	exit 1
}

backend() {
	local value
	value="$(uci -q get "$config.globals.routing_backend" 2>/dev/null || echo pbr)"
	case "$value" in overlay) printf '%s\n' "$value" ;; *) printf 'pbr\n' ;; esac
}

active() {
	[ "$(uci -q get "$config.globals.configured" 2>/dev/null || echo 0)" = 1 ] || return 1
	[ "$(uci -q get "$config.domains.paused" 2>/dev/null || echo 0)" != 1 ] || return 1
	[ "$(backend)" != pbr ]
}

valid_ifname() {
	[ -n "${1:-}" ] && printf '%s\n' "$1" | grep -Eq '^[A-Za-z0-9_.:@-]+$'
}

network_device() {
	local interface="$1" status device
	status="$(ubus call "network.interface.$interface" status 2>/dev/null || true)"
	device="$(printf '%s' "$status" | jsonfilter -e '@.l3_device' 2>/dev/null || true)"
	[ -n "$device" ] || device="$(printf '%s' "$status" | jsonfilter -e '@.device' 2>/dev/null || true)"
	[ -n "$device" ] || device="$(uci -q get "network.$interface.device" 2>/dev/null || true)"
	valid_ifname "$device" && printf '%s\n' "$device"
}

# The devices whose traffic follows the destination lists, one per line.
source_devices() {
	local interface device
	for interface in $(uci -q get "$config.globals.source_interface" 2>/dev/null || true); do
		device="$(network_device "$interface")" ||
			die "Protected network '$interface' has no usable device"
		printf '%s\n' "$device"
	done
	if [ "$(uci -q get "$config.server.enabled" 2>/dev/null || echo 0)" = 1 ] &&
	   [ "$(uci -q get "$config.globals.source_include_vpn" 2>/dev/null || echo 1)" = 1 ]; then
		printf 'ipsec-in\n'
	fi
}

# IPv4 networks and addresses of FILE, one per line, comments dropped.
address_lines() {
	[ -r "$1" ] || return 0
	awk '
		{ sub(/#.*/, ""); gsub(/[ \t\r]/, "") }
		/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(\/[0-9]+)?$/ { print }
	' "$1"
}

elements() {
	awk 'BEGIN { first = 1 } NF { if (!first) printf ", "; printf "%s", $0; first = 0 }' "$1"
}

quoted_elements() {
	awk 'BEGIN { first = 1 } NF { if (!first) printf ", "; printf "\"%s\"", $0; first = 0 }' "$1"
}

# The WAN's IPv4 default, as "via GATEWAY dev DEVICE" or "dev DEVICE".
wan_default() {
	local interface status device gateway
	interface="$(uci -q get "$config.globals.wan_interface" 2>/dev/null || echo wan)"
	status="$(ubus call "network.interface.$interface" status 2>/dev/null || true)"
	device="$(printf '%s' "$status" | jsonfilter -e '@.l3_device' 2>/dev/null || true)"
	valid_ifname "$device" || return 1
	gateway="$(printf '%s' "$status" |
		jsonfilter -e '@.route[@.target="0.0.0.0" && @.mask=0].nexthop' 2>/dev/null | head -n1)"
	case "$gateway" in
		'' | 0.0.0.0) printf 'dev %s\n' "$device" ;;
		*.*.*.*) printf 'via %s dev %s\n' "$gateway" "$device" ;;
		*) return 1 ;;
	esac
}

tunnel_ready() {
	[ -s "$vip_file" ] || return 1
	"$ip_bin" link show ipsec-out 2>/dev/null | grep -q 'UP' || return 1
	"$sa_helper" installed proxy-out proxy4 || return 1
	"$ip_bin" -4 addr show dev ipsec-out 2>/dev/null | grep -Fq "$(cat "$vip_file")/"
}

ensure_rule() {
	local family="$1" priority="$2" selector="$3"
	"$ip_bin" -"$family" rule show 2>/dev/null |
		grep -Eq "^$priority:[[:space:]]+from all $selector\$" && return 0
	while "$ip_bin" -"$family" rule del priority "$priority" 2>/dev/null; do :; done
	# shellcheck disable=SC2086
	"$ip_bin" -"$family" rule add priority "$priority" $selector
}

delete_rules() {
	local family priority
	for family in 4 6; do
		for priority in "$rule_main" "$rule_tunnel" "$rule_wan"; do
			while "$ip_bin" -"$family" rule del priority "$priority" 2>/dev/null; do :; done
		done
	done
}

# Routes first: a rule pointing at a table without its unreachable default
# would let marked traffic fall through to the WAN.
sync_routes() {
	local lan subnet inbound wan
	"$ip_bin" -4 route replace unreachable default metric 32767 table "$tunnel_table" || return 1
	"$ip_bin" -6 route replace unreachable default metric 32767 table "$tunnel_table" 2>/dev/null || :
	# Replies to local and inbound clients stay local whatever is marked.
	while IFS= read -r lan; do
		subnet="$("$ip_bin" -4 route show dev "$lan" scope link 2>/dev/null |
			awk '$1 ~ /^[0-9.]+\/[0-9]+$/ { print $1; exit }')"
		[ -z "$subnet" ] || "$ip_bin" -4 route replace "$subnet" dev "$lan" table "$tunnel_table" || return 1
	done <"$work/sources"
	if [ "$(uci -q get "$config.server.enabled" 2>/dev/null || echo 0)" = 1 ]; then
		inbound="$("$system_helper" gateway-network 2>/dev/null || true)"
		[ -z "$inbound" ] ||
			"$ip_bin" -4 route replace "$inbound" dev ipsec-in table "$tunnel_table" || return 1
	fi
	if tunnel_ready; then
		"$ip_bin" -4 route replace default dev ipsec-out metric 10 table "$tunnel_table" || return 1
	elif "$ip_bin" -4 route show table "$tunnel_table" | grep -q '^default dev ipsec-out'; then
		"$ip_bin" -4 route del default dev ipsec-out metric 10 table "$tunnel_table" || return 1
	fi
	if wan="$(wan_default)"; then
		# shellcheck disable=SC2086
		"$ip_bin" -4 route replace default $wan table "$wan_table" || return 1
	fi
	# A WAN without a default keeps the last one: exclusions then resume the
	# moment it returns instead of taking whatever else routes by default.
}

sync_rules() {
	ensure_rule 4 "$rule_main" 'lookup main suppress_prefixlength 1' &&
		ensure_rule 4 "$rule_tunnel" "fwmark $rule_tunnel_mark/$rule_mask lookup $tunnel_table" &&
		ensure_rule 4 "$rule_wan" "fwmark $rule_wan_mark/$rule_mask lookup $wan_table" &&
		ensure_rule 6 "$rule_main" 'lookup main suppress_prefixlength 1' &&
		ensure_rule 6 "$rule_tunnel" "fwmark $rule_tunnel_mark/$rule_mask lookup $tunnel_table"
}

# The table is changed in place, never recreated: the domain sets hold what
# dnsmasq learned, and a new table would start them empty.
write_ruleset() {
	local set_mark="counter meta mark set meta mark & 0xf0ffffff | $tunnel_mark"
	printf 'add table inet %s\n' "$table"
	printf 'add chain inet %s ikev2_manager_owned { comment "IKEv2 Manager policy routing"; }\n' "$table"
	printf 'add set inet %s src_ifaces { type ifname; }\n' "$table"
	printf 'add set inet %s src4 { type ipv4_addr; flags interval; auto-merge; }\n' "$table"
	printf 'add set inet %s service4 { type ipv4_addr; flags interval; auto-merge; }\n' "$table"
	printf 'add set inet %s dst4 { type ipv4_addr; flags interval; auto-merge; }\n' "$table"
	printf 'add set inet %s dst6 { type ipv6_addr; flags interval; auto-merge; }\n' "$table"
	# After every hook that decides a packet's path: the device table (-152),
	# PBR and fw4 (-150) and the inbound users' WAN exclusion (-149).
	printf 'add chain inet %s prerouting { type filter hook prerouting priority mangle + 2; policy accept; }\n' "$table"
	printf 'flush chain inet %s prerouting\n' "$table"
	for name in src_ifaces src4 service4; do
		printf 'flush set inet %s %s\n' "$table" "$name"
	done
	[ ! -s "$work/sources" ] ||
		printf 'add element inet %s src_ifaces { %s }\n' "$table" "$(quoted_elements "$work/sources")"
	[ ! -s "$work/src4" ] ||
		printf 'add element inet %s src4 { %s }\n' "$table" "$(elements "$work/src4")"
	[ ! -s "$work/service4" ] ||
		printf 'add element inet %s service4 { %s }\n' "$table" "$(elements "$work/service4")"
	# A mark of ours is final. So is any other in the bits the rest of the
	# router uses - a WAN exclusion, FakeIP delivery, another VPN - except
	# PBR's own tunnel mark, which only says the same thing as ours.
	printf 'add rule inet %s prerouting meta mark & %s != 0 return\n' "$table" "$mark_mask"
	if [ -n "$pbr_tunnel" ]; then
		printf 'add rule inet %s prerouting meta mark & 0x00ff0000 != 0 meta mark & 0x00ff0000 != %s return\n' \
			"$table" "$pbr_tunnel"
	else
		printf 'add rule inet %s prerouting meta mark & 0x00ff0000 != 0 return\n' "$table"
	fi
	for match in 'iifname @src_ifaces' 'ip saddr @src4'; do
		printf 'add rule inet %s prerouting %s ip daddr @dst4 %s\n' "$table" "$match" "$set_mark"
		printf 'add rule inet %s prerouting %s ip daddr @service4 %s\n' "$table" "$match" "$set_mark"
	done
	printf 'add rule inet %s prerouting iifname @src_ifaces ip6 daddr @dst6 %s\n' "$table" "$set_mark"
}

# In overlay mode the domain sets follow PBR's, which dnsmasq fills.
copy_pbr_sets() {
	local family set elements
	for family in 4 6; do
		set="$("$nft_bin" list table inet fw4 2>/dev/null |
			sed -n "s/^[[:space:]]*set \(pbr_ikev2out_${family}_dst_ip_[^[:space:]]*\) {.*/\1/p" |
			grep -v '_user$' | head -n1)"
		[ -n "$set" ] || continue
		elements="$("$nft_bin" list set inet fw4 "$set" 2>/dev/null |
			sed -n '/elements = {/,/}/p' | tr -d '\n\t' |
			sed 's/.*{//; s/}.*//; s/ //g')"
		[ -z "$elements" ] ||
			"$nft_bin" add element inet "$table" "dst$family" "{ $elements }" 2>/dev/null || :
	done
}

desired_state() {
	source_devices | sort -u >"$work/sources" || return 1
	device_addresses domain >"$work/src4" || die 'Device routing configuration is not valid'
	address_lines "$service_file" | sort -u >"$work/service4"
	pbr_tunnel=''
	local values
	if values="$(mark_values "$(pbr_mark_rule pbr_ikev2out)")"; then
		pbr_tunnel="$(printf '0x%08x' "$(( ${values#* } & 0x00ff0000 ))")"
	fi
	signature="$({
		printf 'backend=%s\npbr=%s\nsources\n' "$(backend)" "$pbr_tunnel"
		cat "$work/sources"
		printf 'src4\n'
		cat "$work/src4"
		printf 'service4\n'
		cat "$work/service4"
	} | sha256sum | awk '{ print $1 }')"
}

sync_runtime() {
	if ! active; then
		# Called every watcher pass: nothing to stop costs one rule listing.
		[ -e "$state_file" ] || "$ip_bin" -4 rule show 2>/dev/null | grep -q "^$rule_tunnel:" ||
			runtime_exists || return 0
		stop_runtime
		return
	fi
	if runtime_exists && ! runtime_owned; then
		die "nft table '$table' is not owned by IKEv2 Manager"
	fi
	work="$(mktemp -d "${TMPDIR:-/tmp}/ikev2-routing.XXXXXX")" || return 1
	trap 'rm -rf "$work"' EXIT INT TERM
	desired_state || return 1
	sync_routes || die 'Unable to install the policy routing tables'
	sync_rules || die 'Unable to install the policy routing rules'
	if ! runtime_owned || [ "$(sed -n '1p' "$state_file" 2>/dev/null)" != "$signature" ] ||
	   ! runtime_unchanged "$state_file"; then
		write_ruleset >"$work/rules.nft"
		"$nft_bin" -c -f "$work/rules.nft" >"$work/check.log" 2>&1 || {
			cat "$work/check.log" >&2
			die 'Policy routing nftables validation failed'
		}
		"$nft_bin" -f "$work/rules.nft" >/dev/null 2>&1 ||
			die 'Unable to install the policy routing nftables rules'
		record_runtime "$state_file" "$signature" ||
			die 'Unable to read back the installed policy routing rules'
	fi
	[ "$(backend)" != overlay ] || copy_pbr_sets
	rm -rf "$work"
	trap - EXIT INT TERM
}

check_runtime() {
	active || {
		! runtime_exists && ! "$ip_bin" -4 rule show 2>/dev/null | grep -q "^$rule_tunnel:"
		return
	}
	runtime_owned || return 1
	work="$(mktemp -d "${TMPDIR:-/tmp}/ikev2-routing-check.XXXXXX")" || return 1
	trap 'rm -rf "$work"' EXIT INT TERM
	desired_state 2>/dev/null || return 1
	[ "$(sed -n '1p' "$state_file" 2>/dev/null)" = "$signature" ] || return 1
	runtime_unchanged "$state_file" || return 1
	"$ip_bin" -4 rule show 2>/dev/null |
		grep -Eq "^$rule_tunnel:[[:space:]]+from all fwmark $rule_tunnel_mark/$rule_mask lookup $tunnel_table\$" || return 1
	"$ip_bin" -4 route show table "$tunnel_table" 2>/dev/null |
		grep -Eq '^unreachable default .*metric 32767' || return 1
	rm -rf "$work"
	trap - EXIT INT TERM
}

stop_runtime() {
	delete_rules
	if runtime_exists; then
		runtime_owned || die "nft table '$table' is not owned by IKEv2 Manager"
		"$nft_bin" delete table inet "$table" >/dev/null 2>&1 || return 1
	fi
	"$ip_bin" -4 route flush table "$tunnel_table" 2>/dev/null || :
	"$ip_bin" -6 route flush table "$tunnel_table" 2>/dev/null || :
	"$ip_bin" -4 route flush table "$wan_table" 2>/dev/null || :
	rm -f "$state_file"
}

status_runtime() {
	printf 'backend=%s\n' "$(backend)"
	if runtime_owned; then printf 'runtime=installed\n'; else printf 'runtime=absent\n'; fi
	if tunnel_ready; then printf 'tunnel=up\n'; else printf 'tunnel=down\n'; fi
}

case "${1:-}" in
	sync) sync_runtime ;;
	check) check_runtime ;;
	stop) stop_runtime ;;
	status) status_runtime ;;
	*)
		printf '%s\n' 'usage: ikev2-routing {sync|check|stop|status}' >&2
		exit 2
		;;
esac
