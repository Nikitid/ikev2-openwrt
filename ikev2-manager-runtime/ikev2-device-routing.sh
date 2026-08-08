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
	device_addresses fullroute >"$full" || return 1
	device_addresses exclude >"$excluded" || return 1
	device_flag_addresses dpi_passthrough >"$dpi" || return 1
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
	collect_sources "$full" "$excluded" "$dpi" || return 1
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
	} | sha256sum | awk '{ print $1 }')"
	if runtime_owned && [ "$(cat "$signature_file" 2>/dev/null || true)" = "$signature" ] &&
	   runtime_matches "$full" "$excluded" "$dpi" "$work/listing" \
		"$ike_clear" "$ike_mark" "$wan_clear" "$wan_mark" "$dpi_mark"; then
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
		cat <<EOF
  chain prerouting {
    type filter hook prerouting priority -152; policy accept;
EOF
		[ -s "$dpi" ] && write_dpi_rules "$dpi" "$dpi_mark"
		write_route_rules "$excluded" exclude "$wan_clear" "$wan_mark"
		write_route_rules "$full" fullroute "$ike_clear" "$ike_mark"
		cat <<'EOF'
  }
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
	collect_sources "$work/full" "$work/excluded" "$work/dpi" || return 1
	ike_values="$(mark_values "$(pbr_mark_rule pbr_ikev2out)")" || return 1
	wan_values="$(mark_values "$(pbr_mark_rule pbr_wan)")" || return 1
	ike_clear="${ike_values%% *}"
	ike_mark="${ike_values#* }"
	wan_clear="${wan_values%% *}"
	wan_mark="${wan_values#* }"
	dpi_mark=''
	[ ! -s "$work/dpi" ] || dpi_mark="$(zapret_desync_mark)" || return 1
	runtime_matches "$work/full" "$work/excluded" "$work/dpi" "$work/listing" \
		"$ike_clear" "$ike_mark" "$wan_clear" "$wan_mark" "$dpi_mark"
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
