#!/bin/sh
# IKEv2 Manager for OpenWrt compatibility and runtime controller.

set -eu

uci_config_dir="${IKEV2_UCI_CONFIG_DIR:-/etc/config}"
uci_binary="${IKEV2_UCI_BIN:-/sbin/uci}"

uci() {
	"$uci_binary" -c "$uci_config_dir" "$@"
}

config='ikev2-manager'
dns_input_file="${IKEV2_DNS_INPUT:-}"
user_policy_helper="${IKEV2_USER_POLICY_HELPER:-/usr/libexec/ikev2-user-policy}"
user_policy_init="${IKEV2_USER_POLICY_INIT:-/etc/init.d/ikev2-user-policy}"
domain_router_helper="${IKEV2_DOMAIN_ROUTER_HELPER:-/usr/libexec/ikev2-domain-router}"
device_runtime_helper="${IKEV2_DEVICE_RUNTIME_HELPER:-/usr/libexec/ikev2-device-routing}"
nft_binary="${IKEV2_NFT:-/usr/sbin/nft}"
dns_segments_status_file="${IKEV2_DNS_SEGMENTS_STATUS:-/var/run/ikev2-dns-segments.status}"

die() {
	printf '%s\n' "$*" >&2
	exit 1
}

input_file_for() {
	token="$1"
	case "$token" in
		'' | *[!A-Za-z0-9-]* ) die 'Invalid input token' ;;
	esac
	[ "${#token}" -ge 8 ] && [ "${#token}" -le 64 ] || die 'Invalid input token'
	printf '/tmp/ikev2-manager-dns-%s.in\n' "$token"
}

getv() {
	uci -q get "$config.$1.$2" 2>/dev/null || true
}

get_list() {
	uci -q get "$config.$1.$2" 2>/dev/null || true
}

valid_name() {
	[ -n "$1" ] && [ "${#1}" -le 32 ] &&
		printf '%s' "$1" | grep -Eq '^[A-Za-z0-9_.-]+$'
}

normalize_list() {
	printf '%s' "$1" | tr ',' ' ' | tr -s ' ' | sed 's/^ //;s/ $//'
}

list_without() {
	local candidates="$1" excluded="$2" item seen duplicate result=''
	for item in $candidates; do
		duplicate=0
		for seen in $excluded $result; do
			[ "$seen" != "$item" ] || { duplicate=1; break; }
		done
		[ "$duplicate" = 0 ] || continue
		result="${result:+$result }$item"
	done
	printf '%s\n' "$result"
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

defaultv() {
	value="$(getv "$1" "$2")"
	printf '%s\n' "${value:-$3}"
}

valid_name_list() {
	value="$(normalize_list "$1")"
	[ -n "$value" ] || return 1
	count=0
	for item in $value; do
		count=$((count + 1))
		[ "$count" -le 32 ] || return 1
		valid_name "$item" || return 1
	done
}

set_list() {
	section="$1"
	option="$2"
	value="$(normalize_list "$3")"
	uci -q delete "$config.$section.$option" || true
	for item in $value; do
		uci add_list "$config.$section.$option=$item"
	done
}

add_list_unique() {
	package="$1"
	section="$2"
	option="$3"
	value="$4"
	current="$(uci -q get "$package.$section.$option" 2>/dev/null || true)"
	for item in $current; do
		[ "$item" = "$value" ] && return 0
	done
	uci add_list "$package.$section.$option=$value"
}

domain_file_has_entries() {
	awk 'NF && $1 !~ /^#/ { found = 1 } END { exit found ? 0 : 1 }' "$1" 2>/dev/null
}

delete_prefixed_sections() {
	package="$1"
	prefix="$2"
	uci show "$package" 2>/dev/null |
		sed -n "s/^${package}\.\(${prefix}[A-Za-z0-9_]*\)=.*/\1/p" |
		sort -u |
		while IFS= read -r section; do
			[ -n "$section" ] && uci -q delete "$package.$section"
		done
}

delete_sections() {
	package="$1"
	shift
	for section in "$@"; do
		uci -q delete "$package.$section" || true
	done
}

# fw4 can return success while dropping a section with invalid options. Treat
# that diagnostic as a failed validation so an apparently successful apply can
# never leave DNS enforcement or another managed rule absent.
firewall_check_strict() {
	local log="${TMPDIR:-/tmp}/ikev2-fw4-check.$$"
	if ! fw4 check >"$log" 2>&1; then
		cat "$log" >&2
		rm -f "$log"
		return 1
	fi
	if grep -Eq "must not be a list|skipped due to invalid options|Section .* skipped" "$log"; then
		cat "$log" >&2
		rm -f "$log"
		return 1
	fi
	rm -f "$log"
}

sync_device_runtime() {
	[ ! -x "$device_runtime_helper" ] || "$device_runtime_helper" sync
}

# Package upgrades must repair the DNS policy without restarting PBR, WAN,
# strongSwan or the fw4 table. Managed DNS changes are applied through the same
# validated transaction as LuCI: resolver processes may restart briefly, while
# failure restores their previous configuration and process state. Install the
# owned nftables table before retiring old generated UCI sections.
reconcile_upgrade_runtime() {
	local changed=0 section dns_reconciled=0
	[ "$(getv globals configured)" = 1 ] || return 0
	# Runtime flags and per-segment process ownership live outside package files,
	# so merely replacing the init script is insufficient. Re-apply saved DNS to
	# disable duplicate optimistic caches, refresh segment fallback groups and
	# activate the current sing-box DNS rules immediately after an upgrade.
	if [ "$(defaultv dns managed 0)" = 1 ]; then
		apply_saved_dns || return 1
		dns_reconciled=1
	fi
	# The package replaces the renderer, not the already generated sing-box
	# configuration. Refresh an active Reliable-mode runtime transactionally so
	# a DNS-policy hotfix takes effect immediately after upgrade. The helper
	# validates the new configuration before cutover and restores the previous
	# generated files and process if the replacement fails.
	if [ "$dns_reconciled" = 0 ] && [ "$(getv domains engine)" = fakeip ] &&
	   [ -x "$domain_router_helper" ]; then
		"$domain_router_helper" refresh || return 1
	fi
	sync_device_runtime || return 1
	sync_inbound_user_policy || return 1
	for section in $(uci show firewall 2>/dev/null |
		sed -n \
			-e 's/^firewall\.\(ikev2pbr_dns_[A-Za-z0-9_]*\)=.*/\1/p' \
			-e 's/^firewall\.\(ikev2pbr_dot_[A-Za-z0-9_]*\)=.*/\1/p' |
		sort -u); do
		uci -q delete "firewall.$section" || return 1
		changed=1
	done
	[ "$changed" = 0 ] || uci commit firewall
}

sanitize() {
	printf '%s' "$1" | tr -c 'A-Za-z0-9_' '_'
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
	[ -n "$device" ] && printf '%s\n' "$device"
}

gateway_network() {
	gateway="$(getv server gateway4)"
	[ -n "$gateway" ] || return 0
	ipcalc.sh "$gateway" 2>/dev/null |
		awk -F= '/^NETWORK=/{network=$2}/^PREFIX=/{prefix=$2}END{if(network!=""&&prefix!="")print network "/" prefix}'
}

zone_exists() {
	zone="$1"
	uci show firewall 2>/dev/null |
		grep -Fq ".name='$zone'"
}

zone_name_count() {
	wanted="$1"
	index=0
	count=0
	while uci -q get "firewall.@zone[$index]" >/dev/null 2>&1; do
		name="$(uci -q get "firewall.@zone[$index].name" 2>/dev/null || true)"
		[ "$name" != "$wanted" ] || count=$((count + 1))
		index=$((index + 1))
	done
	printf '%s\n' "$count"
}

managed_zone_name_available() {
	name="$1"
	owner="$2"
	count="$(zone_name_count "$name")"
	owner_type="$(uci -q get "firewall.$owner" 2>/dev/null || true)"
	owner_name="$(uci -q get "firewall.$owner.name" 2>/dev/null || true)"
	if [ "$owner_type" = zone ] && [ "$owner_name" = "$name" ]; then
		[ "$count" -eq 1 ]
	else
		[ "$count" -eq 0 ]
	fi
}

validate_server_zone_names() {
	[ "$#" -eq 2 ] || die 'Expected inbound and outbound firewall zone names'
	inbound_zone="$1"
	outbound_zone="$2"
	valid_name "$inbound_zone" || die 'Invalid inbound firewall zone name'
	valid_name "$outbound_zone" || die 'Invalid outbound firewall zone name'
	[ "$inbound_zone" != "$outbound_zone" ] ||
		die 'Inbound and outbound firewall zones must be different'
	managed_zone_name_available "$inbound_zone" ikev2pbr_in ||
		die "Inbound firewall zone name '$inbound_zone' is already in use"
	managed_zone_name_available "$outbound_zone" ikev2pbr_out ||
		die "Outbound firewall zone name '$outbound_zone' is already in use"
}

port_range_contains() {
	range="$1"
	port="$2"
	case "$range" in
		*-*) start="${range%%-*}"; end="${range#*-}" ;;
		*:*) start="${range%%:*}"; end="${range#*:}" ;;
		*) start="$range"; end="$range" ;;
	esac
	case "$start:$end:$port" in
		*[!0-9:]* | ::*) return 1 ;;
	esac
	[ "$port" -ge "$start" ] && [ "$port" -le "$end" ]
}

upnp_port_action() {
	wanted="$1"
	index=0
	while uci -q get "upnpd.@perm_rule[$index]" >/dev/null 2>&1; do
		action="$(uci -q get "upnpd.@perm_rule[$index].action" 2>/dev/null || echo deny)"
		ranges="$(uci -q get "upnpd.@perm_rule[$index].ext_ports" 2>/dev/null || true)"
		for range in $ranges; do
			if port_range_contains "$range" "$wanted"; then
				printf '%s\n' "$action"
				return 0
			fi
		done
		index=$((index + 1))
	done
	printf 'deny\n'
}

upnp_ikev2_check() {
	if [ "$(uci -q get upnpd.config.enabled 2>/dev/null || echo 0)" != 1 ]; then
		printf 'upnp_ikev2_ports=ok:not-enabled\n'
		return 0
	fi
	upnp_rules="$(nft list chain inet fw4 upnp_prerouting 2>/dev/null || true)"
	if printf '%s\n' "$upnp_rules" | grep 'udp dport' |
		grep -Eq '(^|[^0-9])(500|4500)([^0-9]|$)'; then
		printf 'upnp_ikev2_ports=conflict:active-UDP-500-or-4500-mapping\n'
		return 1
	fi
	available=''
	for port in 500 4500; do
		[ "$(upnp_port_action "$port")" != allow ] ||
			available="${available}${available:+,}$port"
	done
	if [ -n "$available" ]; then
		printf 'upnp_ikev2_ports=warn:UDP-%s-available-to-UPnP\n' "$available"
	else
		printf 'upnp_ikev2_ports=ok:UDP-500-and-4500-reserved\n'
	fi
}

compatibility_checks() {
	release_id='unknown'
	release='unknown'
	target='unknown'
	arch='unknown'
	if [ -r /etc/openwrt_release ]; then
		. /etc/openwrt_release
		release_id="${DISTRIB_ID:-unknown}"
		release="${DISTRIB_RELEASE:-unknown}"
		target="${DISTRIB_TARGET:-unknown}"
		arch="${DISTRIB_ARCH:-unknown}"
	fi

	board_json="$(ubus call system board 2>/dev/null || true)"
	board_model="$(printf '%s' "$board_json" | jsonfilter -e '@.model' 2>/dev/null || true)"
	board_name="$(printf '%s' "$board_json" | jsonfilter -e '@.board_name' 2>/dev/null || true)"
	printf 'board_model=ok:%s\n' "${board_model:-unknown}"
	printf 'board_name=ok:%s\n' "${board_name:-unknown}"
	printf 'target=ok:%s\n' "$target"
	printf 'architecture=ok:%s\n' "$arch"
	printf 'kernel=ok:%s\n' "$(uname -r 2>/dev/null || echo unknown)"

	if [ "$release_id" = OpenWrt ]; then
		printf 'firmware_source=ok:official\n'
	else
		printf 'firmware_source=unsupported:%s\n' "$release_id"
		ok=0
		dependencies_ok=0
	fi
	case "$release" in
		24.10.*) printf 'openwrt=ok:%s\n' "$release" ;;
		25.12.*)
			printf 'openwrt=ok:%s-apk\n' "$release"
			;;
		*)
			printf 'openwrt=unsupported:%s\n' "$release"
			ok=0
			dependencies_ok=0
			;;
	esac

	package_manager="$(pkg_manager_name)"
	case "$release:$package_manager" in
		24.10.*:opkg | 25.12.*:apk)
			printf 'package_manager=ok:%s\n' "$package_manager"
			;;
		*:missing)
			printf 'package_manager=missing\n'
			ok=0
			dependencies_ok=0
			;;
		*)
			printf 'package_manager=unsupported:%s-for-%s\n' "$package_manager" "$release"
			ok=0
			dependencies_ok=0
			;;
	esac
	if pkg_release_feed_ok "$release"; then
		printf 'package_feeds=ok:official\n'
	else
		printf 'package_feeds=unsupported:non-release-or-vendor\n'
		ok=0
		dependencies_ok=0
	fi

	install_space_needed=0
	if ! pkg_dnsmasq_has_nftset 2>/dev/null; then
		install_space_needed=1
	else
		for package in $(runtime_packages); do
			pkg_installed "$package" || { install_space_needed=1; break; }
		done
	fi
	overlay_required=12288
	tmp_required=16384
	if [ "$install_space_needed" = 1 ]; then
		overlay_required=65536
		tmp_required=65536
	fi

	overlay_free="$(df -Pk /overlay 2>/dev/null | awk 'NR == 2 { print $4 }')"
	[ -n "$overlay_free" ] ||
		overlay_free="$(df -Pk / 2>/dev/null | awk 'NR == 2 { print $4 }')"
	case "${overlay_free:-0}" in *[!0-9]*) overlay_free=0 ;; esac
	if [ "$overlay_free" -ge "$overlay_required" ]; then
		printf 'storage_free=ok:%sKiB\n' "$overlay_free"
	else
		printf 'storage_free=low:%sKiB-required-%sKiB\n' \
			"$overlay_free" "$overlay_required"
		ok=0
		dependencies_ok=0
	fi

	tmp_free="$(df -Pk /tmp 2>/dev/null | awk 'NR == 2 { print $4 }')"
	case "${tmp_free:-0}" in *[!0-9]*) tmp_free=0 ;; esac
	if [ "$tmp_free" -ge "$tmp_required" ]; then
		printf 'tmp_free=ok:%sKiB\n' "$tmp_free"
	else
		printf 'tmp_free=low:%sKiB-required-%sKiB\n' \
			"$tmp_free" "$tmp_required"
		ok=0
		dependencies_ok=0
	fi

	mem_available="$(awk '/^MemAvailable:/ { print $2; exit }' /proc/meminfo 2>/dev/null)"
	case "${mem_available:-0}" in *[!0-9]*) mem_available=0 ;; esac
	if [ "$mem_available" -ge 32768 ]; then
		printf 'memory_available=ok:%sKiB\n' "$mem_available"
	else
		printf 'memory_available=low:%sKiB\n' "$mem_available"
		ok=0
		dependencies_ok=0
	fi

	year="$(date +%Y 2>/dev/null || echo 0)"
	case "$year" in *[!0-9]*) year=0 ;; esac
	if [ "$year" -ge 2024 ]; then
		printf 'system_clock=ok:%s\n' "$(date -Iseconds 2>/dev/null || date)"
	else
		printf 'system_clock=invalid:%s\n' "$year"
		ok=0
		dependencies_ok=0
	fi

	if grep -Eq '^Features[[:space:]]*:.*(^|[[:space:]])aes([[:space:]]|$)' \
		/proc/cpuinfo 2>/dev/null ||
		lsmod 2>/dev/null | grep -q '^crypto_safexcel '; then
		printf 'crypto_acceleration=ok:detected\n'
	else
		printf 'crypto_acceleration=notice:not-detected\n'
	fi

	flow_sw="$(uci -q get firewall.@defaults[0].flow_offloading 2>/dev/null || echo 0)"
	flow_hw="$(uci -q get firewall.@defaults[0].flow_offloading_hw 2>/dev/null || echo 0)"
	if [ "$flow_hw" = 1 ]; then
		printf 'flow_offloading=notice:hardware-enabled\n'
	elif [ "$flow_sw" = 1 ]; then
		printf 'flow_offloading=notice:software-enabled\n'
	else
		printf 'flow_offloading=ok:disabled\n'
	fi

	resource_conflicts=''
	if [ "$(getv globals configured)" != 1 ]; then
		uci -q get network.ikev2out >/dev/null 2>&1 &&
			resource_conflicts="${resource_conflicts}network.ikev2out,"
		uci show firewall 2>/dev/null | grep -q '^firewall\.ikev2pbr_' &&
			resource_conflicts="${resource_conflicts}firewall.ikev2pbr_*,"
		uci show pbr 2>/dev/null | grep -q '^pbr\.ikev2pbr_' &&
			resource_conflicts="${resource_conflicts}pbr.ikev2pbr_*,"
	fi
	if [ -n "$resource_conflicts" ]; then
		printf 'resource_conflict=%s\n' "${resource_conflicts%,}"
		ok=0
	else
		printf 'resource_conflict=none\n'
	fi
}

preflight() {
	ok=1
	dependencies_ok=1
	compatibility_checks
	printf 'preflight_ok=%s\n' "$ok"
	[ "$ok" -eq 1 ]
}

sing_box_fakeip_safe() {
	local version binary
	version="$(pkg_version sing-box)"
	binary="${IKEV2_SING_BOX_BINARY:-/usr/bin/sing-box}"
	pkg_version_at_least sing-box 1.13.1 && return 0
	[ "$version" = 1.12.17-r2 ] && [ -r "$binary" ] &&
		grep -aFq 'save FakeIP cache:' "$binary" 2>/dev/null
}

validate_runtime_config() {
	wan_interface="$(getv globals wan_interface)"
	wan_zone="$(getv globals wan_zone)"
	source_interfaces="$(get_list globals source_interface)"
	[ -n "$source_interfaces" ] || die 'At least one protected network is required'
	uci -q get "network.$wan_interface" >/dev/null 2>&1 ||
		die "WAN network '$wan_interface' does not exist"
	zone_exists "$wan_zone" ||
		die "WAN firewall zone '$wan_zone' does not exist"
	validate_server_zone_names \
		"$(defaultv server firewall_zone ikev2in)" \
		"$(defaultv server outbound_zone ikev2out)"

	for interface in $source_interfaces; do
		[ "$interface" != "$wan_interface" ] ||
			die "WAN network '$wan_interface' cannot be a protected network"
		uci -q get "network.$interface" >/dev/null 2>&1 ||
			die "Protected network '$interface' does not exist"
		network_device "$interface" >/dev/null ||
			die "Protected network '$interface' has no device"
		[ "$(zone_for_network "$interface")" != "$wan_zone" ] ||
			die "Protected network '$interface' belongs to the WAN firewall zone '$wan_zone'"
	done
	for zone in $(get_list globals source_zone); do
		zone_exists "$zone" ||
			die "Firewall zone '$zone' does not exist"
	done
	if [ "$(getv server enabled)" = 1 ] && [ "$(defaultv server allow_lan 1)" = 1 ]; then
		for zone in $(get_list server lan_zone); do
			zone_exists "$zone" ||
				die "Inbound LAN firewall zone '$zone' does not exist"
		done
	fi
	if [ "$(defaultv domains engine nftset)" = fakeip ]; then
		sing_box_fakeip_safe ||
			die 'Reliable mode requires sing-box 1.13.1 or the verified 1.12.17-r2 FakeIP backport'
	fi
}

