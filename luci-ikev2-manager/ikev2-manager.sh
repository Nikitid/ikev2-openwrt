#!/bin/sh

set -eu
umask 077

root="${IKEV2_ROOT:-}"
uci_config_dir="${IKEV2_UCI_CONFIG_DIR:-$root/etc/config}"
uci_binary="${IKEV2_UCI_BIN:-/sbin/uci}"

uci() {
	"$uci_binary" -c "$uci_config_dir" "$@"
}

uci_config='ikev2-manager'
users_db="$root/etc/ikev2-manager/users.db"
inbound_conf="$root/etc/swanctl/conf.d/30-inbound.conf"
inbound_secrets="$root/etc/swanctl/conf.d/91-inbound-secrets.conf"
outbound_conf="$root/etc/swanctl/conf.d/20-proxy-out.conf"
outbound_secret="$root/etc/swanctl/conf.d/90-proxy-out-secret.conf"
client_secret_db="$root/etc/ikev2-manager/client.secret"
user_input_file="${IKEV2_USER_INPUT:-}"
client_input_file="${IKEV2_CLIENT_INPUT:-}"
server_input_file="${IKEV2_SERVER_INPUT:-}"
inbound_custom="$root/etc/ikev2-manager/inbound.custom.conf"
outbound_custom="$root/etc/ikev2-manager/outbound.custom.conf"
system_helper="${IKEV2_SYSTEM_HELPER:-$root/usr/libexec/ikev2-manager-system}"
acme_cert_section='ikev2'
acme_log_file='/tmp/ikev2-acme.log'
acme_dnsapi_dir="${IKEV2_ACME_DNSAPI:-/usr/lib/acme/client/dnsapi}"
acme_input_file="${IKEV2_ACME_INPUT:-}"
action_status_file="${IKEV2_ACTION_STATUS:-/var/run/ikev2-manager-action.status}"
action_status_dir="${IKEV2_ACTION_STATUS_DIR:-/var/run/ikev2-manager-actions}"
action_lock_dir="${IKEV2_ACTION_LOCK:-/var/run/ikev2-action.lock}"
action_lock_status="${IKEV2_ACTION_LOCK_STATUS:-/var/run/ikev2-action.lock.status}"
auto_connect_lock="${IKEV2_AUTO_CONNECT_LOCK:-/var/run/ikev2-auto-connect.lock}"
auto_connect_attempt="${IKEV2_AUTO_CONNECT_ATTEMPT:-/var/run/ikev2-auto-connect.attempt}"
config_lock_dir="${IKEV2_CONFIG_LOCK:-/var/run/ikev2-manager-config.lock}"
runtime_lib_dir="${IKEV2_RUNTIME_LIB_DIR:-$root/usr/libexec/ikev2-manager.d}"

. "$runtime_lib_dir/actions.sh"

die() {
	printf '%s\n' "$*" >&2
	exit 1
}

input_file_for() {
	local kind="$1" token="$2"
	case "$token" in
		'' | *[!A-Za-z0-9-]* ) die 'Invalid input token' ;;
	esac
	[ "${#token}" -ge 8 ] && [ "${#token}" -le 64 ] || die 'Invalid input token'
	case "$kind" in
		user) printf '/var/run/ikev2-manager-user-%s.in\n' "$token" ;;
		client) printf '/var/run/ikev2-manager-client-%s.in\n' "$token" ;;
		server) printf '/var/run/ikev2-manager-server-%s.in\n' "$token" ;;
		profile) printf '/var/run/ikev2-manager-profile-%s.in\n' "$token" ;;
		acme) printf '/tmp/ikev2-acme-%s.in\n' "$token" ;;
		*) die 'Invalid input kind' ;;
	esac
}

filter_swanctl_noise() {
	grep -viE "plugin '.*': failed to load|no plugin file available|_plugin_create" |
		sed '/^[[:space:]]*$/d'
}

swanctl_quiet() {
	err="$(mktemp)"
	if swanctl "$@" 2>"$err"; then
		rm -f "$err"
		return 0
	fi
	code=$?
	filtered="$(filter_swanctl_noise <"$err" | tail -n 8 | tr '\n' ' ')"
	rm -f "$err"
	[ -n "$filtered" ] && printf '%s\n' "$filtered" >&2
	return "$code"
}

consume_user_input() {
	local extra user_count normalized_targets normalized_ports policy_supplied
	[ -f "$user_input_file" ] || die 'User input is missing'
	[ ! -L "$user_input_file" ] || die 'User input must not be a symbolic link'
	input_bytes="$(wc -c <"$user_input_file" | tr -d ' ')"
	case "$input_bytes" in '' | *[!0-9]*) die 'Invalid user input size' ;; esac
	[ "$input_bytes" -le 4096 ] || {
		rm -f "$user_input_file"
		die 'User input is too large'
	}
	chmod 600 "$user_input_file" || die 'Unable to protect user input'
	action="$(sed -n '1p' "$user_input_file")"
	user="$(sed -n '2p' "$user_input_file")"
	password="$(sed -n '3p' "$user_input_file")"
	router_access="$(sed -n '4p' "$user_input_file")"
	internet_access="$(sed -n '5p' "$user_input_file")"
	lan_access="$(sed -n '6p' "$user_input_file")"
	pbr_mode="$(sed -n '7p' "$user_input_file")"
	lan_targets="$(sed -n '8p' "$user_input_file")"
	public_ports="$(sed -n '9p' "$user_input_file")"
	if [ -n "$router_access$internet_access$lan_access$pbr_mode$lan_targets$public_ports" ]; then
		policy_supplied=1
	else
		policy_supplied=0
	fi
	extra="$(sed -n '10,$p' "$user_input_file" | sed '/^[[:space:]]*$/d')"
	rm -f "$user_input_file"
	[ -z "$extra" ] || die 'User input contains unexpected fields'
	[ "$action" = add ] || [ "$action" = password ] || [ "$action" = policy ] ||
		die 'Invalid user action'
	valid_user "$user" || die 'Invalid username'
	if [ "$action" = add ] || [ "$action" = password ]; then
		valid_password "$password" ||
			die 'Password must be 1-256 characters without control characters'
	else
		[ -z "$password" ] || die 'Policy input must not contain a password'
	fi
	if [ "$action" = add ] && user_exists "$user"; then
		die 'VPN user already exists'
	fi
	if [ "$action" = add ]; then
		user_count="$(awk -F '\t' 'NF && $1 != "" { count++ } END { print count + 0 }' "$users_db")"
		[ "$user_count" -lt 512 ] || die 'VPN user limit reached (512)'
	fi
	if [ "$action" = password ] && ! user_exists "$user"; then
		die 'VPN user does not exist'
	fi
	if [ "$action" = policy ] && ! user_exists "$user"; then
		die 'VPN user does not exist'
	fi
	if [ "$action" = password ]; then
		[ -z "$router_access$internet_access$lan_access$pbr_mode$lan_targets$public_ports" ] ||
			die 'Password input contains unexpected policy fields'
	fi
	if [ "$action" = add ] || [ "$action" = policy ]; then
		router_access="${router_access:-inherit}"
		internet_access="${internet_access:-inherit}"
		lan_access="${lan_access:-inherit}"
		pbr_mode="${pbr_mode:-inherit}"
		normalized_targets="$(normalize_user_targets "$lan_targets")" ||
			die 'Local targets must contain IPv4 addresses or CIDR networks'
		lan_targets="$normalized_targets"
		normalized_ports="$(normalize_list "$public_ports")"
		valid_port_list "$normalized_ports" ||
			die 'Public router ports must contain valid TCP/UDP ports or ranges'
		public_ports="$normalized_ports"
		validate_user_policy "$router_access" "$internet_access" "$lan_access" \
			"$pbr_mode" "$lan_targets" "$public_ports"
	fi
	if [ "$action" = policy ]; then
		update_user_policy_transaction "$user" "$router_access" "$internet_access" \
			"$lan_access" "$pbr_mode" "$lan_targets" "$public_ports" ||
			die 'Unable to apply VPN user policy; previous policy was restored'
		return 0
	fi
	encoded="$(printf '%s' "$password" | openssl base64 -A)"
	if [ "$action" = add ] && [ "$policy_supplied" = 1 ]; then
		add_user_with_policy_transaction "$user" "0s$encoded" \
			"$router_access" "$internet_access" "$lan_access" \
			"$pbr_mode" "$lan_targets" "$public_ports" ||
			die 'Unable to apply VPN user policy; the new user was removed'
		return 0
	fi
	update_user "$user" "0s$encoded"
}

consume_client_input() {
	local extra
	[ -f "$client_input_file" ] || die 'Client input is missing'
	[ ! -L "$client_input_file" ] || die 'Client input must not be a symbolic link'
	input_bytes="$(wc -c <"$client_input_file" | tr -d ' ')"
	case "$input_bytes" in '' | *[!0-9]*) die 'Invalid client input size' ;; esac
	[ "$input_bytes" -le 8192 ] || {
		rm -f "$client_input_file"
		die 'Client input is too large'
	}
	chmod 600 "$client_input_file" || die 'Unable to protect client input'
	mode="$(sed -n '1p' "$client_input_file")"
	enabled="$(sed -n '2p' "$client_input_file")"
	remote_address="$(sed -n '3p' "$client_input_file")"
	remote_id="$(sed -n '4p' "$client_input_file")"
	username="$(sed -n '5p' "$client_input_file")"
	dpd="$(sed -n '6p' "$client_input_file")"
	mtu="$(sed -n '7p' "$client_input_file")"
	password="$(sed -n '8p' "$client_input_file")"
	reconnect_cooldown="$(sed -n '9p' "$client_input_file")"
	extra="$(sed -n '10,$p' "$client_input_file" | sed '/^[[:space:]]*$/d')"
	[ -n "$reconnect_cooldown" ] || reconnect_cooldown=15
	rm -f "$client_input_file"
	[ -z "$extra" ] || die 'Client input contains unexpected fields'

	[ "$mode" = set ] || [ "$mode" = save ] || die 'Invalid client action'
	[ "$enabled" = 0 ] || [ "$enabled" = 1 ] || die 'Invalid enabled value'
	[ -z "$remote_address" ] || valid_host_list "$remote_address" ||
		die 'Invalid remote address list'
	[ -z "$remote_id" ] || valid_host "$remote_id" || die 'Invalid remote identity'
	[ -z "$username" ] || valid_user "$username" || die 'Invalid username'
	[ -z "$password" ] || valid_password "$password" ||
		die 'Password must be at most 256 characters without control characters'
	if [ "$enabled" = 1 ]; then
		if [ "$mode" = set ]; then
			[ "$(getv globals configured)" = 1 ] ||
				ip link show ipsec-out >/dev/null 2>&1 ||
				die 'Complete and enable Overview first'
		fi
		valid_host_list "$remote_address" || die 'Invalid remote address list'
		valid_host "$remote_id" || die 'Invalid remote identity'
		valid_user "$username" || die 'Invalid username'
		[ -s "$client_secret_db" ] || [ -n "$password" ] ||
			die 'EAP password is required when enabling the client'
	fi
	in_range "$dpd" 10 300 || die 'DPD must be 10-300 seconds'
	in_range "$mtu" 1280 1500 || die 'MTU must be 1280-1500'
	in_range "$reconnect_cooldown" 15 300 ||
		die 'Reconnect cooldown must be 15-300 seconds'

	pid_lock_acquire "$config_lock_dir" ||
		die 'Another configuration change is already in progress'
	client_state="$(mktemp -d)" || {
		pid_lock_release "$config_lock_dir"
		die 'Unable to prepare client configuration rollback'
	}
	if ! snapshot_path "$uci_config_dir/$uci_config" "$client_state" uci ||
	   ! snapshot_path "$client_secret_db" "$client_state" secret ||
	   ! snapshot_path "$outbound_conf" "$client_state" profile ||
	   ! snapshot_path "$outbound_secret" "$client_state" rendered_secret; then
		rm -rf "$client_state"
		pid_lock_release "$config_lock_dir"
		die 'Unable to back up current client configuration'
	fi
	trap 'restore_client_state "$client_state"; rm -rf "$client_state"; pid_lock_release "$config_lock_dir"; exit 1' INT TERM HUP
	if ! commit_client_settings; then
		client_restored=0
		restore_client_state "$client_state" && client_restored=1
		rm -rf "$client_state"
		pid_lock_release "$config_lock_dir"
		trap - INT TERM HUP
		[ "$client_restored" = 1 ] &&
			die 'Unable to save client settings; previous configuration restored'
		die 'Unable to save client settings and automatic rollback was incomplete'
	fi
	rm -rf "$client_state"
	pid_lock_release "$config_lock_dir"
	trap - INT TERM HUP

	[ "$mode" = set ] || return 0
	if [ "$(getv globals configured)" = 1 ]; then
		if [ "$enabled" = 1 ]; then
			start_action client-connect
		else
			start_action client-disable
		fi
	elif [ "$enabled" = 1 ]; then
		start_action connect
	fi
}

valid_user() {
	[ -n "$1" ] && [ "${#1}" -le 64 ] &&
		printf '%s' "$1" | grep -Eq '^[A-Za-z0-9_.@-]+$'
}

valid_password() {
	[ -n "$1" ] && [ "${#1}" -le 256 ] &&
		! printf '%s' "$1" | LC_ALL=C grep -q '[[:cntrl:]]'
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

valid_ipv6() {
	awk -v value="$1" 'BEGIN {
		if (value == "" || length(value) > 45 || value !~ /^[0-9A-Fa-f:]+$/ || index(value, ":") == 0)
			exit 1
		if (index(value, ":::") != 0)
			exit 1

		compressed = index(value, "::")
		if (compressed != 0) {
			left = substr(value, 1, compressed - 1)
			right = substr(value, compressed + 2)
			if (index(right, "::") != 0)
				exit 1
			left_count = left == "" ? 0 : split(left, left_groups, ":")
			right_count = right == "" ? 0 : split(right, right_groups, ":")
			if (left_count + right_count >= 8)
				exit 1
			for (i = 1; i <= left_count; i++)
				if (left_groups[i] !~ /^[0-9A-Fa-f]+$/ || length(left_groups[i]) > 4)
					exit 1
			for (i = 1; i <= right_count; i++)
				if (right_groups[i] !~ /^[0-9A-Fa-f]+$/ || length(right_groups[i]) > 4)
					exit 1
			exit 0
		}

		count = split(value, groups, ":")
		if (count != 8)
			exit 1
		for (i = 1; i <= count; i++)
			if (groups[i] !~ /^[0-9A-Fa-f]+$/ || length(groups[i]) > 4)
				exit 1
	}'
}

