#!/bin/sh

set -u

config='ikev2-manager'
nft_bin="${IKEV2_NFT:-/usr/sbin/nft}"
table="${IKEV2_DEVICE_TABLE:-ikev2_device_policy}"
signature_file="${IKEV2_DEVICE_SIGNATURE:-/var/run/ikev2-device-routing.signature}"
runtime_lib_dir="${IKEV2_RUNTIME_LIB_DIR:-/usr/libexec/ikev2-manager.d}"

. "$runtime_lib_dir/devices.sh"

runtime_exists() {
	"$nft_bin" list table inet "$table" >/dev/null 2>&1
}

runtime_owned() {
	"$nft_bin" list table inet "$table" 2>/dev/null |
		grep -Fq 'chain ikev2_manager_owned'
}

stop_runtime() {
	if runtime_exists; then
		runtime_owned || {
			printf "nft table '%s' is not owned by IKEv2 Manager\n" "$table" >&2
			return 1
		}
		"$nft_bin" delete table inet "$table" >/dev/null 2>&1 || return 1
	fi
	rm -f "$signature_file"
}

pbr_mark_rule() {
	lookup="$1"
	ip -4 rule show 2>/dev/null |
		awk -v table="$lookup" '
			$0 ~ ("lookup " table "([[:space:]]|$)") {
				for (i = 1; i <= NF; i++)
					if ($i == "fwmark") { print $(i + 1); exit }
			}
		'
}

mark_values() {
	rule="$1"
	case "$rule" in
		0x[0-9A-Fa-f]*/0x[0-9A-Fa-f]*) ;;
		*) return 1 ;;
	esac
	mark="${rule%%/*}"
	mask="${rule#*/}"
	mark_value=$((mark))
	mask_value=$((mask))
	clear_value=$((0xffffffff ^ mask_value))
	printf '%s %s\n' "$(printf '0x%08x' "$clear_value")" \
		"$(printf '0x%08x' "$mark_value")"
}

collect_sources() {
	full="$1"
	excluded="$2"
	dpi="$3"
	dns="$4"
	device_addresses fullroute >"$full" || return 1
	device_addresses exclude >"$excluded" || return 1
	device_flag_addresses dpi_passthrough >"$dpi" || return 1
	device_flag_addresses dns_passthrough >"$dns" || return 1
}

valid_ifname() {
	[ -n "${1:-}" ] && printf '%s\n' "$1" | grep -Eq '^[A-Za-z0-9_.:@-]+$'
}

