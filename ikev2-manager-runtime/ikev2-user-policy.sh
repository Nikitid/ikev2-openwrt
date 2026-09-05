#!/bin/sh

set -u
umask 077

config='ikev2-manager'
nft_bin="${IKEV2_NFT:-/usr/sbin/nft}"
table="${IKEV2_USER_POLICY_TABLE:-ikev2_user_policy}"
users_db="${IKEV2_USERS_DB:-/etc/ikev2-manager/users.db}"
sessions_file="${IKEV2_SESSIONS_FILE:-}"
raw_sessions_file="${IKEV2_SWANCTL_RAW:-}"
rules_out="${IKEV2_RULES_OUT:-}"
signature_file="${IKEV2_USER_POLICY_SIGNATURE:-/var/run/ikev2-user-policy.signature}"
session_state="${IKEV2_USER_POLICY_SESSIONS:-/var/run/ikev2-user-policy.sessions}"
sync_lock_dir="${IKEV2_USER_POLICY_LOCK:-/var/run/ikev2-user-policy.lock}"
refresh_interval="${IKEV2_USER_POLICY_REFRESH_INTERVAL:-30}"
swanctl_bin="${IKEV2_SWANCTL:-/usr/sbin/swanctl}"
socat_bin="${IKEV2_SOCAT:-/usr/bin/socat}"
event_source="${IKEV2_USER_POLICY_EVENT_SOURCE:-}"
uci_config_dir="${IKEV2_UCI_CONFIG_DIR:-/etc/config}"
uci_binary="${IKEV2_UCI_BIN:-/sbin/uci}"
runtime_lib_dir="${IKEV2_RUNTIME_LIB_DIR:-/usr/libexec/ikev2-manager.d}"
. "$runtime_lib_dir/actions.sh"
# Backstop only. The VICI watcher reacts to inbound CHILD_SA events immediately
# and performs a full authoritative reconciliation. This timeout protects
# active sessions if the event stream is temporarily unavailable; the periodic
# reconciliation refreshes it independently of outbound and DNS health checks.
session_timeout="${IKEV2_USER_POLICY_TIMEOUT:-90s}"
direct_tproxy_address='127.0.0.1'
direct_tproxy_port='1603'
direct_tproxy_mark='0x00400001'
tproxy_mark='0x00400000'
tproxy_mask='0x00ff0000'
fakeip_range='198.18.0.0/15'

uci() {
	"$uci_binary" -c "$uci_config_dir" "$@"
}

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
	rm -f "$signature_file" "$session_state"
}

acquire_sync_lock() {
	attempt=0
	while [ "$attempt" -lt 6 ]; do
		pid_lock_acquire "$sync_lock_dir" && return 0
		attempt=$((attempt + 1))
		sleep 1
	done
	printf '%s\n' 'Inbound user-policy update is already running' >&2
	return 1
}

release_sync_lock() {
	pid_lock_release "$sync_lock_dir"
}

run_locked() {
	operation="$1"
	acquire_sync_lock || return 1
	if "$operation"; then
		result=0
	else
		result=$?
	fi
	release_sync_lock
	return "$result"
}

valid_user() {
	[ -n "$1" ] && [ "${#1}" -le 64 ] &&
		printf '%s' "$1" | grep -Eq '^[A-Za-z0-9_.@-]+$'
}

valid_ipv4() {
	printf '%s\n' "$1" | awk -F. '
		NF != 4 { exit 1 }
		{
			for (i = 1; i <= 4; i++)
				if ($i !~ /^[0-9]+$/ || $i < 0 || $i > 255)
					exit 1
		}
	'
}

valid_ipv4_target() {
	case "$1" in
		*/*)
			address="${1%/*}"
			prefix="${1#*/}"
			case "$prefix" in '' | *[!0-9]*) return 1 ;; esac
			[ "$prefix" -le 32 ] && valid_ipv4 "$address"
			;;
		*) valid_ipv4 "$1" ;;
	esac
}

valid_target_list() {
	count=0
	for target in $1; do
		count=$((count + 1))
		[ "$count" -le 64 ] && valid_ipv4_target "$target" || return 1
	done
	[ "$count" -gt 0 ]
}