valid_dns_name() {
	awk -v value="$1" 'BEGIN {
		if (value == "" || length(value) > 253 || value !~ /^[A-Za-z0-9.-]+$/)
			exit 1
		if (value ~ /^[0-9.]+$/)
			exit 1
		count = split(value, labels, ".")
		for (i = 1; i <= count; i++) {
			label = labels[i]
			if (label == "" || length(label) > 63 ||
			    label !~ /^[A-Za-z0-9]/ || label !~ /[A-Za-z0-9]$/ ||
			    label !~ /^[A-Za-z0-9-]+$/)
				exit 1
		}
	}'
}

valid_host() {
	valid_ipv4 "$1" || valid_ipv6 "$1" || valid_dns_name "$1"
}

valid_ipv4_pool() {
	start="${1%%-*}"
	end="${1#*-}"
	[ "$start" != "$1" ] && valid_ipv4 "$start" && valid_ipv4 "$end"
}

valid_ipv4_cidr() {
	address="${1%/*}"
	prefix="${1#*/}"
	[ "$address" != "$1" ] && valid_ipv4 "$address" &&
		valid_uint "$prefix" && [ "$prefix" -ge 0 ] && [ "$prefix" -le 32 ]
}

ipv4_to_uint() {
	printf '%s\n' "$1" | awk -F. '{ print ((($1 * 256 + $2) * 256 + $3) * 256 + $4) }'
}

canonical_ipv4_cidr() {
	printf '%s\n' "$1" | awk -F'[./]' '
		NF == 5 {
			value = ((($1 * 256 + $2) * 256 + $3) * 256 + $4)
			block = 2 ^ (32 - $5)
			network = int(value / block) * block
			a = int(network / 16777216)
			network -= a * 16777216
			b = int(network / 65536)
			network -= b * 65536
			c = int(network / 256)
			d = network - c * 256
			printf "%.0f.%.0f.%.0f.%.0f/%s\n", a, b, c, d, $5
		}
	'
}

valid_server_pool_layout() {
	pool="$1"
	gateway_cidr="$2"
	start="${pool%%-*}"
	end="${pool#*-}"
	gateway="${gateway_cidr%/*}"
	prefix="${gateway_cidr#*/}"
	start_n="$(ipv4_to_uint "$start")"
	end_n="$(ipv4_to_uint "$end")"
	gateway_n="$(ipv4_to_uint "$gateway")"
	block="$(awk -v prefix="$prefix" 'BEGIN { printf "%.0f\n", 2 ^ (32 - prefix) }')"
	network_n="$(awk -v value="$gateway_n" -v block="$block" \
		'BEGIN { printf "%.0f\n", int(value / block) * block }')"
	broadcast_n=$((network_n + block - 1))
	[ "$prefix" -le 30 ] || return 1
	[ "$start_n" -le "$end_n" ] || return 1
	[ "$start_n" -gt "$network_n" ] && [ "$end_n" -lt "$broadcast_n" ] || return 1
	[ "$start_n" -le "$gateway_n" ] && [ "$gateway_n" -le "$end_n" ] && return 1
	[ $((end_n - start_n + 1)) -le 4096 ]
}

pool_overlaps_connected_network() {
	pool="$1"
	start_n="$(ipv4_to_uint "${pool%%-*}")"
	end_n="$(ipv4_to_uint "${pool#*-}")"
	ip -4 route show scope link 2>/dev/null | awk \
		-v pool_start="$start_n" -v pool_end="$end_n" '
		function ipnum(ip, o) {
			split(ip, o, ".")
			return (((o[1] * 256 + o[2]) * 256 + o[3]) * 256 + o[4])
		}
		$1 ~ /^[0-9.]+\/[0-9]+$/ {
			dev = ""
			for (i = 1; i <= NF; i++) if ($i == "dev") dev = $(i + 1)
			if (dev == "ipsec-in") next
			split($1, cidr, "/")
			block = 2 ^ (32 - cidr[2])
			start = int(ipnum(cidr[1]) / block) * block
			end = start + block - 1
			if (pool_start <= end && pool_end >= start) found = 1
		}
		END { exit found ? 0 : 1 }
	'
}

normalize_list() {
	printf '%s' "$1" | tr ',' ' ' | tr -s ' ' | sed 's/^ //;s/ $//'
}

valid_ipv4_cidr_list() {
	value="$(normalize_list "$1")"
	[ -n "$value" ] || return 1
	count=0
	for cidr in $value; do
		count=$((count + 1))
		[ "$count" -le 32 ] || return 1
		valid_ipv4_cidr "$cidr" || return 1
	done
}

normalize_user_targets() {
	value="$(normalize_list "$1")"
	[ -n "$value" ] || return 0
	count=0
	normalized=''
	for target in $value; do
		count=$((count + 1))
		[ "$count" -le 64 ] || return 1
		if valid_ipv4 "$target"; then
			target="$target/32"
		elif valid_ipv4_cidr "$target"; then
			target="$(canonical_ipv4_cidr "$target")"
		else
			return 1
		fi
		normalized="${normalized:+$normalized }$target"
	done
	printf '%s\n' "$normalized"
}

validate_user_policy() {
	router="$1"
	internet="$2"
	lan="$3"
	pbr="$4"
	targets="$5"
	public_ports="$6"
	case "$router" in inherit | allow | deny) ;; *) die 'Invalid router access mode' ;; esac
	case "$internet" in inherit | allow | deny) ;; *) die 'Invalid Internet access mode' ;; esac
	case "$lan" in inherit | all | limited | deny) ;; *) die 'Invalid local network access mode' ;; esac
	case "$pbr" in inherit | exclude) ;; *) die 'Invalid PBR mode' ;; esac
	if [ "$lan" = limited ]; then
		[ -n "$targets" ] || die 'Limited local access requires at least one IPv4 target'
	else
		[ -z "$targets" ] || die 'Local targets are valid only for limited local access'
	fi
	valid_port_list "$public_ports" ||
		die 'Invalid public router port list'
}

valid_name() {
	[ -n "$1" ] && [ "${#1}" -le 32 ] &&
		printf '%s' "$1" | grep -Eq '^[A-Za-z0-9_.-]+$'
}

valid_name_list() {
	value="$(normalize_list "$1")"
	[ -n "$value" ] || return 1
	count=0
	for name in $value; do
		count=$((count + 1))
		[ "$count" -le 32 ] || return 1
		valid_name "$name" || return 1
	done
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

valid_path_or_empty() {
	[ -z "$1" ] || {
		[ "${#1}" -le 255 ] &&
			printf '%s' "$1" | grep -Eq '^/[A-Za-z0-9_./@+-]+$'
	}
}

normalize_host_list() {
	printf '%s' "$1" | tr ',' ' ' | tr -s ' ' |
		sed 's/^ //; s/ $//'
}

valid_host_list() {
	hosts="$(normalize_host_list "$1")"
	[ -n "$hosts" ] || return 1
	count=0
	for host in $hosts; do
		count=$((count + 1))
		[ "$count" -le 16 ] || return 1
		valid_host "$host" || return 1
	done
}

valid_uint() {
	[ -n "$1" ] && printf '%s' "$1" | grep -Eq '^[0-9]+$'
}

in_range() {
	valid_uint "$1" && [ "$1" -ge "$2" ] && [ "$1" -le "$3" ]
}

atomic_install() {
	local src="$1" dst="$2" mode="$3"
	chmod "$mode" "$src"
	mv "$src" "$dst"
}

snapshot_path() {
	local source="$1" directory="$2" name="$3"
	if [ -e "$source" ]; then
		cp -p "$source" "$directory/$name" || return 1
		: >"$directory/$name.present"
	else
		: >"$directory/$name.absent"
	fi
}

restore_path() {
	local destination="$1" directory="$2" name="$3"
	if [ -f "$directory/$name.present" ]; then
		mkdir -p "${destination%/*}" || return 1
		cp -p "$directory/$name" "${destination}.restore.$$" || return 1
		mv "${destination}.restore.$$" "$destination" || {
			rm -f "${destination}.restore.$$"
			return 1
		}
	elif [ -f "$directory/$name.absent" ]; then
		rm -f "$destination" || return 1
	else
		return 1
	fi
}

restore_client_state() {
	local directory="$1"
	restored=1
	uci -q revert "$uci_config" >/dev/null 2>&1 || true
	restore_path "$uci_config_dir/$uci_config" "$directory" uci || restored=0
	restore_path "$client_secret_db" "$directory" secret || restored=0
	restore_path "$outbound_conf" "$directory" profile || restored=0
	restore_path "$outbound_secret" "$directory" rendered_secret || restored=0
	[ "$restored" -eq 1 ]
}

commit_client_settings() {
	uci set "$uci_config.client.enabled=$enabled" || return 1
	uci set "$uci_config.client.remote_address=$(normalize_host_list "$remote_address")" || return 1
	uci set "$uci_config.client.remote_id=$remote_id" || return 1
	uci set "$uci_config.client.username=$username" || return 1
	uci set "$uci_config.client.dpd=$dpd" || return 1
	uci set "$uci_config.client.mtu=$mtu" || return 1
	uci set "$uci_config.client.reconnect_cooldown=$reconnect_cooldown" || return 1
	uci commit "$uci_config" || return 1
	if [ -n "$password" ]; then
		set_client_secret "$username" "$password" || return 1
	else
		sync_client_secret_identity "$username" || return 1
	fi
	render_client || return 1
	render_client_secret
}

getv_default() {
	value="$(uci -q get "$uci_config.$1.$2" 2>/dev/null || true)"
	printf '%s\n' "${value:-$3}"
}

get_list() {
	uci -q get "$uci_config.$1.$2" 2>/dev/null || true
}

interface_counter() {
	local file="$root/sys/class/net/$1/statistics/$2" value=0
	if [ -r "$file" ]; then
		IFS= read -r value <"$file" || value=0
	fi
	case "$value" in '' | *[!0-9]*) value=0 ;; esac
	printf '%s\n' "$value"
}

set_list() {
	section="$1"
	option="$2"
	value="$(normalize_list "$3")"
	uci -q delete "$uci_config.$section.$option" || true
	for item in $value; do
		uci add_list "$uci_config.$section.$option=$item" || return 1
	done
}

init_uci() {
	mkdir -p "$uci_config_dir"
	mkdir -p "$root/etc/ikev2-manager" "$root/etc/swanctl/conf.d"
	chmod 700 "$root/etc/ikev2-manager"
	touch "$uci_config_dir/$uci_config"

	uci -q get "$uci_config.globals" >/dev/null 2>&1 || {
		uci set "$uci_config.globals=globals"
		uci set "$uci_config.globals.schema_version=1"
		uci set "$uci_config.globals.configured=0"
		uci set "$uci_config.globals.wan_interface=wan"
		uci set "$uci_config.globals.wan_zone=wan"
		uci add_list "$uci_config.globals.source_interface=lan"
		uci add_list "$uci_config.globals.source_zone=lan"
		# Default off, matching the shipped conffile. Enabling DNS redirect /
		# DoT block by default has caused LAN DNS outages; let the admin opt in.
		uci set "$uci_config.globals.dns_enforce=0"
		uci set "$uci_config.globals.block_dot=0"
		uci set "$uci_config.globals.source_include_vpn=1"
	}

	uci -q get "$uci_config.server" >/dev/null 2>&1 || {
		uci set "$uci_config.server=server"
		uci set "$uci_config.server.enabled=0"
		uci set "$uci_config.server.identity="
		uci set "$uci_config.server.pool4=10.20.30.10-10.20.30.100"
		uci set "$uci_config.server.gateway4=10.20.30.1/24"
		uci set "$uci_config.server.dns4=10.20.30.1"
		uci set "$uci_config.server.cert_source=/etc/ssl/acme"
		uci set "$uci_config.server.cert_file="
		uci set "$uci_config.server.key_file="
		uci set "$uci_config.server.dpd=30"
		uci set "$uci_config.server.ike_rekey=14400"
		uci set "$uci_config.server.child_rekey=3600"
		uci set "$uci_config.server.mtu=1400"
		uci set "$uci_config.server.mobike=1"
		uci set "$uci_config.server.fragmentation=1"
		uci set "$uci_config.server.local_ts=0.0.0.0/0"
		uci set "$uci_config.server.allow_internet=1"
		uci set "$uci_config.server.allow_lan=1"
		uci set "$uci_config.server.allow_router=0"
		uci set "$uci_config.server.router_ports="
		uci add_list "$uci_config.server.lan_zone=lan"
		uci set "$uci_config.server.firewall_zone=ikev2in"
		uci set "$uci_config.server.outbound_zone=ikev2out"
		uci set "$uci_config.server.custom_config=0"
	}

	uci -q get "$uci_config.client" >/dev/null 2>&1 || {
		uci set "$uci_config.client=client"
		uci set "$uci_config.client.enabled=0"
		uci set "$uci_config.client.remote_address="
		uci set "$uci_config.client.remote_id="
		uci set "$uci_config.client.username="
		uci set "$uci_config.client.dpd=30"
		uci set "$uci_config.client.mtu=1400"
		uci set "$uci_config.client.reconnect_cooldown=15"
		uci set "$uci_config.client.custom_config=0"
	}

	uci -q get "$uci_config.dns" >/dev/null 2>&1 || {
		uci set "$uci_config.dns=dns"
		uci set "$uci_config.dns.managed=0"
		uci set "$uci_config.dns.protocol=doh"
		uci set "$uci_config.dns.provider=cloudflare"
		uci set "$uci_config.dns.upstream_mode=load_balance"
		uci set "$uci_config.dns.upstream=https://dns.cloudflare.com/dns-query"
		uci set "$uci_config.dns.bootstrap=1.1.1.1:53 1.0.0.1:53"
		uci set "$uci_config.dns.fallback="
		uci set "$uci_config.dns.timeout=10s"
	}

	for assignment in \
		'server.gateway4=10.20.30.1/24' \
		'server.cert_source=/etc/ssl/acme' \
		'server.cert_file=' \
		'server.key_file=' \
		'server.local_ts=0.0.0.0/0' \
		'server.allow_internet=1' \
		'server.allow_lan=1' \
		'server.allow_router=0' \
		'server.router_ports=' \
		'server.firewall_zone=ikev2in' \
		'server.outbound_zone=ikev2out' \
		'server.custom_config=0' \
		'client.custom_config=0'; do
		section="${assignment%%.*}"
		rest="${assignment#*.}"
		option="${rest%%=*}"
		value="${rest#*=}"
		uci -q get "$uci_config.$section.$option" >/dev/null 2>&1 ||
			uci set "$uci_config.$section.$option=$value"
	done
	uci -q get "$uci_config.server.lan_zone" >/dev/null 2>&1 ||
		set_list server lan_zone lan
	uci commit "$uci_config"
}

