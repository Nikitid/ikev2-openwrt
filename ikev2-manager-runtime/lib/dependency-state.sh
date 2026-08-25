#!/bin/sh

# Persistent ownership record for the runtime dependency transaction. It lets
# removal restore only packages that this application added.
deps_state_dir="${IKEV2_DEPS_STATE_DIR:-/etc/ikev2-manager/deps-state}"
deps_state_dhcp_file="${IKEV2_DEPS_DHCP_FILE:-/etc/config/dhcp}"
deps_state_release_file="${IKEV2_OPENWRT_RELEASE_FILE:-/etc/openwrt_release}"

deps_state_file() {
	printf '%s/%s\n' "$deps_state_dir" "$1"
}

deps_state_has() {
	local file
	file="$(deps_state_file "$1")"
	grep -Fxq "$2" "$file" 2>/dev/null
}

deps_state_value() {
	local key
	key="$1"
	sed -n "s/^${key}=//p" "$(deps_state_file metadata)" 2>/dev/null | head -n1
}

deps_state_version() {
	local version
	version="$(deps_state_value version)"
	printf '%s\n' "${version:-1}"
}

deps_state_current_platform() {
	local manager release target
	manager="$(pkg_manager_name 2>/dev/null || true)"
	release='unknown'
	target='unknown'
	if [ -r "$deps_state_release_file" ]; then
		DISTRIB_RELEASE=''
		DISTRIB_TARGET=''
		. "$deps_state_release_file"
		release="${DISTRIB_RELEASE:-unknown}"
		target="${DISTRIB_TARGET:-unknown}"
	fi
	printf 'manager=%s\nrelease=%s\ntarget=%s\n' \
		"${manager:-unknown}" "$release" "$target"
}

deps_state_platform_matches() {
	local current key stored actual
	case "$(deps_state_version)" in
		1) return 0 ;;
		3) ;;
		*) return 1 ;;
	esac
	current="$(deps_state_current_platform)"
	for key in manager release target; do
		stored="$(deps_state_value "$key")"
		actual="$(printf '%s\n' "$current" | sed -n "s/^${key}=//p")"
		[ -n "$stored" ] && [ "$stored" = "$actual" ] || return 1
	done
}

deps_state_captured() {
	local state
	state="$(deps_state_value state)"
	case "$state" in installing | installed) ;; *) return 1 ;; esac
	[ -n "$(deps_state_value dns_provider)" ] &&
	[ -r "$(deps_state_file before-packages)" ] &&
	[ -r "$(deps_state_file owned-packages)" ] &&
	[ -r "$(deps_state_file dhcp.before)" ]
}

deps_state_ready() {
	deps_state_captured && [ "$(deps_state_value state)" = installed ] &&
		case "$(deps_state_version)" in 1 | 3) return 0 ;; *) return 1 ;; esac
}

deps_state_capture() {
	local provider parent tmp platform
	deps_state_ready && return 0
	[ ! -e "$deps_state_dir" ] || return 1
	provider="$(pkg_dnsmasq_provider || true)"
	[ -n "$provider" ] || return 1
	[ -r "$deps_state_dhcp_file" ] || return 1

	parent="${deps_state_dir%/*}"
	tmp="${deps_state_dir}.new.$$"
	mkdir -p "$parent" || return 1
	rm -rf "$tmp"
	( umask 077; mkdir -p "$tmp" ) || return 1

	pkg_list_installed_names >"$tmp/before-packages" || {
		rm -rf "$tmp"
		return 1
	}
	: >"$tmp/owned-packages"
	cp "$deps_state_dhcp_file" "$tmp/dhcp.before" || {
		rm -rf "$tmp"
		return 1
	}
	platform="$(deps_state_current_platform)"
	cat >"$tmp/metadata" <<EOF
version=3
state=installing
dns_provider=$provider
$platform
EOF
	rm -rf "$deps_state_dir"
	mv "$tmp" "$deps_state_dir"
}

deps_state_mark_installed() {
	local provider metadata manager release target
	[ -r "$(deps_state_file metadata)" ] || return 1
	provider="$(deps_state_value dns_provider)"
	[ -n "$provider" ] || return 1
	metadata="$(deps_state_file metadata)"
	manager="$(deps_state_value manager)"
	release="$(deps_state_value release)"
	target="$(deps_state_value target)"
	cat >"${metadata}.new.$$" <<EOF
version=$(deps_state_version)
state=installed
dns_provider=$provider
manager=$manager
release=$release
target=$target
EOF
	mv "${metadata}.new.$$" "$metadata"
}

deps_state_upgrade_v1() {
	local provider platform metadata
	[ "$(deps_state_version)" = 1 ] || return 0
	deps_state_ready || return 1
	provider="$(deps_state_value dns_provider)"
	platform="$(deps_state_current_platform)"
	metadata="$(deps_state_file metadata)"
	cat >"${metadata}.new.$$" <<EOF
version=3
state=installed
dns_provider=$provider
$platform
EOF
	mv "${metadata}.new.$$" "$metadata"
}

deps_state_store_dnsmasq_package() {
	local package_file
	package_file="$1"
	deps_state_captured || return 1
	[ -s "$package_file" ] || return 1
	mkdir -p "$(deps_state_file packages)" || return 1
	cp "$package_file" "$(deps_state_file packages)/${package_file##*/}.new" || return 1
	mv "$(deps_state_file packages)/${package_file##*/}.new" \
		"$(deps_state_file packages)/${package_file##*/}"
}