doctor_dns_segments_status() {
	local segment_state
	segment_state="$(sed -n 's/^state=//p' "$dns_segments_status_file" 2>/dev/null |
		tail -n1)"
	case "$segment_state" in
		up | ok)
			printf 'dns_segments=ok\n'
			return 0
			;;
		degraded)
			printf 'dns_segments=degraded:%s\n' \
				"$(sed -n 's/^failure_ids=//p' "$dns_segments_status_file" | tail -n1)"
			return 1
			;;
		*)
			printf 'dns_segments=notice:not-checked-yet\n'
			return 0
			;;
	esac
}

doctor() {
	ok=1
	dependencies_ok=1
	check_command() {
		name="$1"
		command="$2"
		if command -v "$command" >/dev/null 2>&1; then
			printf '%s=ok\n' "$name"
		else
			printf '%s=missing\n' "$name"
			ok=0
			dependencies_ok=0
		fi
	}
	check_file() {
		name="$1"
		path="$2"
		if [ -e "$path" ]; then
			printf '%s=ok\n' "$name"
		else
			printf '%s=missing\n' "$name"
			ok=0
			dependencies_ok=0
		fi
	}

	compatibility_checks
	upnp_ikev2_check || ok=0

	check_command firewall4 fw4
	check_command ip_full ip
	check_command nft nft
	check_command swanctl swanctl
	check_command openssl openssl
	check_command jsonfilter jsonfilter
	check_command swanmon swanmon
	check_command dnsproxy dnsproxy
	check_command sing_box sing-box
	if command -v curl >/dev/null 2>&1 && curl --version >/dev/null 2>&1; then
		printf 'curl=ok\n'
	else
		printf 'curl=missing\n'
		ok=0
		dependencies_ok=0
	fi
	if find /lib/modules/"$(uname -r)" -name 'xfrm_interface.ko*' -print 2>/dev/null |
		grep -q .; then
		printf 'xfrm_module=ok\n'
	else
		printf 'xfrm_module=missing\n'
		ok=0
		dependencies_ok=0
	fi
	check_file pbr_service /etc/init.d/pbr
	if command -v fw4 >/dev/null 2>&1; then
		if firewall_check_strict; then
			printf 'firewall4_config=ok\n'
		else
			printf 'firewall4_config=invalid\n'
			ok=0
		fi
	fi
	if [ "$(getv globals configured)" = 1 ]; then
		if [ ! -x "$device_runtime_helper" ]; then
			printf 'device_policy_runtime=missing-helper\n'
			ok=0
		elif "$device_runtime_helper" check >/dev/null 2>&1; then
			printf 'device_policy_runtime=ok\n'
		elif [ "${IKEV2_DOCTOR_ALLOW_RUNTIME_REPAIR:-0}" = 1 ]; then
			printf 'device_policy_runtime=warn:repair-required\n'
		else
			printf 'device_policy_runtime=missing\n'
			ok=0
		fi
		if [ "$(defaultv dns managed 0)" = 1 ]; then
			if [ "${IKEV2_DOCTOR_SKIP_PROBES:-0}" = 1 ]; then
				if ! doctor_dns_segments_status; then
					ok=0
				fi
			elif dns_segments_check; then
				printf 'dns_segments=ok\n'
			else
				printf 'dns_segments=degraded:%s\n' \
					"$(sed -n 's/^failure_ids=//p' "$dns_segments_status_file" | tail -n1)"
				ok=0
			fi
		fi
	fi

	# The fail-closed apply sequence is coupled to PBR 1.2.x fw4 behavior.
	# Unknown or unsupported versions are a hard compatibility failure.
	pbr_version="$(pkg_version pbr)"
	case "$pbr_version" in
		1.2.*) printf 'pbr_version=ok:%s\n' "$pbr_version" ;;
		'') printf 'pbr_version=missing\n'; ok=0; dependencies_ok=0 ;;
		*) printf 'pbr_version=unsupported:%s\n' "$pbr_version"; ok=0; dependencies_ok=0 ;;
	esac
	sing_box_version="$(pkg_version sing-box)"
	sing_box_binary="${IKEV2_SING_BOX_BINARY:-/usr/bin/sing-box}"
	if pkg_version_at_least sing-box 1.13.1; then
		printf 'sing_box_fakeip=ok:%s-upstream-fix\n' "$sing_box_version"
	elif [ "$sing_box_version" = 1.12.17-r2 ] && [ -r "$sing_box_binary" ] &&
	   grep -aFq 'save FakeIP cache:' "$sing_box_binary" 2>/dev/null; then
		printf 'sing_box_fakeip=ok:%s-backport\n' "$sing_box_version"
	elif [ "$(defaultv domains engine nftset)" = fakeip ]; then
		printf 'sing_box_fakeip=invalid:%s-concurrent-allocation\n' \
			"${sing_box_version:-missing}"
		ok=0
	else
		printf 'sing_box_fakeip=notice:%s\n' "${sing_box_version:-missing}"
	fi
	strongswan_version="$(pkg_version strongswan)"
	if strongswan_cohort="$(strongswan_cohort_version 2>/dev/null)" &&
	   [ -n "$strongswan_cohort" ]; then
		printf 'strongswan_cohort=ok:%s\n' "$strongswan_cohort"
	else
		printf 'strongswan_cohort=invalid:mixed-or-missing-version\n'
		ok=0
		dependencies_ok=0
	fi
	if pkg_version_at_least strongswan 6.0.3; then
		printf 'strongswan_eap_client_security=ok:%s\n' "$strongswan_version"
	else
		printf 'strongswan_eap_client_security=warn:%s-cve-2025-62291\n' \
			"${strongswan_version:-missing}"
	fi
	if pkg_version_at_least strongswan 6.0.7; then
		printf 'strongswan_eap_server_security=ok:%s\n' "$strongswan_version"
	else
		printf 'strongswan_eap_server_security=notice:%s-cve-2026-47895\n' \
			"${strongswan_version:-missing}"
	fi
	if [ "$(getv globals configured)" = 1 ]; then
		if failclosed_check; then
			printf 'failclosed_route=ok\n'
		else
			# Report drift without blocking apply_system, which is the repair
			# path that recreates the PBR table and validates it afterwards.
			printf 'failclosed_route=warn:missing\n'
		fi
		if failclosed_ipv6_check; then
			printf 'failclosed_ipv6_route=ok\n'
		else
			printf 'failclosed_ipv6_route=warn:missing\n'
		fi
	fi

	# Reserved XFRM if_id 42 (ipsec-out) and 43 (ipsec-in). A foreign xfrm
	# interface holding either id collides with the ones this app creates.
	xfrm_conflict="$(
		ip -d link show type xfrm 2>/dev/null | awk '
			/^[0-9]+:/ { name = $2; sub(/@.*/, "", name); sub(/:$/, "", name); next }
			/if_id/ {
				for (i = 1; i <= NF; i++)
					if ($i == "if_id") id = $(i + 1)
				if (name != "ipsec-out" && name != "ipsec-in" &&
				    (id == "42" || id == "0x2a" || id == "43" || id == "0x2b"))
					print name ":" id
			}
		'
	)"
	if [ -n "$xfrm_conflict" ]; then
		printf 'xfrm_ifid_conflict=%s\n' "$(printf '%s' "$xfrm_conflict" | tr '\n' ',')"
		ok=0
	else
		printf 'xfrm_ifid_conflict=none\n'
	fi

	xfrm_name_conflicts=''
	for name_id in 'ipsec-out:42:0x2a' 'ipsec-in:43:0x2b'; do
		name="${name_id%%:*}"
		rest="${name_id#*:}"
		expected_dec="${rest%%:*}"
		expected_hex="${rest#*:}"
		link="$(ip -d link show dev "$name" 2>/dev/null || true)"
		[ -n "$link" ] || continue
		if ! printf '%s\n' "$link" | grep -q ' xfrm '; then
			xfrm_name_conflicts="${xfrm_name_conflicts}${name}:not-xfrm,"
			continue
		fi
		actual="$(printf '%s\n' "$link" |
			awk '/if_id/ { for (i=1; i<=NF; i++) if ($i=="if_id") { print $(i+1); exit } }')"
		[ "$actual" = "$expected_dec" ] || [ "$actual" = "$expected_hex" ] ||
			xfrm_name_conflicts="${xfrm_name_conflicts}${name}:${actual:-unknown},"
	done
	if [ -n "$xfrm_name_conflicts" ]; then
		printf 'xfrm_name_conflict=%s\n' "${xfrm_name_conflicts%,}"
		ok=0
	else
		printf 'xfrm_name_conflict=none\n'
	fi

	if pkg_dnsmasq_has_nftset; then
		printf 'dnsmasq_nftset=ok\n'
	else
		printf 'dnsmasq_nftset=missing\n'
		ok=0
		dependencies_ok=0
	fi
	if lsmod 2>/dev/null | grep -Eq '^(nft_tproxy|nf_tproxy_ipv4) '; then
		printf 'nft_tproxy=ok\n'
	else
		printf 'nft_tproxy=missing\n'
		ok=0
		dependencies_ok=0
	fi

	for plugin in kernel-netlink vici openssl eap-mschapv2 x509; do
		if find /usr/lib/ipsec/plugins -name "libstrongswan-${plugin}.so" -print 2>/dev/null |
			grep -q .; then
			printf 'strongswan_%s=ok\n' "$(sanitize "$plugin")"
		else
			printf 'strongswan_%s=missing\n' "$(sanitize "$plugin")"
			ok=0
			dependencies_ok=0
		fi
	done

	printf 'configured=%s\n' "$(getv globals configured)"
	printf 'dependencies_ok=%s\n' "$dependencies_ok"
	printf 'doctor_ok=%s\n' "$ok"
	[ "$ok" -eq 1 ]
}

strongswan_security_check() {
	case "$1" in
		client)
			pkg_version_at_least strongswan 6.0.3 ||
				die 'Installed strongSwan is vulnerable to CVE-2025-62291; upgrade strongSwan before enabling the outbound EAP client'
			;;
		# Inbound compatibility is advisory. The installed OpenWrt package may be
		# older than the upstream fix, but operators can deliberately keep the
		# EAP server enabled; doctor reports the version without changing runtime.
		server) return 0 ;;
		*) die 'Expected strongSwan security mode: client or server' ;;
	esac
}

runtime_packages() {
	cat <<'EOF'
pbr
dnsproxy
sing-box
strongswan
strongswan-charon
strongswan-swanctl
strongswan-mod-aes
strongswan-mod-attr
strongswan-mod-constraints
strongswan-mod-eap-identity
strongswan-mod-eap-mschapv2
strongswan-mod-gcm
strongswan-mod-gmp
strongswan-mod-hmac
strongswan-mod-kdf
strongswan-mod-kernel-netlink
strongswan-mod-md4
strongswan-mod-openssl
strongswan-mod-pem
strongswan-mod-pkcs1
strongswan-mod-pubkey
strongswan-mod-random
strongswan-mod-sha2
strongswan-mod-socket-default
strongswan-mod-vici
strongswan-mod-x509
kmod-xfrm-interface
kmod-nft-tproxy
kmod-nf-tproxy
ip-full
openssl-util
curl
libcurl4
conntrack
swanmon
acme
luci-app-acme
acme-acmesh-dnsapi
EOF
}

strongswan_cohort_version() {
	local package packages version cohort='' found=0 base=0
	packages="$(pkg_list_installed_names)" || return 1
	for package in $packages; do
		case "$package" in strongswan | strongswan-*) ;; *) continue ;; esac
		pkg_installed "$package" || continue
		found=1
		[ "$package" != strongswan ] || base=1
		version="$(pkg_version "$package")"
		[ -n "$version" ] || return 1
		if [ -z "$cohort" ]; then
			cohort="$version"
		elif [ "$version" != "$cohort" ]; then
			return 1
		fi
	done
	[ "$found" = 0 ] || [ "$base" = 1 ] || return 1
	printf '%s\n' "$cohort"
}

# Preserve an already installed strongSwan build as one versioned cohort.
# Adding a missing plugin must fail if that exact build is no longer present in
# the feed; it must never upgrade only the base library or an arbitrary subset.
runtime_install_arguments() {
	local package cohort
	cohort="$(strongswan_cohort_version)" || return 1
	for package in "$@"; do
		case "$package" in
			strongswan | strongswan-*)
				if [ -n "$cohort" ]; then
					case "$(pkg_manager_name)" in
						apk) printf '%s=%s\n' "$package" "$cohort" ;;
						# opkg has no reliable version constraint syntax. Do not pass
						# installed cohort members back to `opkg install`, and refuse
						# automatic repair if one of them is absent.
						opkg) pkg_installed "$package" || return 1 ;;
						*) return 1 ;;
					esac
				else
					printf '%s\n' "$package"
				fi
				;;
			*) printf '%s\n' "$package" ;;
		esac
	done
}

verify_install_plan() {
	package_names="$(runtime_packages | tr '\n' ' ')"
	packages="$(runtime_install_arguments $package_names | tr '\n' ' ')" || {
		deps_status error 'Installed strongSwan packages do not form one version cohort'
		return 1
	}
	plan_allow_dns=0
	pkg_installed dnsmasq-full || plan_allow_dns=1
	if ! PKG_PLAN_ALLOW_DNSMASQ_SWAP="$plan_allow_dns" \
		pkg_install_plan_safe dnsmasq-full $packages; then
		deps_status error 'Required packages do not match this firmware/kernel or are missing from configured feeds'
		return 1
	fi
}

cleanup_dnsmasq_transaction() {
	rm -rf /tmp/ikev2-manager-dns-packages
	rm -f /tmp/ikev2-manager-dhcp.before-deps
}

deps_status_file='/tmp/ikev2-manager-deps.status'
default_app_config="${IKEV2_DEFAULT_APP_CONFIG:-/usr/share/ikev2-manager/defaults/ikev2-manager}"
routing_check_helper="${IKEV2_ROUTING_CHECK_HELPER:-/usr/libexec/ikev2-domains-restart}"
action_status_file="${IKEV2_SYSTEM_ACTION_STATUS:-/var/run/ikev2-system-action.status}"
action_status_dir="${IKEV2_SYSTEM_ACTION_STATUS_DIR:-/var/run/ikev2-system-actions}"
action_lock_dir="${IKEV2_ACTION_LOCK:-/var/run/ikev2-action.lock}"
action_lock_status="${IKEV2_ACTION_LOCK_STATUS:-/var/run/ikev2-action.lock.status}"
runtime_lib_dir="${IKEV2_RUNTIME_LIB_DIR:-/usr/libexec/ikev2-manager.d}"

. "$runtime_lib_dir/actions.sh"
. "$runtime_lib_dir/package-manager.sh"
. "$runtime_lib_dir/dependency-state.sh"
. "$runtime_lib_dir/routing.sh"
. "$runtime_lib_dir/devices.sh"

deps_status() {
	status_tmp="${deps_status_file}.new.$$"
	{
		[ -z "${DEPS_ACTION_ID:-}" ] || printf 'action_id=%s\n' "$DEPS_ACTION_ID"
		printf 'state=%s\n' "$1"
		printf 'updated=%s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')"
		[ -z "${2:-}" ] || printf 'message=%s\n' "$2"
	} >"$status_tmp"
	mv "$status_tmp" "$deps_status_file"
}

rollback_dependency_install() {
	cleanup_dnsmasq_transaction
	deps_state_captured || return 1
	deps_state_restore || return 1
	deps_state_clear
}