init_client_secret() {
	[ -s "$client_secret_db" ] && return 0
	[ -s "$outbound_secret" ] || return 0
	username="$(sed -n 's/^[[:space:]]*id[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$outbound_secret" | head -n1)"
	secret="$(sed -n 's/^[[:space:]]*secret[[:space:]]*=[[:space:]]*\([^[:space:]]*\).*/\1/p' "$outbound_secret" | head -n1)"
	[ -n "$username" ] && [ -n "$secret" ] || return 0
	printf '%s\t%s\n' "$username" "$secret" >"${client_secret_db}.new"
	atomic_install "${client_secret_db}.new" "$client_secret_db" 600
}

init_users() {
	[ -s "$users_db" ] && return 0

	mkdir -p "${users_db%/*}"
	chmod 700 "${users_db%/*}"
	tmp="${users_db}.new"
	awk '
		/^[[:space:]]*eap-[^[:space:]]+[[:space:]]*\{/ {
			in_eap = 1
			id = ""
			secret = ""
			next
		}
		in_eap && /^[[:space:]]*id[[:space:]]*=/ {
			id = $0
			sub(/^[^=]*=[[:space:]]*/, "", id)
			gsub(/^"|"$/, "", id)
			next
		}
		in_eap && /^[[:space:]]*secret[[:space:]]*=/ {
			secret = $0
			sub(/^[^=]*=[[:space:]]*/, "", secret)
			next
		}
		in_eap && /^[[:space:]]*\}/ {
			if (id != "" && secret != "")
				printf "%s\t%s\n", id, secret
			in_eap = 0
		}
	' "$inbound_secrets" 2>/dev/null >"$tmp" || :
	atomic_install "$tmp" "$users_db" 600
}

render_users() {
	local tmp="${inbound_secrets}.new" index user secret
	{
		echo 'secrets {'
		index=0
		while IFS="$(printf '\t')" read -r user secret; do
			[ -n "$user" ] || continue
			index=$((index + 1))
			# Keep section names independent from user-controlled identities.
			# Dots and other valid EAP-ID characters are not valid in every
			# strongSwan settings section name.
			printf '\teap-%s {\n' "$index"
			printf '\t\tid = "%s"\n' "$user"
			printf '\t\tsecret = %s\n' "$secret"
			echo '	}'
			echo
		done <"$users_db"
		echo '	private-key {'
		printf '\t\tfile = %s\n' "$root/etc/swanctl/private/ikev2.key"
		echo '	}'
		echo '}'
	} >"$tmp"
	atomic_install "$tmp" "$inbound_secrets" 600
}

reload_credentials() {
	# Replacing an EAP secret under the same identity does not reliably evict
	# the previous in-memory credential. Clear and immediately reload the full
	# credential set; established IKE SAs are not terminated by this operation.
	swanctl_quiet --load-creds --clear --noprompt >/dev/null
}

user_exists() {
	awk -F '\t' -v user="$1" '$1 == user { found = 1 } END { exit found ? 0 : 1 }' \
		"$users_db"
}

user_policy_section() {
	printf 'user_%s\n' "$(printf '%s' "$1" | sha256sum |
		awk '{ print substr($1, 1, 16) }')"
}

user_policy_value() {
	local user="$1" option="$2" fallback="$3" section saved_user value
	section="$(user_policy_section "$user")"
	saved_user="$(uci -q get "$uci_config.$section.username" 2>/dev/null || true)"
	if [ "$saved_user" = "$user" ]; then
		value="$(uci -q get "$uci_config.$section.$option" 2>/dev/null || true)"
	else
		value=''
	fi
	printf '%s\n' "${value:-$fallback}"
}

save_user_policy() {
	local user="$1" router="$2" internet="$3" lan="$4" pbr="$5" targets="$6" public_ports="$7"
	local section saved_user
	section="$(user_policy_section "$user")"
	saved_user="$(uci -q get "$uci_config.$section.username" 2>/dev/null || true)"
	if [ -n "$saved_user" ] && [ "$saved_user" != "$user" ]; then
		printf '%s\n' 'VPN user policy identifier collision' >&2
		return 1
	fi
	uci set "$uci_config.$section=user_policy" || return 1
	uci set "$uci_config.$section.username=$user" || return 1
	uci set "$uci_config.$section.router_access=$router" || return 1
	uci set "$uci_config.$section.internet_access=$internet" || return 1
	uci set "$uci_config.$section.lan_access=$lan" || return 1
	uci set "$uci_config.$section.pbr_mode=$pbr" || return 1
	uci set "$uci_config.$section.lan_targets=$targets" || return 1
	uci set "$uci_config.$section.public_ports=$public_ports" || return 1
	uci commit "$uci_config"
}

apply_user_policy_runtime() {
	[ "$(uci -q get "$uci_config.globals.configured" 2>/dev/null || echo 0)" = 1 ] ||
		return 0
	[ "$(uci -q get "$uci_config.server.enabled" 2>/dev/null || echo 0)" = 1 ] ||
		return 0
	"$system_helper" access-apply
}

restore_user_policy_backup() {
	local backup="$1"
	uci -q revert "$uci_config" >/dev/null 2>&1 || true
	cp -p "$backup" "$uci_config_dir/$uci_config"
}

add_user_with_policy_transaction() {
	local user="$1" secret="$2" router="$3" internet="$4" lan="$5" pbr="$6" targets="$7"
	local public_ports="$8"
	local backup rollback_policy
	backup="$(mktemp)" || return 1
	cp -p "$uci_config_dir/$uci_config" "$backup" || {
		rm -f "$backup"
		return 1
	}
	rollback_policy=1
	trap '
		if [ "$rollback_policy" = 1 ]; then
			restore_user_policy_backup "$backup" >/dev/null 2>&1 || true
		fi
		rm -f "$backup"
	' EXIT
	if ! save_user_policy "$user" "$router" "$internet" "$lan" "$pbr" "$targets" \
		"$public_ports"; then
		restore_user_policy_backup "$backup" >/dev/null 2>&1 || true
		rm -f "$backup"
		trap - EXIT
		return 1
	fi
	# Store the restrictive policy before loading the credential. A concurrent
	# health refresh can therefore never admit a new identity under global
	# defaults during the add operation.
	update_user "$user" "$secret"
	if apply_user_policy_runtime; then
		rollback_policy=0
		trap - EXIT
		rm -f "$backup"
		return 0
	fi
	# If credential removal itself fails, keep the restrictive policy instead
	# of restoring global inheritance for a credential that may still exist.
	rollback_policy=0
	delete_user "$user"
	restored=0
	restore_user_policy_backup "$backup" && restored=1
	rm -f "$backup"
	trap - EXIT
	[ "$restored" = 1 ] || return 1
	apply_user_policy_runtime >/dev/null 2>&1 || return 1
	return 1
}

update_user_policy_transaction() {
	local user="$1" router="$2" internet="$3" lan="$4" pbr="$5" targets="$6"
	local public_ports="$7"
	local backup restored
	backup="$(mktemp)" || return 1
	cp -p "$uci_config_dir/$uci_config" "$backup" || {
		rm -f "$backup"
		return 1
	}
	if save_user_policy "$user" "$router" "$internet" "$lan" "$pbr" "$targets" \
		"$public_ports" &&
	   apply_user_policy_runtime; then
		rm -f "$backup"
		return 0
	fi
	restored=0
	uci -q revert "$uci_config" >/dev/null 2>&1 || true
	cp -p "$backup" "$uci_config_dir/$uci_config" && restored=1
	rm -f "$backup"
	[ "$restored" = 1 ] || return 1
	apply_user_policy_runtime >/dev/null 2>&1 || return 1
	return 1
}

delete_user_policy() {
	local user="$1" section saved_user
	section="$(user_policy_section "$user")"
	saved_user="$(uci -q get "$uci_config.$section.username" 2>/dev/null || true)"
	[ "$saved_user" = "$user" ] || return 0
	uci -q delete "$uci_config.$section" || return 1
	uci commit "$uci_config" || return 1
	apply_user_policy_runtime
}

delete_user_account() {
	local user="$1"
	delete_user "$user"
	delete_user_policy "$user" ||
		die 'VPN user was deleted, but live access rules could not be refreshed'
}

restore_user_files() {
	local db_backup="$1" secrets_backup="$2"
	restored=1
	cp "$db_backup" "${users_db}.restore" &&
		atomic_install "${users_db}.restore" "$users_db" 600 || restored=0
	cp "$secrets_backup" "${inbound_secrets}.restore" &&
		atomic_install "${inbound_secrets}.restore" "$inbound_secrets" 600 || restored=0
	reload_credentials >/dev/null 2>&1 || restored=0
	[ "$restored" -eq 1 ]
}

update_user() {
	local user="$1" secret="$2" db_backup secrets_backup tmp
	[ -f "$inbound_secrets" ] || render_users
	db_backup="${users_db}.rollback.$$"
	secrets_backup="${inbound_secrets}.rollback.$$"
	cp "$users_db" "$db_backup" || die 'Unable to back up VPN credentials'
	cp "$inbound_secrets" "$secrets_backup" || {
		rm -f "$db_backup"
		die 'Unable to back up VPN credentials'
	}
	tmp="${users_db}.new"
	awk -F '\t' -v user="$user" '$1 != user' "$users_db" >"$tmp"
	printf '%s\t%s\n' "$user" "$secret" >>"$tmp"
	# BusyBox sort has no -o: it would leave the file unsorted and print every
	# username/secret pair on this command's stdout, which LuCI reads back.
	sort "$tmp" >"${tmp}.sorted" || die 'Unable to store VPN credentials'
	mv "${tmp}.sorted" "$tmp"
	if ! atomic_install "$tmp" "$users_db" 600 ||
	   ! render_users || ! reload_credentials; then
		user_restored=0
		restore_user_files "$db_backup" "$secrets_backup" && user_restored=1
		rm -f "$db_backup" "$secrets_backup"
		[ "$user_restored" = 1 ] &&
			die 'Unable to reload VPN credentials; previous credentials restored'
		die 'Unable to reload VPN credentials and automatic rollback was incomplete'
	fi
	rm -f "$db_backup" "$secrets_backup"
}

delete_user() {
	local user="$1" db_backup secrets_backup tmp
	user_exists "$user" || die 'VPN user does not exist'
	[ -f "$inbound_secrets" ] || render_users
	db_backup="${users_db}.rollback.$$"
	secrets_backup="${inbound_secrets}.rollback.$$"
	cp "$users_db" "$db_backup" || die 'Unable to back up VPN credentials'
	cp "$inbound_secrets" "$secrets_backup" || {
		rm -f "$db_backup"
		die 'Unable to back up VPN credentials'
	}
	tmp="${users_db}.new"
	awk -F '\t' -v user="$user" '$1 != user' "$users_db" >"$tmp"
	if ! atomic_install "$tmp" "$users_db" 600 ||
	   ! render_users || ! reload_credentials; then
		user_restored=0
		restore_user_files "$db_backup" "$secrets_backup" && user_restored=1
		rm -f "$db_backup" "$secrets_backup"
		[ "$user_restored" = 1 ] &&
			die 'Unable to reload VPN credentials; previous credentials restored'
		die 'Unable to reload VPN credentials and automatic rollback was incomplete'
	fi
	rm -f "$db_backup" "$secrets_backup"
}

getv() {
	# Tolerate empty/missing options like get_list/getv_default and the system
	# helper's getv. A bare `uci -q get` returns non-zero for a set-but-empty
	# option, which under `set -eu` aborts mid-operation (e.g. server-set commits
	# enabled=1, then sync_server_certificate dies on an empty cert_file before
	# rendering/loading — a partial-applied state). Callers only read the value.
	uci -q get "$uci_config.$1.$2" 2>/dev/null || true
}

