#!/bin/sh

set -u

config='ikev2-manager'
domain_file="${IKEV2_DOMAIN_FILE:-/etc/pbr-ikev2-domains.txt}"
config_file="${IKEV2_DOMAIN_CONFIG:-/etc/ikev2-manager/domain-router.json}"
ruleset_file="${IKEV2_DOMAIN_RULESET:-/etc/ikev2-manager/domain-router-rules.json}"
work_dir="${IKEV2_DOMAIN_WORK_DIR:-/etc/ikev2-manager/domain-router}"
state_file="${IKEV2_DOMAIN_STATE:-/var/run/ikev2-domain-router.status}"
log_file="${IKEV2_DOMAIN_LOG:-/tmp/ikev2-domain-router.log}"
lock_dir="${IKEV2_DOMAIN_LOCK:-/var/run/ikev2-domain-router.lock}"
runtime_lib_dir="${IKEV2_RUNTIME_LIB_DIR:-/usr/libexec/ikev2-manager.d}"
dns_address='127.0.0.42'
dns_port='53'
tproxy_address='127.0.0.1'
tproxy_port='1602'
direct_tproxy_port='1603'
fakeip_range='198.18.0.0/15'
tproxy_mark='0x400000'
tproxy_mask='0xff0000'
direct_tproxy_mark='0x00400001'
tproxy_table='51820'
tproxy_priority='11000'
nft_table='ikev2_domain_router'

. "$runtime_lib_dir/actions.sh"
. "$runtime_lib_dir/devices.sh"

die() {
	printf '%s\n' "$*" >&2
	exit 1
}

getv() {
	uci -q get "$config.$1.$2" 2>/dev/null || true
}

defaultv() {
	value="$(getv "$1" "$2")"
	[ -n "$value" ] && printf '%s\n' "$value" || printf '%s\n' "$3"
}

write_status() {
	{
		[ -z "${ACTION_ID:-}" ] || printf 'action_id=%s\n' "$ACTION_ID"
		printf 'state=%s\n' "$1"
		printf 'updated=%s\n' "$(date +%s)"
		[ -z "${2:-}" ] || printf 'message=%s\n' "$2"
	} >"${state_file}.new"
	mv "${state_file}.new" "$state_file"
}

init_config() {
	uci -q get "$config.domains" >/dev/null 2>&1 || {
		uci set "$config.domains=domains"
		uci set "$config.domains.engine=nftset"
		uci set "$config.domains.fakeip_ttl=60"
		uci set "$config.domains.cache_path=/etc/ikev2-manager/domain-router-cache.db"
		uci set "$config.domains.log_level=warn"
		uci set "$config.domains.route_router_traffic=0"
		uci commit "$config"
	}
}

with_lock() {
	action="$1"
	shift
	if ! pid_lock_acquire "$lock_dir"; then
		write_status error 'Another domain-routing action is already running'
		return 1
	fi
	trap 'pid_lock_release "$lock_dir"' EXIT INT TERM
	"$action" "$@"
	result=$?
	trap - EXIT INT TERM
	pid_lock_release "$lock_dir"
	return "$result"
}

json_array_file() {
	awk '
		BEGIN { printf "["; first = 1 }
		{
			gsub(/\r/, "")
			gsub(/^[ \t]+|[ \t]+$/, "")
			if ($0 == "" || substr($0, 1, 1) == "#")
				next
				if (!first)
					printf ","
				gsub(/\\/, "\\\\")
				gsub(/\"/, "\\\"")
				printf "\"%s\"", $0
			first = 0
		}
		END { printf "]" }
	' "$1"
}

validate_domain_file() {
	local file="$1" bytes count
	bytes="$(wc -c <"$file" | tr -d ' ')"
	count="$(awk 'NF && $1 !~ /^#/ { count++ } END { print count + 0 }' "$file")"
	[ "$bytes" -le 8388608 ] && [ "$count" -le 200000 ] || return 1
	awk '
		{
			gsub(/\r/, "")
			gsub(/^[ \t]+|[ \t]+$/, "")
			line = tolower($0)
			if (line == "" || substr(line, 1, 1) == "#") next
			if (length(line) > 253 || line !~ /^[a-z0-9._-]+$/ ||
			    line ~ /^\./ || line ~ /\.$/ || line ~ /\.\./) exit 1
			labels_count = split(line, labels, ".")
			for (i = 1; i <= labels_count; i++)
				if (length(labels[i]) < 1 || length(labels[i]) > 63 ||
				    labels[i] ~ /^-/ || labels[i] ~ /-$/) exit 1
		}
	' "$file"
}

json_array_words() {
	printf '%s\n' "$@" | awk '
		BEGIN { printf "["; first = 1 }
		NF {
			if (!first)
				printf ","
			printf "\"%s\"", $0
			first = 0
		}
		END { printf "]" }
	'
}