valid_port_list() {
	value="$(normalize_list "$1")"
	[ -z "$value" ] && return 0
	count=0
	for item in $value; do
		count=$((count + 1))
		[ "$count" -le 64 ] || return 1
		printf '%s' "$item" | grep -Eq '^[0-9]+(-[0-9]+)?$' || return 1
		start="${item%%-*}"
		end="${item#*-}"
		[ "$start" -ge 1 ] && [ "$start" -le 65535 ] || return 1
		[ "$end" -ge "$start" ] && [ "$end" -le 65535 ] || return 1
	done
}

valid_device() {
	[ -n "$1" ] && [ "${#1}" -le 15 ] &&
		printf '%s' "$1" | grep -Eq '^[A-Za-z0-9_.:@-]+$'
}

# BusyBox sort has no -o: it would silently leave the file untouched and print
# the sorted result on stdout instead. Duplicate elements then abort the whole
# nft transaction and every active client loses access when its timeout entry
# expires.
sort_unique_in_place() {
	file="$1"
	sort -u "$file" >"${file}.sorted" || return 1
	mv "${file}.sorted" "$file"
}

normalize_list() {
	printf '%s' "$1" | tr ',' ' ' | tr -s ' ' | sed 's/^ //;s/ $//'
}

policy_section() {
	printf 'user_%s\n' "$(printf '%s' "$1" | sha256sum | awk '{ print substr($1, 1, 16) }')"
}

policy_value() {
	user="$1"
	option="$2"
	fallback="$3"
	section="$(policy_section "$user")"
	saved_user="$(uci -q get "$config.$section.username" 2>/dev/null || true)"
	if [ "$saved_user" = "$user" ]; then
		value="$(uci -q get "$config.$section.$option" 2>/dev/null || true)"
	else
		value=''
	fi
	printf '%s\n' "${value:-$fallback}"
}

user_exists() {
	awk -F '\t' -v user="$1" '$1 == user { found = 1 } END { exit found ? 0 : 1 }' \
		"$users_db" 2>/dev/null
}

network_device() {
	interface="$1"
	device="$(ubus call "network.interface.$interface" status 2>/dev/null |
		jsonfilter -e '@.l3_device' 2>/dev/null || true)"
	[ -n "$device" ] ||
		device="$(ubus call "network.interface.$interface" status 2>/dev/null |
			jsonfilter -e '@.device' 2>/dev/null || true)"
	[ -n "$device" ] ||
		device="$(uci -q get "network.$interface.device" 2>/dev/null || true)"
	valid_device "$device" && printf '%s\n' "$device"
}

collect_lan_devices() {
	output="$1"
	: >"$output"
	for wanted in $(uci -q get "$config.server.lan_zone" 2>/dev/null || echo lan); do
		uci show firewall 2>/dev/null |
			sed -n 's/^firewall\.\([^.=]*\)=zone$/\1/p' |
			while IFS= read -r section; do
			name="$(uci -q get "firewall.$section.name" 2>/dev/null || true)"
			if [ "$name" = "$wanted" ]; then
				for network in $(uci -q get "firewall.$section.network" 2>/dev/null || true); do
					network_device "$network" >>"$output" 2>/dev/null || true
				done
				for device in $(uci -q get "firewall.$section.device" 2>/dev/null || true); do
					valid_device "$device" && printf '%s\n' "$device" >>"$output"
				done
			fi
		done
	done
	sort_unique_in_place "$output"
}

lan_access_configured() {
	[ "$(uci -q get "$config.server.allow_lan" 2>/dev/null || echo 1)" = 1 ] &&
		return 0
	for section in $(uci show "$config" 2>/dev/null |
		sed -n "s/^${config}\.\([^.=]*\)=user_policy$/\1/p"); do
		case "$(uci -q get "$config.$section.lan_access" 2>/dev/null || true)" in
			all | limited) return 0 ;;
		esac
	done
	return 1
}