deps_state_record_owned_names() {
	deps_state_captured || return 1
	local owned tmp package
	owned="$(deps_state_file owned-packages)"
	tmp="${owned}.new.$$"
	cp "$owned" "$tmp" || return 1
	for package in "$@"; do
		[ -n "$package" ] || continue
		deps_state_has before-packages "$package" && continue
		deps_state_has owned-packages "$package" && continue
		printf '%s\n' "$package" >>"$tmp"
	done
	# BusyBox sort has no -o; it would print the list on stdout and leave the
	# file unsorted.
	sort -u "$tmp" >"${tmp}.sorted" || { rm -f "$tmp" "${tmp}.sorted"; return 1; }
	mv "${tmp}.sorted" "$tmp"
	mv "$tmp" "$owned"
}

deps_state_record_added_since() {
	local snapshot owned added tmp
	snapshot="$1"
	deps_state_captured || return 1
	[ "$(deps_state_version)" = 3 ] || return 1
	[ -s "$snapshot" ] || return 1
	owned="$(deps_state_file owned-packages)"
	added="${owned}.added.$$"
	tmp="${owned}.new.$$"
	pkg_added_since "$snapshot" >"$added" || {
		rm -f "$added" "$tmp"
		return 1
	}
	cat "$owned" "$added" | sed '/^$/d' | sort -u >"$tmp" || {
		rm -f "$added" "$tmp"
		return 1
	}
	rm -f "$added"
	mv "$tmp" "$owned"
}

deps_state_record_owned() {
	[ "$(deps_state_version)" = 1 ] || return 1
	deps_state_record_owned_names "$@"
}

deps_state_clear() {
	rm -rf "$deps_state_dir"
}

deps_state_remaining() {
	local file package
	file="$(deps_state_file owned-packages)"
	[ -r "$file" ] || return 1
	while IFS= read -r package; do
		[ -n "$package" ] || continue
		pkg_installed "$package" && printf '%s\n' "$package"
	done <"$file"
}

deps_state_restore() {
	local provider owned restore_provider current_provider packages package shared_retained remaining
	deps_state_retained=''
	# Restore is also valid while an installation is in progress. This is the
	# state in which every installer failure and interrupted retry must roll back.
	deps_state_captured || return 1
	deps_state_platform_matches || return 1
	provider="$(deps_state_value dns_provider)"
	[ -n "$provider" ] || return 1
	owned="$(deps_state_file owned-packages)"

	restore_provider=0
	if [ "$(deps_state_version)" = 3 ]; then
		current_provider="$(pkg_dnsmasq_provider || true)"
		[ "$current_provider" = "$provider" ] || restore_provider=1
	elif deps_state_has owned-packages dnsmasq-full; then
		restore_provider=1
	fi
	# Another application may rely on the nftset-capable resolver that Manager
	# originally installed. The embedding runtime supplies this optional hook;
	# dependency removal must not replace a shared live DNS provider merely to
	# reproduce Manager's historical package snapshot.
	if command -v deps_shared_dnsmasq_required >/dev/null 2>&1 &&
	   deps_shared_dnsmasq_required; then
		restore_provider=0
	fi
	if [ "$restore_provider" = 1 ]; then
		pkg_restore_dnsmasq "$(deps_state_file packages)" "$provider" || return 1
		cp "$(deps_state_file dhcp.before)" "$deps_state_dhcp_file" || return 1
		rm -f "${deps_state_dhcp_file}.apk-new" "${deps_state_dhcp_file}-opkg"
		/etc/init.d/dnsmasq restart >/dev/null 2>&1 || return 1
	fi

	packages=''
	shared_retained=''
	while IFS= read -r package; do
		[ -n "$package" ] && [ "$package" != dnsmasq-full ] || continue
		if command -v deps_shared_package_required >/dev/null 2>&1 &&
		   deps_shared_package_required "$package"; then
			shared_retained="${shared_retained}${shared_retained:+ }$package"
		else
			packages="${packages}${packages:+ }$package"
		fi
	done <"$owned"
	[ -z "$packages" ] || pkg_remove_runtime $packages || return 1
	if deps_state_has owned-packages dnsproxy &&
	   [ "$(uci -q get dhcp.@dnsmasq[0].server 2>/dev/null || true)" = '127.0.0.1#5453' ]; then
		uci -q delete dhcp.@dnsmasq[0].server || true
		uci -q delete dhcp.@dnsmasq[0].noresolv || true
		uci commit dhcp || return 1
		/etc/init.d/dnsmasq restart >/dev/null 2>&1 || return 1
	fi

	# A package installed by this app may have become a dependency of another
	# application in the meantime. A successful package-manager transaction is
	# authoritative: keep such shared packages instead of treating the safe
	# solver decision as a failed rollback.
	remaining="$(deps_state_remaining || true)"
	deps_state_retained="$({
		printf '%s\n' $shared_retained
		printf '%s\n' "$remaining"
	} | sed '/^$/d' | sort -u)"
	if [ "$restore_provider" = 1 ]; then
		pkg_installed "$provider" || return 1
	fi
}