dns_segment_https_suffixes() {
	local section enabled compat suffix
	for section in $(uci show "$config" 2>/dev/null |
		sed -n "s/^${config}\.\([^.=]*\)=dns_segment\$/\1/p"); do
		enabled="$(defaultv "$section" enabled 1)"
		compat="$(defaultv "$section" https_compat 1)"
		[ "$enabled" = 1 ] && [ "$compat" = 1 ] || continue
		for suffix in $(getv "$section" domains); do
			suffix="${suffix#.}"
			[ -n "$suffix" ] && printf '%s\n' "$suffix"
		done
	done | sort -u
}

network_cidrs() {
	interface="$1"
	device="$(ubus call "network.interface.$interface" status 2>/dev/null |
		jsonfilter -e '@.l3_device' 2>/dev/null || true)"
	[ -n "$device" ] ||
		device="$(ubus call "network.interface.$interface" status 2>/dev/null |
			jsonfilter -e '@.device' 2>/dev/null || true)"
	[ -n "$device" ] || return 1
	ip -4 route show dev "$device" scope link 2>/dev/null |
		awk '$1 ~ /^[0-9.]+\/[0-9]+$/ { print $1 }' | sort -u
}

covered_sources() {
	found=0
	for interface in $(uci -q get "$config.globals.source_interface" 2>/dev/null); do
		cidrs="$(network_cidrs "$interface")"
		[ -n "$cidrs" ] || {
			printf 'Protected network has no usable IPv4 subnet: %s\n' "$interface" >&2
			return 1
		}
		printf '%s\n' "$cidrs"
		found=1
	done
	if [ "$(defaultv globals source_include_vpn 1)" = 1 ] &&
	   [ "$(defaultv server enabled 0)" = 1 ]; then
		vpn_cidr="$(/usr/libexec/ikev2-manager-system gateway-network 2>/dev/null || true)"
		[ -n "$vpn_cidr" ] || {
			printf 'Inbound VPN source has no usable IPv4 subnet\n' >&2
			return 1
		}
		printf '%s\n' "$vpn_cidr"
		found=1
	fi
	src="$(uci -q get pbr.ikev2pbr_domains.src_addr 2>/dev/null || true)"
	for address in $src; do
		case "$address" in
			@*) ;;
			*) printf '%s\n' "$address"; found=1 ;;
		esac
	done
	[ "$found" = 1 ]
}

excluded_sources() {
	device_addresses exclude
}