collect_sessions() {
	output="$1"
	: >"$output"
	if [ -n "$sessions_file" ]; then
		[ -r "$sessions_file" ] && cat "$sessions_file" >"$output"
		return
	fi
	# Scope the listing to the inbound server's own connection. The segments
	# below are cut on "ikev2-in {" and matched greedily, so an unrelated
	# IKEv2 connection listed after a client session would contribute its
	# remote-vips to that client's line and authorise the wrong address.
	if [ -n "$raw_sessions_file" ] && [ -r "$raw_sessions_file" ]; then
		raw="$(cat "$raw_sessions_file")"
	else
		raw="$(swanctl --list-sas --ike ikev2-in --raw 2>/dev/null || true)"
	fi
	[ -n "$raw" ] || return 0
	# One segment per inbound session. Within a segment the session's own
	# fields come first, so the first match wins; anything trailing after the
	# last session belongs to another connection and must not be read.
	{
		printf '%s\n' "$raw" | tr '\n' ' '
		printf '\n'
	} |
		sed 's/ikev2-in {/\
ikev2-in {/g' |
		awk '
			/^ikev2-in \{/ {
				identity = ""
				address = ""
				if (match($0, /remote-eap-id="?[^ "}]+/)) {
					identity = substr($0, RSTART, RLENGTH)
					sub(/remote-eap-id="?/, "", identity)
				}
				if (match($0, /remote-vips=\[[^], }]+/)) {
					address = substr($0, RSTART, RLENGTH)
					sub(/remote-vips=\[/, "", address)
				}
				if (identity != "" && address != "")
					printf "%s\t%s\n", identity, address
			}
		' >"$output"
}

pbr_mark_rule() {
	ip -4 rule show 2>/dev/null |
		awk '
			/lookup pbr_wan([[:space:]]|$)/ {
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

set_elements() {
	file="$1"
	[ -s "$file" ] || return 0
	awk 'BEGIN { first=1 } NF { if (!first) printf ", "; printf "%s", $0; first=0 }' "$file"
}

write_address_set() {
	name="$1"
	file="$2"
	printf '  set %s {\n    type ipv4_addr\n    flags timeout\n    timeout %s\n' \
		"$name" "$session_timeout"
	if [ -s "$file" ]; then
		printf '    elements = { '
		set_elements "$file"
		printf ' }\n'
	fi
	printf '  }\n\n'
}

write_device_set() {
	file="$1"
	printf '  set lan_devices {\n    type ifname\n'
	if [ -s "$file" ]; then
		printf '    elements = { '
		awk 'BEGIN { first=1 } NF {
			if (!first) printf ", "
			printf "\"%s\"", $0
			first=0
		}' "$file"
		printf ' }\n'
	fi
	printf '  }\n\n'
}

resolve_access() {
	user="$1"
	global_router="$2"
	global_internet="$3"
	global_lan="$4"

	router="$(policy_value "$user" router_access inherit)"
	case "$router" in
		allow) resolved_router=1 ;;
		deny) resolved_router=0 ;;
		*) resolved_router="$global_router" ;;
	esac

	internet="$(policy_value "$user" internet_access inherit)"
	case "$internet" in
		allow) resolved_internet=1 ;;
		deny) resolved_internet=0 ;;
		*) resolved_internet="$global_internet" ;;
	esac

	lan="$(policy_value "$user" lan_access inherit)"
	case "$lan" in
		all | limited | deny) resolved_lan="$lan" ;;
		*) [ "$global_lan" = 1 ] && resolved_lan=all || resolved_lan=deny ;;
	esac

	pbr="$(policy_value "$user" pbr_mode inherit)"
	[ "$pbr" = exclude ] || pbr=inherit
}