# Heavy installer body. Runs detached (see install_deps) and reports progress
# through deps_status_file so the LuCI page can poll instead of blocking on a
# long XHR that would otherwise time out during package updates/installations.
run_install_deps() {
	DEPS_ACTION_ID="${1:-}"
	exec >>/tmp/ikev2-manager-deps.log 2>&1
	deps_status running 'Waiting for other router actions...'
	if ! acquire_action_lock dependencies "$DEPS_ACTION_ID"; then
		deps_status error 'Another router action is still running.'
		return 1
	fi
	trap 'rm -f "$action_lock_status"; rmdir "$action_lock_dir" 2>/dev/null || true' EXIT INT TERM
	[ -r /etc/openwrt_release ] || { deps_status error 'This command must run on OpenWrt'; exit 1; }
	. /etc/openwrt_release
	package_manager="$(pkg_manager_name)"
	case "${DISTRIB_RELEASE:-}:$package_manager" in
		24.10.*:opkg | 25.12.*:apk) ;;
		*)
			deps_status error "OpenWrt 24.10.x with opkg or 25.12.x with apk is required; found ${DISTRIB_RELEASE:-unknown} with $package_manager"
			exit 1
			;;
	esac
	if ! preflight >/tmp/ikev2-manager-preflight.last 2>&1; then
		deps_status error 'Compatibility preflight failed; run ikev2-manager-system preflight'
		exit 1
	fi
	if [ -e "$deps_state_dir" ] && [ "$(deps_state_version)" = 2 ]; then
		# Version 2 compared every future package against the original baseline and
		# could claim packages installed later by an administrator. Discard it and
		# establish a conservative version-3 baseline instead of deleting anything.
		deps_status running 'Resetting an unsafe legacy dependency ownership record...'
		deps_state_clear
	elif [ -e "$deps_state_dir" ] && ! deps_state_ready; then
		deps_status running 'Recovering an interrupted dependency installation...'
		if ! rollback_dependency_install; then
			deps_status error 'An interrupted installation could not be rolled back; see /tmp/ikev2-manager-deps.log'
			exit 1
		fi
	fi
	if deps_state_ready && [ "$(deps_state_version)" = 1 ] &&
	   ! deps_state_upgrade_v1; then
		deps_status error 'Legacy dependency ownership could not be upgraded safely'
		exit 1
	fi

	deps_status running 'Creating a recovery backup...'
	backup="/tmp/ikev2-manager-deps-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
	if ! sysupgrade -b "$backup"; then
		deps_status error 'Unable to create the pre-install sysupgrade backup'
		exit 1
	fi

	deps_status running 'Updating package lists...'
	if ! pkg_update; then
		deps_status error 'Package list update failed; check WAN and DNS connectivity'
		exit 1
	fi

	deps_status running 'Checking firmware, kernel ABI, storage and package availability...'
	if ! verify_install_plan; then
		exit 1
	fi
	packages="$(runtime_packages | tr '\n' ' ')"
	if deps_state_ready; then
		if ! pkg_installed dnsmasq-full || ! pkg_dnsmasq_has_nftset; then
			deps_status error 'Installed dependency state is inconsistent with dnsmasq; use Remove Dependencies before reinstalling'
			exit 1
		fi
		missing=''
		for package in $packages; do
			pkg_installed "$package" || missing="${missing}${missing:+ }$package"
		done
		if [ -n "$missing" ]; then
			deps_status running 'Repairing missing runtime packages...'
			install_args="$(runtime_install_arguments $missing | tr '\n' ' ')" || {
				deps_status error 'Installed strongSwan packages do not form one version cohort'
				exit 1
			}
			if ! pkg_install_plan_safe $install_args; then
				deps_status error 'Missing packages are unavailable without changing the installed runtime cohort'
				exit 1
			fi
			repair_snapshot="/tmp/ikev2-manager-repair-before.$$"
			if ! pkg_list_installed_names >"$repair_snapshot"; then
				deps_status error 'Unable to snapshot installed packages before dependency repair'
				exit 1
			fi
			if ! pkg_install $install_args; then
				pkg_remove_added_since "$repair_snapshot" >/dev/null 2>&1 || true
				rm -f "$repair_snapshot"
				deps_status error 'Dependency repair failed; the previous runtime packages were kept'
				exit 1
			fi
		fi
		doctor >/tmp/ikev2-manager-doctor.last 2>&1 || true
		if ! grep -q '^dependencies_ok=1' /tmp/ikev2-manager-doctor.last; then
			[ -z "$missing" ] || pkg_remove_added_since "$repair_snapshot" >/dev/null 2>&1 || true
			[ -z "${repair_snapshot:-}" ] || rm -f "$repair_snapshot"
			deps_status error 'Dependency repair failed package checks; the previous runtime packages were kept'
			exit 1
		fi
		if [ -n "$missing" ] && ! deps_state_record_added_since "$repair_snapshot"; then
			pkg_remove_added_since "$repair_snapshot" >/dev/null 2>&1 || true
			rm -f "$repair_snapshot"
			deps_status error 'Repaired package ownership could not be saved; newly added packages were removed'
			exit 1
		fi
		[ -z "${repair_snapshot:-}" ] || rm -f "$repair_snapshot"
		deps_status ok 'All runtime dependencies are installed and verified.'
		return 0
	fi

	cache="/tmp/ikev2-manager-dns-packages"
	dnsmasq_provider=''
	if ! pkg_installed dnsmasq-full; then
		dnsmasq_provider="$(pkg_dnsmasq_provider || true)"
		if [ -z "$dnsmasq_provider" ]; then
			deps_status error 'No supported dnsmasq provider is installed; dependency installation stopped'
			exit 1
		fi
		rm -rf "$cache"
		mkdir -p "$cache"
		if [ "$package_manager" = opkg ]; then
			deps_status running 'Downloading DNS rollback packages...'
			if ! (cd "$cache" && pkg_download "$dnsmasq_provider" dnsmasq-full); then
				deps_status error 'Unable to download dnsmasq packages before replacement'
				cleanup_dnsmasq_transaction
				exit 1
			fi
			full_pkg="$(pkg_package_file "$cache" dnsmasq-full)"
			previous_pkg="$(pkg_package_file "$cache" "$dnsmasq_provider")"
			if [ ! -s "$full_pkg" ] || [ ! -s "$previous_pkg" ]; then
				deps_status error 'DNS rollback packages were not downloaded'
				cleanup_dnsmasq_transaction
				exit 1
			fi
		fi
	fi

	if ! deps_state_capture; then
		deps_status error 'Unable to save the pre-install package and DNS state'
		cleanup_dnsmasq_transaction
		exit 1
	fi
	if [ "$package_manager" = opkg ] && [ -n "$dnsmasq_provider" ]; then
		previous_pkg="$(pkg_package_file "$cache" "$dnsmasq_provider")"
		if ! deps_state_store_dnsmasq_package "$previous_pkg"; then
			deps_state_clear
			deps_status error 'Unable to preserve the original dnsmasq package for rollback'
			cleanup_dnsmasq_transaction
			exit 1
		fi
	fi

	if [ -n "$dnsmasq_provider" ]; then
		deps_status running 'Replacing dnsmasq with dnsmasq-full...'
		dns_snapshot="/tmp/ikev2-manager-dns-before.$$"
		if ! pkg_list_installed_names >"$dns_snapshot"; then
			deps_status error 'Unable to snapshot packages before replacing dnsmasq'
			rollback_dependency_install || true
			exit 1
		fi
		if ! pkg_switch_dnsmasq_full "$cache" "$dnsmasq_provider"; then
			deps_state_record_added_since "$dns_snapshot" || true
			rm -f "$dns_snapshot"
			if rollback_dependency_install; then
				deps_status error 'dnsmasq-full installation failed; previous dnsmasq provider restored'
			else
				deps_status error 'dnsmasq-full installation failed and rollback failed; see /tmp/ikev2-manager-deps.log'
			fi
			exit 1
		fi
		if ! deps_state_record_added_since "$dns_snapshot"; then
			rm -f "$dns_snapshot"
			rollback_dependency_install || true
			deps_status error 'dnsmasq-full was installed but package ownership could not be saved; previous state restored'
			exit 1
		fi
		rm -f "$dns_snapshot"
		if ! cp "$(deps_state_file dhcp.before)" /etc/config/dhcp; then
			if rollback_dependency_install; then
				deps_status error 'Unable to restore DHCP configuration after dnsmasq replacement; previous state restored'
			else
				deps_status error 'DHCP configuration restore and automatic rollback failed; see /tmp/ikev2-manager-deps.log'
			fi
			exit 1
		fi
		rm -f /etc/config/dhcp.apk-new /etc/config/dhcp-opkg
		if ! pkg_installed dnsmasq-full || ! pkg_dnsmasq_has_nftset; then
			if rollback_dependency_install; then
				deps_status error 'dnsmasq-full verification failed; previous dnsmasq provider restored'
			else
				deps_status error 'dnsmasq-full verification failed and rollback failed; see /tmp/ikev2-manager-deps.log'
			fi
			exit 1
		fi
		if ! /etc/init.d/dnsmasq restart >/dev/null 2>&1; then
			rollback_dependency_install || true
			deps_status error 'dnsmasq-full was installed but DNS service did not restart; previous state restored'
			exit 1
		fi
		cleanup_dnsmasq_transaction
	fi

	deps_status running 'Installing strongSwan, PBR, sing-box and XFRM packages...'
	install_args="$(runtime_install_arguments $packages | tr '\n' ' ')" || {
		rollback_dependency_install || true
		deps_status error 'Installed strongSwan packages do not form one version cohort'
		exit 1
	}
	runtime_snapshot="/tmp/ikev2-manager-runtime-before.$$"
	if ! pkg_list_installed_names >"$runtime_snapshot"; then
		rollback_dependency_install || true
		deps_status error 'Unable to snapshot packages before runtime installation'
		exit 1
	fi
	if ! pkg_install $install_args; then
		deps_state_record_added_since "$runtime_snapshot" || true
		rm -f "$runtime_snapshot"
		if rollback_dependency_install; then
			deps_status error 'Package installation failed; the pre-install package and DNS state was restored'
		else
			deps_status error 'Package installation failed; automatic rollback also failed; see /tmp/ikev2-manager-deps.log'
		fi
		exit 1
	fi
	if ! deps_state_record_added_since "$runtime_snapshot"; then
		rm -f "$runtime_snapshot"
		if rollback_dependency_install; then
			deps_status error 'Installed package ownership could not be saved; the pre-install state was restored'
		else
			deps_status error 'Installed package ownership could not be saved and rollback failed; see /tmp/ikev2-manager-deps.log'
		fi
		exit 1
	fi
	rm -f "$runtime_snapshot"
	doctor >/tmp/ikev2-manager-doctor.last 2>&1 || true
	if ! grep -q '^dependencies_ok=1' /tmp/ikev2-manager-doctor.last; then
		if rollback_dependency_install; then
			deps_status error 'Installed packages failed dependency checks; the pre-install state was restored'
		else
			deps_status error 'Installed packages failed dependency checks and rollback failed; see /tmp/ikev2-manager-deps.log'
		fi
		exit 1
	fi
	if ! deps_state_mark_installed; then
		if rollback_dependency_install; then
			deps_status error 'Dependency ownership could not be saved; the pre-install state was restored'
		else
			deps_status error 'Dependency ownership could not be saved and rollback failed; see /tmp/ikev2-manager-deps.log'
		fi
		exit 1
	fi
	deps_status ok 'All runtime dependencies installed.'
}

install_deps() {
	DEPS_ACTION_ID="$(date +%s)-$$"
	deps_status running 'Starting dependency installation...'
	if command -v start-stop-daemon >/dev/null 2>&1; then
		if ! start-stop-daemon -b -q -S -x "$0" -- _install-deps-run "$DEPS_ACTION_ID"; then
			deps_status error 'Unable to start dependency installation'
			die 'Unable to start dependency installation'
		fi
	else
		setsid "$0" _install-deps-run "$DEPS_ACTION_ID" </dev/null >/dev/null 2>&1 &
	fi
	printf 'action_id=%s\n' "$DEPS_ACTION_ID"
}

# Restore only packages recorded as application-owned at installation time,
# together with the DNS provider and DHCP file present before installation.
run_remove_deps() {
	DEPS_ACTION_ID="${1:-}"
	exec >>/tmp/ikev2-manager-deps.log 2>&1
	deps_status running 'Waiting for other router actions...'
	if ! acquire_action_lock dependencies "$DEPS_ACTION_ID"; then
		deps_status error 'Another router action is still running.'
		return 1
	fi
	trap 'rm -f "$action_lock_status"; rmdir "$action_lock_dir" 2>/dev/null || true' EXIT INT TERM
	if ! deps_state_ready; then
		deps_status error 'Dependency ownership is unavailable; install dependencies once with this version before using Remove'
		return 1
	fi
	if [ "$(defaultv dns managed 0)" = 1 ] ||
	   { [ "$(defaultv dns saved 0)" = 1 ] && [ -d "$dns_original_dir" ]; }; then
		deps_status running 'Restoring the DNS configuration used before this application...'
		if ! "$0" _dns-apply-inner 0 '' '' '' '' '' ''; then
			deps_status error 'Original DNS could not be restored; dependency removal stopped before removing packages'
			return 1
		fi
	fi
	deps_status running 'Disabling managed configuration...'
	if ! disable_managed; then
		deps_status error 'Managed routing could not be disabled; dependency removal stopped before removing packages'
		return 1
	fi
	swanctl --terminate --ike proxy-out --timeout 3 >/dev/null 2>&1 || true
	swanctl --terminate --ike ikev2-in --timeout 3 >/dev/null 2>&1 || true
	swanctl --unload-conn proxy-out >/dev/null 2>&1 || true
	swanctl --unload-conn ikev2-in >/dev/null 2>&1 || true
	if [ -x /usr/libexec/ikev2-domain-router ]; then
		/usr/libexec/ikev2-domain-router deactivate >/dev/null 2>&1 || true
	fi
	if [ -x /etc/init.d/ikev2-xfrm ]; then
		/etc/init.d/ikev2-xfrm stop >/dev/null 2>&1 || {
			deps_status error 'XFRM interfaces could not be stopped; dependency removal stopped'
			return 1
		}
		/etc/init.d/ikev2-xfrm disable >/dev/null 2>&1 || {
			deps_status error 'XFRM service could not be disabled; dependency removal stopped'
			return 1
		}
	fi

	deps_status running 'Restoring the pre-install DNS and package state...'
	if ! deps_state_restore; then
		doctor >/tmp/ikev2-manager-doctor.last 2>&1 || true
		deps_status error 'Runtime dependency restore failed; see /tmp/ikev2-manager-deps.log'
		return 1
	fi
	retained_packages="$(printf '%s\n' "${deps_state_retained:-}" | tr '\n' ' ' | sed 's/ *$//')"
	[ -z "$retained_packages" ] ||
		printf 'Packages retained because other software requires them: %s\n' "$retained_packages"
	deps_status running 'Resetting application settings...'
	if ! reset_application_state; then
		deps_status error 'Dependencies were restored, but application settings could not be reset completely'
		return 1
	fi
	deps_state_clear
	doctor >/tmp/ikev2-manager-doctor.last 2>&1 || true
	if [ -n "$retained_packages" ]; then
		deps_status ok 'Router state restored. Shared packages required by other software were kept.'
	else
		deps_status ok 'Pre-install packages, settings and managed routing state were restored.'
	fi
}

reset_application_state() {
	[ -r "$default_app_config" ] || return 1
	config_tmp="${uci_config_dir}/${config}.new.$$"
	cp "$default_app_config" "$config_tmp" || return 1
	chmod 600 "$config_tmp" || { rm -f "$config_tmp"; return 1; }
	mv "$config_tmp" "${uci_config_dir}/${config}" || return 1

	# Site Link's exit role reuses both the certificate and its renewal job.
	if ! site_link_exit_active && uci -q get acme.ikev2 >/dev/null 2>&1; then
		uci -q delete acme.ikev2 || return 1
		uci commit acme || return 1
	fi

	rm -f /etc/ikev2-manager/client.secret /etc/ikev2-manager/users.db
	rm -f /etc/ikev2-manager/domain-router-cache.db
	rm -f /etc/ikev2-manager/domain-router-rules.json
	rm -f /etc/ikev2-manager/domain-router.json /etc/ikev2-manager/pbr-set4.dump
	rm -rf /etc/ikev2-manager/dns-original /etc/pbr-ikev2-community-cache
	rm -f /etc/swanctl/conf.d/20-proxy-out.conf
	rm -f /etc/swanctl/conf.d/30-inbound.conf
	rm -f /etc/swanctl/conf.d/90-proxy-out-secret.conf
	rm -f /etc/swanctl/conf.d/91-inbound-secrets.conf
	# The exit role of Site Link intentionally reuses this certificate contract.
	# Reset Manager's certificate only after the last applied consumer releases
	# it; otherwise removing Manager silently breaks the still-enabled responder.
	if ! site_link_exit_active; then
		rm -f /etc/swanctl/x509/ikev2.pem /etc/swanctl/private/ikev2.key
		rm -f /etc/swanctl/x509ca/ikev2-le-isrg-root-*.pem
		rm -f /etc/swanctl/x509ca/ikev2-server-chain-*.pem
	fi
	for file in /etc/pbr-ikev2-domains.txt \
		/etc/pbr-ikev2-domains.manual.txt \
		/etc/pbr-ikev2-addresses.manual.txt \
		/etc/pbr-ikev2-community-selected.txt; do
		: >"$file" || return 1
		chmod 600 "$file" || return 1
	done
}

remove_deps() {
	DEPS_ACTION_ID="$(date +%s)-$$"
	deps_status running 'Starting dependency removal...'
	if command -v start-stop-daemon >/dev/null 2>&1; then
		if ! start-stop-daemon -b -q -S -x "$0" -- _remove-deps-run "$DEPS_ACTION_ID"; then
			deps_status error 'Unable to start dependency removal'
			die 'Unable to start dependency removal'
		fi
	else
		setsid "$0" _remove-deps-run "$DEPS_ACTION_ID" </dev/null >/dev/null 2>&1 &
	fi
	printf 'action_id=%s\n' "$DEPS_ACTION_ID"
}

sync_network() {
	uci -q delete network.ikev2out || true
	uci set network.ikev2out=interface
	uci set network.ikev2out.proto='none'
	uci set network.ikev2out.device='ipsec-out'
	uci set network.ikev2out.auto='1'
	uci commit network
}

sync_firewall() {
	wan_zone="$(getv globals wan_zone)"
	server_enabled="$(getv server enabled)"
	[ "$server_enabled" = 1 ] || server_enabled=0
	inbound_zone="$(defaultv server firewall_zone ikev2in)"
	outbound_zone="$(defaultv server outbound_zone ikev2out)"
	source_zones="$(get_list globals source_zone)"
	validate_server_zone_names "$inbound_zone" "$outbound_zone"

	delete_prefixed_sections firewall ikev2pbr_

	uci set firewall.ikev2pbr_out=zone
	uci set "firewall.ikev2pbr_out.name=$outbound_zone"
	uci set firewall.ikev2pbr_out.device='ipsec-out'
	uci set firewall.ikev2pbr_out.input='REJECT'
	uci set firewall.ikev2pbr_out.output='ACCEPT'
	uci set firewall.ikev2pbr_out.forward='REJECT'
	uci set firewall.ikev2pbr_out.masq='1'
	uci set firewall.ikev2pbr_out.mtu_fix='1'

	uci set firewall.ikev2pbr_in=zone
	uci set "firewall.ikev2pbr_in.name=$inbound_zone"
	uci set firewall.ikev2pbr_in.device='ipsec-in'
	uci set firewall.ikev2pbr_in.input='REJECT'
	uci set firewall.ikev2pbr_in.output='ACCEPT'
	uci set firewall.ikev2pbr_in.forward='REJECT'
	uci set firewall.ikev2pbr_in.mtu_fix='1'

	for zone in $source_zones; do
		key="$(sanitize "$zone")"
		section="ikev2pbr_${key}_out"
		uci set "firewall.$section=forwarding"
		uci set "firewall.$section.src=$zone"
		uci set "firewall.$section.dest=$outbound_zone"

	done

	uci set firewall.ikev2pbr_server=rule
	uci set firewall.ikev2pbr_server.name='IKEv2 PBR inbound server'
	uci set "firewall.ikev2pbr_server.src=$wan_zone"
	uci set firewall.ikev2pbr_server.proto='udp'
	uci set firewall.ikev2pbr_server.dest_port='500 4500'
	uci set firewall.ikev2pbr_server.target='ACCEPT'
	uci set "firewall.ikev2pbr_server.enabled=$server_enabled"

	uci set firewall.ikev2pbr_server_esp=rule
	uci set firewall.ikev2pbr_server_esp.name='IKEv2 PBR inbound ESP'
	uci set "firewall.ikev2pbr_server_esp.src=$wan_zone"
	uci set firewall.ikev2pbr_server_esp.proto='esp'
	uci set firewall.ikev2pbr_server_esp.target='ACCEPT'
	uci set "firewall.ikev2pbr_server_esp.enabled=$server_enabled"

	uci set firewall.ikev2pbr_in_dns=rule
	uci set firewall.ikev2pbr_in_dns.name='IKEv2 PBR inbound DNS'
	uci set "firewall.ikev2pbr_in_dns.src=$inbound_zone"
	uci set firewall.ikev2pbr_in_dns.proto='tcp udp'
	uci set firewall.ikev2pbr_in_dns.dest_port='53'
	uci set firewall.ikev2pbr_in_dns.target='ACCEPT'
	uci set "firewall.ikev2pbr_in_dns.enabled=$server_enabled"

	uci commit firewall
	sync_inbound_access
}