upstream_dns() {
	if [ "$(defaultv domains dns_saved 0)" = 1 ]; then
		servers="$(uci -q get "$config.domains.prev_server" 2>/dev/null || true)"
		noresolv="$(defaultv domains prev_noresolv 0)"
	else
		servers="$(uci -q get dhcp.@dnsmasq[0].server 2>/dev/null || true)"
		noresolv="$(uci -q get dhcp.@dnsmasq[0].noresolv 2>/dev/null || echo 0)"
	fi
	for server in $servers; do
		case "$server" in
			/* | 127.0.0.1 | 127.0.0.1#53 | "$dns_address" | "$dns_address#$dns_port")
				continue
				;;
		esac
		host="${server%%#*}"
		port="${server#*#}"
		[ "$port" != "$server" ] || port=53
		if printf '%s\n' "$host" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' &&
		   printf '%s\n' "$port" | grep -Eq '^[0-9]+$'; then
			printf '%s %s\n' "$host" "$port"
			return 0
		fi
	done
	if [ "$noresolv" != 1 ]; then
		host="$(awk '$1 == "nameserver" && $2 ~ /^[0-9]+\./ { print $2; exit }' \
			/tmp/resolv.conf.d/resolv.conf.auto 2>/dev/null)"
		case "$host" in
			'' | 127.0.0.1 | "$dns_address") ;;
			*) printf '%s 53\n' "$host"; return 0 ;;
		esac
	fi
	die 'Unable to determine the DNS upstream used before FakeIP'
}

local_devices() {
	ubus call network.interface dump 2>/dev/null |
		jsonfilter -e '@.interface[*].interface' 2>/dev/null |
		while IFS= read -r interface; do
			case "$interface" in
				'' | loopback | lo | wan | wan6 | ikev2out) continue ;;
			esac
			device="$(ubus call "network.interface.$interface" status 2>/dev/null |
				jsonfilter -e '@.l3_device' 2>/dev/null || true)"
			[ -n "$device" ] ||
				device="$(ubus call "network.interface.$interface" status 2>/dev/null |
					jsonfilter -e '@.device' 2>/dev/null || true)"
			[ -n "$device" ] && printf '%s\n' "$device"
		done
	[ "$(defaultv server enabled 0)" = 1 ] && printf 'ipsec-in\n'
}

render_ruleset() {
	[ -f "$domain_file" ] || die 'Active domain list is missing'
	validate_domain_file "$domain_file" ||
		die 'Active domain list is invalid or exceeds resource limits'
	mkdir -p "${ruleset_file%/*}"
	domains="$(json_array_file "$domain_file")"
	printf '{"version":3,"rules":[{"domain_suffix":%s}]}\n' "$domains" \
		>"${ruleset_file}.new"
	chmod 600 "${ruleset_file}.new"
	mv "${ruleset_file}.new" "$ruleset_file"
}

render_config() {
	render_ruleset
	mkdir -p "$work_dir"
	ttl="$(defaultv domains fakeip_ttl 60)"
	log_level="$(defaultv domains log_level warn)"
	case "$log_level" in trace | debug | info | warn | error | fatal | panic) ;;
		*) die 'Invalid FakeIP log level' ;;
	esac
	cache_path="$(defaultv domains cache_path /etc/ikev2-manager/domain-router-cache.db)"
	upstream="$(upstream_dns)" || return 1
	set -- $upstream
	upstream_host="$1"
	upstream_port="$2"
	covered_file="$(mktemp)"
	excluded_file="$(mktemp)"
	if ! covered_sources >"$covered_file"; then
		rm -f "$covered_file" "$excluded_file"
		return 1
	fi
	# A rejected device configuration must not degrade into an empty exclusion
	# list: that would quietly pull an excluded device back into the tunnel.
	if ! excluded_sources >"$excluded_file"; then
		rm -f "$covered_file" "$excluded_file"
		return 1
	fi
	covered="$(sort -u "$covered_file" | json_array_file /dev/stdin)"
	excluded="$(sort -u "$excluded_file" | json_array_file /dev/stdin)"
	rm -f "$covered_file" "$excluded_file"
	[ "$covered" != '[]' ] || die 'No source networks are enabled for domain routing'
	segment_https_words="$(dns_segment_https_suffixes)"
	# Suffixes are validated UCI words; pass them as arguments because
	# json_array_words intentionally does not consume standard input.
	segment_https_suffixes="$(json_array_words $segment_https_words)"
	segment_https_rule=''
	if [ "$segment_https_suffixes" != '[]' ]; then
		segment_https_rule='
      {
        "domain_suffix": '"$segment_https_suffixes"',
        "query_type": [ "HTTPS" ],
        "action": "predefined",
        "rcode": "NOERROR"
      },'
	fi
	excluded_rule=''
	if [ "$excluded" != '[]' ]; then
		excluded_rule='
      {
        "inbound": [ "tproxy-in" ],
        "source_ip_cidr": '"$excluded"',
        "action": "route",
        "outbound": "direct-out"
      },'
	fi

	cat >"${config_file}.new" <<EOF
{
  "log": {
    "level": "$log_level",
    "timestamp": true
  },
  "dns": {
    "servers": [
      {
        "type": "udp",
        "tag": "upstream",
        "server": "$upstream_host",
        "server_port": $upstream_port
      },
      {
        "type": "fakeip",
        "tag": "fakeip",
        "inet4_range": "$fakeip_range"
      }
    ],
    "rules": [
      {
        "rule_set": [ "ikev2-domains" ],
        "query_type": [ "HTTPS" ],
        "action": "predefined",
        "rcode": "NOERROR"
      },
$segment_https_rule
      {
        "domain": [ "use-application-dns.net" ],
        "action": "reject"
      },
      {
        "rule_set": [ "ikev2-domains" ],
        "query_type": [ "AAAA" ],
        "action": "predefined",
        "rcode": "NOERROR"
      },
      {
        "rule_set": [ "ikev2-domains" ],
        "query_type": [ "A" ],
        "action": "route",
        "server": "fakeip",
        "rewrite_ttl": $ttl
      }
    ],
    "final": "upstream",
    "independent_cache": true
  },
  "inbounds": [
    {
      "type": "direct",
      "tag": "dns-in",
      "listen": "$dns_address",
      "listen_port": $dns_port
    },
    {
      "type": "tproxy",
      "tag": "tproxy-in",
      "listen": "$tproxy_address",
      "listen_port": $tproxy_port
    },
    {
      "type": "tproxy",
      "tag": "tproxy-direct-in",
      "listen": "$tproxy_address",
      "listen_port": $direct_tproxy_port
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct-out",
      "domain_resolver": "upstream"
    },
    {
      "type": "direct",
      "tag": "ikev2-out",
      "bind_interface": "ipsec-out",
      "domain_resolver": "upstream"
    }
  ],
  "route": {
    "rules": [
      {
        "inbound": [ "dns-in" ],
        "action": "hijack-dns"
      },
      {
        "inbound": [ "tproxy-in", "tproxy-direct-in" ],
        "action": "sniff",
        "timeout": "300ms"
      },
      {
        "inbound": [ "tproxy-direct-in" ],
        "action": "route",
        "outbound": "direct-out"
      },
$excluded_rule
      {
        "inbound": [ "tproxy-in" ],
        "source_ip_cidr": $covered,
        "rule_set": [ "ikev2-domains" ],
        "action": "route",
        "outbound": "ikev2-out"
      },
      {
        "inbound": [ "tproxy-in" ],
        "action": "route",
        "outbound": "direct-out"
      }
    ],
    "rule_set": [
      {
        "type": "local",
        "tag": "ikev2-domains",
        "format": "source",
        "path": "$ruleset_file"
      }
    ],
    "final": "direct-out",
    "default_domain_resolver": "upstream"
  },
  "experimental": {
    "cache_file": {
      "enabled": true,
      "path": "$cache_path",
      "store_fakeip": true
    }
  }
}
EOF
	chmod 600 "${config_file}.new"
	mv "${config_file}.new" "$config_file"
}

check_config() {
	command -v sing-box >/dev/null 2>&1 || die 'sing-box is not installed'
	render_config
	sing-box check -c "$config_file"
}

backup_generated() {
	backup_dir="$1"
	mkdir -p "$backup_dir"
	[ -s "$config_file" ] && cp "$config_file" "$backup_dir/config.json"
	[ -s "$ruleset_file" ] && cp "$ruleset_file" "$backup_dir/rules.json"
}

restore_generated() {
	backup_dir="$1"
	if [ -s "$backup_dir/config.json" ]; then
		cp "$backup_dir/config.json" "${config_file}.restore"
		mv "${config_file}.restore" "$config_file"
	fi
	if [ -s "$backup_dir/rules.json" ]; then
		cp "$backup_dir/rules.json" "${ruleset_file}.restore"
		mv "${ruleset_file}.restore" "$ruleset_file"
	fi
}

routing_slot_available() {
	local foreign routes
	foreign="$(ip -4 rule show 2>/dev/null | awk \
		-v priority="${tproxy_priority}:" \
		-v mark="$tproxy_mark/$tproxy_mask" \
		-v table="$tproxy_table" '
		$1 == priority || index($0, "lookup " table) {
			if (!($1 == priority && index($0, "fwmark " mark) &&
			      index($0, "lookup " table))) print
		}')"
	[ -z "$foreign" ] || return 1
	routes="$(ip -4 route show table "$tproxy_table" 2>/dev/null || true)"
	printf '%s\n' "$routes" | awk '
		NF && !($1 == "local" && ($2 == "default" || $2 == "0.0.0.0/0") &&
		        $3 == "dev" && $4 == "lo") { bad = 1 }
		END { exit bad }
	'
}

nft_slot_available() {
	local state
	state="$(nft list table inet "$nft_table" 2>/dev/null || true)"
	[ -n "$state" ] || return 0
	printf '%s\n' "$state" | grep -Fq 'set local_devices' || return 1
	printf '%s\n' "$state" | grep -Fq "$fakeip_range" || return 1
	printf '%s\n' "$state" | grep -Fq ":$tproxy_port" || return 1
}

delete_local_tproxy_route() {
	local table="$1"
	while ip -4 route del local 0.0.0.0/0 dev lo table "$table" \
		2>/dev/null; do :; done
	while ip -4 route del local default dev lo table "$table" \
		2>/dev/null; do :; done
}

nft_stop() {
	nft delete table inet "$nft_table" >/dev/null 2>&1 || true
	while ip -4 rule del fwmark "$tproxy_mark/$tproxy_mask" \
		table "$tproxy_table" priority "$tproxy_priority" 2>/dev/null; do :; done
	delete_local_tproxy_route "$tproxy_table"
	# Remove the exact route/rule used by releases before 1.1. No table flush is
	# used, so unrelated routes in the legacy numeric table remain untouched.
	while ip -4 rule del fwmark "$tproxy_mark/$tproxy_mask" \
		table 100 priority 100 2>/dev/null; do :; done
	delete_local_tproxy_route 100
}

listener_ready() {
	netstat -ln 2>/dev/null | grep -Fq "$1:$2"
}

nft_runtime_ready() {
	nft list chain inet "$nft_table" prerouting 2>/dev/null |
		grep -Fq "$fakeip_range" || return 1
	nft list chain inet "$nft_table" prerouting 2>/dev/null |
		grep -Fq "$direct_tproxy_mark" || return 1
	if [ "$(defaultv domains route_router_traffic 0)" = 1 ]; then
		nft list chain inet "$nft_table" output 2>/dev/null |
			grep -Fq "$fakeip_range" || return 1
	else
		! nft list chain inet "$nft_table" output 2>/dev/null |
			grep -Fq "$fakeip_range" || return 1
	fi
	ip -4 rule show |
		grep -q "fwmark $tproxy_mark/$tproxy_mask.*lookup $tproxy_table" || return 1
	ip -4 route show table "$tproxy_table" 2>/dev/null |
		grep -Eq '^local (default|0\.0\.0\.0/0) dev lo( |$)'
}

nft_start() {
	routing_slot_available || die "TProxy routing table $tproxy_table or priority $tproxy_priority is already in use"
	nft_slot_available || die "nft table '$nft_table' exists but is not owned by IKEv2 Manager"
	nft_stop
	devices="$(local_devices | sort -u)"
	[ -n "$devices" ] || die 'No local interfaces found for FakeIP interception'
	device_set="$(json_array_words $devices | tr '[]' '{}')"
	output_rules=''
	if [ "$(defaultv domains route_router_traffic 0)" = 1 ]; then
		output_rules="
    ip daddr $fakeip_range meta l4proto tcp meta mark set $tproxy_mark counter
    ip daddr $fakeip_range meta l4proto udp meta mark set $tproxy_mark counter"
	fi

	if ! nft -f - <<EOF
table inet $nft_table {
  set local_devices {
    type ifname
    elements = $device_set
  }

  chain prerouting {
    type filter hook prerouting priority -151; policy accept;
    meta mark == $direct_tproxy_mark return
    meta mark & $tproxy_mask == $tproxy_mark meta l4proto tcp tproxy ip to $tproxy_address:$tproxy_port counter accept
    meta mark & $tproxy_mask == $tproxy_mark meta l4proto udp tproxy ip to $tproxy_address:$tproxy_port counter accept
    iifname @local_devices ip daddr $fakeip_range meta l4proto tcp meta mark set $tproxy_mark tproxy ip to $tproxy_address:$tproxy_port counter accept
    iifname @local_devices ip daddr $fakeip_range meta l4proto udp meta mark set $tproxy_mark tproxy ip to $tproxy_address:$tproxy_port counter accept
  }

  chain output {
    type route hook output priority -151; policy accept;
$output_rules
  }
}
EOF
	then
		nft_stop
		return 1
	fi
	if ! ip -4 route replace local 0.0.0.0/0 dev lo table "$tproxy_table" ||
	   ! ip -4 rule add fwmark "$tproxy_mark/$tproxy_mask" \
		table "$tproxy_table" priority "$tproxy_priority" || ! nft_runtime_ready; then
		nft_stop
		return 1
	fi
}

set_router_traffic() {
	value="${1:-}"
	case "$value" in 0 | 1) ;; *) die 'Expected router traffic value: 0 or 1' ;; esac
	old="$(defaultv domains route_router_traffic 0)"
	[ "$old" = "$value" ] && return 0
	uci set "$config.domains.route_router_traffic=$value" &&
		uci commit "$config" || die 'Unable to save router-originated traffic policy'
	if [ "$(defaultv domains engine nftset)" = fakeip ] &&
	   { ! nft_start || ! runtime_healthy; }; then
		restored=1
		uci set "$config.domains.route_router_traffic=$old" &&
			uci commit "$config" || restored=0
		[ "$restored" = 0 ] || nft_start >/dev/null 2>&1 || restored=0
		[ "$restored" = 1 ] ||
			die 'Router-originated traffic policy failed and automatic rollback was incomplete'
		die 'Unable to apply router-originated traffic policy; previous setting restored'
	fi
}

set_log_level() {
	value="${1:-}"
	case "$value" in trace | debug | info | warn | error) ;;
		*) die 'Expected log level: trace, debug, info, warn or error' ;;
	esac
	old="$(defaultv domains log_level warn)"
	[ "$old" = "$value" ] && return 0
	uci set "$config.domains.log_level=$value" &&
		uci commit "$config" || die 'Unable to save FakeIP log level'
	if [ "$(defaultv domains engine nftset)" = fakeip ] && ! refresh; then
		restored=1
		uci set "$config.domains.log_level=$old" &&
			uci commit "$config" || restored=0
		[ "$restored" = 0 ] || refresh >/dev/null 2>&1 || restored=0
		[ "$restored" = 1 ] ||
			die 'FakeIP log level failed and automatic rollback was incomplete'
		die 'Unable to apply FakeIP log level; previous setting restored'
	fi
}

resolver_diagnostic_inner() {
	duration="$1"
	old="$(defaultv domains log_level warn)"
	restored=0
	restore_level() {
		[ "$restored" = 0 ] || return 0
		uci set "$config.domains.log_level=$old" || return 1
		uci commit "$config" || return 1
		refresh >/dev/null 2>&1 || return 1
		restored=1
	}
	trap 'restore_level >/dev/null 2>&1 || true' EXIT INT TERM HUP
	uci set "$config.domains.log_level=debug" || return 1
	uci commit "$config" || return 1
	if ! refresh; then
		restore_level >/dev/null 2>&1 || true
		return 1
	fi
	write_status running "FakeIP debug logging is active for $duration seconds"
	sleep "$duration"
	if ! restore_level; then
		write_status error 'Diagnostic ended, but the normal FakeIP log level could not be restored'
		return 1
	fi
	trap - EXIT INT TERM HUP
	write_status active "FakeIP diagnostic completed; log level restored to $old"
}

resolver_diagnostic() {
	duration="${1:-60}"
	case "$duration" in '' | *[!0-9]*) die 'Invalid diagnostic duration' ;; esac
	[ "$duration" -ge 30 ] && [ "$duration" -le 300 ] ||
		die 'Diagnostic duration must be 30-300 seconds'
	[ "$(defaultv domains engine nftset)" = fakeip ] ||
		die 'FakeIP diagnostics require Reliable mode'
	# Keep the restoration trap inside a subshell so it cannot replace the
	# outer action-lock trap maintained by with_lock().
	( resolver_diagnostic_inner "$duration" )
}

save_dnsmasq() {
	[ "$(defaultv domains dns_saved 0)" = 1 ] && return 0
	uci set "$config.domains.dns_saved=1"
	uci set "$config.domains.prev_noresolv=$(uci -q get dhcp.@dnsmasq[0].noresolv 2>/dev/null || echo 0)"
	uci set "$config.domains.prev_cachesize=$(uci -q get dhcp.@dnsmasq[0].cachesize 2>/dev/null || echo 150)"
	uci -q delete "$config.domains.prev_server" || true
	for server in $(uci -q get dhcp.@dnsmasq[0].server 2>/dev/null); do
		uci add_list "$config.domains.prev_server=$server"
	done
	uci commit "$config"
}

clear_dnsmasq_snapshot() {
	for option in dns_saved prev_noresolv prev_cachesize prev_server; do
		uci -q delete "$config.domains.$option" || true
	done
	uci commit "$config"
}

use_fakeip_dns() {
	save_dnsmasq
	uci set dhcp.@dnsmasq[0].noresolv='1'
	uci set dhcp.@dnsmasq[0].cachesize='0'
	uci -q delete dhcp.@dnsmasq[0].server || true
	uci add_list "dhcp.@dnsmasq[0].server=$dns_address"
	uci commit dhcp
	/etc/init.d/dnsmasq restart
}

restore_dnsmasq() {
	[ "$(defaultv domains dns_saved 0)" = 1 ] || return 0
	uci set "dhcp.@dnsmasq[0].noresolv=$(defaultv domains prev_noresolv 0)"
	uci set "dhcp.@dnsmasq[0].cachesize=$(defaultv domains prev_cachesize 150)"
	uci -q delete dhcp.@dnsmasq[0].server || true
	for server in $(uci -q get "$config.domains.prev_server" 2>/dev/null); do
		uci add_list "dhcp.@dnsmasq[0].server=$server"
	done
	uci commit dhcp
	/etc/init.d/dnsmasq restart
	clear_dnsmasq_snapshot
}

is_fakeip() {
	printf '%s\n' "$1" | grep -Eq '^198\.(18|19)\.'
}

lookup_address() {
	nslookup "$1" "$2" 2>/dev/null |
		sed -n 's/^Address[^:]*:[[:space:]]*//p' |
		grep -E '^[0-9]+\.' | tail -n1
}