render_server() {
	enabled="$(getv server enabled)"
	tmp="${inbound_conf}.new"

	if [ "$enabled" != 1 ]; then
		echo '# Managed by IKEv2 Manager. Inbound server is disabled.' >"$tmp"
		atomic_install "$tmp" "$inbound_conf" 600
		return
	fi

	if [ "$(getv_default server custom_config 0)" = 1 ]; then
		[ -s "$inbound_custom" ] || die 'Inbound custom configuration is missing'
		cp "$inbound_custom" "$tmp"
		atomic_install "$tmp" "$inbound_conf" 600
		return
	fi

	identity="$(getv server identity)"
	pool4="$(getv server pool4)"
	dns4="$(getv server dns4)"
	dpd="$(getv server dpd)"
	ike_rekey="$(getv server ike_rekey)"
	child_rekey="$(getv server child_rekey)"
	mobike="$(getv server mobike)"
	fragmentation="$(getv server fragmentation)"
	local_ts="$(normalize_list "$(getv_default server local_ts 0.0.0.0/0)" | sed 's/ /, /g')"
	cat >"$tmp" <<EOF
connections {
	ikev2-in {
		version = 2
		send_cert = always
		proposals = aes256gcm16-prfsha384-ecp384,aes256-sha256-modp2048
		unique = never
		dpd_delay = ${dpd}s
		rekey_time = ${ike_rekey}s
		mobike = $([ "$mobike" = 1 ] && echo yes || echo no)
		fragmentation = $([ "$fragmentation" = 1 ] && echo yes || echo no)
		pools = router_pool4

		local {
			auth = pubkey
			certs = ikev2.pem
			id = $identity
		}

		remote {
			auth = eap-mschapv2
			eap_id = %any
			id = %any
		}

		children {
			net {
				esp_proposals = aes256gcm16-ecp384,aes256gcm16-ecp256,aes256gcm16-modp2048,aes256gcm16,aes256-sha256-modp2048,aes256-sha256
				local_ts = $local_ts
				if_id_in = 43
				if_id_out = 43
				rekey_time = ${child_rekey}s
				dpd_action = clear
				start_action = none
			}
			}
		}
	}
pools {
	router_pool4 {
		addrs = $pool4
		dns = $dns4
	}
}
EOF
	atomic_install "$tmp" "$inbound_conf" 600
}

validate_server_certificate_files() {
	local cert="$1" key="$2" identity="$3" work
	work="$(mktemp -d)" || return 1
	if ! openssl x509 -in "$cert" -noout >/dev/null 2>&1 ||
	   ! openssl x509 -in "$cert" -checkend 0 -noout >/dev/null 2>&1 ||
	   ! openssl pkey -in "$key" -noout >/dev/null 2>&1 ||
	   ! openssl x509 -in "$cert" -pubkey -noout 2>/dev/null |
		openssl pkey -pubin -outform DER >"$work/cert.pub" 2>/dev/null ||
	   ! openssl pkey -in "$key" -pubout -outform DER >"$work/key.pub" 2>/dev/null ||
	   ! cmp -s "$work/cert.pub" "$work/key.pub"; then
		rm -rf "$work"
		return 1
	fi
	if valid_ipv4 "$identity" || valid_ipv6 "$identity"; then
		openssl x509 -in "$cert" -checkip "$identity" -noout >/dev/null 2>&1 || {
			rm -rf "$work"
			return 1
		}
	else
		openssl x509 -in "$cert" -checkhost "$identity" -noout >/dev/null 2>&1 || {
			rm -rf "$work"
			return 1
		}
	fi
	rm -rf "$work"
}

restore_server_certificate_backup() {
	local stage="$1" x509_dir="$2" private_dir="$3" ca_dir="$4" old
	rm -f "$x509_dir/ikev2.pem" "$private_dir/ikev2.key" \
		"$ca_dir"/ikev2-server-chain-*.pem
	[ ! -f "$stage/backup/ikev2.pem" ] ||
		cp "$stage/backup/ikev2.pem" "$x509_dir/ikev2.pem"
	[ ! -f "$stage/backup/ikev2.key" ] ||
		cp "$stage/backup/ikev2.key" "$private_dir/ikev2.key"
	for old in "$stage/backup"/ikev2-server-chain-*.pem; do
		[ -f "$old" ] && cp "$old" "$ca_dir/${old##*/}"
	done
}

sync_server_certificate() {
	local identity cert_file key_file cert_source x509_dir ca_dir private_dir
	local stage index current line chain_index pem old
	[ "$(getv server enabled)" = 1 ] || return 0
	identity="$(getv server identity)"
	cert_file="$(getv server cert_file)"
	key_file="$(getv server key_file)"
	cert_source="$(getv server cert_source)"
	[ -n "$cert_file" ] || cert_file="$cert_source/$identity.fullchain.crt"
	[ -n "$key_file" ] || key_file="$cert_source/$identity.key"
	[ -s "$cert_file" ] || die "Server certificate not found: $cert_file"
	[ -s "$key_file" ] || die "Server private key not found: $key_file"
	validate_server_certificate_files "$cert_file" "$key_file" "$identity" ||
		die 'Server certificate is expired, does not match its identity, or does not match the private key'

	x509_dir="$root/etc/swanctl/x509"
	ca_dir="$root/etc/swanctl/x509ca"
	private_dir="$root/etc/swanctl/private"
	mkdir -p "$x509_dir" "$ca_dir" "$private_dir"
	stage="$(mktemp -d)" || die 'Unable to stage server certificate'
	umask 077
	cp "$cert_file" "$stage/ikev2.pem" || { rm -rf "$stage"; die 'Unable to stage server certificate'; }
	cp "$key_file" "$stage/ikev2.key" || { rm -rf "$stage"; die 'Unable to stage server key'; }
	mkdir -p "$stage/chain" "$stage/backup"
	index=0
	current=
	while IFS= read -r line; do
		case "$line" in
			'-----BEGIN CERTIFICATE-----')
				index=$((index + 1))
				current="$stage/cert-$index.pem"
				;;
		esac
		[ -n "$current" ] && printf '%s\n' "$line" >>"$current"
		case "$line" in '-----END CERTIFICATE-----') current= ;; esac
	done <"$cert_file"
	[ "$index" -ge 1 ] || { rm -rf "$stage"; die 'Server certificate contains no PEM certificate'; }
	chain_index=0
	for pem in "$stage"/cert-*.pem; do
		[ -s "$pem" ] || continue
		openssl x509 -in "$pem" -noout >/dev/null 2>&1 || {
			rm -rf "$stage"
			die 'Server certificate chain contains an invalid certificate'
		}
		[ "${pem##*-}" = '1.pem' ] && continue
		chain_index=$((chain_index + 1))
		cp "$pem" "$stage/chain/ikev2-server-chain-$chain_index.pem"
	done
	[ ! -f "$x509_dir/ikev2.pem" ] || cp "$x509_dir/ikev2.pem" "$stage/backup/ikev2.pem"
	[ ! -f "$private_dir/ikev2.key" ] || cp "$private_dir/ikev2.key" "$stage/backup/ikev2.key"
	for pem in "$ca_dir"/ikev2-server-chain-*.pem; do
		[ -f "$pem" ] && cp "$pem" "$stage/backup/${pem##*/}"
	done

	if ! cp "$stage/ikev2.pem" "$x509_dir/ikev2.pem.new" ||
	   ! chmod 644 "$x509_dir/ikev2.pem.new" ||
	   ! mv "$x509_dir/ikev2.pem.new" "$x509_dir/ikev2.pem" ||
	   ! cp "$stage/ikev2.key" "$private_dir/ikev2.key.new" ||
	   ! chmod 600 "$private_dir/ikev2.key.new" ||
	   ! mv "$private_dir/ikev2.key.new" "$private_dir/ikev2.key"; then
		rm -f "$x509_dir/ikev2.pem.new" "$private_dir/ikev2.key.new"
		restore_server_certificate_backup "$stage" "$x509_dir" "$private_dir" "$ca_dir"
		rm -rf "$stage"
		die 'Unable to install the server certificate; previous certificate restored'
	fi
	rm -f "$ca_dir"/ikev2-server-chain-*.pem
	for pem in "$stage/chain"/*.pem; do
		[ -f "$pem" ] || continue
		cp "$pem" "$ca_dir/${pem##*/}.new" && chmod 644 "$ca_dir/${pem##*/}.new" &&
			mv "$ca_dir/${pem##*/}.new" "$ca_dir/${pem##*/}" || {
				restore_server_certificate_backup "$stage" "$x509_dir" "$private_dir" "$ca_dir"
				rm -rf "$stage"
				die 'Unable to install the server certificate chain; previous certificate restored'
			}
	done
	rm -rf "$stage"
}

validate_server_settings() {
	[ "$enabled" = 0 ] || [ "$enabled" = 1 ] || die 'Invalid enabled value'
	[ -z "$identity" ] || valid_host "$identity" || die 'Invalid server identity'
	[ "$enabled" = 0 ] || [ -n "$identity" ] || die 'Server identity is required'
	valid_ipv4_pool "$pool4" || die 'Invalid IPv4 pool'
	valid_ipv4_cidr "$gateway4" || die 'Invalid IPv4 gateway/prefix'
	valid_server_pool_layout "$pool4" "$gateway4" ||
		die 'Client pool must be ordered, inside the gateway subnet, exclude the gateway, and contain at most 4096 addresses'
	if [ -z "$root" ] && pool_overlaps_connected_network "$pool4"; then
		die 'Client pool overlaps an existing connected IPv4 network'
	fi
	valid_ipv4 "$dns4" || die 'Invalid IPv4 DNS'
	valid_path_or_empty "$cert_source" || die 'Invalid certificate directory'
	valid_path_or_empty "$cert_file" || die 'Invalid certificate path'
	valid_path_or_empty "$key_file" || die 'Invalid private key path'
	in_range "$dpd" 10 300 || die 'DPD must be 10-300 seconds'
	in_range "$ike_rekey" 3600 86400 || die 'IKE rekey must be 3600-86400 seconds'
	in_range "$child_rekey" 900 86400 || die 'CHILD rekey must be 900-86400 seconds'
	in_range "$mtu" 1280 1500 || die 'MTU must be 1280-1500'
	[ "$mobike" = 0 ] || [ "$mobike" = 1 ] || die 'Invalid MOBIKE value'
	[ "$fragmentation" = 0 ] || [ "$fragmentation" = 1 ] ||
		die 'Invalid fragmentation value'
	if [ "$enabled" = 1 ]; then
		_certf="$cert_file"
		_keyf="$key_file"
		[ -n "$_certf" ] || _certf="$cert_source/$identity.fullchain.crt"
		[ -n "$_keyf" ] || _keyf="$cert_source/$identity.key"
		[ -s "$_certf" ] ||
			die "Server certificate not found: $_certf (issue or install it before enabling the server)"
		[ -s "$_keyf" ] || die "Server private key not found: $_keyf"
		validate_server_certificate_files "$_certf" "$_keyf" "$identity" ||
			die 'Server certificate is expired, does not match its identity, or does not match the private key'
	fi
}

validate_server_access_settings() {
	valid_ipv4_cidr_list "$local_ts" || die 'Invalid IPv4 traffic selector list'
	for value in "$allow_internet" "$allow_lan" "$allow_router"; do
		[ "$value" = 0 ] || [ "$value" = 1 ] || die 'Invalid access toggle'
	done
	valid_port_list "$router_ports" ||
		die 'Router ports must contain ports or ranges separated by spaces'
	valid_name_list "$lan_zones" || die 'Invalid LAN firewall zone list'
	valid_name "$firewall_zone" || die 'Invalid inbound firewall zone'
	valid_name "$outbound_zone" || die 'Invalid outbound firewall zone'
	[ "$firewall_zone" != "$outbound_zone" ] ||
		die 'Inbound and outbound firewall zones must be different'
	if [ -z "$root" ]; then
		zone_error="$("$system_helper" validate-server-zones \
			"$firewall_zone" "$outbound_zone" 2>&1)" ||
			die "${zone_error:-Unable to validate managed firewall zone names}"
	fi
}

snapshot_server_state() {
	local directory="$1" pem
	mkdir -p "$directory/chain" || return 1
	snapshot_path "$uci_config_dir/$uci_config" "$directory" uci || return 1
	snapshot_path "$inbound_conf" "$directory" profile || return 1
	snapshot_path "$root/etc/swanctl/x509/ikev2.pem" "$directory" certificate || return 1
	snapshot_path "$root/etc/swanctl/private/ikev2.key" "$directory" private_key || return 1
	for pem in "$root/etc/swanctl/x509ca"/ikev2-server-chain-*.pem; do
		[ -f "$pem" ] || continue
		cp -p "$pem" "$directory/chain/${pem##*/}" || return 1
	done
}