sync_inbound_access() {
	server_enabled="$(getv server enabled)"
	[ "$server_enabled" = 1 ] || server_enabled=0
	inbound_zone="$(defaultv server firewall_zone ikev2in)"
	outbound_zone="$(defaultv server outbound_zone ikev2out)"
	wan_zone="$(getv globals wan_zone)"
	[ -n "$wan_zone" ] || wan_zone='wan'
	allow_internet="$(defaultv server allow_internet 1)"
	allow_lan="$(defaultv server allow_lan 1)"
	allow_router="$(defaultv server allow_router 0)"
	router_ports="$(normalize_list "$(getv server router_ports)")"
	public_ports=''
	effective_internet="$allow_internet"
	effective_lan="$allow_lan"
	effective_router="$allow_router"
	for policy in $(uci show "$config" 2>/dev/null |
		sed -n "s/^${config}\.\([^.=]*\)=user_policy$/\1/p"); do
		[ -n "$(uci -q get "$config.$policy.username" 2>/dev/null || true)" ] || continue
		policy_public_ports="$(normalize_list \
			"$(uci -q get "$config.$policy.public_ports" 2>/dev/null || true)")"
		valid_port_list "$policy_public_ports" ||
			die "Invalid public router ports in VPN user policy '$policy'"
		for port in $policy_public_ports; do
			case " $public_ports " in
				*" $port "*) ;;
				*) public_ports="${public_ports:+$public_ports }$port" ;;
			esac
		done
		[ "$(uci -q get "$config.$policy.internet_access" 2>/dev/null || true)" = allow ] &&
			effective_internet=1
		case "$(uci -q get "$config.$policy.lan_access" 2>/dev/null || true)" in
			all | limited) effective_lan=1 ;;
		esac
		[ "$(uci -q get "$config.$policy.router_access" 2>/dev/null || true)" = allow ] &&
			effective_router=1
	done

	delete_prefixed_sections firewall ikev2access_
	if [ "$server_enabled" != 1 ]; then
		uci commit firewall
		return 0
	fi

	if [ "$effective_internet" = 1 ]; then
		uci set firewall.ikev2access_in_wan=forwarding
		uci set "firewall.ikev2access_in_wan.src=$inbound_zone"
		uci set "firewall.ikev2access_in_wan.dest=$wan_zone"

		if zone_exists "$outbound_zone"; then
			uci set firewall.ikev2access_in_out=forwarding
			uci set "firewall.ikev2access_in_out.src=$inbound_zone"
			uci set "firewall.ikev2access_in_out.dest=$outbound_zone"
		fi
	fi

	if [ "$effective_lan" = 1 ]; then
		for zone in $(get_list server lan_zone); do
			key="$(sanitize "$zone")"
			section="ikev2access_in_${key}"
			uci set "firewall.$section=forwarding"
			uci set "firewall.$section.src=$inbound_zone"
			uci set "firewall.$section.dest=$zone"
		done
	fi

	if [ "$effective_router" = 1 ]; then
		uci set firewall.ikev2access_router=rule
		uci set firewall.ikev2access_router.name='IKEv2 inbound access to router'
		uci set "firewall.ikev2access_router.src=$inbound_zone"
		uci set firewall.ikev2access_router.target='ACCEPT'
		if [ -n "$router_ports" ]; then
			uci set firewall.ikev2access_router.proto='tcp udp'
			uci set "firewall.ikev2access_router.dest_port=$router_ports"
		else
			uci set firewall.ikev2access_router.proto='all'
		fi
	fi

	if [ -n "$public_ports" ]; then
		uci set firewall.ikev2access_public=rule
		uci set firewall.ikev2access_public.name='IKEv2 inbound selected router services'
		uci set "firewall.ikev2access_public.src=$inbound_zone"
		uci set firewall.ikev2access_public.proto='tcp udp'
		uci set "firewall.ikev2access_public.dest_port=$public_ports"
		uci set firewall.ikev2access_public.target='ACCEPT'
	fi

	uci commit firewall
}

sync_inbound_user_policy() {
	[ -x "$user_policy_helper" ] || return 0
	policy_active=0
	if [ "$(getv globals configured)" = 1 ] &&
	   [ "$(getv server enabled)" = 1 ] &&
	   [ "$(defaultv server custom_config 0)" != 1 ]; then
		policy_active=1
	fi
	if [ "$policy_active" != 1 ]; then
		if [ -x "$user_policy_init" ]; then
			if "$user_policy_init" running >/dev/null 2>&1; then
				"$user_policy_init" stop >/dev/null 2>&1 || return 1
			fi
			"$user_policy_init" disable >/dev/null 2>&1 || return 1
		fi
		"$user_policy_helper" stop >/dev/null 2>&1
		return $?
	fi
	if [ "$(defaultv domains engine nftset)" = fakeip ] &&
	   [ -x "$domain_router_helper" ]; then
		"$domain_router_helper" ensure >/dev/null 2>&1 || return 1
	fi
	# Install the fail-closed table before starting the event watcher. Starting
	# first would race its initial sync against this one on the same nft table.
	"$user_policy_helper" sync >/dev/null || return 1
	if [ -x "$user_policy_init" ]; then
		"$user_policy_init" enable >/dev/null 2>&1 || return 1
		"$user_policy_init" running >/dev/null 2>&1 ||
			"$user_policy_init" start >/dev/null 2>&1 || return 1
	fi
}

sync_pbr() {
	domain_file='/etc/pbr-ikev2-domains.txt'
	service_cidr_file='/etc/pbr-ikev2-service-cidrs.txt'
	manual_file='/etc/pbr-ikev2-domains.manual.txt'
	source_interfaces="$(get_list globals source_interface)"
	src=''
	for interface in $source_interfaces; do
		device="$(network_device "$interface" || true)"
		[ -n "$device" ] || die "Unable to resolve network device for '$interface'"
		src="${src:+$src }@$device"
	done
	# Inbound VPN-server clients (ipsec-in) follow the domain policy like local
	# networks only when both the server is enabled and the "VPN server" network
	# is selected in Network Integration (globals.source_include_vpn, default on).
	if [ "$(getv server enabled)" = 1 ] &&
		[ "$(defaultv globals source_include_vpn 1)" = 1 ]; then
		src="${src:+$src }@ipsec-in"
	fi
	# Per-device settings live in the application's own sections. Importing the
	# previous representation here means an upgraded package converts on its
	# first apply, without a separate migration step the operator has to run.
	if ! device_schema_ready; then
		device_migrate || die 'Unable to import device routing policies'
		uci commit "$config" || die 'Unable to save device routing policies'
	fi
	device_sources="$(device_addresses domain)" ||
		die 'Device routing configuration is not valid'
	for device_source in $device_sources; do
		case " $src " in
			*" $device_source "*) ;;
			*) src="${src:+$src }$device_source" ;;
		esac
	done

	# Snapshot the user's original pbr.config once, so disabling managed mode can
	# restore it. Enabling PBR globally and not reverting it broke routers where
	# PBR was intentionally disabled.
	if [ "$(uci -q get "$config.globals.pbr_saved" 2>/dev/null)" != 1 ]; then
		uci set "$config.globals.pbr_prev_enabled=$(uci -q get pbr.config.enabled 2>/dev/null || echo 0)"
		uci set "$config.globals.pbr_prev_ipv6=$(uci -q get pbr.config.ipv6_enabled 2>/dev/null || echo 0)"
		uci set "$config.globals.pbr_prev_resolver=$(uci -q get pbr.config.resolver_set 2>/dev/null || true)"
		uci set "$config.globals.pbr_prev_strict=$(uci -q get pbr.config.strict_enforcement 2>/dev/null || true)"
		uci set "$config.globals.pbr_saved=1"
		uci commit "$config"
	fi
	uci set pbr.config.enabled='1'
	# The IKEv2 tunnel is IPv4-only. Enabling IPv6 processing makes PBR create
	# an unreachable IPv6 route for this interface, so selected AAAA destinations
	# fail closed and clients fall back to IPv4 through the tunnel.
	uci set pbr.config.ipv6_enabled='1'
	uci set pbr.config.resolver_set='dnsmasq.nftset'
	uci set pbr.config.strict_enforcement='1'
	add_list_unique pbr config supported_interface ikev2out

	# PBR 1.2.x reads file:// policies through curl. Keep the active merged
	# file present before PBR starts, and avoid enabling an empty domain policy.
	if [ ! -s "$domain_file" ]; then
		if [ -x /usr/libexec/ikev2-domains-community ]; then
			IKEV2_ACTION_LOCK_HELD=1 \
				/usr/libexec/ikev2-domains-community apply >/dev/null 2>&1 || true
		fi
		if [ ! -s "$domain_file" ] && [ -s "$manual_file" ]; then
			cp "$manual_file" "${domain_file}.tmp"
			chmod 600 "${domain_file}.tmp"
			mv "${domain_file}.tmp" "$domain_file"
		fi
	fi

	uci -q delete pbr.ikev2pbr_domains || true
	uci set pbr.ikev2pbr_domains=policy
	uci set pbr.ikev2pbr_domains.name='IKEv2 PBR domains'
	uci set pbr.ikev2pbr_domains.interface='ikev2out'
	uci set "pbr.ikev2pbr_domains.src_addr=$src"
	uci set pbr.ikev2pbr_domains.dest_addr='file:///etc/pbr-ikev2-domains.txt'
	uci set pbr.ikev2pbr_domains.proto='all'
	if domain_file_has_entries "$domain_file"; then
		uci set pbr.ikev2pbr_domains.enabled='1'
	else
		uci set pbr.ikev2pbr_domains.enabled='0'
	fi

	uci -q delete pbr.ikev2pbr_service_cidrs || true
	uci set pbr.ikev2pbr_service_cidrs=policy
	uci set pbr.ikev2pbr_service_cidrs.name='IKEv2 PBR service networks'
	uci set pbr.ikev2pbr_service_cidrs.interface='ikev2out'
	uci set "pbr.ikev2pbr_service_cidrs.src_addr=$src"
	uci set pbr.ikev2pbr_service_cidrs.dest_addr='file:///etc/pbr-ikev2-service-cidrs.txt'
	uci set pbr.ikev2pbr_service_cidrs.proto='all'
	if domain_file_has_entries "$service_cidr_file"; then
		uci set pbr.ikev2pbr_service_cidrs.enabled='1'
	else
		uci set pbr.ikev2pbr_service_cidrs.enabled='0'
	fi

	uci -q delete pbr.ikev2pbr_include || true
	uci set pbr.ikev2pbr_include=include
	uci set pbr.ikev2pbr_include.path='/usr/share/pbr/pbr.user.ikev2out'
	uci set pbr.ikev2pbr_include.enabled='1'

	# Device overrides live in the independent early nftables table. Remove the
	# legacy duplicate PBR sections so they cannot lengthen global rebuilds.
	device_pbr_render ikev2pbr_domains \
		'file:///etc/pbr-ikev2-domains.txt file:///etc/pbr-ikev2-service-cidrs.txt' ||
		die 'Unable to remove legacy per-device PBR policies'
	uci commit pbr
}

dns_original_dir='/etc/ikev2-manager/dns-original'
ensure_dns_section() {
	uci -q get "$config.dns" >/dev/null 2>&1 && return 0
	uci set "$config.dns=dns"
	uci set "$config.dns.managed=0"
	uci set "$config.dns.protocol=doh"
	uci set "$config.dns.provider=cloudflare"
	uci set "$config.dns.upstream_mode=load_balance"
	uci set "$config.dns.upstream=https://dns.cloudflare.com/dns-query"
	uci set "$config.dns.bootstrap=1.1.1.1:53 1.0.0.1:53"
	uci set "$config.dns.fallback="
	uci set "$config.dns.timeout=4s"
	uci commit "$config"
}

dns_runtime_timeout() {
	# dnsproxy applies the timeout once to the primary group and again to the
	# fallback group.  Keep their combined budget below sing-box's 10-second
	# DNS deadline in Reliable mode, and avoid making Standard-mode clients wait
	# twenty seconds when a configured primary resolver becomes unreachable.
	local fallback="$1" value seconds limit
	value="$(defaultv dns timeout 4s)"
	case "$value" in
		*[!0-9s]* | *s*s | s | '') seconds=4 ;;
		*s) seconds="${value%s}" ;;
		*) seconds="$value" ;;
	esac
	case "$seconds" in '' | *[!0-9]*) seconds=4 ;; esac
	[ "$seconds" -ge 1 ] 2>/dev/null || seconds=4
	limit=8
	[ -z "$fallback" ] || limit=4
	[ "$seconds" -le "$limit" ] || seconds="$limit"
	printf '%ss\n' "$seconds"
}

dns_protocol_for_upstream() {
	case "$1" in
		udp://*) printf 'udp\n' ;;
		tcp://*) printf 'tcp\n' ;;
		tls://*) printf 'dot\n' ;;
		https://*) printf 'doh\n' ;;
		h3://*) printf 'h3\n' ;;
		quic://*) printf 'doq\n' ;;
		sdns://*) printf 'dnscrypt\n' ;;
		*) printf 'unknown\n' ;;
	esac
}

valid_dns_ipv4() {
	printf '%s\n' "$1" | awk -F. '
		NF != 4 { exit 1 }
		{
			for (i = 1; i <= 4; i++)
				if ($i !~ /^[0-9]+$/ || $i < 0 || $i > 255)
					exit 1
		}
	'
}

valid_dns_hostname() {
	awk -v value="$1" 'BEGIN {
		if (value == "" || length(value) > 253 || value !~ /^[A-Za-z0-9.-]+$/ ||
		    value ~ /^[0-9.]+$/)
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

valid_dns_authority() {
	authority="$1"
	case "$authority" in
		'' | *'/'* | *'?'* | *'#'* | *'@'* | *'['* | *']'*) return 1 ;;
	esac
	case "$authority" in
		*:*)
			host="${authority%:*}"
			port="${authority##*:}"
			[ "$host" = "${host%:*}" ] || return 1
			printf '%s' "$port" | grep -Eq '^[0-9]+$' || return 1
			[ "$port" -ge 1 ] && [ "$port" -le 65535 ] || return 1
			;;
		*) host="$authority" ;;
	esac
	valid_dns_ipv4 "$host" || valid_dns_hostname "$host"
}

valid_dns_endpoint() {
	protocol="$1"
	endpoint="$2"
	[ -n "$endpoint" ] && [ "${#endpoint}" -le 2048 ] || return 1
	case "$protocol" in
		udp) prefix='udp://' ;;
		tcp) prefix='tcp://' ;;
		dot) prefix='tls://' ;;
		doh | doh3) prefix='https://' ;;
		h3) prefix='h3://' ;;
		doq) prefix='quic://' ;;
		dnscrypt)
			case "$endpoint" in sdns://*) stamp="${endpoint#sdns://}" ;; *) return 1 ;; esac
			[ "${#stamp}" -ge 8 ] &&
				printf '%s' "$stamp" | grep -Eq '^[A-Za-z0-9_-]+$'
			return
			;;
		*) return 1 ;;
	esac
	case "$endpoint" in "$prefix"*) remainder="${endpoint#"$prefix"}" ;; *) return 1 ;; esac
	case "$protocol" in
		doh | doh3 | h3)
			case "$remainder" in */*) authority="${remainder%%/*}"; path="/${remainder#*/}" ;; *) return 1 ;; esac
			valid_dns_authority "$authority" || return 1
			[ "$path" != / ] &&
				printf '%s' "$path" | grep -Eq '^/[A-Za-z0-9._~:/?%+=,&;@-]+$'
			;;
		*)
			valid_dns_authority "$remainder"
			;;
	esac
}

valid_dns_endpoint_list() {
	protocol="$1"
	value="$(normalize_list "$2")"
	[ -n "$value" ] || return 1
	for endpoint in $value; do
		valid_dns_endpoint "$protocol" "$endpoint" || return 1
	done
}

valid_dns_endpoint_any() {
	endpoint="$1"
	protocol="$(dns_protocol_for_upstream "$endpoint")"
	[ "$protocol" != unknown ] && valid_dns_endpoint "$protocol" "$endpoint"
}

valid_dns_endpoint_list_any() {
	value="$(normalize_list "$1")"
	[ -n "$value" ] || return 1
	for endpoint in $value; do
		valid_dns_endpoint_any "$endpoint" || return 1
	done
}

valid_dns_bootstrap_list() {
	value="$(normalize_list "$1")"
	[ -n "$value" ] || return 1
	for endpoint in $value; do
		printf '%s\n' "$endpoint" | awk -F: '
			NF != 2 || $2 !~ /^[0-9]+$/ || $2 < 1 || $2 > 65535 { exit 1 }
			{
				split($1, octet, ".")
				if (length(octet) != 4) exit 1
				for (i = 1; i <= 4; i++)
					if (octet[i] !~ /^[0-9]+$/ || octet[i] < 0 || octet[i] > 255)
						exit 1
			}
		' || return 1
	done
}

dns_segment_sections() {
	uci show "$config" 2>/dev/null |
		sed -n "s/^${config}\.\([^.=]*\)=dns_segment\$/\1/p"
}

valid_dns_suffix_list() {
	value="$(normalize_list "$1")"
	[ -n "$value" ] || return 1
	count=0
	for suffix in $value; do
		count=$((count + 1))
		[ "$count" -le 256 ] || return 1
		case "$suffix" in .*) suffix="${suffix#.}" ;; esac
		valid_dns_hostname "$suffix" || return 1
	done
}

normalize_dns_suffix_list() {
	# BusyBox tr does not consistently expand POSIX character classes here and
	# can translate the letters in "ru" to "rl". DNS suffixes are validated as
	# ASCII hostnames, so an explicit ASCII range is both sufficient and stable.
	value="$(normalize_list "$1" | tr 'A-Z' 'a-z')"
	normalized=''
	for suffix in $value; do
		case "$suffix" in .*) suffix="${suffix#.}" ;; esac
		normalized="${normalized:+$normalized }$suffix"
	done
	printf '%s\n' "$normalized"
}

dns_suffixes_overlap() {
	left="${1#.}"
	right="${2#.}"
	[ "$left" = "$right" ] && return 0
	case "$left" in *."$right") return 0 ;; esac
	case "$right" in *."$left") return 0 ;; esac
	return 1
}