selected_test_domain() {
	sed -n '/^[[:space:]]*#/d; /^[[:space:]]*$/d; { s/[[:space:]]//g; p; q; }' \
		"$domain_file"
}

wait_for_dns() {
	tries=0
	while [ "$tries" -lt 15 ]; do
		if listener_ready "$dns_address" "$dns_port"; then
			return 0
		fi
		tries=$((tries + 1))
		sleep 1
	done
	return 1
}

validate_dns_server() {
	server="${1:-$dns_address}"
	selected="$(selected_test_domain)"
	if [ -n "$selected" ]; then
		selected_ip="$(lookup_address "$selected" "$server")"
		is_fakeip "$selected_ip" ||
			die "Selected domain did not receive FakeIP: $selected -> ${selected_ip:-none}"
	fi
	control='openwrt.org'
	grep -qx "$control" "$domain_file" 2>/dev/null && control='example.com'
	control_ip="$(lookup_address "$control" "$server")"
	[ -n "$control_ip" ] && ! is_fakeip "$control_ip" ||
		die "Control domain did not receive a real address: $control -> ${control_ip:-none}"
}

runtime_healthy() {
	[ "$(defaultv domains engine nftset)" = fakeip ] || return 1
	/etc/init.d/ikev2-domain-router running >/dev/null 2>&1 || return 1
	listener_ready "$dns_address" "$dns_port" || return 1
	listener_ready "$tproxy_address" "$tproxy_port" || return 1
	listener_ready "$tproxy_address" "$direct_tproxy_port" || return 1
	[ "$(uci -q get dhcp.@dnsmasq[0].server 2>/dev/null || true)" = "$dns_address" ] ||
		return 1
	[ "$(uci -q get dhcp.@dnsmasq[0].cachesize 2>/dev/null || true)" = 0 ] ||
		return 1
	nft_runtime_ready
}