restore_server_state() {
	local directory="$1" pem ca_dir
	uci -q revert "$uci_config" >/dev/null 2>&1 || true
	restore_path "$uci_config_dir/$uci_config" "$directory" uci || return 1
	restore_path "$inbound_conf" "$directory" profile || return 1
	restore_path "$root/etc/swanctl/x509/ikev2.pem" "$directory" certificate || return 1
	restore_path "$root/etc/swanctl/private/ikev2.key" "$directory" private_key || return 1
	ca_dir="$root/etc/swanctl/x509ca"
	mkdir -p "$ca_dir" || return 1
	for pem in "$directory/chain"/ikev2-server-chain-*.pem; do
		[ -f "$pem" ] || continue
		cp -p "$pem" "$ca_dir/${pem##*/}.restore.$$" || {
			rm -f "$ca_dir"/*.restore.$$ 2>/dev/null || true
			return 1
		}
	done
	rm -f "$ca_dir"/ikev2-server-chain-*.pem \
		"$inbound_conf.new" "$root/etc/swanctl/x509/ikev2.pem.new" \
		"$root/etc/swanctl/private/ikev2.key.new"
	for pem in "$ca_dir"/ikev2-server-chain-*.pem.restore.$$; do
		[ -f "$pem" ] || continue
		mv "$pem" "${pem%.restore.$$}" || return 1
	done
}

commit_server_settings() {
	uci set "$uci_config.server.enabled=$enabled" || return 1
	uci set "$uci_config.server.identity=$identity" || return 1
	uci set "$uci_config.server.pool4=$pool4" || return 1
	uci set "$uci_config.server.gateway4=$gateway4" || return 1
	uci set "$uci_config.server.dns4=$dns4" || return 1
	uci set "$uci_config.server.cert_source=$cert_source" || return 1
	uci set "$uci_config.server.cert_file=$cert_file" || return 1
	uci set "$uci_config.server.key_file=$key_file" || return 1
	uci set "$uci_config.server.dpd=$dpd" || return 1
	uci set "$uci_config.server.ike_rekey=$ike_rekey" || return 1
	uci set "$uci_config.server.child_rekey=$child_rekey" || return 1
	uci set "$uci_config.server.mtu=$mtu" || return 1
	uci set "$uci_config.server.mobike=$mobike" || return 1
	uci set "$uci_config.server.fragmentation=$fragmentation" || return 1
	uci set "$uci_config.server.local_ts=$(normalize_list "$local_ts")" || return 1
	uci set "$uci_config.server.allow_internet=$allow_internet" || return 1
	uci set "$uci_config.server.allow_lan=$allow_lan" || return 1
	uci set "$uci_config.server.allow_router=$allow_router" || return 1
	uci set "$uci_config.server.router_ports=$(normalize_list "$router_ports")" || return 1
	set_list server lan_zone "$lan_zones" || return 1
	uci set "$uci_config.server.firewall_zone=$firewall_zone" || return 1
	uci set "$uci_config.server.outbound_zone=$outbound_zone" || return 1
	uci commit "$uci_config" || return 1
	[ "$enabled" = 0 ] || ( sync_server_certificate ) || return 1
	( render_server )
}

consume_server_input() {
	local input_bytes extra action_output
	[ -n "$server_input_file" ] || die 'Server input is missing'
	[ -f "$server_input_file" ] || die 'Server input is missing'
	[ ! -L "$server_input_file" ] || die 'Server input must not be a symbolic link'
	input_bytes="$(wc -c <"$server_input_file" | tr -d ' ')"
	case "$input_bytes" in '' | *[!0-9]*) die 'Invalid server input size' ;; esac
	[ "$input_bytes" -le 32768 ] || {
		rm -f "$server_input_file"
		die 'Server input is too large'
	}
	chmod 600 "$server_input_file" || die 'Unable to protect server input'
	enabled="$(sed -n '1p' "$server_input_file")"
	identity="$(sed -n '2p' "$server_input_file")"
	pool4="$(sed -n '3p' "$server_input_file")"
	gateway4="$(sed -n '4p' "$server_input_file")"
	dns4="$(sed -n '5p' "$server_input_file")"
	cert_source="$(sed -n '6p' "$server_input_file")"
	cert_file="$(sed -n '7p' "$server_input_file")"
	key_file="$(sed -n '8p' "$server_input_file")"
	dpd="$(sed -n '9p' "$server_input_file")"
	ike_rekey="$(sed -n '10p' "$server_input_file")"
	child_rekey="$(sed -n '11p' "$server_input_file")"
	mtu="$(sed -n '12p' "$server_input_file")"
	mobike="$(sed -n '13p' "$server_input_file")"
	fragmentation="$(sed -n '14p' "$server_input_file")"
	local_ts="$(sed -n '15p' "$server_input_file")"
	allow_internet="$(sed -n '16p' "$server_input_file")"
	allow_lan="$(sed -n '17p' "$server_input_file")"
	allow_router="$(sed -n '18p' "$server_input_file")"
	router_ports="$(sed -n '19p' "$server_input_file")"
	lan_zones="$(sed -n '20p' "$server_input_file")"
	firewall_zone="$(sed -n '21p' "$server_input_file")"
	outbound_zone="$(sed -n '22p' "$server_input_file")"
	extra="$(sed -n '23,$p' "$server_input_file" | sed '/^[[:space:]]*$/d')"
	rm -f "$server_input_file"
	[ -z "$extra" ] || die 'Server input contains unexpected fields'
	validate_server_settings
	validate_server_access_settings
	if [ "$enabled" = 1 ] && [ "$(getv_default server custom_config 0)" = 1 ]; then
		[ -s "$inbound_custom" ] || die 'Inbound custom configuration is missing'
	fi
	old_enabled="$(getv_default server enabled 0)"
	pid_lock_acquire "$config_lock_dir" ||
		die 'Another configuration change is already in progress'
	server_state="$(mktemp -d)" || {
		pid_lock_release "$config_lock_dir"
		die 'Unable to prepare server configuration rollback'
	}
	if ! snapshot_server_state "$server_state"; then
		rm -rf "$server_state"
		pid_lock_release "$config_lock_dir"
		die 'Unable to back up current server configuration'
	fi
	trap 'restore_server_state "$server_state"; rm -rf "$server_state"; pid_lock_release "$config_lock_dir"; exit 1' INT TERM HUP
	if ! commit_server_settings; then
		server_restored=0
		restore_server_state "$server_state" && server_restored=1
		rm -rf "$server_state"
		pid_lock_release "$config_lock_dir"
		trap - INT TERM HUP
		[ "$server_restored" = 1 ] &&
			die 'Unable to save server settings; previous configuration restored'
		die 'Unable to save server settings and automatic rollback was incomplete'
	fi
	cp -p "$uci_config_dir/$uci_config" "$server_state/applied.uci" || {
		server_restored=0
		restore_server_state "$server_state" && server_restored=1
		rm -rf "$server_state"
		pid_lock_release "$config_lock_dir"
		trap - INT TERM HUP
		[ "$server_restored" = 1 ] &&
			die 'Unable to preserve the server rollback checkpoint; previous configuration restored'
		die 'Unable to preserve the server rollback checkpoint and automatic rollback was incomplete'
	}
	if [ "$(getv globals configured)" = 1 ]; then
		[ "$old_enabled" = "$enabled" ] && pbr_changed=0 || pbr_changed=1
		if ! action_output="$(start_action server-apply "$pbr_changed" "$server_state")"; then
			server_restored=0
			restore_server_state "$server_state" && server_restored=1
			rm -rf "$server_state"
			pid_lock_release "$config_lock_dir"
			trap - INT TERM HUP
			[ "$server_restored" = 1 ] &&
				die 'Unable to start server apply; previous configuration restored'
			die 'Unable to start server apply and automatic rollback was incomplete'
		fi
	else
		rm -rf "$server_state"
		action_output=''
	fi
	pid_lock_release "$config_lock_dir"
	trap - INT TERM HUP
	[ -z "$action_output" ] || printf '%s\n' "$action_output"
}

# ACME issuance for the inbound server certificate. The app owns the
# /etc/config/acme cert section so the UI can pick HTTP-01 or DNS-01 without
# touching luci-app-acme. The acme hotplug (90-ikev2-acme) and acme-issue both
# sync the issued cert into swanctl.
acme_server_cert_path() {
	cert_source="$(getv server cert_source)"
	[ -n "$cert_source" ] || cert_source='/etc/ssl/acme'
	printf '%s/%s.fullchain.crt' "$cert_source" "$(getv server identity)"
}

acme_emit() {
	identity="$(getv server identity)"
	section="acme.$acme_cert_section"
	method="$(uci -q get "$section.validation_method" 2>/dev/null || true)"
	case "$method" in
		dns) printf 'method=dns\n' ;;
		*) printf 'method=http\n' ;;
	esac
	email="$(uci -q get acme.@acme[0].account_email 2>/dev/null || true)"
	[ "$email" = 'email@example.org' ] && email=''
	printf 'email=%s\n' "$email"
	printf 'dns_provider=%s\n' "$(uci -q get "$section.dns" 2>/dev/null || true)"
	printf 'staging=%s\n' "$(uci -q get "$section.staging" 2>/dev/null || echo 0)"
	[ -n "$(uci -q get "$section.credentials" 2>/dev/null || true)" ] &&
		printf 'has_credentials=1\n' || printf 'has_credentials=0\n'
	printf 'providers='
	for d in "$acme_dnsapi_dir"/dns_*.sh; do
		[ -e "$d" ] || continue
		b="${d##*/}"
		printf '%s ' "${b%.sh}"
	done
	printf '\n'
	printf 'identities='
	identity_candidates=''
	for section_name in $(uci show acme 2>/dev/null \
		| sed -n 's/^acme\.\([^.=]*\)=cert$/\1/p'); do
		[ "$(uci -q get "acme.$section_name.enabled" 2>/dev/null || echo 0)" = 1 ] || continue
		for domain in $(uci -q get "acme.$section_name.domains" 2>/dev/null || true); do
			case "$domain" in \*.*|'') continue ;; esac
			case " $identity_candidates " in *" $domain "*) continue ;; esac
			if valid_host "$domain"; then
				printf '%s ' "$domain"
				identity_candidates="${identity_candidates:+$identity_candidates }$domain"
			fi
		done
	done
	printf '\n'
	cert="$(acme_server_cert_path)"
	if [ -n "$identity" ] && [ -s "$cert" ]; then
		printf 'cert_present=1\n'
		printf 'cert_expiry=%s\n' "$(openssl x509 -in "$cert" -noout -enddate 2>/dev/null | cut -d= -f2-)"
		printf 'cert_subject=%s\n' "$(openssl x509 -in "$cert" -noout -subject 2>/dev/null | sed 's/^subject=//')"
	else
		printf 'cert_present=0\n'
	fi
	# Runtime truth for the Inbound Server page: is the conn actually loaded into
	# charon? Lets the UI distinguish "enabled with a cert" from "actually serving".
	printf 'conn_loaded=%s\n' "$([ -z "$root" ] && swanctl --list-conns 2>/dev/null | grep -q 'ikev2-in:' && echo 1 || echo 0)"
}

# Primary env var for single-credential DNS providers, so a user can paste just
# the token instead of the exact `VAR="value"` acme.sh syntax.
acme_primary_var() {
	case "$1" in
		dns_timeweb) echo 'TW_Token' ;;
		dns_cf) echo 'CF_Token' ;;
		dns_duckdns) echo 'DuckDNS_Token' ;;
		dns_dynv6) echo 'DYNV6_TOKEN' ;;
		dns_desec) echo 'DEDYN_TOKEN' ;;
		dns_hetzner) echo 'HETZNER_Token' ;;
		dns_njalla) echo 'NJALLA_Token' ;;
		dns_vultr) echo 'VULTR_API_KEY' ;;
		dns_gcore) echo 'GCORE_Key' ;;
		dns_namesilo) echo 'Namesilo_Key' ;;
		dns_linode_v4) echo 'LINODE_V4_API_KEY' ;;
		dns_dynu) echo 'Dynu_ClientId' ;;
		*) echo '' ;;
	esac
}

normalize_acme_credentials() {
	local provider="$1" source="$2" output="$3" primary_var line name value names count backtick
	primary_var="$(acme_primary_var "$provider")"
	backtick="$(printf '\\140')"
	names=''
	count=0
	: >"$output" || return 1
	while IFS= read -r line || [ -n "$line" ]; do
		line="$(printf '%s' "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
		[ -n "$line" ] || continue
		case "$line" in
			*=*)
				name="${line%%=*}"
				value="${line#*=}"
				;;
			*)
				[ -n "$primary_var" ] || return 1
				name="$primary_var"
				value="$line"
				;;
		esac
		printf '%s' "$name" | grep -Eq '^[A-Za-z_][A-Za-z0-9_]*$' || return 1
		case "$value" in
			\"*\") value="${value#\"}"; value="${value%\"}" ;;
			\'*) [ "${value%\'}" != "$value" ] || return 1
				value="${value#\'}"; value="${value%\'}" ;;
		esac
		[ -n "$value" ] && [ "${#value}" -le 4096 ] || return 1
		! printf '%s' "$value" | LC_ALL=C grep -q '[[:cntrl:]]' || return 1
		# acme-common consumes KEY=VAL as shell assignments. Re-quote the value
		# ourselves and reject characters that could escape or expand that quoting.
		! printf '%s' "$value" | grep -q '[\"\\$]' || return 1
		case "$value" in *"$backtick"*) return 1 ;; esac
		case " $names " in *" $name "*) return 1 ;; esac
		names="$names $name"
		count=$((count + 1))
		[ "$count" -le 32 ] || return 1
		printf '%s="%s"\n' "$name" "$value" >>"$output" || return 1
	done <"$source"
}

restore_acme_state() {
	local directory="$1"
	uci -q revert acme >/dev/null 2>&1 || true
	restore_path "$uci_config_dir/acme" "$directory" uci
}

commit_acme_settings() {
	local credential
	uci -q get acme.@acme[0] >/dev/null 2>&1 ||
		uci add acme acme >/dev/null || return 1
	uci set "acme.@acme[0].account_email=$a_email" || return 1
	uci set "acme.$acme_cert_section=cert" || return 1
	uci -q delete "acme.$acme_cert_section.domains" >/dev/null 2>&1 || true
	uci add_list "acme.$acme_cert_section.domains=$identity" || return 1
	uci set "acme.$acme_cert_section.enabled=1" || return 1
	uci set "acme.$acme_cert_section.key_type=rsa2048" || return 1
	uci set "acme.$acme_cert_section.staging=$a_staging" || return 1
	case "$a_method" in
		dns)
			uci set "acme.$acme_cert_section.validation_method=dns" || return 1
			uci set "acme.$acme_cert_section.dns=$a_provider" || return 1
			uci set "acme.$acme_cert_section.dns_wait=120" || return 1
			if [ -s "$acme_work/credentials" ]; then
				uci -q delete "acme.$acme_cert_section.credentials" >/dev/null 2>&1 || true
				while IFS= read -r credential; do
					uci add_list "acme.$acme_cert_section.credentials=$credential" || return 1
				done <"$acme_work/credentials"
			fi
			;;
		http)
			# Webroot avoids colliding with LuCI/uhttpd on local TCP 80. Current
			# acme-common serves /var/run/acme/challenge through the web root.
			uci set "acme.$acme_cert_section.validation_method=webroot" || return 1
			uci -q delete "acme.$acme_cert_section.dns" >/dev/null 2>&1 || true
			uci -q delete "acme.$acme_cert_section.dns_wait" >/dev/null 2>&1 || true
			uci -q delete "acme.$acme_cert_section.credentials" >/dev/null 2>&1 || true
			;;
	esac
	uci commit acme || return 1
	chmod 600 "$uci_config_dir/acme"
}