validate_dns_segments() {
	local section enabled protocol mode domains upstream bootstrap fallback port suffix existing https_compat
	local ports='' suffixes='' enabled_count=0
	for section in $(dns_segment_sections); do
		enabled="$(defaultv "$section" enabled 1)"
		[ "$enabled" = 0 ] || [ "$enabled" = 1 ] || return 1
		[ "$enabled" = 1 ] || continue
		https_compat="$(defaultv "$section" https_compat 1)"
		[ "$https_compat" = 0 ] || [ "$https_compat" = 1 ] || return 1
		enabled_count=$((enabled_count + 1))
		[ "$enabled_count" -le 8 ] || return 1
		protocol="$(getv "$section" protocol)"
		mode="$(defaultv "$section" upstream_mode load_balance)"
		domains="$(getv "$section" domains)"
		upstream="$(getv "$section" upstream)"
		bootstrap="$(getv "$section" bootstrap)"
		fallback="$(getv "$section" fallback)"
		port="$(getv "$section" port)"
		case "$mode" in load_balance | parallel | fastest_addr) ;; *) return 1 ;; esac
		case "$port" in '' | *[!0-9]*) return 1 ;; esac
		[ "$port" -ge 5550 ] && [ "$port" -le 5599 ] || return 1
		case " $ports " in *" $port "*) return 1 ;; esac
		ports="${ports:+$ports }$port"
		valid_dns_suffix_list "$domains" || return 1
		for suffix in $(normalize_dns_suffix_list "$domains"); do
			for existing in $suffixes; do
				dns_suffixes_overlap "$suffix" "$existing" && return 1
			done
			suffixes="${suffixes:+$suffixes }$suffix"
		done
		valid_dns_endpoint_list "$protocol" "$upstream" || return 1
		valid_dns_bootstrap_list "$bootstrap" || return 1
		[ -z "$fallback" ] || valid_dns_endpoint_list_any "$fallback" || return 1
	done
}

dns_combined_upstreams() {
	local base="$1"
	printf '%s\n' "$base"
	# Destination segments never sit behind this resolver. Reliable mode sends
	# them directly from sing-box; Standard mode lets dnsmasq select the worker.
	# Keeping this helper makes upgrades overwrite legacy dnsproxy decorations.
}

dnsmasq_combined_servers() {
	local base="$1" section enabled domains port suffix decorated=''
	printf '%s\n' "$base"
	for section in $(dns_segment_sections); do
		enabled="$(defaultv "$section" enabled 1)"
		[ "$enabled" = 1 ] || continue
		domains="$(normalize_list "$(getv "$section" domains)")"
		port="$(getv "$section" port)"
		decorated=''
		for suffix in $domains; do
			suffix="${suffix#.}"
			decorated="$decorated/$suffix"
		done
		printf '%s/127.0.0.1#%s\n' "$decorated" "$port"
	done
}

set_uci_list() {
	package="$1"
	section="$2"
	option="$3"
	value="$(normalize_list "$4")"
	uci -q delete "$package.$section.$option" || true
	for item in $value; do
		uci add_list "$package.$section.$option=$item"
	done
}

dns_service_state() {
	{
		if /etc/init.d/dnsproxy enabled 2>/dev/null; then
			printf 'enabled=1\n'
		else
			printf 'enabled=0\n'
		fi
		if /etc/init.d/dnsproxy running 2>/dev/null; then
			printf 'running=1\n'
		else
			printf 'running=0\n'
		fi
		if /etc/init.d/ikev2-dns-segments enabled 2>/dev/null; then
			printf 'segments_enabled=1\n'
		else
			printf 'segments_enabled=0\n'
		fi
		if /etc/init.d/ikev2-dns-segments running 2>/dev/null; then
			printf 'segments_running=1\n'
		else
			printf 'segments_running=0\n'
		fi
	}
}

restore_dns_segment_service_state() {
	local state="$1" enabled running
	[ -x /etc/init.d/ikev2-dns-segments ] || return 0
	enabled="$(sed -n 's/^segments_enabled=//p' "$state" 2>/dev/null | tail -1)"
	running="$(sed -n 's/^segments_running=//p' "$state" 2>/dev/null | tail -1)"
	case "$enabled:$running" in
		1:1)
			/etc/init.d/ikev2-dns-segments enable >/dev/null 2>&1 &&
				/etc/init.d/ikev2-dns-segments restart >/dev/null 2>&1
			;;
		1:0)
			/etc/init.d/ikev2-dns-segments enable >/dev/null 2>&1 &&
				/etc/init.d/ikev2-dns-segments stop >/dev/null 2>&1
			;;
		0:1)
			# Running and enabled are independent procd states. Preserve a
			# deliberately one-shot service instead of declaring DNS rollback
			# incomplete merely because it is not registered for autostart.
			/etc/init.d/ikev2-dns-segments disable >/dev/null 2>&1 &&
				/etc/init.d/ikev2-dns-segments restart >/dev/null 2>&1
			;;
		0:0)
			/etc/init.d/ikev2-dns-segments stop >/dev/null 2>&1 &&
				/etc/init.d/ikev2-dns-segments disable >/dev/null 2>&1
			;;
		*) return 1 ;;
	esac
}

save_dns_state() {
	local dir="$1" tmp package source
	tmp="${dir}.new.$$"
	rm -rf "$tmp"
	mkdir -p "${dir%/*}" "$tmp" || return 1
	for package in dnsproxy dhcp; do
		source="$uci_config_dir/$package"
		if [ -f "$source" ]; then
			cp "$source" "$tmp/$package.config" || { rm -rf "$tmp"; return 1; }
		else
			: >"$tmp/$package.absent"
		fi
	done
	dns_service_state >"$tmp/service.state" || { rm -rf "$tmp"; return 1; }
	rm -rf "$dir"
	mv "$tmp" "$dir"
}

repair_dns_original_snapshot() {
	local dir="$dns_original_dir" work servers server uses_fakeip
	local restored_servers restored_noresolv restored_cachesize
	local saved_running listen_addr listen_port destination
	[ -f "$dir/dhcp.config" ] || return 0

	work="${dir}.repair.$$"
	rm -rf "$work"
	mkdir -p "$work" || return 1
	cp "$dir/dhcp.config" "$work/dhcp" || { rm -rf "$work"; return 1; }
	servers="$("$uci_binary" -c "$work" -q get 'dhcp.@dnsmasq[0].server' 2>/dev/null || true)"
	uses_fakeip=0
	for server in $servers; do
		case "$server" in
			127.0.0.42 | 127.0.0.42#53) uses_fakeip=1 ;;
		esac
	done
	if [ "$uses_fakeip" = 0 ]; then
		rm -rf "$work"
		return 0
	fi

	if [ "$(defaultv domains dns_saved 0)" = 1 ]; then
		restored_servers="$(get_list domains prev_server)"
		restored_noresolv="$(defaultv domains prev_noresolv 0)"
		restored_cachesize="$(defaultv domains prev_cachesize 150)"
	else
		saved_running="$(sed -n 's/^running=//p' "$dir/service.state" 2>/dev/null | tail -1)"
		[ "$saved_running" = 1 ] && [ -f "$dir/dnsproxy.config" ] || {
			rm -rf "$work"
			return 1
		}
		cp "$dir/dnsproxy.config" "$work/dnsproxy" || { rm -rf "$work"; return 1; }
		listen_addr="$("$uci_binary" -c "$work" -q get dnsproxy.global.listen_addr 2>/dev/null || true)"
		listen_port="$("$uci_binary" -c "$work" -q get dnsproxy.global.listen_port 2>/dev/null || true)"
		set -- $listen_addr
		[ "$#" -eq 1 ] && [ "$1" = 127.0.0.1 ] || { rm -rf "$work"; return 1; }
		set -- $listen_port
		[ "$#" -eq 1 ] || { rm -rf "$work"; return 1; }
		case "$1" in
			'' | *[!0-9]*) rm -rf "$work"; return 1 ;;
		esac
		[ "$1" -ge 1 ] && [ "$1" -le 65535 ] || { rm -rf "$work"; return 1; }
		restored_servers="127.0.0.1#$1"
		restored_noresolv=1
		restored_cachesize="$(uci -q get 'dhcp.@dnsmasq[0].cachesize' 2>/dev/null || true)"
		case "$restored_cachesize" in
			'' | *[!0-9]*) restored_cachesize=150 ;;
		esac
	fi

	case "$restored_noresolv" in 0 | 1) ;; *) rm -rf "$work"; return 1 ;; esac
	case "$restored_cachesize" in '' | *[!0-9]*) rm -rf "$work"; return 1 ;; esac
	"$uci_binary" -c "$work" -q delete 'dhcp.@dnsmasq[0].server' || true
	for server in $restored_servers; do
		"$uci_binary" -c "$work" add_list "dhcp.@dnsmasq[0].server=$server" || {
			rm -rf "$work"
			return 1
		}
	done
	"$uci_binary" -c "$work" set "dhcp.@dnsmasq[0].noresolv=$restored_noresolv" || {
		rm -rf "$work"
		return 1
	}
	"$uci_binary" -c "$work" set "dhcp.@dnsmasq[0].cachesize=$restored_cachesize" || {
		rm -rf "$work"
		return 1
	}
	"$uci_binary" -c "$work" commit dhcp || { rm -rf "$work"; return 1; }
	destination="$dir/dhcp.config.repair.$$"
	cp "$work/dhcp" "$destination" || { rm -rf "$work"; return 1; }
	chmod 600 "$destination" || { rm -f "$destination"; rm -rf "$work"; return 1; }
	mv "$destination" "$dir/dhcp.config" || { rm -f "$destination"; rm -rf "$work"; return 1; }
	rm -rf "$work"
}

restore_dns_state() {
	local dir="$1" restart_dnsmasq="${2:-1}" package destination enabled running
	[ -d "$dir" ] || return 0
	for package in dnsproxy dhcp; do
		destination="$uci_config_dir/$package"
		uci -q revert "$package" >/dev/null 2>&1 || true
		if [ -f "$dir/$package.config" ]; then
			cp "$dir/$package.config" "${destination}.restore.$$" || return 1
			mv "${destination}.restore.$$" "$destination" || return 1
		elif [ -f "$dir/$package.absent" ]; then
			rm -f "$destination"
		elif [ -s "$dir/$package.uci" ]; then
			uci import "$package" <"$dir/$package.uci" || return 1
			uci commit "$package" || return 1
		else
			return 1
		fi
	done
	enabled="$(sed -n 's/^enabled=//p' "$dir/service.state" 2>/dev/null | tail -1)"
	running="$(sed -n 's/^running=//p' "$dir/service.state" 2>/dev/null | tail -1)"
	if [ "$enabled" = 1 ]; then
		/etc/init.d/dnsproxy enable >/dev/null 2>&1 || return 1
	else
		/etc/init.d/dnsproxy disable >/dev/null 2>&1 || return 1
	fi
	if [ "$running" = 1 ]; then
		/etc/init.d/dnsproxy restart >/dev/null 2>&1 || return 1
	else
		/etc/init.d/dnsproxy stop >/dev/null 2>&1 || return 1
	fi
	if [ "$restart_dnsmasq" = 1 ]; then
		/etc/init.d/dnsmasq restart >/dev/null 2>&1 || return 1
	fi
}

ensure_dns_original() {
	if [ "$(defaultv dns saved 0)" = 1 ] &&
	   [ -s "$dns_original_dir/service.state" ] &&
	   { [ -f "$dns_original_dir/dhcp.config" ] || [ -f "$dns_original_dir/dhcp.absent" ]; } &&
	   { [ -f "$dns_original_dir/dnsproxy.config" ] || [ -f "$dns_original_dir/dnsproxy.absent" ]; }; then
		repair_dns_original_snapshot
		return
	fi
	rm -rf "$dns_original_dir"
	save_dns_state "$dns_original_dir" || return 1
	repair_dns_original_snapshot || { rm -rf "$dns_original_dir"; return 1; }
	uci set "$config.dns.saved=1"
	uci commit "$config"
}

rollback_dns_transaction() {
	trap - EXIT INT TERM HUP
	[ "${dns_rollback_active:-0}" = 1 ] || return 0
	dns_rollback_active=0
	rollback_ok=1
	# Restore the application model first. FakeIP and segment renderers consume
	# it, so starting them against the rejected candidate can make an otherwise
	# valid resolver snapshot impossible to bring back.
	uci -q revert "$config" >/dev/null 2>&1 || true
	if [ -s "$rollback/$config.uci" ]; then
		uci import "$config" <"$rollback/$config.uci" &&
			uci commit "$config" || rollback_ok=0
	else
		rollback_ok=0
	fi
	# Restore files and the main proxy without exposing dnsmasq to a half-built
	# chain. Segment listeners must be available before sing-box is rendered.
	restore_dns_state "$rollback" 0 || rollback_ok=0
	restore_dns_segment_service_state "$rollback/service.state" || rollback_ok=0
	if [ "${fakeip_active:-0}" = 1 ] && [ -x /usr/libexec/ikev2-domain-router ]; then
		if ! /usr/libexec/ikev2-domain-router refresh >/dev/null 2>&1; then
			/usr/libexec/ikev2-domain-router restore-snapshot \
				"$rollback/domain-router" >/dev/null 2>&1 || rollback_ok=0
		fi
	else
		/etc/init.d/dnsmasq restart >/dev/null 2>&1 || rollback_ok=0
	fi
	dns_query_ok >/dev/null 2>&1 || rollback_ok=0
	rm -rf "$rollback"
	[ "$rollback_ok" -eq 1 ]
}

abort_dns_transaction() {
	if rollback_dns_transaction; then
		printf '%s\n' 'DNS apply aborted; previous resolver configuration was restored' >&2
	else
		printf '%s\n' 'DNS apply aborted and automatic resolver rollback was incomplete' >&2
	fi
}

dns_query_ok() {
	local tries=0 test_file="/tmp/ikev2-manager-dns-test.$$"
	while [ "$tries" -lt 8 ]; do
		if nslookup openwrt.org 127.0.0.1 >"$test_file" 2>&1 &&
			awk '
				/^Name:/ { answer = 1; next }
				answer && /^Address:/ { found = 1 }
				END { exit found ? 0 : 1 }
				' "$test_file"; then
			rm -f "$test_file"
			return 0
		fi
		tries=$((tries + 1))
		sleep 1
	done
	cat "$test_file" >&2 2>/dev/null || true
	rm -f "$test_file"
	return 1
}

dns_segments_check() {
	local section enabled domains port suffix probe output now rc=0 total=0 failed=0
	local probe_count=0 segment_failed=0 failure_ids=''
	local direct_failed=0 path_failed=0 direct_failure_ids='' path_failure_ids=''
	now="$(date +%s)"
	output="/tmp/ikev2-manager-dns-segment-check.$$"
	for section in $(dns_segment_sections); do
		enabled="$(defaultv "$section" enabled 1)"
		[ "$enabled" = 1 ] || continue
		domains="$(normalize_dns_suffix_list "$(getv "$section" domains)")"
		port="$(getv "$section" port)"
		[ -n "$domains" ] || continue
		total=$((total + 1))
		segment_failed=0
		# Every suffix in a segment reaches the same loopback worker and the same
		# dnsmasq rule path. Probe one representative suffix instead of issuing up
		# to 512 network queries per segment from the health loop.
		suffix="${domains%% *}"
		probe_count=$((probe_count + 1))
		probe="ikev2-health-${now}-${probe_count}.${suffix}"
		rc=0
		if command -v timeout >/dev/null 2>&1; then
			timeout 3 nslookup -port="$port" "$probe" 127.0.0.1 >"$output" 2>&1 || rc=$?
		else
			nslookup -port="$port" "$probe" 127.0.0.1 >"$output" 2>&1 || rc=$?
		fi
		# A random child normally returns NXDOMAIN. That is a healthy recursive
		# response; only timeout, REFUSED and SERVFAIL mean the suffix path failed.
		if grep -Eqi 'SERVFAIL|REFUSED|timed out|no servers could be reached' "$output" ||
		   { [ "$rc" -ne 0 ] && ! grep -Eqi 'NXDOMAIN|name error' "$output"; }; then
			segment_failed=1
			direct_failed=1
		else
			rc=0
			if command -v timeout >/dev/null 2>&1; then
				timeout 3 nslookup "$probe" 127.0.0.1 >"$output" 2>&1 || rc=$?
			else
				nslookup "$probe" 127.0.0.1 >"$output" 2>&1 || rc=$?
			fi
			if grep -Eqi 'SERVFAIL|REFUSED|timed out|no servers could be reached' "$output" ||
			   { [ "$rc" -ne 0 ] && ! grep -Eqi 'NXDOMAIN|name error' "$output"; }; then
				segment_failed=1
				path_failed=1
			fi
		fi
		rc=0
		if [ "$segment_failed" -eq 1 ]; then
			failed=$((failed + 1))
			failure_ids="${failure_ids}${failure_ids:+,}${section#dnsseg_}"
		fi
		if [ "$direct_failed" -eq 1 ]; then
			direct_failure_ids="${direct_failure_ids}${direct_failure_ids:+,}${section#dnsseg_}"
		fi
		if [ "$path_failed" -eq 1 ]; then
			path_failure_ids="${path_failure_ids}${path_failure_ids:+,}${section#dnsseg_}"
		fi
		direct_failed=0
		path_failed=0
		rc=0
	done
	rm -f "$output"
	mkdir -p "${dns_segments_status_file%/*}"
	{
		if [ "$total" -eq 0 ]; then
			printf 'state=disabled\n'
		elif [ "$failed" -eq 0 ]; then
			printf 'state=up\n'
		else
			printf 'state=degraded\n'
		fi
		printf 'checked=%s\n' "$now"
		printf 'segments=%s\n' "$total"
		printf 'failed=%s\n' "$failed"
		printf 'failure_ids=%s\n' "$failure_ids"
		printf 'direct_failure_ids=%s\n' "$direct_failure_ids"
		printf 'path_failure_ids=%s\n' "$path_failure_ids"
	} >"${dns_segments_status_file}.new"
	mv "${dns_segments_status_file}.new" "$dns_segments_status_file"
	[ "$failed" -eq 0 ]
}

dns_show() {
	ensure_dns_section
	managed="$(defaultv dns managed 0)"
	protocol="$(defaultv dns protocol doh)"
	provider="$(defaultv dns provider cloudflare)"
	upstream_mode="$(defaultv dns upstream_mode load_balance)"
	upstream="$(getv dns upstream)"
	bootstrap="$(getv dns bootstrap)"
	fallback="$(getv dns fallback)"
	current_upstream="$(uci -q get dnsproxy.servers.upstream 2>/dev/null || true)"
	current_bootstrap="$(uci -q get dnsproxy.servers.bootstrap 2>/dev/null || true)"
	current_fallback="$(uci -q get dnsproxy.servers.fallback 2>/dev/null || true)"
	current_upstream_mode="$(uci -q get dnsproxy.global.upstream_mode 2>/dev/null || true)"
	[ -n "$current_upstream_mode" ] || current_upstream_mode=load_balance
	current_protocol='unknown'
	for endpoint in $current_upstream; do
		current_protocol="$(dns_protocol_for_upstream "$endpoint")"
		break
	done
	printf 'managed=%s\n' "$managed"
	printf 'protocol=%s\n' "$protocol"
	printf 'provider=%s\n' "$provider"
	printf 'upstream_mode=%s\n' "$upstream_mode"
	printf 'upstream=%s\n' "$upstream"
	printf 'bootstrap=%s\n' "$bootstrap"
	printf 'fallback=%s\n' "$fallback"
	printf 'current_protocol=%s\n' "$current_protocol"
	printf 'current_upstream=%s\n' "$current_upstream"
	printf 'current_bootstrap=%s\n' "$current_bootstrap"
	printf 'current_fallback=%s\n' "$current_fallback"
	printf 'current_upstream_mode=%s\n' "$current_upstream_mode"
	printf 'segment_health=%s\n' \
		"$(sed -n 's/^state=//p' "$dns_segments_status_file" 2>/dev/null | tail -n1)"
	printf 'segment_failures=%s\n' \
		"$(sed -n 's/^failure_ids=//p' "$dns_segments_status_file" 2>/dev/null | tail -n1)"
	printf 'segment_direct_failures=%s\n' \
		"$(sed -n 's/^direct_failure_ids=//p' "$dns_segments_status_file" 2>/dev/null | tail -n1)"
	printf 'segment_path_failures=%s\n' \
		"$(sed -n 's/^path_failure_ids=//p' "$dns_segments_status_file" 2>/dev/null | tail -n1)"
	if /etc/init.d/dnsproxy running 2>/dev/null; then
		printf 'running=1\n'
	else
		printf 'running=0\n'
	fi
}