wait_for_query() {
	server="$1"
	domain="$2"
	tries=0
	while [ "$tries" -lt 15 ]; do
		[ -n "$(lookup_address "$domain" "$server")" ] && return 0
		tries=$((tries + 1))
		sleep 1
	done
	return 1
}

repair_runtime() {
	[ "$(defaultv domains engine nftset)" = fakeip ] || return 0
	if ! /etc/init.d/ikev2-domain-router running >/dev/null 2>&1 ||
	   ! listener_ready "$dns_address" "$dns_port" ||
	   ! listener_ready "$tproxy_address" "$tproxy_port" ||
	   ! listener_ready "$tproxy_address" "$direct_tproxy_port"; then
		/etc/init.d/ikev2-domain-router restart
		wait_for_dns || return 1
	fi
	validate_dns_server "$dns_address" || return 1
	if ! nft_runtime_ready; then
		nft_start || return 1
	fi
	if [ "$(uci -q get dhcp.@dnsmasq[0].server 2>/dev/null || true)" != "$dns_address" ] ||
	   [ "$(uci -q get dhcp.@dnsmasq[0].cachesize 2>/dev/null || true)" != 0 ]; then
		validate_dns_server "$dns_address"
		use_fakeip_dns
		wait_for_query 127.0.0.1 openwrt.org
		validate_dns_server 127.0.0.1
	fi
	runtime_healthy || return 1
	write_status active 'FakeIP runtime repaired'
}