normalized_address() {
	local value="$1" calculated network prefix
	case "$value" in
		*/*)
			calculated="$(ipcalc.sh "$value" 2>/dev/null)" || return 1
			network="$(printf '%s\n' "$calculated" | sed -n 's/^NETWORK=//p' | head -n1)"
			prefix="$(printf '%s\n' "$calculated" | sed -n 's/^PREFIX=//p' | head -n1)"
			[ -n "$network" ] && [ -n "$prefix" ] || return 1
			[ "$prefix" = 32 ] && printf '%s\n' "$network" ||
				printf '%s/%s\n' "$network" "$prefix"
			;;
		*) printf '%s\n' "$value" ;;
	esac
}

network_device() {
	local interface="$1" device
	device="$(ubus call "network.interface.$interface" status 2>/dev/null |
		jsonfilter -e '@.l3_device' 2>/dev/null || true)"
	[ -n "$device" ] ||
		device="$(ubus call "network.interface.$interface" status 2>/dev/null |
			jsonfilter -e '@.device' 2>/dev/null || true)"
	[ -n "$device" ] ||
		device="$(uci -q get "network.$interface.device" 2>/dev/null || true)"
	valid_ifname "$device" && printf '%s\n' "$device"
}

collect_policy_ifaces() {
	local sources="$1" wan="$2" dns_enforce block_dot interface device
	: >"$sources"
	: >"$wan"
	dns_enforce="$(uci -q get "$config.globals.dns_enforce" 2>/dev/null || echo 0)"
	block_dot="$(uci -q get "$config.globals.block_dot" 2>/dev/null || echo 0)"
	[ "$dns_enforce" = 1 ] || [ "$block_dot" = 1 ] || return 0
	for interface in $(uci -q get "$config.globals.source_interface" 2>/dev/null || true); do
		device="$(network_device "$interface" || true)"
		[ -n "$device" ] || {
			printf "Protected network '%s' has no usable device\n" "$interface" >&2
			return 1
		}
		printf '%s\n' "$device" >>"$sources"
	done
	if [ "$(uci -q get "$config.globals.source_include_vpn" 2>/dev/null || echo 1)" = 1 ] &&
	   [ "$(uci -q get "$config.server.enabled" 2>/dev/null || echo 0)" = 1 ]; then
		printf '%s\n' 'ipsec-in' >>"$sources"
	fi
	sort -u "$sources" >"${sources}.sorted" || return 1
	mv "${sources}.sorted" "$sources" || return 1
	[ -s "$sources" ] || {
		printf '%s\n' 'DNS policy has no protected network devices' >&2
		return 1
	}
	[ "$block_dot" = 1 ] || return 0
	interface="$(uci -q get "$config.globals.wan_interface" 2>/dev/null || echo wan)"
	device="$(network_device "$interface" || true)"
	[ -n "$device" ] || {
		printf "WAN network '%s' has no usable device\n" "$interface" >&2
		return 1
	}
	printf '%s\n' "$device" >"$wan"
}

runtime_matches() {
	full="$1"
	excluded="$2"
	dpi="$3"
	listing="$4"
	ike_clear="$5"
	ike_mark="$6"
	wan_clear="$7"
	wan_mark="$8"
	dpi_mark="$9"
	"$nft_bin" list chain inet "$table" prerouting >"$listing" 2>/dev/null || return 1
	expected=0
	for spec in "fullroute:$full" "exclude:$excluded" "dpi:$dpi"; do
		kind="${spec%%:*}"
		file="${spec#*:}"
		while IFS= read -r address; do
			[ -n "$address" ] || continue
			line="$(grep -F "comment \"ikev2-device:$kind:$address\"" "$listing" || true)"
			[ -n "$line" ] || return 1
			case "$kind" in
				fullroute) expected_mark="meta mark & $ike_clear | $ike_mark" ;;
				exclude) expected_mark="meta mark & $wan_clear | $wan_mark" ;;
				dpi) expected_mark="meta mark | $dpi_mark" ;;
			esac
			printf '%s\n' "$line" | grep -Fq "$expected_mark" || return 1
			expected=$((expected + 1))
		done <"$file"
	done
	actual="$(grep -c 'comment "ikev2-device:' "$listing" 2>/dev/null || true)"
	[ "$actual" -eq "$expected" ]
}

policy_runtime_matches() {
	local dns="$1" sources="$2" wan="$3" work="$4"
	local dns_enforce block_dot spec name file value pattern
	dns_enforce="$(uci -q get "$config.globals.dns_enforce" 2>/dev/null || echo 0)"
	block_dot="$(uci -q get "$config.globals.block_dot" 2>/dev/null || echo 0)"
	"$nft_bin" list table inet "$table" >"$work/policy-listing" 2>/dev/null || return 1
	for spec in "dns_bypass_ipv4:$dns" "source_ifaces:$sources"; do
		name="${spec%%:*}"
		file="${spec#*:}"
		"$nft_bin" list set inet "$table" "$name" >"$work/set-$name" 2>/dev/null || return 1
		while IFS= read -r value; do
			[ -n "$value" ] || continue
			if [ "$name" = dns_bypass_ipv4 ]; then
				value="$(normalized_address "$value")" || return 1
				pattern="$(printf '%s' "$value" | sed 's/[.]/\\./g')"
				grep -Eq "(^|[,{[:space:]])${pattern}([,}[:space:]]|$)" \
					"$work/set-$name" || return 1
			else
				grep -Fq "\"$value\"" "$work/set-$name" || return 1
			fi
		done <"$file"
	done
	if [ "$block_dot" = 1 ]; then
		"$nft_bin" list set inet "$table" wan_ifaces >"$work/set-wan_ifaces" 2>/dev/null || return 1
		while IFS= read -r value; do
			[ -n "$value" ] || continue
			grep -Fq "\"$value\"" "$work/set-wan_ifaces" || return 1
		done <"$wan"
	fi
	if [ "$dns_enforce" = 1 ]; then
		"$nft_bin" list chain inet "$table" dns_prerouting >"$work/dns-chain" 2>/dev/null || return 1
		grep -Fq 'comment "ikev2-device:dns-enforce"' "$work/dns-chain" || return 1
	else
		! "$nft_bin" list chain inet "$table" dns_prerouting >/dev/null 2>&1 || return 1
	fi
	if [ "$block_dot" = 1 ]; then
		"$nft_bin" list chain inet "$table" dot_forward >"$work/dot-chain" 2>/dev/null || return 1
		grep -Fq 'comment "ikev2-device:dot-block"' "$work/dot-chain" || return 1
	else
		! "$nft_bin" list chain inet "$table" dot_forward >/dev/null 2>&1 || return 1
	fi
}

zapret_desync_mark() {
	value="$(uci -q get zapret.config.DESYNC_MARK 2>/dev/null || true)"
	printf '%s\n' "$value" | grep -Eq '^0x[0-9A-Fa-f]{1,8}$' || return 1
	[ "$((value))" -ne 0 ] || return 1
	printf '%s\n' "$value" | tr 'A-F' 'a-f'
}

set_elements() {
	file="$1"
	[ -s "$file" ] || return 0
	awk 'BEGIN { first=1 } NF { if (!first) printf ", "; printf "%s", $0; first=0 }' "$file"
}

write_set() {
	name="$1"
	file="$2"
	printf '  set %s {\n    type ipv4_addr\n    flags interval\n' "$name"
	if [ -s "$file" ]; then
		printf '    elements = { '
		set_elements "$file"
		printf ' }\n'
	fi
	printf '  }\n\n'
}

ifname_elements() {
	file="$1"
	[ -s "$file" ] || return 0
	awk 'BEGIN { first=1 } NF { if (!first) printf ", "; printf "\"%s\"", $0; first=0 }' "$file"
}

write_ifname_set() {
	name="$1"
	file="$2"
	printf '  set %s {\n    type ifname\n' "$name"
	if [ -s "$file" ]; then
		printf '    elements = { '
		ifname_elements "$file"
		printf ' }\n'
	fi
	printf '  }\n\n'
}

write_dpi_rules() {
	file="$1"
	mark="$2"
	while IFS= read -r address; do
		[ -n "$address" ] || continue
		printf '    ip saddr %s meta mark set meta mark | %s counter comment "ikev2-device:dpi:%s"\n' \
			"$address" "$mark" "$address"
	done <"$file"
}

write_route_rules() {
	file="$1"
	kind="$2"
	clear="$3"
	mark="$4"
	while IFS= read -r address; do
		[ -n "$address" ] || continue
		printf '    ip saddr %s meta mark set meta mark & %s | %s counter accept comment "ikev2-device:%s:%s"\n' \
			"$address" "$clear" "$mark" "$kind" "$address"
	done <"$file"
}

sync_runtime() {
	[ "$(uci -q get "$config.globals.configured" 2>/dev/null || echo 0)" = 1 ] || {
		stop_runtime
		return $?
	}
	ike_values="$(mark_values "$(pbr_mark_rule pbr_ikev2out)")" || {
		printf '%s\n' 'Unable to derive the active IKEv2 PBR mark' >&2
		return 1
	}
	wan_values="$(mark_values "$(pbr_mark_rule pbr_wan)")" || {
		printf '%s\n' 'Unable to derive the active WAN PBR mark' >&2
		return 1
	}
	ike_clear="${ike_values%% *}"
	ike_mark="${ike_values#* }"
	wan_clear="${wan_values%% *}"
	wan_mark="${wan_values#* }"

	work="${TMPDIR:-/tmp}/ikev2-device-routing.$$"
	mkdir -p "$work" || return 1
	trap 'rm -rf "$work"' EXIT INT TERM
	full="$work/full"
	excluded="$work/excluded"
	dpi="$work/dpi"
	dns="$work/dns"
	sources="$work/sources"
	wan="$work/wan"
	collect_sources "$full" "$excluded" "$dpi" "$dns" || return 1
	collect_policy_ifaces "$sources" "$wan" || return 1
	dns_enforce="$(uci -q get "$config.globals.dns_enforce" 2>/dev/null || echo 0)"
	block_dot="$(uci -q get "$config.globals.block_dot" 2>/dev/null || echo 0)"
	dpi_mark=''
	if [ -s "$dpi" ]; then
		dpi_mark="$(zapret_desync_mark)" || {
			printf '%s\n' 'DPI passthrough requires a valid non-zero zapret.config.DESYNC_MARK' >&2
			return 1
		}
	fi

	signature="$({
		printf 'ike=%s/%s\nwan=%s/%s\nfull\n' "$ike_clear" "$ike_mark" "$wan_clear" "$wan_mark"
		cat "$full"
		printf 'excluded\n'
		cat "$excluded"
		printf 'dpi=%s\n' "$dpi_mark"
		cat "$dpi"
		printf 'dns=%s\n' "$dns_enforce"
		cat "$dns"
		printf 'dot=%s\nsources\n' "$block_dot"
		cat "$sources"
		printf 'wan\n'
		cat "$wan"
	} | sha256sum | awk '{ print $1 }')"
	if runtime_owned && [ "$(cat "$signature_file" 2>/dev/null || true)" = "$signature" ] &&
	   runtime_matches "$full" "$excluded" "$dpi" "$work/listing" \
		"$ike_clear" "$ike_mark" "$wan_clear" "$wan_mark" "$dpi_mark" &&
	   policy_runtime_matches "$dns" "$sources" "$wan" "$work"; then
		rm -rf "$work"
		trap - EXIT INT TERM
		return 0
	fi
	if runtime_exists && ! runtime_owned; then
		printf "nft table '%s' is not owned by IKEv2 Manager\n" "$table" >&2
		return 1
	fi

	rules="$work/rules.nft"
	{
		runtime_exists && printf 'delete table inet %s\n' "$table"
		printf 'table inet %s {\n' "$table"
		cat <<'EOF'
  chain ikev2_manager_owned {
    comment "IKEv2 Manager device routing"
  }

EOF
		write_set full_route_ipv4 "$full"
		write_set exclude_ipv4 "$excluded"
		write_set dns_bypass_ipv4 "$dns"
		write_ifname_set source_ifaces "$sources"
		write_ifname_set wan_ifaces "$wan"
		cat <<EOF
  chain prerouting {
    type filter hook prerouting priority -152; policy accept;
EOF
		[ -s "$dpi" ] && write_dpi_rules "$dpi" "$dpi_mark"
		write_route_rules "$excluded" exclude "$wan_clear" "$wan_mark"
		write_route_rules "$full" fullroute "$ike_clear" "$ike_mark"
		printf '  }\n\n'
		if [ "$dns_enforce" = 1 ]; then
			cat <<'EOF'
  chain dns_prerouting {
    type nat hook prerouting priority -102; policy accept;
    iifname @source_ifaces ip saddr != @dns_bypass_ipv4 meta l4proto { tcp, udp } th dport 53 counter redirect to :53 comment "ikev2-device:dns-enforce"
  }

EOF
		fi
		if [ "$block_dot" = 1 ]; then
			cat <<'EOF'
  chain dot_forward {
    type filter hook forward priority -2; policy accept;
    iifname @source_ifaces oifname @wan_ifaces ip saddr != @dns_bypass_ipv4 meta l4proto { tcp, udp } th dport 853 counter reject comment "ikev2-device:dot-block"
  }

EOF
		fi
		cat <<'EOF'
}
EOF
	} >"$rules"
	"$nft_bin" -c -f "$rules" >"$work/nft-check.log" 2>&1 || {
		printf '%s\n' 'Device-routing nftables validation failed' >&2
		cat "$work/nft-check.log" >&2
		return 1
	}
	"$nft_bin" -f "$rules" >/dev/null 2>&1 || {
		printf '%s\n' 'Unable to install device-routing nftables rules' >&2
		return 1
	}
	mkdir -p "${signature_file%/*}"
	printf '%s\n' "$signature" >"${signature_file}.new"
	mv "${signature_file}.new" "$signature_file"
	rm -rf "$work"
	trap - EXIT INT TERM
}

check_runtime() {
	[ "$(uci -q get "$config.globals.configured" 2>/dev/null || echo 0)" = 1 ] || {
		! runtime_exists
		return
	}
	runtime_owned || return 1
	work="${TMPDIR:-/tmp}/ikev2-device-check.$$"
	mkdir -p "$work" || return 1
	trap 'rm -rf "$work"' EXIT INT TERM
	collect_sources "$work/full" "$work/excluded" "$work/dpi" "$work/dns" || return 1
	collect_policy_ifaces "$work/sources" "$work/wan" || return 1
	ike_values="$(mark_values "$(pbr_mark_rule pbr_ikev2out)")" || return 1
	wan_values="$(mark_values "$(pbr_mark_rule pbr_wan)")" || return 1
	ike_clear="${ike_values%% *}"
	ike_mark="${ike_values#* }"
	wan_clear="${wan_values%% *}"
	wan_mark="${wan_values#* }"
	dpi_mark=''
	[ ! -s "$work/dpi" ] || dpi_mark="$(zapret_desync_mark)" || return 1
	runtime_matches "$work/full" "$work/excluded" "$work/dpi" "$work/listing" \
		"$ike_clear" "$ike_mark" "$wan_clear" "$wan_mark" "$dpi_mark" &&
		policy_runtime_matches "$work/dns" "$work/sources" "$work/wan" "$work"
	status=$?
	rm -rf "$work"
	trap - EXIT INT TERM
	return "$status"
}

stats_runtime() {
	runtime_owned || return 0
	"$nft_bin" list chain inet "$table" prerouting 2>/dev/null |
	while IFS= read -r line; do
		case "$line" in
			*'comment "ikev2-device:'*) ;;
			*) continue ;;
		esac
		identifier="$(printf '%s\n' "$line" |
			sed -n 's/.*comment "ikev2-device:\([^"]*\)".*/\1/p')"
		packets="$(printf '%s\n' "$line" |
			sed -n 's/.*counter packets \([0-9][0-9]*\) bytes.*/\1/p')"
		bytes="$(printf '%s\n' "$line" |
			sed -n 's/.*counter packets [0-9][0-9]* bytes \([0-9][0-9]*\).*/\1/p')"
		kind="${identifier%%:*}"
		address="${identifier#*:}"
		[ -n "$kind" ] && [ "$address" != "$identifier" ] || continue
		printf 'addr=%s kind=%s packets=%s bytes=%s\n' \
			"$address" "$kind" "${packets:-0}" "${bytes:-0}"
	done
}

case "${1:-sync}" in
	sync) sync_runtime ;;
	stop) stop_runtime ;;
	check) check_runtime ;;
	stats) stats_runtime ;;
	*) printf 'usage: %s [sync|stop|check|stats]\n' "$0" >&2; exit 2 ;;
esac