dns_segments_show() {
	local section
	for section in $(dns_segment_sections); do
		printf 'id=%s\tname=%s\tenabled=%s\tdomains=%s\tprotocol=%s\tmode=%s\tupstream=%s\tbootstrap=%s\tfallback=%s\thttps_compat=%s\tport=%s\n' \
			"${section#dnsseg_}" "$(getv "$section" name)" \
			"$(defaultv "$section" enabled 1)" "$(getv "$section" domains)" \
			"$(getv "$section" protocol)" "$(defaultv "$section" upstream_mode load_balance)" \
			"$(getv "$section" upstream)" "$(getv "$section" bootstrap)" \
			"$(getv "$section" fallback)" \
			"$(defaultv "$section" https_compat 1)" \
			"$(getv "$section" port)"
	done
}

next_dns_segment_port() {
	port=5550
	while [ "$port" -le 5599 ]; do
		used=0
		for section in $(dns_segment_sections); do
			[ "$(getv "$section" port)" != "$port" ] || used=1
		done
		[ "$used" = 1 ] || { printf '%s\n' "$port"; return 0; }
		port=$((port + 1))
	done
	return 1
}

apply_saved_dns() {
	dns_apply "$(defaultv dns managed 0)" "$(defaultv dns protocol doh)" \
		"$(defaultv dns provider custom)" "$(defaultv dns upstream_mode load_balance)" \
		"$(getv dns upstream)" "$(getv dns bootstrap)" "$(getv dns fallback)"
}

dns_segment_update() {
	local action="$1" id="$2" name="$3" enabled="$4" domains="$5"
	local protocol="$6" mode="$7" upstream="$8" bootstrap="$9" fallback="${10:-}" https_compat="${11:-1}"
	local section backup port current_port restored=0 mutation_ok=1
	case "$id" in '' | *[!A-Za-z0-9_]* ) die 'Invalid DNS segment identifier' ;; esac
	[ "${#id}" -le 40 ] || die 'DNS segment identifier is too long'
	section="dnsseg_$id"
	backup="$(mktemp)" || die 'Unable to snapshot DNS segments'
	uci export "$config" >"$backup" || { rm -f "$backup"; die 'Unable to snapshot DNS segments'; }
	case "$action" in
		delete)
			uci -q delete "$config.$section" || true
			;;
		set)
			valid_name "$name" || { rm -f "$backup"; die 'Invalid DNS segment name'; }
			[ "$enabled" = 0 ] || [ "$enabled" = 1 ] || { rm -f "$backup"; die 'Invalid DNS segment state'; }
			[ "$https_compat" = 0 ] || [ "$https_compat" = 1 ] || {
				rm -f "$backup"; die 'Invalid DNS segment browser compatibility mode'; }
			valid_dns_suffix_list "$domains" || { rm -f "$backup"; die 'Invalid DNS suffix list'; }
			case "$mode" in load_balance | parallel | fastest_addr) ;;
				*) rm -f "$backup"; die 'Invalid DNS segment query strategy' ;;
			esac
			valid_dns_endpoint_list "$protocol" "$upstream" || {
				rm -f "$backup"; die 'Invalid DNS segment upstream'; }
			valid_dns_bootstrap_list "$bootstrap" || {
				rm -f "$backup"; die 'Invalid DNS segment bootstrap'; }
			[ -z "$fallback" ] || valid_dns_endpoint_list_any "$fallback" || {
				rm -f "$backup"; die 'Invalid DNS segment fallback'; }
			current_port="$(getv "$section" port)"
			case "$current_port" in '' | *[!0-9]*) port="$(next_dns_segment_port)" || {
				rm -f "$backup"; die 'No DNS segment listener ports remain'; } ;;
			*) port="$current_port" ;;
			esac
			domains="$(normalize_dns_suffix_list "$domains")"
			uci set "$config.$section=dns_segment" &&
				uci set "$config.$section.name=$name" &&
				uci set "$config.$section.enabled=$enabled" &&
				uci set "$config.$section.domains=$domains" &&
				uci set "$config.$section.protocol=$protocol" &&
				uci set "$config.$section.upstream_mode=$mode" &&
				uci set "$config.$section.upstream=$(normalize_list "$upstream")" &&
				uci set "$config.$section.bootstrap=$(normalize_list "$bootstrap")" &&
				uci set "$config.$section.fallback=$(normalize_list "$fallback")" &&
				uci set "$config.$section.https_compat=$https_compat" &&
				uci set "$config.$section.port=$port" || mutation_ok=0
			;;
		*) rm -f "$backup"; die 'Expected DNS segment action: set or delete' ;;
	esac
	if [ "$mutation_ok" != 1 ] || ! validate_dns_segments || ! uci commit "$config"; then
		uci -q revert "$config" >/dev/null 2>&1 || true
		if uci import "$config" <"$backup" && uci commit "$config"; then
			rm -f "$backup"
			die 'Invalid DNS segment; previous configuration restored'
		fi
		rm -f "$backup"
		die 'DNS segment update failed and automatic rollback was incomplete'
	fi
	if [ "$(defaultv dns managed 0)" = 1 ] && ! ( apply_saved_dns ); then
		uci import "$config" <"$backup" && uci commit "$config" && restored=1
		[ "$restored" = 0 ] || ( apply_saved_dns ) >/dev/null 2>&1 || restored=0
		rm -f "$backup"
		[ "$restored" = 1 ] && die 'DNS segment failed validation; previous configuration restored'
		die 'DNS segment failed and automatic rollback was incomplete'
	fi
	rm -f "$backup"
}

dns_segment_input() {
	local token file bytes
	token="$1"
	file="/tmp/ikev2-manager-dns-segment-$token.in"
	case "$token" in '' | *[!A-Za-z0-9-]*) die 'Invalid DNS segment input token' ;; esac
	[ -f "$file" ] && [ ! -L "$file" ] || die 'DNS segment input is missing'
	bytes="$(wc -c <"$file" | tr -d ' ')"
	case "$bytes" in '' | *[!0-9]*) rm -f "$file"; die 'Invalid DNS segment input size' ;; esac
	[ "$bytes" -le 16384 ] || { rm -f "$file"; die 'DNS segment input is too large'; }
	chmod 600 "$file" || die 'Unable to protect DNS segment input'
	start_action dns-segment "$file"
}

dns_apply() {
	ensure_dns_section
	managed="$1"
	protocol="$2"
	selected_protocol="$protocol"
	provider="$3"
	upstream_mode="$4"
	upstream="$(normalize_list "$5")"
	bootstrap="$(normalize_list "$6")"
	fallback="$(normalize_list "$7")"
	[ "$managed" = 0 ] || [ "$managed" = 1 ] || die 'Invalid DNS management mode'
	[ "$managed" = 0 ] || valid_name "$provider" || die 'Invalid DNS provider'
	fakeip_active=0
	if [ "$(getv domains engine)" = fakeip ] &&
	   [ -x /usr/libexec/ikev2-domain-router ]; then
		fakeip_active=1
	fi

	if [ "$managed" = 0 ]; then
		if [ -x /etc/init.d/ikev2-dns-segments ]; then
			/etc/init.d/ikev2-dns-segments stop >/dev/null 2>&1 || true
			/etc/init.d/ikev2-dns-segments disable >/dev/null 2>&1 || true
		fi
		if [ "$(defaultv dns saved 0)" = 1 ] && [ -d "$dns_original_dir" ]; then
			repair_dns_original_snapshot ||
				die 'Saved original DNS state is incomplete; managed DNS remains configured'
			rollback="/tmp/ikev2-manager-dns-disable-rollback-$$"
			rm -rf "$rollback"
			save_dns_state "$rollback" || die 'Unable to snapshot the current DNS configuration'
			uci export "$config" >"$rollback/$config.uci" || {
				rm -rf "$rollback"
				die 'Unable to snapshot application DNS settings'
			}
			if [ "$fakeip_active" = 1 ] &&
			   ! /usr/libexec/ikev2-domain-router snapshot "$rollback/domain-router"; then
				rm -rf "$rollback"
				die 'Unable to snapshot the active FakeIP resolver runtime'
			fi
			dns_rollback_active=1
			trap abort_dns_transaction EXIT INT TERM HUP
			if ! restore_dns_state "$dns_original_dir" "$([ "$fakeip_active" = 1 ] && echo 0 || echo 1)" ||
			   { [ "$fakeip_active" = 1 ] && ! /usr/libexec/ikev2-domain-router adopt-upstream; } ||
			   ! dns_query_ok; then
				if rollback_dns_transaction; then
					die 'Original DNS could not be restored safely; managed DNS remains configured'
				fi
				die 'Original DNS restore failed and automatic rollback was incomplete'
			fi
		fi
		uci set "$config.dns.managed=0"
		uci set "$config.dns.saved=0"
		uci commit "$config"
		dns_query_ok || die 'Restored DNS configuration is not resolving'
		if [ "${dns_rollback_active:-0}" = 1 ]; then
			dns_rollback_active=0
			trap - EXIT INT TERM HUP
			rm -rf "$rollback"
		fi
		rm -rf "$dns_original_dir"
		return 0
	fi

	case "$selected_protocol" in
		udp | tcp | dot | doh | doh3 | h3 | doq | dnscrypt) ;;
		*) die 'Unsupported DNS protocol' ;;
	esac
	case "$upstream_mode" in
		load_balance | parallel | fastest_addr) ;;
		*) die 'Unsupported DNS upstream mode' ;;
	esac
	valid_dns_endpoint_list "$selected_protocol" "$upstream" ||
		die 'Invalid DNS upstream for the selected protocol'
	valid_dns_bootstrap_list "$bootstrap" ||
		die 'Bootstrap DNS must contain IPv4:port entries'
	if [ -n "$fallback" ]; then
		valid_dns_endpoint_list_any "$fallback" ||
			die 'Invalid fallback DNS endpoint'
	fi
	# Retrying the same endpoint as both primary and fallback doubles the outage
	# delay without adding a recovery path. Preserve only independent fallbacks.
	fallback="$(list_without "$fallback" "$upstream")"
	command -v dnsproxy >/dev/null 2>&1 || die 'dnsproxy is not installed'
	validate_dns_segments || die 'A destination DNS segment is invalid or reuses a listener port'

	ensure_dns_original || die 'Unable to save the original DNS configuration'
	rollback="/tmp/ikev2-manager-dns-rollback-$$"
	rm -rf "$rollback"
	save_dns_state "$rollback" || die 'Unable to snapshot the current DNS configuration'
	uci export "$config" >"$rollback/$config.uci" || {
		rm -rf "$rollback"
		die 'Unable to snapshot application DNS settings'
	}
	if [ "$fakeip_active" = 1 ] &&
	   ! /usr/libexec/ikev2-domain-router snapshot "$rollback/domain-router"; then
		rm -rf "$rollback"
		die 'Unable to snapshot the active FakeIP resolver runtime'
	fi
	dns_rollback_active=1
	trap abort_dns_transaction EXIT INT TERM HUP

	uci -q get dnsproxy.global >/dev/null 2>&1 ||
		uci set dnsproxy.global=dnsproxy
	uci -q get dnsproxy.servers >/dev/null 2>&1 ||
		uci set dnsproxy.servers=dnsproxy
	uci -q get dnsproxy.cache >/dev/null 2>&1 ||
		uci set dnsproxy.cache=cache
	uci set dnsproxy.global.enabled='1'
	uci set dnsproxy.global.http3="$([ "$selected_protocol" = doh3 ] && echo 1 || echo 0)"
	uci set dnsproxy.global.insecure='0'
	runtime_timeout="$(dns_runtime_timeout "$fallback")"
	uci set dnsproxy.global.timeout="$runtime_timeout"
	uci set dnsproxy.global.upstream_mode="$upstream_mode"
	set_uci_list dnsproxy global listen_addr '127.0.0.1'
	set_uci_list dnsproxy global listen_port '5453'
	combined_upstream="$(dns_combined_upstreams "$upstream")"
	set_uci_list dnsproxy servers upstream "$combined_upstream"
	set_uci_list dnsproxy servers bootstrap "$bootstrap"
	set_uci_list dnsproxy servers fallback "$fallback"
	# dnsmasq owns the cache in standard mode and sing-box owns it in Reliable
	# mode.  A second optimistic cache here can retain a transient SERVFAIL and
	# amplify it through every client, especially through a destination segment.
	uci set dnsproxy.cache.enabled='0'
	uci set dnsproxy.cache.cache_optimistic='0'
	uci set dnsproxy.cache.size='65535'
	uci commit dnsproxy

	if [ "$fakeip_active" = 1 ]; then
		uci set "$config.domains.prev_noresolv=1"
		uci -q delete "$config.domains.prev_server" || true
		uci add_list "$config.domains.prev_server=127.0.0.1#5453"
	else
		uci set dhcp.@dnsmasq[0].noresolv='1'
		dnsmasq_upstream="$(dnsmasq_combined_servers '127.0.0.1#5453')"
		set_uci_list dhcp '@dnsmasq[0]' server "$dnsmasq_upstream"
		uci commit dhcp
	fi

	uci set "$config.dns.managed=1"
	uci set "$config.dns.protocol=$selected_protocol"
	uci set "$config.dns.provider=$provider"
	uci set "$config.dns.upstream_mode=$upstream_mode"
	uci set "$config.dns.upstream=$upstream"
	uci set "$config.dns.bootstrap=$bootstrap"
	uci set "$config.dns.fallback=$fallback"
	uci commit "$config"

	if ! /etc/init.d/ikev2-dns-segments enable >/dev/null 2>&1 ||
	   ! /etc/init.d/ikev2-dns-segments restart >/dev/null 2>&1 ||
	   ! /etc/init.d/dnsproxy enable >/dev/null 2>&1 ||
	   ! /etc/init.d/dnsproxy restart >/dev/null 2>&1 ||
		{ [ "$fakeip_active" = 1 ] &&
			! /usr/libexec/ikev2-domain-router refresh; } ||
		{ [ "$fakeip_active" != 1 ] &&
			! /etc/init.d/dnsmasq restart >/dev/null 2>&1; } ||
		! dns_query_ok || ! dns_segments_check; then
		if rollback_dns_transaction; then
			die 'DNS validation failed; previous resolver configuration was restored'
		fi
		die 'DNS validation failed and automatic resolver rollback was incomplete'
	fi
	dns_rollback_active=0
	trap - EXIT INT TERM HUP
	rm -rf "$rollback"
}

dns_set_async() {
	[ -f "$dns_input_file" ] || die 'DNS settings input is missing'
	[ ! -L "$dns_input_file" ] || {
		rm -f "$dns_input_file"
		die 'DNS settings input must not be a symbolic link'
	}
	input_bytes="$(wc -c <"$dns_input_file" | tr -d ' ')"
	case "$input_bytes" in '' | *[!0-9]*) rm -f "$dns_input_file"; die 'Invalid DNS input size' ;; esac
	[ "$input_bytes" -le 16384 ] || {
		rm -f "$dns_input_file"
		die 'DNS settings input is too large'
	}
	chmod 600 "$dns_input_file" || die 'Unable to protect DNS settings input'
	[ -z "$(sed -n '8p' "$dns_input_file")" ] || {
		rm -f "$dns_input_file"
		die 'DNS settings input has unexpected extra fields'
	}
	{
		IFS= read -r managed
		IFS= read -r protocol
		IFS= read -r provider
		IFS= read -r upstream_mode
		IFS= read -r upstream
		IFS= read -r bootstrap
		IFS= read -r fallback || true
	} <"$dns_input_file"
	rm -f "$dns_input_file"
	start_action dns-set "$managed" "$protocol" "$provider" "$upstream_mode" \
		"$upstream" "$bootstrap" "$fallback"
}

backup_uci_state() {
	label="$1"
	stamp="$(date +%Y%m%d-%H%M%S)"
	dir="/etc/ikev2-manager/backups/${stamp}-$$-${label}"
	tmp="${dir}.new"
	rm -rf "$tmp"
	mkdir -p "$tmp" || return 1
	for package in ikev2-manager firewall pbr network dhcp dnsproxy; do
		if [ -f "$uci_config_dir/$package" ]; then
			cp -p "$uci_config_dir/$package" "$tmp/$package.config" || {
				rm -rf "$tmp"
				return 1
			}
		else
			: >"$tmp/$package.absent"
		fi
	done
	for service in ikev2-xfrm dnsproxy dnsmasq ikev2-dns-segments ikev2-domain-router pbr ikev2-health ikev2-user-policy; do
		[ -x "/etc/init.d/$service" ] || continue
		if "/etc/init.d/$service" enabled >/dev/null 2>&1; then
			enabled=1
		else
			enabled=0
		fi
		if "/etc/init.d/$service" running >/dev/null 2>&1; then
			running=1
		else
			running=0
		fi
		printf '%s\t%s\t%s\n' "$service" "$enabled" "$running"
	done >"$tmp/services.state"
	mv "$tmp" "$dir" || return 1
	printf '%s\n' "$dir"
}