ensure_runtime() {
	init_config
	[ "$(defaultv domains engine nftset)" = fakeip ] || return 0
	runtime_healthy && return 0
	pid_lock_busy "$lock_dir" && return 0
	with_lock repair_runtime
}

prepare() {
	init_config
	check_config
	nft_start
}

refresh() {
	init_config
	[ "$(defaultv domains engine nftset)" = fakeip ] || return 0
	backup="/tmp/ikev2-domain-router-refresh.$$"
	backup_generated "$backup"
	if ! check_config; then
		restore_generated "$backup"
		rm -rf "$backup"
		write_status error 'New domain rules failed validation; previous rules remain active'
		return 1
	fi
	if ! /etc/init.d/ikev2-domain-router restart ||
	   ! wait_for_dns ||
	   ! validate_dns_server "$dns_address"; then
		restore_generated "$backup"
		/etc/init.d/ikev2-domain-router restart >/dev/null 2>&1 || true
		rm -rf "$backup"
		write_status error 'New domain rules failed at runtime; previous rules restored'
		return 1
	fi
	if ! nft_start || ! runtime_healthy; then
		restore_generated "$backup"
		/etc/init.d/ikev2-domain-router restart >/dev/null 2>&1 || true
		wait_for_dns >/dev/null 2>&1 || true
		nft_start >/dev/null 2>&1 || true
		rm -rf "$backup"
		write_status error 'New domain TProxy runtime failed; previous rules restored'
		return 1
	fi
	rm -rf "$backup"
	write_status active 'FakeIP domain rules refreshed'
}