acme_set() {
	# Settings arrive through a token-addressed file written with fs.write. Only
	# the short random token is passed on the command line, so credentials never
	# enter rpcd ACL matching or the process list. Layout: line1=email,
	# line2=method, line3=provider, line4=staging, line5+=credentials.
	infile="$acme_input_file"
	[ -s "$infile" ] || die 'No ACME settings received'
	[ ! -L "$infile" ] || die 'ACME settings input must not be a symbolic link'
	input_bytes="$(wc -c <"$infile" | tr -d ' ')"
	case "$input_bytes" in '' | *[!0-9]*) die 'Invalid ACME input size' ;; esac
	[ "$input_bytes" -le 65536 ] || {
		rm -f "$infile"
		die 'ACME settings input is too large'
	}
	chmod 600 "$infile" || die 'Unable to protect ACME settings input'
	acme_work="$(mktemp -d)" || die 'Unable to prepare ACME settings'
	a_email="$(sed -n '1p' "$infile")"
	a_method="$(sed -n '2p' "$infile")"
	a_provider="$(sed -n '3p' "$infile")"
	a_staging="$(sed -n '4p' "$infile")"
	sed -n '5,$p' "$infile" >"$acme_work/credentials.raw" || {
		rm -rf "$acme_work"
		die 'Unable to read ACME credentials'
	}
	rm -f "$infile"
	identity="$(getv server identity)"
	[ -n "$identity" ] || { rm -rf "$acme_work"; die 'Set the server public identity first'; }
	valid_host "$identity" || { rm -rf "$acme_work"; die 'Invalid server identity'; }
	printf '%s' "$a_email" | grep -Eq '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' ||
		{ rm -rf "$acme_work"; die 'A valid ACME account email is required'; }
	{ [ "$a_staging" = 0 ] || [ "$a_staging" = 1 ]; } ||
		{ rm -rf "$acme_work"; die 'Invalid staging value'; }

	case "$a_method" in
		dns)
			printf '%s' "$a_provider" | grep -Eq '^dns_[a-z0-9_]+$' ||
				{ rm -rf "$acme_work"; die 'Invalid DNS provider'; }
			[ -e "$acme_dnsapi_dir/$a_provider.sh" ] ||
				{ rm -rf "$acme_work"; die "DNS provider not installed: $a_provider"; }
			if grep -q '[^[:space:]]' "$acme_work/credentials.raw"; then
				normalize_acme_credentials "$a_provider" "$acme_work/credentials.raw" \
					"$acme_work/credentials" ||
					{ rm -rf "$acme_work"; die 'Invalid DNS provider credentials'; }
			else
				old_provider="$(uci -q get "acme.$acme_cert_section.dns" 2>/dev/null || true)"
				existing_credentials="$(uci -q get "acme.$acme_cert_section.credentials" 2>/dev/null || true)"
				[ "$old_provider" = "$a_provider" ] && [ -n "$existing_credentials" ] ||
					{ rm -rf "$acme_work"; die 'DNS provider credentials are required'; }
			fi
			;;
		http)
			: >"$acme_work/credentials"
			;;
		*)
			rm -rf "$acme_work"
			die 'Invalid challenge method (expected dns or http)'
			;;
	esac
	pid_lock_acquire "$config_lock_dir" || {
		rm -rf "$acme_work"
		die 'Another configuration change is already in progress'
	}
	if ! snapshot_path "$uci_config_dir/acme" "$acme_work" uci; then
		rm -rf "$acme_work"
		pid_lock_release "$config_lock_dir"
		die 'Unable to back up ACME settings'
	fi
	trap 'restore_acme_state "$acme_work"; rm -rf "$acme_work"; pid_lock_release "$config_lock_dir"; exit 1' INT TERM HUP
	if ! commit_acme_settings; then
		acme_restored=0
		restore_acme_state "$acme_work" && acme_restored=1
		rm -rf "$acme_work"
		pid_lock_release "$config_lock_dir"
		trap - INT TERM HUP
		[ "$acme_restored" = 1 ] &&
			die 'Unable to save ACME settings; previous configuration restored'
		die 'Unable to save ACME settings and automatic rollback was incomplete'
	fi
	rm -rf "$acme_work"
	pid_lock_release "$config_lock_dir"
	trap - INT TERM HUP
}

acme_issue_action() {
	local identity cert key attempt
	identity="$(getv server identity)"
	[ -n "$identity" ] || return 1
	cert="$(acme_server_cert_path)"
	key="$(getv server key_file)"
	[ -n "$key" ] || key="$(getv server cert_source)/$identity.key"
	printf '\n=== %s acme issue ===\n' "$(date)" >>"$acme_log_file"
	/etc/init.d/acme renew "$acme_cert_section" >>"$acme_log_file" 2>&1 || return 1
	attempt=0
	while [ "$attempt" -lt 72 ]; do
		if [ -s "$cert" ] && [ -s "$key" ] &&
		   validate_server_certificate_files "$cert" "$key" "$identity"; then
			if [ "$(getv server enabled)" = 1 ]; then
				sync_server_certificate || return 1
				render_server || return 1
				render_users || return 1
				server_apply_action 1 || return 1
			fi
			return 0
		fi
		attempt=$((attempt + 1))
		sleep 5
	done
	return 1
}

acme_issue() {
	local identity
	identity="$(getv server identity)"
	[ -n "$identity" ] || die 'Set the server public identity first'
	uci -q get "acme.$acme_cert_section" >/dev/null 2>&1 ||
		die 'Configure ACME settings first'
	start_action acme-issue
}

# strongSwan validates the remote VPS certificate only against CAs in
# /etc/swanctl/x509ca/. Unlike iPhone/Windows it does not consult the OS trust
# store automatically, so a public Let's Encrypt server cert is otherwise
# rejected ("no trusted RSA public key" -> AUTH_FAILED). Install the Let's
# Encrypt (ISRG) roots shipped with this package into the swanctl trust store.
# The server identity is still pinned via remote `id`, so this is not blanket
# trust of every CA — only the roots that sign the VPS certificate. Copying the
# bundled PEMs is instant; scanning the system ca-bundle (~150 certs) was too
# slow and timed out the LuCI view that re-renders the client on open.
sync_client_ca() {
	src="$root/usr/share/ikev2-manager/ca"
	dir="$root/etc/swanctl/x509ca"
	mkdir -p "$dir" || return 1
	for pem in "$src"/isrg-root-*.pem; do
		[ -s "$pem" ] || continue
		cp "$pem" "$dir/ikev2-le-${pem##*/}.new" || return 1
		chmod 644 "$dir/ikev2-le-${pem##*/}.new" || return 1
		mv "$dir/ikev2-le-${pem##*/}.new" "$dir/ikev2-le-${pem##*/}" || return 1
	done
}

render_client() {
	enabled="$(getv client enabled)"
	tmp="${outbound_conf}.new"

	if [ "$enabled" != 1 ]; then
		echo '# Managed by IKEv2 Manager. Outbound client is disabled.' >"$tmp" || return 1
		atomic_install "$tmp" "$outbound_conf" 600
		return
	fi

	if ! "$system_helper" strongswan-security client >/dev/null 2>&1; then
		echo '# Managed by IKEv2 Manager. Outbound client is blocked: installed strongSwan is unsafe for EAP-MSCHAPv2.' >"$tmp"
		atomic_install "$tmp" "$outbound_conf" 600
		return
	fi

	if [ "$(getv_default client custom_config 0)" = 1 ]; then
		[ -s "$outbound_custom" ] || {
			printf '%s\n' 'Outbound custom configuration is missing' >&2
			return 1
		}
		cp "$outbound_custom" "$tmp" || return 1
		atomic_install "$tmp" "$outbound_conf" 600
		return
	fi

	sync_client_ca || return 1

	remote_address="$(getv client remote_address)"
	remote_id="$(getv client remote_id)"
	username="$(getv client username)"
	dpd="$(getv client dpd)"
	remote_addrs="$(normalize_host_list "$remote_address" | sed 's/ /, /g')"

	cat >"$tmp" <<EOF
connections {
	proxy-out {
		version = 2
		remote_addrs = $remote_addrs
		proposals = aes256gcm16-prfsha384-ecp384
		vips = 0.0.0.0
		mobike = yes
		fragmentation = yes
		dpd_delay = ${dpd}s
		reauth_time = 0
		keyingtries = 0

		local {
			auth = eap-mschapv2
			id = $username
			eap_id = $username
		}

		remote {
			auth = pubkey
			id = $remote_id
		}

		children {
			proxy4 {
				local_ts = 0.0.0.0/0
				remote_ts = 0.0.0.0/0
				esp_proposals = aes256gcm16-ecp384
				if_id_in = 42
				if_id_out = 42
				start_action = start
				dpd_action = restart
				close_action = start
			}
		}
	}
}
EOF
	[ -s "$tmp" ] || return 1
	atomic_install "$tmp" "$outbound_conf" 600
}

set_client_secret() {
	username="$1"
	password="$2"
	encoded="$(printf '%s' "$password" | openssl base64 -A)" || return 1
	mkdir -p "${client_secret_db%/*}" || return 1
	printf '%s\t0s%s\n' "$username" "$encoded" >"${client_secret_db}.new" || return 1
	atomic_install "${client_secret_db}.new" "$client_secret_db" 600
}

render_client_secret() {
	tmp="${outbound_secret}.new"
	if [ ! -s "$client_secret_db" ]; then
		echo '# Managed by IKEv2 Manager. Client secret is not configured.' >"$tmp" || return 1
		atomic_install "$tmp" "$outbound_secret" 600
		return
	fi
	IFS="$(printf '\t')" read -r username encoded <"$client_secret_db" || return 1
	tmp="${outbound_secret}.new"
	cat >"$tmp" <<EOF
secrets {
	eap-proxy-out {
		id = "$username"
		secret = $encoded
	}
}
EOF
	[ -s "$tmp" ] || return 1
	atomic_install "$tmp" "$outbound_secret" 600
}

sync_client_secret_identity() {
	username="$1"
	[ -s "$client_secret_db" ] || return 0
	IFS="$(printf '\t')" read -r old_username encoded <"$client_secret_db" || return 1
	[ "$old_username" = "$username" ] && return 0
	printf '%s\t%s\n' "$username" "$encoded" >"${client_secret_db}.new" || return 1
	atomic_install "${client_secret_db}.new" "$client_secret_db" 600
}

load_profile() {
	profile="$1"
	[ -z "$root" ] || return 0
	case "$profile" in
		inbound)
			swanctl_quiet --load-all >/dev/null
			;;
		outbound)
			swanctl_quiet --load-all >/dev/null
			if [ "$(getv client enabled)" = 1 ]; then
				swanctl_quiet --terminate --ike proxy-out --timeout 5 >/dev/null || :
				initiate_outbound
				/usr/libexec/ikev2-sync-vips
				/usr/share/pbr/pbr.user.ikev2out
			fi
			;;
		*)
			die 'Unknown profile'
			;;
	esac
}

profile_values() {
	case "$1" in
		inbound)
			profile_section='server'
			profile_active="$inbound_conf"
			profile_custom="$inbound_custom"
			;;
		outbound)
			profile_section='client'
			profile_active="$outbound_conf"
			profile_custom="$outbound_custom"
			;;
		*)
			die 'Expected profile: inbound or outbound'
			;;
	esac
}

advanced_read() {
	profile_values "$1"
	if [ "$profile_section" = server ]; then
		render_server
	else
		render_client
	fi
	cat "$profile_active"
}

advanced_set() {
	profile="$1"
	input="$2"
	profile_values "$profile"
	case "$profile" in
		inbound) ;;
		outbound) "$system_helper" strongswan-security client >/dev/null 2>&1 ||
			die 'Outbound custom configuration is blocked by the installed strongSwan version' ;;
	esac
	[ -f "$input" ] || die 'Custom configuration input is missing'
	[ ! -L "$input" ] || die 'Custom configuration input must not be a symbolic link'
	input_bytes="$(wc -c <"$input" | tr -d ' ')"
	case "$input_bytes" in '' | *[!0-9]*) rm -f "$input"; die 'Invalid custom configuration size' ;; esac
	[ "$input_bytes" -le 65536 ] || {
		rm -f "$input"
		die 'Custom configuration is larger than 64 KiB'
	}
	chmod 600 "$input" || { rm -f "$input"; die 'Unable to protect custom configuration'; }
	tmp="${profile_custom}.new"
	if ! cp "$input" "$tmp"; then
		rm -f "$input" "$tmp"
		die 'Unable to stage custom configuration'
	fi
	rm -f "$input"
	[ -s "$tmp" ] || {
		rm -f "$tmp"
		die 'Custom configuration cannot be empty'
	}
	[ "$(wc -c <"$tmp")" -le 65536 ] || {
		rm -f "$tmp"
		die 'Custom configuration is larger than 64 KiB'
	}
	grep -Eq '^[[:space:]]*connections[[:space:]]*\{' "$tmp" || {
		rm -f "$tmp"
		die 'Custom configuration must contain a connections block'
	}
	case "$profile" in
		inbound)
			grep -Eq '^[[:space:]]*ikev2-in[[:space:]]*\{' "$tmp" &&
				grep -Eq '^[[:space:]]*router_pool4[[:space:]]*\{' "$tmp" || {
				rm -f "$tmp"
				die 'Inbound custom configuration must define ikev2-in and router_pool4'
			}
			;;
		outbound)
			grep -Eq '^[[:space:]]*proxy-out[[:space:]]*\{' "$tmp" || {
				rm -f "$tmp"
				die 'Outbound custom configuration must define proxy-out'
			}
			;;
	esac

	old_mode="$(getv_default "$profile_section" custom_config 0)"
	backup="${profile_custom}.backup"
	[ -s "$profile_custom" ] && cp "$profile_custom" "$backup" || rm -f "$backup"
	atomic_install "$tmp" "$profile_custom" 600
	uci set "$uci_config.$profile_section.custom_config=1"
	uci commit "$uci_config"

	if ! {
		cp "$profile_custom" "${profile_active}.new"
		atomic_install "${profile_active}.new" "$profile_active" 600
		load_profile "$profile"
	}; then
		[ -s "$backup" ] && mv "$backup" "$profile_custom" || rm -f "$profile_custom"
		uci set "$uci_config.$profile_section.custom_config=$old_mode"
		uci commit "$uci_config"
		if [ "$profile_section" = server ]; then
			render_server
		else
			render_client
		fi
		load_profile "$profile" >/dev/null 2>&1 || :
		die 'strongSwan rejected the custom configuration'
	fi
	rm -f "$backup"
}