restore_uci_state() {
	dir="$1"
	restored=1
	for package in ikev2-manager firewall pbr network dhcp dnsproxy; do
		destination="$uci_config_dir/$package"
		uci -q revert "$package" >/dev/null 2>&1 || true
		if [ -f "$dir/$package.config" ]; then
			cp -p "$dir/$package.config" "${destination}.restore.$$" &&
				mv "${destination}.restore.$$" "$destination" || restored=0
		elif [ -f "$dir/$package.absent" ]; then
			rm -f "$destination" || restored=0
		else
			restored=0
		fi
	done
	# Rollback must be able to restore a pre-upgrade configuration even when it
	# contains a warning that the new apply path would repair and reject.
	fw4 -q check >/dev/null 2>&1 && fw4 -q reload >/dev/null 2>&1 || restored=0
	while IFS="$(printf '\t')" read -r service enabled running; do
		[ -n "$service" ] || continue
		case "$service" in
			pbr | ikev2-xfrm | ikev2-dns-segments | ikev2-domain-router | dnsproxy | dnsmasq | ikev2-health | ikev2-user-policy) ;;
			*) restored=0; continue ;;
		esac
		[ -x "/etc/init.d/$service" ] || { restored=0; continue; }
		if [ "$enabled" = 1 ]; then
			/etc/init.d/"$service" enable >/dev/null 2>&1 || restored=0
		else
			/etc/init.d/"$service" disable >/dev/null 2>&1 || restored=0
		fi
		if [ "$running" = 1 ]; then
			/etc/init.d/"$service" restart >/dev/null 2>&1 || restored=0
		else
			/etc/init.d/"$service" stop >/dev/null 2>&1 || restored=0
		fi
	done <"$dir/services.state"
	[ ! -x /usr/share/pbr/pbr.user.ikev2out ] ||
		/usr/share/pbr/pbr.user.ikev2out >/dev/null 2>&1 || restored=0
	sync_inbound_user_policy >/dev/null 2>&1 || restored=0
	if [ "$(getv globals configured)" = 1 ]; then
		[ ! -x "$device_runtime_helper" ] ||
			"$device_runtime_helper" sync >/dev/null 2>&1 || restored=0
		[ ! -x /usr/libexec/ikev2-discord-voice ] ||
			/usr/libexec/ikev2-discord-voice sync >/dev/null 2>&1 || restored=0
		if [ "$(getv domains engine)" = fakeip ] &&
		   [ -x "$domain_router_helper" ]; then
			"$domain_router_helper" refresh >/dev/null 2>&1 || restored=0
		fi
	fi
	[ "$restored" -eq 1 ]
}

# Cross-package ownership contract. Site Link keeps its last successfully
# applied state in a separate section, so an edited candidate cannot make
# Manager retain shared resources for a link that is not actually active.
site_link_active() {
	[ "$(uci -q get ikev2-site-link.applied 2>/dev/null || true)" = state ] &&
	[ "$(uci -q get ikev2-site-link.applied.enabled 2>/dev/null || echo 0)" = 1 ] &&
	case "$(uci -q get ikev2-site-link.applied.role 2>/dev/null || true)" in
		source | exit) return 0 ;;
		*) return 1 ;;
	esac
}

site_link_source_active() {
	site_link_active &&
	[ "$(uci -q get ikev2-site-link.applied.role 2>/dev/null || true)" = source ]
}

site_link_exit_active() {
	site_link_active &&
	[ "$(uci -q get ikev2-site-link.applied.role 2>/dev/null || true)" = exit ]
}

# dependency-state.sh calls this optional hook before restoring the previous
# dnsmasq provider. A source Site Link requires dnsmasq nftset support even if
# Manager itself is being removed.
deps_shared_dnsmasq_required() {
	site_link_source_active
}

# Do not ask the package solver to remove a runtime that an applied Site Link
# still consumes. This is required in addition to package dependency metadata:
# opkg may abort the whole multi-package removal at the first reverse dependency
# instead of retaining that package and continuing with unrelated ones.
deps_shared_package_required() {
	site_link_active || return 1
	case "$1" in
		pbr | ip-full | kmod-xfrm-interface | openssl-util | curl | libcurl4 | \
		strongswan | strongswan-*) return 0 ;;
		*) return 1 ;;
	esac
}

reload_pbr_for_site_link() {
	local tries=0
	/etc/init.d/pbr reload >/dev/null 2>&1 || true
	while [ "$tries" -lt 30 ]; do
		if /etc/init.d/pbr running >/dev/null 2>&1 &&
		   nft list chain inet fw4 pbr_prerouting 2>/dev/null |
			grep -Fq "IKEv2 Site Link: $([ "$(uci -q get ikev2-site-link.applied.role 2>/dev/null)" = source ] &&
				echo 'selected services' || echo 'direct exit WAN')" &&
		   { [ ! -x /usr/libexec/ikev2-site-link ] ||
		     /usr/libexec/ikev2-site-link policy-check >/dev/null 2>&1; }; then
			return 0
		fi
		tries=$((tries + 1))
		sleep 1
	done
	return 1
}

remove_managed() {
	# Stop the reconciler before removing any runtime it owns.  Leaving it alive
	# until the end lets a health cycle recreate the inbound, device or FakeIP
	# tables between teardown and disabled_runtime_absent(), making disable fail
	# nondeterministically.  The outer transaction restores the previous service
	# state if any later cleanup step fails.
	if [ -x /etc/init.d/ikev2-health ]; then
		/etc/init.d/ikev2-health stop >/dev/null 2>&1 || return 1
		/etc/init.d/ikev2-health disable >/dev/null 2>&1 || return 1
	fi
	if [ -x /usr/libexec/ikev2-discord-voice ]; then
		/usr/libexec/ikev2-discord-voice stop >/dev/null 2>&1 || return 1
	fi
	if [ -x /usr/libexec/ikev2-domain-router ]; then
		/usr/libexec/ikev2-domain-router deactivate >/dev/null 2>&1 || return 1
	fi
	if [ -x /etc/init.d/ikev2-dns-segments ]; then
		/etc/init.d/ikev2-dns-segments stop >/dev/null 2>&1 || return 1
		/etc/init.d/ikev2-dns-segments disable >/dev/null 2>&1 || return 1
	fi
	delete_prefixed_sections firewall ikev2pbr_
	delete_prefixed_sections firewall ikev2access_
	uci commit firewall || return 1
	uci -q delete network.ikev2out || true
	uci commit network || return 1
	uci -q delete pbr.ikev2pbr_domains || true
	uci -q delete pbr.ikev2pbr_service_cidrs || true
	uci -q delete pbr.ikev2pbr_include || true
	device_pbr_clear || return 1
	uci -q del_list pbr.config.supported_interface='ikev2out' || true
	if [ "$(uci -q get "$config.globals.pbr_saved" 2>/dev/null)" = 1 ]; then
		# Site Link is a separate package but shares the global PBR runtime. Never
		# restore Manager's historical snapshot across a live consumer: doing so
		# disables its classifier while its SA and fail-closed route remain active.
		# Once Manager releases ownership, a later enable takes a new snapshot of
		# the then-current shared contract.
		if site_link_active; then
			uci set pbr.config.enabled='1'
			uci set pbr.config.strict_enforcement='1'
			if site_link_source_active; then
				uci set pbr.config.ipv6_enabled='1'
				uci set pbr.config.resolver_set='dnsmasq.nftset'
			fi
		else
			uci set pbr.config.enabled="$(uci -q get "$config.globals.pbr_prev_enabled" 2>/dev/null || echo 0)"
			uci set pbr.config.ipv6_enabled="$(uci -q get "$config.globals.pbr_prev_ipv6" 2>/dev/null || echo 0)"
			v="$(uci -q get "$config.globals.pbr_prev_resolver" 2>/dev/null || true)"
			[ -n "$v" ] && uci set pbr.config.resolver_set="$v" || uci -q delete pbr.config.resolver_set
			v="$(uci -q get "$config.globals.pbr_prev_strict" 2>/dev/null || true)"
			[ -n "$v" ] && uci set pbr.config.strict_enforcement="$v" || uci -q delete pbr.config.strict_enforcement
		fi
		for k in pbr_saved pbr_prev_enabled pbr_prev_ipv6 pbr_prev_resolver pbr_prev_strict; do
			uci -q delete "$config.globals.$k"
		done
		uci commit "$config" || return 1
	fi
	uci commit pbr || return 1
	rm -f /usr/share/nftables.d/chain-pre/forward/20-ikev2-killswitch.nft
	rm -f /var/run/ikev2-vip4
	# Drop the IPv6 fail-fast route only if we added it (no real v6 default).
	ip -6 route show default 2>/dev/null | grep -q 'unreachable' &&
		ip -6 route del unreachable default metric 2147483647 2>/dev/null || true
	# Remove live firewall and PBR references before stopping the XFRM links.
	# OpenWrt 25 can otherwise block forever inside `ip link del ipsec-in`.
	firewall_check_strict >/dev/null 2>&1 || return 1
	fw4 -q reload >/dev/null 2>&1 || return 1
	if [ "$(uci -q get pbr.config.enabled 2>/dev/null || echo 0)" = 1 ]; then
		if site_link_active; then
			reload_pbr_for_site_link || return 1
		else
			/etc/init.d/pbr restart >/dev/null 2>&1 || return 1
		fi
		/etc/init.d/pbr running >/dev/null 2>&1 || return 1
	else
		/etc/init.d/pbr stop >/dev/null 2>&1 || return 1
	fi
	if [ -x /etc/init.d/ikev2-xfrm ]; then
		/etc/init.d/ikev2-xfrm stop >/dev/null 2>&1 || return 1
		/etc/init.d/ikev2-xfrm disable >/dev/null 2>&1 || return 1
	fi
	# The per-user table is the fail-closed guard in front of the deliberately
	# broad fw4 zone forwarding. Keep it until those rules are reloaded and XFRM
	# is down; deleting it earlier creates a transient access-policy bypass.
	if [ -x "$user_policy_init" ]; then
		"$user_policy_init" stop >/dev/null 2>&1 || return 1
		"$user_policy_init" disable >/dev/null 2>&1 || return 1
	elif [ -x "$user_policy_helper" ]; then
		"$user_policy_helper" stop >/dev/null 2>&1 || return 1
	fi
	# Keep the independent atomic device table until every risky service and
	# firewall transition has succeeded. A failed disable can then restore UCI
	# without leaving configured mode missing its live DNS/device policy.
	if [ -x "$device_runtime_helper" ]; then
		"$device_runtime_helper" stop >/dev/null 2>&1 || return 1
	fi
	disabled_runtime_absent
}

apply_system_inner() {
	[ "$(getv globals configured)" = 1 ] ||
		die 'Base setup is not enabled'
	validate_runtime_config
	# Regenerate managed firewall sections before doctor so an upgrade can
	# repair stale sections that an older release rendered in an invalid form.
	# The outer transaction restores the original UCI state on any later error.
	sync_firewall
	IKEV2_DOCTOR_ALLOW_RUNTIME_REPAIR=1 \
		doctor >/tmp/ikev2-manager-doctor.last 2>&1 ||
		die 'Dependency check failed; run ikev2-manager-system doctor'
	sync_network
	sync_pbr
	# Fail-closed behavior has two native layers: an unreachable PBR default and
	# XFRM policy drop when no matching SA exists.
	rm -f /usr/share/nftables.d/chain-pre/forward/20-ikev2-killswitch.nft
	/etc/init.d/ikev2-xfrm enable || die 'Failed to enable ikev2-xfrm'
	/etc/init.d/ikev2-health enable || die 'Failed to enable ikev2-health'
	/etc/init.d/ikev2-xfrm start || die 'Failed to start ikev2-xfrm'
	firewall_check_strict || die 'firewall4 validation failed'
	/etc/init.d/pbr restart || die 'PBR restart command failed'
	/etc/init.d/pbr running >/dev/null 2>&1 ||
		die 'PBR failed to start; check /tmp/ikev2-manager-doctor.last and logread'
	fw4 -q reload || die 'firewall4 reload failed after PBR restart'
	sync_device_runtime || die 'Device policy failed to load'
	sync_inbound_user_policy || die 'Inbound user policy failed to load'
	ensure_forward_chain ||
		die 'fw4 forward chain has no zone forwarding after apply (LAN->WAN would be dropped); rolled back'
	failclosed_check >/dev/null ||
		die 'PBR fail-closed route validation failed'
	failclosed_ipv6_check >/dev/null ||
		die 'PBR IPv6 fail-closed route validation failed'
	ensure_ipv6_failfast
	/etc/init.d/ikev2-health start >/dev/null 2>&1 || true
	if [ "$(getv domains engine)" = fakeip ] &&
	   [ -x /usr/libexec/ikev2-domain-router ]; then
		/usr/libexec/ikev2-domain-router refresh ||
			die 'FakeIP domain router refresh failed'
	fi
}

apply_system() {
	backup_dir="$(backup_uci_state apply)" ||
		die 'Unable to back up router state before apply'
	if ! "$0" _apply-system-inner; then
		if restore_uci_state "$backup_dir"; then
			rm -rf "$backup_dir"
			die 'Managed apply failed; previous router state was restored'
		fi
		rm -rf "$backup_dir"
		die 'Managed apply failed and automatic rollback was incomplete'
	fi
	rm -rf "$backup_dir"
}

disable_managed() {
	backup_dir="$(backup_uci_state disable)" || return 1
	if ! "$0" _disable-managed-inner; then
		restore_uci_state "$backup_dir" || {
			rm -rf "$backup_dir"
			return 1
		}
		rm -rf "$backup_dir"
		return 1
	fi
	rm -rf "$backup_dir"
}

# Narrow runtime apply for Inbound Server saves. Most server edits only need a
# firewall reload and a strongSwan reload (performed by the manager worker).
# PBR itself is restarted only when enabling/disabling the server changes
# whether @ipsec-in participates in the domain policy.
apply_server_runtime() {
	needs_pbr="${1:-0}"
	[ "$(getv globals configured)" = 1 ] ||
		die 'Base setup is not enabled'
	[ "$needs_pbr" = 0 ] || [ "$needs_pbr" = 1 ] ||
		die 'Invalid server PBR-change flag'
	validate_runtime_config
	sync_firewall
	if [ "$needs_pbr" = 1 ]; then
		sync_pbr
	fi
	/etc/init.d/ikev2-xfrm start || die 'Failed to update inbound XFRM interface'
	firewall_check_strict || die 'firewall4 validation failed'
	if [ "$needs_pbr" = 1 ]; then
		/etc/init.d/pbr restart || die 'PBR restart command failed'
		/etc/init.d/pbr running >/dev/null 2>&1 ||
			 die 'PBR failed to start after server policy change'
		failclosed_ipv6_check >/dev/null ||
			die 'PBR IPv6 fail-closed route validation failed after server change'
	fi
	fw4 -q reload || die 'firewall4 reload failed'
	sync_device_runtime || die 'Device policy failed to load'
	ensure_forward_chain ||
		die 'fw4 forward chain has no zone forwarding after server apply'
	sync_inbound_user_policy ||
		die 'Inbound user policy failed to load'
	ensure_ipv6_failfast
	/etc/init.d/ikev2-health start >/dev/null 2>&1 || true
	if [ "$needs_pbr" = 1 ] &&
	   [ "$(getv domains engine)" = fakeip ] &&
	   [ -x /usr/libexec/ikev2-domain-router ]; then
		/usr/libexec/ikev2-domain-router refresh ||
			die 'FakeIP domain router refresh failed'
	fi
}

apply_server_runtime_transaction() {
	needs_pbr="${1:-0}"
	backup_dir="$(backup_uci_state server-runtime)" ||
		die 'Unable to back up router state before server apply'
	if ! "$0" _server-apply-inner "$needs_pbr"; then
		if restore_uci_state "$backup_dir"; then
			rm -rf "$backup_dir"
			die 'Inbound server runtime apply failed; previous router state was restored'
		fi
		rm -rf "$backup_dir"
		die 'Inbound server runtime apply failed and automatic rollback was incomplete'
	fi
	rm -rf "$backup_dir"
}

show_config() {
	domain_status=''
	if [ -x /usr/libexec/ikev2-domain-router ]; then
		domain_status="$(/usr/libexec/ikev2-domain-router status 2>/dev/null || true)"
	fi
	printf 'configured=%s\n' "$(getv globals configured)"
	printf 'wan_interface=%s\n' "$(getv globals wan_interface)"
	printf 'wan_zone=%s\n' "$(getv globals wan_zone)"
	printf 'source_interfaces=%s\n' "$(get_list globals source_interface)"
	printf 'source_zones=%s\n' "$(get_list globals source_zone)"
	printf 'dns_enforce=%s\n' "$(getv globals dns_enforce)"
	printf 'block_dot=%s\n' "$(getv globals block_dot)"
	printf 'source_include_vpn=%s\n' "$(defaultv globals source_include_vpn 1)"
	printf 'server_enabled=%s\n' "$(getv server enabled)"
	for field in engine service dnsmasq_upstream dnsmasq_cache nft rule healthy state message; do
		if [ "$field" = engine ]; then
			value="$(getv domains engine)"
		else
			value="$(printf '%s\n' "$domain_status" | sed -n "s/^$field=//p" | tail -n1)"
		fi
		printf 'domain_%s=%s\n' "$field" "$value"
	done
	if failclosed_ipv6_check >/dev/null 2>&1; then
		printf 'ipv6_failfast=active\n'
	elif ip -6 route show default 2>/dev/null | grep -q .; then
		printf 'ipv6_failfast=missing\n'
	else
		printf 'ipv6_failfast=off\n'
	fi
}

persist_base_config() {
	uci set "$config.globals.configured=$enabled" || return 1
	uci set "$config.globals.wan_interface=$wan_interface" || return 1
	uci set "$config.globals.wan_zone=$wan_zone" || return 1
	set_list globals source_interface "$source_interfaces" || return 1
	set_list globals source_zone "$source_zones" || return 1
	uci set "$config.globals.dns_enforce=$dns_enforce" || return 1
	uci set "$config.globals.block_dot=$block_dot" || return 1
	uci set "$config.globals.source_include_vpn=$include_vpn" || return 1
	uci commit "$config" || return 1
	[ "$(getv globals configured)" = "$enabled" ] || return 1
	[ "$(getv globals wan_interface)" = "$wan_interface" ] || return 1
	[ "$(getv globals wan_zone)" = "$wan_zone" ] || return 1
	[ "$(normalize_list "$(get_list globals source_interface)")" = "$source_interfaces" ] || return 1
	[ "$(normalize_list "$(get_list globals source_zone)")" = "$source_zones" ] || return 1
	[ "$(getv globals dns_enforce)" = "$dns_enforce" ] || return 1
	[ "$(getv globals block_dot)" = "$block_dot" ] || return 1
	[ "$(getv globals source_include_vpn)" = "$include_vpn" ]
}

base_config_matches() {
	[ "$(getv globals configured)" = "$enabled" ] &&
	[ "$(getv globals wan_interface)" = "$wan_interface" ] &&
	[ "$(getv globals wan_zone)" = "$wan_zone" ] &&
	[ "$(normalize_list "$(get_list globals source_interface)")" = "$source_interfaces" ] &&
	[ "$(normalize_list "$(get_list globals source_zone)")" = "$source_zones" ] &&
	[ "$(getv globals dns_enforce)" = "$dns_enforce" ] &&
	[ "$(getv globals block_dot)" = "$block_dot" ] &&
	[ "$(getv globals source_include_vpn)" = "$include_vpn" ]
}