adopt_upstream() {
	init_config
	[ "$(defaultv domains engine nftset)" = fakeip ] || return 0
	rollback="/tmp/ikev2-domain-router-upstream.$$"
	uci export "$config" >"$rollback"
	clear_dnsmasq_snapshot
	save_dnsmasq
	if ! refresh ||
	   ! use_fakeip_dns ||
	   ! wait_for_query 127.0.0.1 openwrt.org ||
	   ! validate_dns_server 127.0.0.1; then
		uci import "$config" <"$rollback"
		uci commit "$config"
		refresh >/dev/null 2>&1 || true
		use_fakeip_dns >/dev/null 2>&1 || true
		rm -f "$rollback"
		write_status error 'DNS upstream update failed; previous FakeIP resolver restored'
		return 1
	fi
	rm -f "$rollback"
	write_status active 'FakeIP DNS upstream updated'
}

activate() {
	init_config
	check_config
	uci set "$config.domains.engine=fakeip"
	uci commit "$config"
	if ! /etc/init.d/ikev2-domain-router enable >/dev/null 2>&1 ||
	   ! /etc/init.d/ikev2-domain-router restart; then
		uci set "$config.domains.engine=nftset"
		uci commit "$config"
		/etc/init.d/ikev2-domain-router stop >/dev/null 2>&1 || true
		/etc/init.d/ikev2-domain-router disable >/dev/null 2>&1 || true
		write_status error 'FakeIP service could not be enabled; standard routing was restored'
		return 1
	fi
	if ! wait_for_dns || ! validate_dns_server "$dns_address"; then
		uci set "$config.domains.engine=nftset"
		uci commit "$config"
		/etc/init.d/ikev2-domain-router stop >/dev/null 2>&1 || true
		/etc/init.d/ikev2-domain-router disable >/dev/null 2>&1 || true
		write_status error 'FakeIP resolver validation failed; existing DNS was not changed'
		return 1
	fi

	if ! nft_start; then
		uci set "$config.domains.engine=nftset"
		uci commit "$config"
		/etc/init.d/ikev2-domain-router stop >/dev/null 2>&1 || true
		/etc/init.d/ikev2-domain-router disable >/dev/null 2>&1 || true
		nft_stop
		write_status error 'TProxy setup failed; existing DNS was not changed'
		return 1
	fi

	if ! use_fakeip_dns ||
	   ! wait_for_query 127.0.0.1 openwrt.org ||
	   ! validate_dns_server 127.0.0.1; then
		restored=1
		restore_dnsmasq || restored=0
		nft_stop
		uci set "$config.domains.engine=nftset"
		uci commit "$config"
		/etc/init.d/ikev2-domain-router stop >/dev/null 2>&1 || true
		/etc/init.d/ikev2-domain-router disable >/dev/null 2>&1 || true
		if [ "$restored" = 1 ]; then
			write_status error 'DNS cutover failed; previous resolver restored'
		else
			write_status error 'DNS cutover failed and resolver rollback was incomplete'
		fi
		return 1
	fi
	write_status active 'FakeIP domain routing is active'
}