advanced_reset() {
	profile="$1"
	profile_values "$profile"
	old_mode="$(getv_default "$profile_section" custom_config 0)"
	active_backup="${profile_active}.rollback.$$"
	[ ! -s "$profile_active" ] || cp "$profile_active" "$active_backup"
	uci set "$uci_config.$profile_section.custom_config=0"
	uci commit "$uci_config"
	if ! {
		if [ "$profile_section" = server ]; then
			render_server
		else
			render_client
		fi
		load_profile "$profile"
	}; then
		uci set "$uci_config.$profile_section.custom_config=$old_mode"
		uci commit "$uci_config"
		if [ -s "$active_backup" ]; then
			cp "$active_backup" "${profile_active}.new"
			atomic_install "${profile_active}.new" "$profile_active" 600
		fi
		load_profile "$profile" >/dev/null 2>&1 || true
		rm -f "$active_backup"
		die 'Unable to restore the generated profile; previous profile restored'
	fi
	rm -f "$active_backup"
}

apply_all() {
	[ "$(getv globals configured)" = 1 ] ||
		die 'Complete and enable Overview first'
	sync_server_certificate
	render_server
	render_client
	render_client_secret
	render_users
	"$system_helper" apply
	swanctl_quiet --load-all >/dev/null
	/usr/libexec/ikev2-sync-vips || :
	/usr/share/pbr/pbr.user.ikev2out || :
}

package_installed() {
	name="$1"
	if command -v opkg >/dev/null 2>&1; then
		opkg status "$name" 2>/dev/null | grep -q '^Status: .* installed'
	elif command -v apk >/dev/null 2>&1; then
		apk info -e "$name" >/dev/null 2>&1
	else
		return 1
	fi
}

widget_status() {
	count_lines() {
		[ -r "$1" ] &&
			awk 'NF && $1 !~ /^#/ { n++ } END { print n + 0 }' "$1" ||
			echo 0
	}
	domain_status=''
	if [ -x "$root/usr/libexec/ikev2-domain-router" ]; then
		domain_status="$("$root/usr/libexec/ikev2-domain-router" status 2>/dev/null || true)"
	fi
	configured="$(getv globals configured)"
	[ -n "$configured" ] || configured=0

	printf 'health=%s\n' \
		"$(sed -n 's/^state=\([^ ]*\).*/\1/p' "$root/var/run/ikev2-health.status" 2>/dev/null || echo unknown)"
	printf 'configured=%s\n' "$configured"
	printf 'pbr=%s\n' \
		"$([ -x "$root/etc/init.d/pbr" ] &&
			"$root/etc/init.d/pbr" running && echo running || echo stopped)"
	printf 'client_enabled=%s\n' "$(getv client enabled)"
	printf 'server_enabled=%s\n' "$(getv server enabled)"
	if [ -d "$root/sys/class/net/ipsec-out" ]; then
		printf 'interface_present=1\n'
	else
		printf 'interface_present=0\n'
	fi
	printf 'interface_bytes_in=%s\n' "$(interface_counter ipsec-out rx_bytes)"
	printf 'interface_bytes_out=%s\n' "$(interface_counter ipsec-out tx_bytes)"
	printf 'inbound_conn_loaded=%s\n' \
		"$(swanctl --list-conns 2>/dev/null |
			grep -q 'ikev2-in:' && echo 1 || echo 0)"
	printf 'inbound_pool_loaded=%s\n' \
		"$(swanctl --list-pools 2>/dev/null |
			grep -q 'router_pool4' && echo 1 || echo 0)"
	printf 'pbr_domains=%s\n' "$(count_lines "$root/etc/pbr-ikev2-domains.txt")"
	printf 'manual_addresses=%s\n' \
		"$(count_lines "$root/etc/pbr-ikev2-addresses.manual.txt")"
	printf 'community_services=%s\n' \
		"$(count_lines "$root/etc/pbr-ikev2-community-selected.txt")"
	printf 'killswitch=%s\n' "$(ip -4 route show table pbr_ikev2out 2>/dev/null |
		grep -Eq '^unreachable default( |$)' && echo active || echo missing)"
	for field in engine service healthy state; do
		if [ "$field" = engine ]; then
			value="$(getv domains engine)"
		else
			value="$(printf '%s\n' "$domain_status" |
				sed -n "s/^$field=//p" | tail -n1)"
		fi
		printf 'domain_%s=%s\n' "$field" "$value"
	done
}

overview() {
	cert="$root/etc/swanctl/x509/ikev2.pem"
	count_lines() {
		[ -r "$1" ] && awk 'NF && $1 !~ /^#/ { n++ } END { print n + 0 }' "$1" || echo 0
	}
	configured="$(getv globals configured)"
	[ -n "$configured" ] || configured=0
	[ "$configured" = 1 ] && runtime_mode=managed || runtime_mode=unconfigured
	printf 'health=%s\n' "$(sed -n 's/^state=\([^ ]*\).*/\1/p' /var/run/ikev2-health.status 2>/dev/null || echo unknown)"
	printf 'pbr=%s\n' "$("$root/etc/init.d/pbr" running && echo running || echo stopped)"
	printf 'configured=%s\n' "$configured"
	printf 'runtime_mode=%s\n' "$runtime_mode"
	printf 'package_installed=%s\n' "$(package_installed luci-app-ikev2-manager && echo 1 || echo 0)"
	printf 'zapret=%s\n' "$([ -x "$root/etc/init.d/zapret" ] &&
		"$root/etc/init.d/zapret" running && echo running || echo not-installed)"
	printf 'client_enabled=%s\n' "$(getv client enabled)"
	printf 'client_remote=%s\n' "$(getv client remote_address)"
	printf 'client_mtu=%s\n' "$(getv client mtu)"
	printf 'server_enabled=%s\n' "$(getv server enabled)"
	# Runtime truth (not just the UCI flag): is the inbound conn + pool actually
	# loaded into charon? A drifted server (cert/pool unloaded) is enabled but not
	# serving — surface that instead of showing a healthy "Enabled".
	printf 'inbound_conn_loaded=%s\n' "$([ -z "$root" ] && swanctl --list-conns 2>/dev/null | grep -q 'ikev2-in:' && echo 1 || echo 0)"
	printf 'inbound_pool_loaded=%s\n' "$([ -z "$root" ] && swanctl --list-pools 2>/dev/null | grep -q 'router_pool4' && echo 1 || echo 0)"
	printf 'server_pool=%s\n' "$(getv server pool4)"
	printf 'configured_users=%s\n' "$(count_lines "$users_db")"
	printf 'pbr_domains=%s\n' "$(count_lines "$root/etc/pbr-ikev2-domains.txt")"
	printf 'manual_domains=%s\n' "$(count_lines "$root/etc/pbr-ikev2-domains.manual.txt")"
	printf 'manual_addresses=%s\n' "$(count_lines "$root/etc/pbr-ikev2-addresses.manual.txt")"
	printf 'community_services=%s\n' "$(count_lines "$root/etc/pbr-ikev2-community-selected.txt")"
	printf 'dns_hijack=%s\n' "$(
		if nft list ruleset 2>/dev/null | grep -Eq 'dport 53.*dnat|dnat.*dport 53'; then
			echo active
		elif uci show firewall 2>/dev/null | grep -Eq '^firewall\.(dns_hijack_|ikev2pbr_dns_)'; then
			echo configured
		else
			echo missing
		fi
	)"
	printf 'dot_block=%s\n' "$(
		if nft list ruleset 2>/dev/null | grep -Eq 'dport 853.*reject|reject.*dport 853'; then
			echo active
		elif uci show firewall 2>/dev/null | grep -Eq '^firewall\.(block_dot|ikev2pbr_dot_)'; then
			echo configured
		else
			echo missing
		fi
	)"
	printf 'killswitch=%s\n' "$(ip -4 route show table pbr_ikev2out 2>/dev/null |
		grep -Eq '^unreachable default( |$)' && echo active || echo missing)"
	printf 'inbound_firewall=%s\n' "$(nft list ruleset 2>/dev/null | grep -Eq 'udp dport.*500.*4500.*accept' && echo active || echo missing)"
	printf 'mtproto=%s\n' "$([ -x "$root/etc/init.d/tg-ws-proxy" ] &&
		"$root/etc/init.d/tg-ws-proxy" running &&
		echo running || echo not-installed)"
	printf 'mtproto_firewall=%s\n' "$(
		nft list ruleset 2>/dev/null |
			grep -Eq 'tcp dport 1443.*(accept|dnat)' &&
			echo active || echo missing
	)"
	printf 'flow_software=%s\n' "$(uci -q get firewall.@defaults[0].flow_offloading || echo 0)"
	printf 'flow_hardware=%s\n' "$(uci -q get firewall.@defaults[0].flow_offloading_hw || echo 0)"
	printf 'safexcel=%s\n' "$(lsmod | grep -q '^crypto_safexcel ' && echo loaded || echo unloaded)"
	printf 'cert_subject=%s\n' "$(openssl x509 -in "$cert" -noout -subject 2>/dev/null | sed 's/^subject=//')"
	printf 'cert_issuer=%s\n' "$(openssl x509 -in "$cert" -noout -issuer 2>/dev/null | sed 's/^issuer=//')"
	printf 'cert_not_before=%s\n' "$(openssl x509 -in "$cert" -noout -startdate 2>/dev/null | cut -d= -f2-)"
	printf 'cert_not_after=%s\n' "$(openssl x509 -in "$cert" -noout -enddate 2>/dev/null | cut -d= -f2-)"
	printf 'cert_fingerprint=%s\n' "$(openssl x509 -in "$cert" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2-)"
}

show_users() {
	while IFS="$(printf '\t')" read -r user secret; do
		[ -n "$user" ] || continue
		# Passwords remain available to strongSwan locally, but are write-only
		# through LuCI/RPC so a read action never returns them to the browser.
		printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
			"$user" \
			"$(user_policy_value "$user" router_access inherit)" \
			"$(user_policy_value "$user" internet_access inherit)" \
			"$(user_policy_value "$user" lan_access inherit)" \
			"$(user_policy_value "$user" pbr_mode inherit)" \
			"$(user_policy_value "$user" lan_targets '')" \
			"$(user_policy_value "$user" public_ports '')"
	done <"$users_db"
}

init_uci
init_users
init_client_secret

# Run swanctl --initiate but swallow strongSwan's noisy plugin-load warnings,
# surfacing only the meaningful failure reason to the caller (and the LuCI UI).
initiate_outbound() {
	_err="$(swanctl --initiate --child proxy4 --timeout 20 2>&1 >/dev/null)" && return 0
	# A busy peer can complete IKE_AUTH immediately after the VICI timeout.
	# Check runtime truth briefly before reporting a failed reconnect.
	_wait=0
	while [ "$_wait" -lt 8 ]; do
		has_outbound_sa && return 0
		_wait=$((_wait + 1))
		sleep 1
	done
	_reason="$(printf '%s\n' "$_err" \
		| grep -viE 'failed to load|no plugin file|_plugin_create' \
		| grep -iE 'initiate|establish|auth|propos|timeout|retransmit|no ike|unable|notify|peer|certificate|fail' \
		| tail -n 4 | tr '\n' ' ' | sed 's/  */ /g')"
	[ -n "$_reason" ] || _reason='establishing CHILD_SA proxy4 failed (run logread for strongSwan details)'
	printf 'Tunnel did not come up: %s\n' "$_reason" >&2
	return 1
}

connect_action() {
	swanctl_quiet --terminate --ike proxy-out --timeout 5 >/dev/null 2>&1 || :
	rm -f /var/run/ikev2-vip4
	ip -4 addr flush dev ipsec-out scope global 2>/dev/null || :
	if initiate_outbound; then
		/usr/libexec/ikev2-sync-vips || return 1
		# The policy itself did not change. Refresh only the live PBR table route;
		# a full PBR restart would rebuild firewall4 and add ~20 seconds.
		/usr/share/pbr/pbr.user.ikev2out || return 1
		return 0
	else
		/usr/libexec/ikev2-sync-vips || :
		/usr/share/pbr/pbr.user.ikev2out || :
		return 1
	fi
}

has_outbound_sa() {
	swanctl --list-sas --raw 2>/dev/null |
		grep -q 'name=proxy4[^{}]* state=INSTALLED'
}

outbound_peer_resolves() {
	peers="$(normalize_host_list "$(getv client remote_address)")"
	for peer in $peers; do
		if valid_ipv4 "$peer" ||
		   printf '%s' "$peer" | grep -q ':' ||
		   resolveip -4 -t 3 "$peer" >/dev/null 2>&1; then
			return 0
		fi
	done
	return 1
}

# Bring up an enabled outbound client without tearing down an already healthy
# SA. This is used by WAN hotplug and the health watcher, so it has its own
# non-blocking lock and a short failure backoff to avoid duplicate initiations.
ensure_client_action() {
	[ -z "$root" ] || return 0
	[ "$(getv globals configured)" = 1 ] || return 0
	[ "$(getv client enabled)" = 1 ] || return 0
	"$system_helper" strongswan-security client >/dev/null 2>&1 || return 0
	has_outbound_sa && return 0
	[ ! -d "$action_lock_dir" ] || return 0

	now="$(date +%s)"
	cooldown="$(getv_default client reconnect_cooldown 15)"
	in_range "$cooldown" 15 300 || cooldown=15
	last="$(cat "$auto_connect_attempt" 2>/dev/null || echo 0)"
	case "$last" in
		'' | *[!0-9]*) last=0 ;;
	esac
	[ $((now - last)) -ge "$cooldown" ] || return 0

	if ! mkdir "$auto_connect_lock" 2>/dev/null; then
		lock_pid="$(cat "$auto_connect_lock/pid" 2>/dev/null || true)"
		if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
			return 0
		fi
		rm -f "$auto_connect_lock/pid"
		rmdir "$auto_connect_lock" 2>/dev/null || return 0
		mkdir "$auto_connect_lock" 2>/dev/null || return 0
	fi
	printf '%s\n' "$$" >"$auto_connect_lock/pid"
	trap 'rm -f "$auto_connect_lock/pid"; rmdir "$auto_connect_lock" 2>/dev/null || true' EXIT INT TERM

	# Recheck after taking the lock: WAN hotplug and the watcher may have raced.
	has_outbound_sa && return 0
	[ ! -d "$action_lock_dir" ] || return 0
	printf '%s\n' "$now" >"$auto_connect_attempt"
	# Do not spend swanctl's full initiation timeout while boot-time DNS is not
	# ready yet. The watcher will retry shortly, and hotplug calls us again only
	# after the WAN has had time to finish resolver/PBR setup.
	outbound_peer_resolves || return 1

	swanctl_quiet --load-conns >/dev/null || return 1
	swanctl_quiet --load-creds >/dev/null || return 1
	initiate_outbound || return 1
	/usr/libexec/ikev2-sync-vips || return 1
	/usr/share/pbr/pbr.user.ikev2out || return 1
}