disabled_runtime_absent() {
	! uci -q get network.ikev2out >/dev/null 2>&1 &&
	! uci show firewall 2>/dev/null | grep -q '^firewall\.ikev2pbr_' &&
	! uci show pbr 2>/dev/null | grep -Eq '^pbr\.(ikev2pbr_|pbr_dev_(fr|ex)_)' &&
	! "$nft_binary" list table inet ikev2_device_policy >/dev/null 2>&1 &&
	! "$nft_binary" list table inet ikev2_user_policy >/dev/null 2>&1 &&
	! "$nft_binary" list table inet ikev2_discord_voice >/dev/null 2>&1 &&
	! "$nft_binary" list table inet ikev2_domain_router >/dev/null 2>&1 &&
	! ip -4 rule show 2>/dev/null | grep -q 'lookup 51820' &&
	[ ! -e /usr/share/nftables.d/chain-pre/forward/20-ikev2-killswitch.nft ]
}

set_config() {
	[ "$#" -eq 5 ] || [ "$#" -eq 6 ] ||
		die 'Expected: configured wan_interface source_interfaces dns_enforce block_dot [source_include_vpn]'
	enabled="$1"
	wan_interface="$2"
	source_interfaces="$3"
	dns_enforce="$4"
	block_dot="$5"
	# Optional 6th arg keeps older callers working; absent -> preserve current.
	include_vpn="${6:-$(defaultv globals source_include_vpn 1)}"

	[ "$enabled" = 0 ] || [ "$enabled" = 1 ] || die 'Invalid enabled value'
	valid_name "$wan_interface" || die 'Invalid WAN network interface'
	valid_name_list "$source_interfaces" || die 'Invalid protected networks'
	[ "$dns_enforce" = 0 ] || [ "$dns_enforce" = 1 ] || die 'Invalid DNS enforcement value'
	[ "$block_dot" = 0 ] || [ "$block_dot" = 1 ] || die 'Invalid DoT block value'
	[ "$include_vpn" = 0 ] || [ "$include_vpn" = 1 ] || die 'Invalid VPN-server inclusion value'
	source_interfaces="$(normalize_list "$source_interfaces")"
	uci -q get "network.$wan_interface" >/dev/null 2>&1 ||
		die "WAN network '$wan_interface' does not exist"

	# Firewall zones are derived from the chosen networks (no separate UI fields).
	wan_zone="$(zone_for_network "$wan_interface")"
	zone_exists "$wan_zone" || die "WAN firewall zone '$wan_zone' does not exist"
	source_zones=""
	unique_sources=""
	for _n in $source_interfaces; do
		[ "$_n" != "$wan_interface" ] ||
			die "WAN network '$wan_interface' cannot be a protected network"
		uci -q get "network.$_n" >/dev/null 2>&1 ||
			die "Protected network '$_n' does not exist"
		network_device "$_n" >/dev/null || die "Protected network '$_n' has no device"
		_z="$(zone_for_network "$_n")"
		zone_exists "$_z" || die "Firewall zone '$_z' does not exist"
		[ "$_z" != "$wan_zone" ] ||
			die "Protected network '$_n' belongs to the WAN firewall zone '$wan_zone'"
		case " $unique_sources " in *" $_n "*) ;; *) unique_sources="${unique_sources:+$unique_sources }$_n" ;; esac
		case " $source_zones " in *" $_z "*) ;; *) source_zones="${source_zones:+$source_zones }$_z" ;; esac
	done
	source_interfaces="$unique_sources"

	# Saving identical settings should not rebuild firewall and PBR for 10-20
	# seconds. Skip the transaction only after proving that the corresponding
	# runtime is already healthy (or fully absent for disabled mode). Any drift
	# still falls through to the normal transactional apply/repair path.
	if base_config_matches; then
		if [ "$enabled" = 1 ] && [ -x "$routing_check_helper" ] &&
		   "$routing_check_helper" --check; then
			return 0
		fi
		if [ "$enabled" = 0 ] && disabled_runtime_absent; then
			return 0
		fi
	fi

	if [ "$enabled" = 1 ]; then
		backup_dir="$(backup_uci_state enable-managed)" ||
			die 'Unable to back up router state before enabling managed mode'
		if ! persist_base_config; then
			if restore_uci_state "$backup_dir"; then
				rm -rf "$backup_dir"
				die 'Unable to save managed settings; previous router state was restored'
			fi
			rm -rf "$backup_dir"
			die 'Unable to save managed settings and automatic rollback was incomplete'
		fi
		# Run in a subshell because die() exits the current shell. This keeps the
		# failure catchable here so the UCI snapshot is actually restored.
		if ! ( apply_system ); then
			if restore_uci_state "$backup_dir"; then
				rm -rf "$backup_dir"
				die 'Managed mode failed; previous router state was restored'
			fi
			rm -rf "$backup_dir"
			die 'Managed mode failed and automatic rollback was incomplete'
		fi
		rm -rf "$backup_dir"
	else
		backup_dir="$(backup_uci_state disable-managed)" ||
			die 'Unable to back up router state before disabling managed mode'
		if ! persist_base_config || ! "$0" _remove-managed-inner; then
			if restore_uci_state "$backup_dir"; then
				rm -rf "$backup_dir"
				die 'Managed mode could not be disabled; previous router state was restored'
			fi
			rm -rf "$backup_dir"
			die 'Managed mode disable failed and automatic rollback was incomplete'
		fi
		rm -rf "$backup_dir"
	fi
}

zone_for_network() {
	n="$1"; i=0
	while uci -q get "firewall.@zone[$i]" >/dev/null 2>&1; do
		zname="$(uci -q get "firewall.@zone[$i].name" 2>/dev/null || true)"
		nets="$(uci -q get "firewall.@zone[$i].network" 2>/dev/null || true)"
		for net in $nets; do
			[ "$net" = "$n" ] && { printf '%s' "${zname:-$n}"; return 0; }
		done
		i=$((i + 1))
	done
	printf '%s' "$n"
}

coverage_add() {
	name="$1"
	valid_name "$name" || die 'Invalid network name'
	uci -q get "network.$name" >/dev/null 2>&1 ||
		die "Network '$name' does not exist"
	network_device "$name" >/dev/null || die "Network '$name' has no device"
	zone="$(zone_for_network "$name")"
	zone_exists "$zone" || die "Firewall zone '$zone' does not exist"
	wan_interface="$(getv globals wan_interface)"
	wan_zone="$(getv globals wan_zone)"
	[ -z "$wan_interface" ] || [ "$name" != "$wan_interface" ] ||
		die "WAN network '$name' cannot be a protected network"
	[ -z "$wan_zone" ] || [ "$zone" != "$wan_zone" ] ||
		die "Network '$name' belongs to the WAN firewall zone '$wan_zone'"
	backup_dir="$(backup_uci_state coverage-add)" || die 'Unable to back up router configuration'
	if ! add_list_unique "$config" globals source_interface "$name" ||
	   ! add_list_unique "$config" globals source_zone "$zone" ||
	   ! uci commit "$config" ||
	   ! printf ' %s ' "$(get_list globals source_interface)" | grep -Fq " $name " ||
	   ! printf ' %s ' "$(get_list globals source_zone)" | grep -Fq " $zone " ||
	   { [ "$(getv globals configured)" = 1 ] && ! apply_system; }; then
		if restore_uci_state "$backup_dir"; then
			rm -rf "$backup_dir"
			die 'Unable to add protected network; previous router state was restored'
		fi
		rm -rf "$backup_dir"
		die 'Unable to add protected network and automatic rollback was incomplete'
	fi
	rm -rf "$backup_dir"
}

coverage_remove() {
	name="$1"
	valid_name "$name" || die 'Invalid network name'
	new=''
	for i in $(get_list globals source_interface); do
		[ "$i" = "$name" ] || new="${new:+$new }$i"
	done
	[ -n "$new" ] || die 'At least one protected network must remain'
	zone="$(zone_for_network "$name")"
	keep=0
	for i in $new; do
		[ "$(zone_for_network "$i")" = "$zone" ] && keep=1
	done
	zn="$(get_list globals source_zone)"
	if [ "$keep" = 0 ]; then
		zn=''
		for z in $(get_list globals source_zone); do
			[ "$z" = "$zone" ] || zn="${zn:+$zn }$z"
		done
	fi
	backup_dir="$(backup_uci_state coverage-remove)" || die 'Unable to back up router configuration'
	if ! set_list globals source_interface "$new" ||
	   ! set_list globals source_zone "$zn" ||
	   ! uci commit "$config" ||
	   [ "$(normalize_list "$(get_list globals source_interface)")" != "$new" ] ||
	   [ "$(normalize_list "$(get_list globals source_zone)")" != "$zn" ] ||
	   { [ "$(getv globals configured)" = 1 ] && ! apply_system; }; then
		if restore_uci_state "$backup_dir"; then
			rm -rf "$backup_dir"
			die 'Unable to remove protected network; previous router state was restored'
		fi
		rm -rf "$backup_dir"
		die 'Unable to remove protected network and automatic rollback was incomplete'
	fi
	rm -rf "$backup_dir"
}

run_action() {
	id="$1"
	kind="$2"
	shift 2
	exec >>/tmp/ikev2-system-action.log 2>&1
	printf '\n=== %s action=%s id=%s ===\n' "$(date)" "$kind" "$id"
	action_status "$id" running 'Waiting for other router actions...'
	if ! acquire_action_lock system "$id"; then
		action_status "$id" error 'Another router action is still running.'
		return 1
	fi
	trap 'rm -f "$action_lock_status"; rmdir "$action_lock_dir" 2>/dev/null || true' EXIT INT TERM
	action_status "$id" running 'Applying router configuration...'

	case "$kind" in
		set)
			if ( set_config "$@" ); then
				action_status "$id" ok 'Router configuration applied.'
			else
				action_status "$id" error 'Router apply failed; previous managed configuration was restored.'
			fi
			;;
		coverage-add)
			if ( coverage_add "$1" ); then
				action_status "$id" ok 'Network added to policy routing.'
			else
				action_status "$id" error 'Unable to add the network; see /tmp/ikev2-system-action.log.'
			fi
			;;
		coverage-remove)
			if ( coverage_remove "$1" ); then
				action_status "$id" ok 'Network removed from policy routing.'
			else
				action_status "$id" error 'Unable to remove the network; see /tmp/ikev2-system-action.log.'
			fi
			;;
		device)
			action_status "$id" running 'Applying and verifying device routing...'
			if IKEV2_ACTION_LOCK_HELD=1 /usr/libexec/ikev2-devices "$@"; then
				action_status "$id" ok 'Device routing updated.'
			else
				action_status "$id" error 'Device routing failed; previous PBR configuration was restored.'
			fi
			;;
		dns-set)
			dns_error_file="/tmp/ikev2-dns-action-$id.error"
			rm -f "$dns_error_file"
			action_status "$id" running 'Applying and testing DNS settings...'
			if "$0" _dns-apply-inner "$@" 2>"$dns_error_file"; then
				action_status "$id" ok 'DNS settings applied.'
			else
				cat "$dns_error_file" >&2 2>/dev/null || true
				dns_error="$(tr -d '\r' <"$dns_error_file" 2>/dev/null | tail -n1)"
				[ -n "$dns_error" ] ||
					dns_error='DNS apply failed; check /tmp/ikev2-system-action.log.'
				action_status "$id" error "$dns_error"
			fi
			rm -f "$dns_error_file"
			;;
		dns-segment)
			segment_file="$1"
			if [ ! -f "$segment_file" ] || [ -L "$segment_file" ] || ! {
				IFS= read -r segment_action
				IFS= read -r segment_id
				IFS= read -r segment_name
				IFS= read -r segment_enabled
				IFS= read -r segment_domains
				IFS= read -r segment_protocol
				IFS= read -r segment_mode
				IFS= read -r segment_upstream
				IFS= read -r segment_bootstrap
			} <"$segment_file"; then
				rm -f "$segment_file"
				action_status "$id" error 'Destination DNS segment input is incomplete.'
				return 1
			fi
			segment_fallback="$(sed -n '10p' "$segment_file")"
			segment_https_compat="$(sed -n '11p' "$segment_file")"
			[ -n "$segment_https_compat" ] || segment_https_compat=1
			segment_extra="$(sed -n '12p' "$segment_file")"
			rm -f "$segment_file"
			if [ -n "$segment_extra" ]; then
				action_status "$id" error 'Destination DNS segment input has extra fields.'
				return 1
			fi
			if ( dns_segment_update "$segment_action" "$segment_id" "$segment_name" \
				"$segment_enabled" "$segment_domains" "$segment_protocol" \
				"$segment_mode" "$segment_upstream" "$segment_bootstrap" \
				"$segment_fallback" "$segment_https_compat" ); then
				action_status "$id" ok 'Destination DNS segment applied.'
			else
				action_status "$id" error 'Destination DNS segment failed; previous resolver preserved.'
			fi
			;;
		*)
			action_status "$id" error 'Unknown router action.'
			;;
	esac
}

case "${1:-}" in
	preflight)
		preflight
		;;
	deps-plan)
		verify_install_plan
		printf 'install_plan=ok\n'
		;;
	doctor)
		doctor
		;;
	doctor-ui)
		IKEV2_DOCTOR_SKIP_PROBES=1
		export IKEV2_DOCTOR_SKIP_PROBES
		doctor
		;;
	failclosed-check)
		failclosed_check
		failclosed_ipv6_check
		printf 'failclosed_route=ok\n'
		;;
	install-deps)
		install_deps
		;;
	_install-deps-run)
		run_install_deps "${2:-}"
		;;
	remove-deps)
		remove_deps
		;;
	_remove-deps-run)
		run_remove_deps "${2:-}"
		;;
	deps-status)
		cat "$deps_status_file" 2>/dev/null || true
		;;
	get)
		show_config
		;;
	dns-get)
		dns_show
		;;
	dns-segments-get)
		dns_segments_show
		;;
	dns-segments-check)
		dns_segments_check
		;;
	dns-buffer-status)
		"$device_runtime_helper" dns-malformed-stats
		errors="$(logread 2>/dev/null |
			grep -Fc 'dns: buffer size too small' 2>/dev/null || true)"
		printf 'singbox_errors=%s\n' "${errors:-0}"
		;;
	_doctor-dns-segments-status)
		doctor_dns_segments_status
		;;
	dns-segment-input)
		[ "$#" -eq 2 ] || die 'Expected DNS segment input token'
		dns_segment_input "$2"
		;;
	dns-set-async)
		[ -n "$dns_input_file" ] || dns_input_file="$(input_file_for "${2:-}")"
		dns_set_async
		;;
	_dns-apply-inner)
		shift
		dns_apply "$@"
		;;
	_validate-dns-endpoint)
		[ "$#" -eq 3 ] || die 'Expected: protocol endpoint'
		valid_dns_endpoint "$2" "$3"
		;;
	_firewall-check)
		[ "$#" -eq 1 ] || die 'Expected no arguments'
		firewall_check_strict
		;;
	_upgrade-reconcile)
		[ "$#" -eq 1 ] || die 'Expected no arguments'
		reconcile_upgrade_runtime
		;;
	_validate-dns-segments)
		[ "$#" -eq 1 ] || die 'Expected no arguments'
		validate_dns_segments
		;;
	_dns-segment-update)
		{ [ "$#" -eq 11 ] || [ "$#" -eq 12 ]; } ||
			die 'Expected DNS segment update arguments'
		shift
		dns_segment_update "$@"
		;;
	_dns-combined-upstreams)
		[ "$#" -eq 2 ] || die 'Expected a base DNS upstream'
		dns_combined_upstreams "$2"
		;;
	_dns-runtime-timeout)
		[ "$#" -eq 2 ] || die 'Expected fallback state'
		dns_runtime_timeout "$2"
		;;
	_dnsmasq-combined-servers)
		[ "$#" -eq 2 ] || die 'Expected a base dnsmasq server'
		dnsmasq_combined_servers "$2"
		;;
	set)
		shift
		set_config "$@"
		;;
	set-async)
		shift
		start_action set "$@"
		;;
	apply)
		apply_system
		;;
	_apply-system-inner)
		apply_system_inner
		;;
	_remove-managed-inner)
		remove_managed
		;;
	_disable-managed-inner)
		uci set "$config.globals.configured=0"
		uci commit "$config"
		remove_managed
		;;
	_sync-pbr)
		sync_pbr
		;;
	_sync-firewall)
		# Drop legacy UCI redirects and refresh the dedicated atomic nftables
		# runtime that owns DNS interception and per-device bypasses.
		sync_firewall
		firewall_check_strict || die 'Firewall validation failed'
		fw4 -q reload || die 'Unable to reload the firewall'
		sync_device_runtime || die 'Device DNS policy failed to load'
		;;
	server-apply)
		apply_server_runtime_transaction "${2:-0}"
		;;
	_server-apply-inner)
		apply_server_runtime "${2:-0}"
		;;
	validate-server-zones)
		[ "$#" -eq 3 ] || die 'Expected: validate-server-zones inbound outbound'
		validate_server_zone_names "$2" "$3"
		;;
	strongswan-security)
		[ "$#" -eq 2 ] || die 'Expected: strongswan-security client|server'
		strongswan_security_check "$2"
		;;
	_upnp-check)
		upnp_ikev2_check
		;;
	access-apply)
		zone="$(defaultv server firewall_zone ikev2in)"
		zone_exists "$zone" ||
			die "Inbound firewall zone '$zone' does not exist"
		sync_inbound_access
		firewall_check_strict
		fw4 -q reload
		sync_device_runtime || die 'Device policy failed to load'
		sync_inbound_user_policy ||
			die 'Inbound user policy failed to load'
		;;
	disable)
		disable_managed ||
			die 'Unable to disable managed mode; previous state was preserved or restored'
		;;
	gateway-network)
		gateway_network
		;;
	coverage-add)
		coverage_add "${2:-}"
		;;
	coverage-remove)
		coverage_remove "${2:-}"
		;;
	coverage-async)
		[ "$#" -eq 3 ] || die 'Expected: coverage-async add|remove network'
		case "$2" in
			add) start_action coverage-add "$3" ;;
			remove) start_action coverage-remove "$3" ;;
			*) die 'Expected coverage action: add or remove' ;;
		esac
		;;
	device-async)
		shift
		case "${1:-}" in
			add-subnet | remove-subnet | remove-override | set-unmanaged | set-included | clear-policy)
				[ "$#" -eq 2 ] || die 'Expected device action and address'
				;;
			add-override)
				[ "$#" -eq 3 ] || die 'Expected add-override address mode'
				;;
			set-flag)
				[ "$#" -eq 4 ] || die 'Expected set-flag address flag value'
				;;
			set-exclusions)
				[ "$#" -eq 5 ] ||
					die 'Expected set-exclusions address pbr dns zapret'
				;;
			*) die 'Unsupported device action' ;;
		esac
		start_action device "$@"
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
	*)
		die 'Usage: ikev2-manager-system {preflight|deps-plan|doctor|doctor-ui|failclosed-check|install-deps|remove-deps|deps-status|get|dns-get|dns-buffer-status|dns-set-async|set|set-async|apply|server-apply|validate-server-zones|strongswan-security|access-apply|disable|gateway-network|coverage-add|coverage-remove|coverage-async|device-async|action-status}'
		;;
esac