deactivate() {
	restore_dnsmasq || {
		write_status error 'Unable to restore DNS before disabling FakeIP routing'
		return 1
	}
	nft_stop
	uci set "$config.domains.engine=nftset"
	uci commit "$config"
	/etc/init.d/ikev2-domain-router stop >/dev/null 2>&1 || return 1
	/etc/init.d/ikev2-domain-router disable >/dev/null 2>&1 || return 1
	write_status disabled 'Standard nftset domain routing is active'
}

fallback() {
	restore_dnsmasq || {
		write_status error 'FakeIP startup failed and previous DNS could not be restored'
		return 1
	}
	nft_stop
	uci set "$config.domains.engine=nftset"
	uci commit "$config"
	write_status error 'FakeIP startup failed; previous DNS was restored'
}

run_async() {
	action="$1"
	ACTION_ID="${2:-}"
	shift 2
	exec >>"$log_file" 2>&1
	write_status running "Domain-routing action: $action"
	if with_lock "$action" "$@"; then
		return 0
	fi
	write_status error "Domain-routing action failed: $action"
	return 1
}

schedule() {
	action="$1"
	shift
	ACTION_ID="$(date +%s)-$$"
	write_status running "Starting domain-routing action: $action"
	if command -v start-stop-daemon >/dev/null 2>&1; then
		start-stop-daemon -b -q -S -x "$0" -- _run "$action" "$ACTION_ID" "$@"
	else
		setsid "$0" _run "$action" "$ACTION_ID" "$@" </dev/null >/dev/null 2>&1 &
	fi
	printf 'action_id=%s\n' "$ACTION_ID"
}

status() {
	init_config
	printf 'engine=%s\n' "$(defaultv domains engine nftset)"
	printf 'route_router_traffic=%s\n' "$(defaultv domains route_router_traffic 0)"
	printf 'log_level=%s\n' "$(defaultv domains log_level warn)"
	printf 'system_log_size=%s\n' "$(uci -q get 'system.@system[0].log_size' 2>/dev/null || echo 0)"
	printf 'service=%s\n' "$(
		/etc/init.d/ikev2-domain-router running >/dev/null 2>&1 &&
			echo running || echo stopped
	)"
	printf 'dnsmasq_upstream=%s\n' "$(uci -q get dhcp.@dnsmasq[0].server 2>/dev/null || true)"
	printf 'dnsmasq_cache=%s\n' "$(uci -q get dhcp.@dnsmasq[0].cachesize 2>/dev/null || true)"
	printf 'nft=%s\n' "$(nft list table inet "$nft_table" >/dev/null 2>&1 && echo active || echo missing)"
	printf 'rule=%s\n' "$(ip -4 rule show | grep -q "fwmark $tproxy_mark/$tproxy_mask.*lookup $tproxy_table" &&
		echo active || echo missing)"
	printf 'healthy=%s\n' "$(runtime_healthy && echo yes || echo no)"
	cat "$state_file" 2>/dev/null || true
}

case "${1:-}" in
	render) init_config; render_config ;;
	check) init_config; check_config ;;
	prepare) prepare ;;
	refresh) with_lock refresh >>"$log_file" 2>&1 ;;
	adopt-upstream) with_lock adopt_upstream >>"$log_file" 2>&1 ;;
	activate) with_lock activate >>"$log_file" 2>&1 ;;
	deactivate) with_lock deactivate >>"$log_file" 2>&1 ;;
	fallback) fallback >>"$log_file" 2>&1 ;;
	activate-async) schedule activate ;;
	deactivate-async) schedule deactivate ;;
	refresh-async) schedule refresh ;;
	diagnostic-start)
		case "${2:-60}" in '' | *[!0-9]*) die 'Invalid diagnostic duration' ;; esac
		[ "${2:-60}" -ge 30 ] && [ "${2:-60}" -le 300 ] ||
			die 'Diagnostic duration must be 30-300 seconds'
		schedule resolver_diagnostic "${2:-60}"
		;;
	_run)
		shift
		run_async "$@"
		;;
	ensure) ensure_runtime >>"$log_file" 2>&1 ;;
	nft-start) nft_start ;;
	nft-stop) nft_stop ;;
	status) status ;;
	router-traffic) init_config; with_lock set_router_traffic "${2:-}" ;;
	log-level) init_config; with_lock set_log_level "${2:-}" ;;
	*)
		die 'Usage: ikev2-domain-router {render|check|prepare|refresh|adopt-upstream|activate|deactivate|fallback|activate-async|deactivate-async|refresh-async|diagnostic-start 30..300|ensure|nft-start|nft-stop|status|router-traffic 0|1|log-level LEVEL}'
		;;
esac