disable_client_action() {
	# The disabled profile contains no proxy-out connection. Reload it first so
	# charon unloads the previous start_action=start definition instead of
	# immediately re-initiating after termination.
	swanctl_quiet --load-conns >/dev/null || return 1
	swanctl_quiet --terminate --ike proxy-out --timeout 5 >/dev/null 2>&1 || :
	rm -f /var/run/ikev2-vip4
	ip -4 addr flush dev ipsec-out scope global 2>/dev/null || :
	/usr/share/pbr/pbr.user.ikev2out || return 1
	tries=0
	while [ "$tries" -lt 10 ]; do
		if ! swanctl --list-conns 2>/dev/null | grep -q 'proxy-out:' &&
		   ! swanctl --list-sas --raw 2>/dev/null | grep -q 'name=proxy-out'; then
			return 0
		fi
		tries=$((tries + 1))
		sleep 1
	done
	return 1
}

apply_action() {
	"$system_helper" apply || return 1
	swanctl_quiet --load-all >/dev/null || return 1
	/usr/libexec/ikev2-sync-vips || :
	return 0
}

server_apply_action() {
	needs_pbr="${1:-0}"
	enabled="$(getv_default server enabled 0)"
	if [ "$enabled" != 1 ]; then
		swanctl_quiet --terminate --ike ikev2-in --timeout 5 >/dev/null 2>&1 || true
	fi
	swanctl_quiet --load-all >/dev/null || return 1
	"$system_helper" server-apply "$needs_pbr" || return 1
	if [ "$(getv_default client enabled 0)" = 1 ] && has_outbound_sa; then
		/usr/libexec/ikev2-sync-vips || return 1
	fi
	/usr/share/pbr/pbr.user.ikev2out || return 1
	if [ "$enabled" = 1 ]; then
		swanctl --list-conns 2>/dev/null | grep -q 'ikev2-in:' || return 1
		swanctl --list-pools 2>/dev/null | grep -q 'router_pool4' || return 1
		ip link show ipsec-in >/dev/null 2>&1 || return 1
	else
		! swanctl --list-conns 2>/dev/null | grep -q 'ikev2-in:' || return 1
		! swanctl --list-sas --raw 2>/dev/null | grep -q 'name=ikev2-in' || return 1
		! ip link show ipsec-in >/dev/null 2>&1 || return 1
	fi
}

run_action() {
	id="$1"
	kind="$2"
	shift 2
	exec >>/tmp/ikev2-manager-action.log 2>&1
	printf '\n=== %s action=%s id=%s ===\n' "$(date)" "$kind" "$id"
	action_status "$id" running 'Waiting for other router actions...'
	if ! acquire_action_lock manager "$id"; then
		action_status "$id" error 'Timed out waiting for another router action.'
		return 1
	fi
	trap 'rm -f "$action_lock_status"; rmdir "$action_lock_dir" 2>/dev/null || true' EXIT INT TERM

	case "$kind" in
		apply)
			action_status "$id" running 'Applying firewall, PBR and strongSwan...'
			if apply_action; then
				action_status "$id" ok 'Configuration applied.'
			else
				action_status "$id" error 'Apply failed; see /tmp/ikev2-manager-action.log and logread.'
			fi
			;;
		connect)
			action_status "$id" running 'Reconnecting the outbound tunnel...'
			if connect_action; then
				action_status "$id" ok 'Outbound tunnel reconnected.'
			else
				action_status "$id" error 'Tunnel did not come up; see /tmp/ikev2-manager-action.log and logread.'
			fi
			;;
		client-connect)
			action_status "$id" running 'Loading settings and reconnecting the outbound tunnel...'
			if swanctl_quiet --load-conns >/dev/null &&
			   swanctl_quiet --load-creds >/dev/null &&
			   connect_action; then
				action_status "$id" ok 'Settings saved and tunnel connected.'
			else
				action_status "$id" error 'Settings were saved, but the tunnel did not come up; see logread.'
			fi
			;;
		client-disable)
			action_status "$id" running 'Stopping the outbound tunnel...'
			if disable_client_action; then
				action_status "$id" ok 'Settings saved and tunnel disabled.'
			else
				action_status "$id" error 'Settings were saved, but the tunnel could not be stopped cleanly.'
			fi
			;;
		server-apply)
			action_status "$id" running 'Applying inbound server settings...'
			server_rollback="${2:-}"
			if server_apply_action "${1:-0}"; then
				[ -z "$server_rollback" ] || rm -rf "$server_rollback"
				action_status "$id" ok 'Inbound server settings applied.'
			else
				server_restored=0
				server_superseded=0
				if [ -d "$server_rollback" ] && [ -f "$server_rollback/applied.uci" ]; then
					if cmp -s "$server_rollback/applied.uci" "$uci_config_dir/$uci_config"; then
						config_tries=0
						config_locked=0
						while [ "$config_locked" = 0 ]; do
							if pid_lock_acquire "$config_lock_dir"; then
								config_locked=1
								break
							fi
							config_tries=$((config_tries + 1))
							[ "$config_tries" -lt 30 ] || break
							sleep 1
						done
						if [ "$config_locked" = 1 ] &&
						   cmp -s "$server_rollback/applied.uci" "$uci_config_dir/$uci_config" &&
						   restore_server_state "$server_rollback" &&
						   server_apply_action 1; then
							server_restored=1
						fi
						[ "$config_locked" = 0 ] || pid_lock_release "$config_lock_dir"
					else
						server_superseded=1
					fi
				fi
				[ -z "$server_rollback" ] || rm -rf "$server_rollback"
				if [ "$server_restored" = 1 ]; then
					action_status "$id" error 'Inbound server apply failed; previous configuration was restored.'
				elif [ "$server_superseded" = 1 ]; then
					action_status "$id" error 'Inbound server apply was superseded by newer settings.'
				else
					action_status "$id" error 'Inbound server apply and automatic rollback failed; see /tmp/ikev2-manager-action.log.'
				fi
			fi
			;;
		acme-issue)
			action_status "$id" running 'Requesting and validating the certificate...'
			if acme_issue_action; then
				action_status "$id" ok 'Certificate is valid and installed.'
			else
				action_status "$id" error 'Certificate request or installation failed; see /tmp/ikev2-acme.log.'
			fi
			;;
		advanced-set)
			action_status "$id" running 'Validating and loading the custom profile...'
			if ( advanced_set "$1" "$2" ); then
				action_status "$id" ok 'Custom profile loaded.'
			else
				action_status "$id" error 'Custom profile was rejected; previous profile restored.'
			fi
			;;
		advanced-reset)
			action_status "$id" running 'Restoring the generated profile...'
			if ( advanced_reset "$1" ); then
				action_status "$id" ok 'Generated profile restored.'
			else
				action_status "$id" error 'Unable to restore the generated profile.'
			fi
			;;
		*)
			action_status "$id" error 'Unknown background action.'
			;;
	esac
}

case "${1:-}" in
	overview)
		overview
		;;
	widget-status)
		widget_status
		;;
	users)
		cut -f1 "$users_db"
		;;
	users-show)
		show_users
		;;
	user-secret-set)
		[ -n "$user_input_file" ] || user_input_file="$(input_file_for user "${2:-}")"
		consume_user_input
		;;
	user-delete)
		user="${2:-}"
		valid_user "$user" || die 'Invalid username'
		delete_user_account "$user"
		;;
	disconnect)
		id="${2:-}"
		valid_uint "$id" || die 'Invalid IKE SA identifier'
		swanctl_quiet --terminate --ike-id "$id" --timeout 5 >/dev/null
		;;
	disconnect-all)
		swanctl_quiet --terminate --ike ikev2-in --timeout 5 >/dev/null || :
		;;
	server-get)
		for key in enabled identity pool4 gateway4 dns4 cert_source cert_file key_file dpd ike_rekey child_rekey mtu mobike fragmentation custom_config; do
			printf '%s=%s\n' "$key" "$(getv server "$key")"
		done
		;;
	server-input)
		[ -n "$server_input_file" ] ||
			server_input_file="$(input_file_for server "${2:-}")"
		consume_server_input
		;;
	server-access-get)
		printf 'local_ts=%s\n' "$(getv_default server local_ts 0.0.0.0/0)"
		printf 'allow_internet=%s\n' "$(getv_default server allow_internet 1)"
		printf 'allow_lan=%s\n' "$(getv_default server allow_lan 1)"
		printf 'allow_router=%s\n' "$(getv_default server allow_router 0)"
		printf 'router_ports=%s\n' "$(getv server router_ports)"
		printf 'lan_zones=%s\n' "$(get_list server lan_zone)"
		printf 'firewall_zone=%s\n' "$(getv_default server firewall_zone ikev2in)"
		printf 'outbound_zone=%s\n' "$(getv_default server outbound_zone ikev2out)"
		;;
	acme-get)
		acme_emit
		;;
	acme-set)
		[ -n "$acme_input_file" ] || acme_input_file="$(input_file_for acme "${2:-}")"
		acme_set
		;;
	acme-issue)
		acme_issue
		;;
	client-get)
		for key in enabled remote_address remote_id username dpd mtu custom_config; do
			printf '%s=%s\n' "$key" "$(getv client "$key")"
		done
		printf 'reconnect_cooldown=%s\n' \
			"$(getv_default client reconnect_cooldown 15)"
		if [ -d "$root/sys/class/net/ipsec-out" ]; then
			printf 'interface_present=1\n'
		else
			printf 'interface_present=0\n'
		fi
		printf 'interface_bytes_in=%s\n' "$(interface_counter ipsec-out rx_bytes)"
		printf 'interface_bytes_out=%s\n' "$(interface_counter ipsec-out tx_bytes)"
		;;
	client-input)
		[ -n "$client_input_file" ] || client_input_file="$(input_file_for client "${2:-}")"
		consume_client_input
		;;
	reconnect-client)
		[ "$(getv globals configured)" = 1 ] || die 'Complete and enable Overview first'
		[ "$(getv client enabled)" = 1 ] || die 'Outbound client is disabled'
		start_action connect
		;;
	ensure-client)
		ensure_client_action
		;;
	advanced-start)
		[ "$#" -eq 3 ] || die 'Expected: profile input-token'
		profile_values "$2"
		profile_input="$(input_file_for profile "$3")"
		[ -f "$profile_input" ] && [ ! -L "$profile_input" ] ||
			die 'Custom configuration input is missing'
		cleanup_profile_input=1
		trap '[ "$cleanup_profile_input" = 0 ] || rm -f "$profile_input"' EXIT INT TERM HUP
		start_action advanced-set "$2" "$profile_input"
		cleanup_profile_input=0
		trap - EXIT INT TERM HUP
		;;
	advanced-reset-start)
		[ "$#" -eq 2 ] || die 'Expected: profile'
		start_action advanced-reset "$2"
		;;
	_action-run)
		shift
		run_action "$@"
		;;
	action-status)
		if [ -n "${2:-}" ]; then
			cat "$action_status_dir/$2.status" 2>/dev/null || printf 'state=idle\n'
		else
			cat "$action_status_file" 2>/dev/null || printf 'state=idle\n'
		fi
		;;
	reload)
		apply_all
		;;
	server-ensure)
		# Self-heal a drifted inbound server: if it is enabled but the cert,
		# connection or pool is not actually loaded into charon (e.g. after a
		# strongSwan reinstall cleared /etc/swanctl, or a partial reload), re-sync
		# the certificate and reload everything. No-op when already healthy or the
		# server is disabled. Called by the health service; safe to run anytime.
		[ "$(getv server enabled)" = 1 ] || exit 0
		_need=0
		[ -s "$root/etc/swanctl/x509/ikev2.pem" ] || _need=1
		if [ -z "$root" ]; then
			swanctl --list-conns 2>/dev/null | grep -q 'ikev2-in:' || _need=1
			swanctl --list-pools 2>/dev/null | grep -q 'router_pool4' || _need=1
			ip link show ipsec-in >/dev/null 2>&1 || _need=1
		fi
		[ "$_need" = 1 ] || exit 0
		sync_server_certificate || die 'server-ensure: certificate sync failed'
		render_server
		render_users
		if [ -z "$root" ]; then
			swanctl_quiet --load-all >/dev/null || die 'server-ensure: strongSwan reload failed'
			/etc/init.d/ikev2-xfrm start >/dev/null || die 'server-ensure: XFRM startup failed'
		fi
		printf 'server-ensured=1\n'
		;;
	server-cert-sync)
		[ "$(getv server enabled)" = 1 ] || exit 0
		sync_server_certificate
		if [ -z "$root" ]; then
			swanctl_quiet --load-creds >/dev/null || die 'server-cert-sync: credential reload failed'
		fi
		printf 'server-cert-synced=1\n'
		;;
	advanced-mode)
		profile_values "${2:-}"
		getv_default "$profile_section" custom_config 0
		;;
	advanced-read)
		advanced_read "${2:-}"
		;;
	*)
		die 'Usage: ikev2-manager {overview|users-show|user-secret-set|user-delete|disconnect|disconnect-all|server-get|server-input|server-access-get|server-ensure|server-cert-sync|acme-get|acme-set|acme-issue|client-get|client-input|reconnect-client|ensure-client|action-status|advanced-mode|advanced-read|advanced-start|advanced-reset-start|reload}'
		;;
esac