sync_runtime() (
	enabled="$(uci -q get "$config.server.enabled" 2>/dev/null || echo 0)"
	configured="$(uci -q get "$config.globals.configured" 2>/dev/null || echo 0)"
	custom="$(uci -q get "$config.server.custom_config" 2>/dev/null || echo 0)"
	if [ "$enabled" != 1 ] || [ "$configured" != 1 ] || [ "$custom" = 1 ]; then
		stop_runtime
		return $?
	fi
	if runtime_exists && ! runtime_owned; then
		printf "nft table '%s' is not owned by IKEv2 Manager\n" "$table" >&2
		return 1
	fi

	pool="$(uci -q get "$config.server.pool4" 2>/dev/null || true)"
	case "$pool" in
		*-*) ;;
		*) printf '%s\n' 'Invalid inbound client pool' >&2; return 1 ;;
	esac
	if ! valid_ipv4 "${pool%%-*}" || ! valid_ipv4 "${pool#*-}"; then
		printf '%s\n' 'Invalid inbound client pool' >&2
		return 1
	fi

	work="${TMPDIR:-/tmp}/ikev2-user-policy.$$"
	mkdir -p "$work" || return 1
	trap 'rm -rf "$work"' EXIT INT TERM
	collect_sessions "$work/sessions"
	sort_unique_in_place "$work/sessions" || return 1
	# A lingering SA can still hold an address the pool has already handed to
	# the next user. Applying both identities would grant that address the
	# union of two policies, so an ambiguous address is dropped entirely.
	awk -F '\t' '
		NR == FNR { if (seen[$2]++ == 0) owner[$2] = $1; else if (owner[$2] != $1) bad[$2] = 1; next }
		!($2 in bad)
	' "$work/sessions" "$work/sessions" >"$work/sessions.filtered" || return 1
	mv "$work/sessions.filtered" "$work/sessions"
	collect_lan_devices "$work/lan-devices"
	if lan_access_configured && [ ! -s "$work/lan-devices" ]; then
		printf '%s\n' 'Unable to resolve an interface for the inbound LAN zones' >&2
		return 1
	fi
	: >"$work/router"
	: >"$work/internet"
	: >"$work/lan-full"
	: >"$work/pbr-excluded"
	: >"$work/limited"
	: >"$work/public"

	global_router="$(uci -q get "$config.server.allow_router" 2>/dev/null || echo 0)"
	global_internet="$(uci -q get "$config.server.allow_internet" 2>/dev/null || echo 1)"
	global_lan="$(uci -q get "$config.server.allow_lan" 2>/dev/null || echo 1)"
	mapped=0
	while IFS="$(printf '\t')" read -r user vip extra; do
		[ -z "${extra:-}" ] || continue
		if ! valid_user "$user" || ! valid_ipv4 "$vip" || ! user_exists "$user"; then
			continue
		fi
		resolve_access "$user" "$global_router" "$global_internet" "$global_lan"
		public_ports="$(normalize_list "$(policy_value "$user" public_ports '')")"
		valid_port_list "$public_ports" || {
			printf 'Invalid public router port list for VPN user %s\n' "$user" >&2
			return 1
		}
		[ -z "$public_ports" ] ||
			printf '%s\t%s\n' "$vip" "$public_ports" >>"$work/public"
		[ "$resolved_router" = 1 ] && printf '%s\n' "$vip" >>"$work/router"
		[ "$resolved_internet" = 1 ] && printf '%s\n' "$vip" >>"$work/internet"
		case "$resolved_lan" in
			all) printf '%s\n' "$vip" >>"$work/lan-full" ;;
			limited)
				targets="$(normalize_list "$(policy_value "$user" lan_targets '')")"
				valid_target_list "$targets" || {
					printf 'Invalid local target list for VPN user %s\n' "$user" >&2
					return 1
				}
				printf '%s\t%s\n' "$vip" "$targets" >>"$work/limited"
				;;
		esac
		[ "$pbr" = exclude ] && printf '%s\n' "$vip" >>"$work/pbr-excluded"
		mapped=$((mapped + 1))
	done <"$work/sessions"
	for file in router internet lan-full pbr-excluded; do
		sort_unique_in_place "$work/$file" || return 1
	done

	wan_values="$(mark_values "$(pbr_mark_rule)")" || wan_values=''
	if [ -s "$work/pbr-excluded" ] && [ -z "$wan_values" ]; then
		printf '%s\n' 'Unable to derive the active WAN PBR mark' >&2
		return 1
	fi
	wan_clear="${wan_values%% *}"
	wan_mark="${wan_values#* }"
	domain_engine="$(uci -q get "$config.domains.engine" 2>/dev/null || echo nftset)"
	if [ "$domain_engine" = fakeip ] && [ -s "$work/pbr-excluded" ]; then
		case "$fakeip_range" in
			*/*) valid_ipv4_target "$fakeip_range" ;;
			*) false ;;
		esac || {
			printf '%s\n' 'Invalid FakeIP range for inbound PBR exclusion' >&2
			return 1
		}
	fi

	rules="$work/rules.nft"
	{
		runtime_exists && printf 'delete table inet %s\n' "$table"
		printf 'table inet %s {\n' "$table"
		cat <<'EOF'
  chain ikev2_manager_owned {
    comment "IKEv2 Manager inbound user policy"
  }

EOF
		printf '  set inbound_pool {\n    type ipv4_addr\n    flags interval\n'
		printf '    elements = { %s }\n  }\n\n' "$pool"
		write_device_set "$work/lan-devices"
		write_address_set router_allowed "$work/router"
		write_address_set internet_allowed "$work/internet"
		write_address_set lan_full "$work/lan-full"
		write_address_set pbr_excluded "$work/pbr-excluded"

		limited_index=0
		while IFS="$(printf '\t')" read -r vip targets; do
			limited_index=$((limited_index + 1))
			printf '  set lan_limited_%s {\n' "$limited_index"
			printf '    type ipv4_addr\n    flags timeout\n    timeout %s\n' "$session_timeout"
			printf '    elements = { %s }\n  }\n\n' "$vip"
		done <"$work/limited"

		public_index=0
		while IFS="$(printf '\t')" read -r vip ports; do
			public_index=$((public_index + 1))
			printf '  set public_client_%s {\n' "$public_index"
			printf '    type ipv4_addr\n    flags timeout\n    timeout %s\n' "$session_timeout"
			printf '    elements = { %s }\n  }\n\n' "$vip"
		done <"$work/public"

		cat <<EOF
  chain input {
    type filter hook input priority -1; policy accept;
    iifname "ipsec-in" ip saddr @inbound_pool meta l4proto { tcp, udp } th dport 53 return
    iifname "ipsec-in" ip saddr @inbound_pool meta mark & $tproxy_mask == $tproxy_mark ip saddr @internet_allowed return
    iifname "ipsec-in" ip saddr @inbound_pool meta mark & $tproxy_mask == $tproxy_mark counter drop
EOF
		public_index=0
		while IFS="$(printf '\t')" read -r vip ports; do
			public_index=$((public_index + 1))
			printf '    iifname "ipsec-in" ip saddr @public_client_%s meta l4proto { tcp, udp } th dport { ' \
				"$public_index"
			printf '%s' "$ports" | tr ' ' ',' | sed 's/,/, /g'
			printf ' } return\n'
		done <"$work/public"
		cat <<EOF
    iifname "ipsec-in" ip saddr @router_allowed return
    iifname "ipsec-in" ip saddr @inbound_pool counter drop
  }

  chain forward {
    type filter hook forward priority -1; policy accept;
    iifname "ipsec-in" ip saddr @inbound_pool jump inbound_policy
  }

  chain inbound_policy {
    ip daddr @inbound_pool counter drop
    oifname @lan_devices jump lan_policy
    ip saddr @internet_allowed return
    counter drop
  }

  chain lan_policy {
    ip saddr @lan_full return
EOF
		limited_index=0
		while IFS="$(printf '\t')" read -r vip targets; do
			limited_index=$((limited_index + 1))
			printf '    ip saddr @lan_limited_%s ip daddr { ' "$limited_index"
			printf '%s' "$targets" | tr ' ' ',' | sed 's/,/, /g'
			printf ' } return\n'
		done <"$work/limited"
		cat <<'EOF'
    counter drop
  }
EOF
		if [ -s "$work/pbr-excluded" ] && [ "$domain_engine" = fakeip ]; then
			cat <<EOF

  chain direct_tproxy {
    type filter hook prerouting priority -153; policy accept;
    iifname "ipsec-in" ip saddr @pbr_excluded ip daddr $fakeip_range meta l4proto tcp meta mark set $direct_tproxy_mark tproxy ip to $direct_tproxy_address:$direct_tproxy_port counter accept
    iifname "ipsec-in" ip saddr @pbr_excluded ip daddr $fakeip_range meta l4proto udp meta mark set $direct_tproxy_mark tproxy ip to $direct_tproxy_address:$direct_tproxy_port counter accept
  }
EOF
		fi
		if [ -s "$work/pbr-excluded" ]; then
			cat <<EOF

  chain direct_wan {
    type filter hook prerouting priority -149; policy accept;
    iifname "ipsec-in" ip saddr @pbr_excluded meta mark & $tproxy_mask != $tproxy_mark meta mark set meta mark & $wan_clear | $wan_mark counter accept
  }
EOF
		fi
		echo '}'
	} >"$rules"

	if [ -n "$rules_out" ]; then
		cp "$rules" "$rules_out"
	else
		"$nft_bin" -c -f "$rules" >/dev/null 2>&1 || {
			printf '%s\n' 'Inbound user-policy nftables validation failed' >&2
			return 1
		}
		"$nft_bin" -f "$rules" >/dev/null 2>&1 || {
			printf '%s\n' 'Unable to install inbound user-policy rules' >&2
			return 1
		}
		signature="$({
			sed "/^delete table inet $table$/d" "$rules"
			cat "$work/sessions"
		} | sha256sum | awk '{ print $1 }')"
		previous="$(cat "$signature_file" 2>/dev/null || true)"
		if [ "$signature" != "$previous" ] && command -v conntrack >/dev/null 2>&1; then
			{
				awk -F '\t' 'NF >= 2 { print $2 }' "$work/sessions"
				cat "$session_state" 2>/dev/null || true
			} | sort -u |
				while IFS= read -r address; do
					valid_ipv4 "$address" || continue
					conntrack -D -s "$address" >/dev/null 2>&1 || :
				done
		fi
		mkdir -p "${signature_file%/*}" "${session_state%/*}"
		printf '%s\n' "$signature" >"${signature_file}.new"
		mv "${signature_file}.new" "$signature_file"
		awk -F '\t' 'NF >= 2 { print $2 }' "$work/sessions" |
			sort -u >"${session_state}.new"
		chmod 600 "${session_state}.new"
		mv "${session_state}.new" "$session_state"
	fi
	printf 'mapped=%s\n' "$mapped"
	rm -rf "$work"
	trap - EXIT INT TERM
)

check_runtime() {
	enabled="$(uci -q get "$config.server.enabled" 2>/dev/null || echo 0)"
	configured="$(uci -q get "$config.globals.configured" 2>/dev/null || echo 0)"
	custom="$(uci -q get "$config.server.custom_config" 2>/dev/null || echo 0)"
	if [ "$enabled" != 1 ] || [ "$configured" != 1 ] || [ "$custom" = 1 ]; then
		! runtime_exists
		return
	fi
	runtime_owned || return 1
	local input forward policy set_name
	input="$("$nft_bin" list chain inet "$table" input 2>/dev/null)" || return 1
	forward="$("$nft_bin" list chain inet "$table" forward 2>/dev/null)" || return 1
	policy="$("$nft_bin" list chain inet "$table" inbound_policy 2>/dev/null)" || return 1
	printf '%s\n' "$input" | grep -q 'hook input' || return 1
	printf '%s\n' "$input" | grep -Eq 'ip saddr @inbound_pool.*drop' || return 1
	printf '%s\n' "$forward" | grep -q 'hook forward' || return 1
	printf '%s\n' "$forward" | grep -q 'jump inbound_policy' || return 1
	printf '%s\n' "$policy" | grep -Eq 'ip daddr @inbound_pool.*drop' || return 1
	for set_name in inbound_pool internet_allowed router_allowed lan_full pbr_excluded; do
		"$nft_bin" list set inet "$table" "$set_name" >/dev/null 2>&1 || return 1
	done
}

capture_inbound_sas() {
	output="$1"
	capture_pid=''
	watchdog_pid=''
	sleeper_pid=''
	rc=0
	"$swanctl_bin" --list-sas --ike ikev2-in --raw >"$output" 2>/dev/null &
	capture_pid=$!
	(
		trap '[ -z "$sleeper_pid" ] || kill "$sleeper_pid" 2>/dev/null; exit 0' TERM INT
		sleep 3 &
		sleeper_pid=$!
		wait "$sleeper_pid" 2>/dev/null || exit 0
		kill "$capture_pid" 2>/dev/null || :
	) >/dev/null 2>&1 &
	watchdog_pid=$!
	wait "$capture_pid" 2>/dev/null || rc=$?
	kill "$watchdog_pid" 2>/dev/null || :
	wait "$watchdog_pid" 2>/dev/null || :
	return "$rc"
}

monitor_source() {
	# swanctl uses stdio and does not explicitly flush every VICI event. socat
	# gives it a PTY so each newline is delivered immediately instead of waiting
	# for a pipe buffer. stderr is intentionally discarded: a monitor failure is
	# reported by the parent watcher and recovered by procd.
	exec "$swanctl_bin" --monitor-sa --raw 2>/dev/null
}

run_event_source() {
	if [ -n "$event_source" ]; then
		exec "$event_source"
	fi
	[ -x "$socat_bin" ] || return 127
	exec "$socat_bin" -u "EXEC:$0 monitor-source,pty,rawer" STDOUT
}

watch_runtime() {
	case "$refresh_interval" in
		'' | *[!0-9]* | 0)
			printf '%s\n' 'Invalid inbound user-policy refresh interval' >&2
			return 1
			;;
	esac
	raw="${TMPDIR:-/tmp}/ikev2-user-policy-watch.$$"
	events="${raw}.events"
	monitor_pid=''
	refresh_pid=''
	cleanup_watcher() {
		if [ -n "$refresh_pid" ]; then
			kill "$refresh_pid" 2>/dev/null || true
			wait "$refresh_pid" 2>/dev/null || true
			refresh_pid=''
		fi
		if [ -n "$monitor_pid" ]; then
			kill "$monitor_pid" 2>/dev/null || true
			wait "$monitor_pid" 2>/dev/null || true
			monitor_pid=''
		fi
		exec 3>&- 3<&-
		rm -f "$raw" "${raw}.new" "$events"
	}
	reload_watcher() {
		cleanup_watcher
		exec "$0" watch
	}
	trap 'cleanup_watcher; exit 0' INT TERM
	trap reload_watcher HUP
	trap cleanup_watcher EXIT
	rm -f "$events"
	mkfifo "$events" || return 1
	# Open both ends before starting the producer, otherwise either side may
	# block while procd is starting or stopping the service.
	exec 3<>"$events"
	# Preserve the boot-time fail-closed guard even if charon is not ready yet.
	"$0" sync >/dev/null 2>&1 || true
	(
		source_pid=''
		stop_source() {
			[ -z "$source_pid" ] || kill "$source_pid" 2>/dev/null || true
			[ -z "$source_pid" ] || wait "$source_pid" 2>/dev/null || true
		}
		trap 'stop_source; exit 0' INT TERM
		run_event_source &
		source_pid=$!
		wait "$source_pid"
		rc=$?
		source_pid=''
		printf 'ikev2-monitor-exit=%s\n' "$rc"
	) >"$events" 2>/dev/null &
	monitor_pid=$!
	(
		sleeper_pid=''
		stop_refresh() {
			[ -z "$sleeper_pid" ] || kill "$sleeper_pid" 2>/dev/null || true
			[ -z "$sleeper_pid" ] || wait "$sleeper_pid" 2>/dev/null || true
			exit 0
		}
		trap stop_refresh INT TERM
		while true; do
			sleep "$refresh_interval" &
			sleeper_pid=$!
			wait "$sleeper_pid"
			sleeper_pid=''
			printf '%s\n' ikev2-refresh
		done
	) >"$events" 2>/dev/null &
	refresh_pid=$!
	# Close the registration gap: an SA established before VICI subscribed is
	# covered by this second snapshot, while an event already queued in the FIFO
	# merely causes one harmless additional reconciliation.
	sleep 1
	"$0" sync >/dev/null 2>&1 || true
	while true; do
		IFS= read -r event <&3 || return 1
		case "$event" in
			ikev2-monitor-exit=*)
				printf '%s\n' 'Inbound VICI monitor stopped' >&2
				return 1
				;;
			ikev2-refresh|'child-updown event {'*'ikev2-in {'*)
				# The timer is the recovery path for a lost event and refreshes
				# timeout-backed set elements without polling every two seconds.
				"$0" sync >/dev/null 2>&1 || true
				;;
		esac
	done
}

case "${1:-sync}" in
	sync) run_locked sync_runtime ;;
	stop) run_locked stop_runtime ;;
	check) check_runtime ;;
	watch) watch_runtime ;;
	monitor-source) monitor_source ;;
	*) printf 'usage: %s [sync|stop|check|watch|monitor-source]\n' "$0" >&2; exit 2 ;;
esac
