#!/bin/sh
# Package-manager compatibility helpers for OpenWrt 24.10 (opkg) and
# OpenWrt 25.12+ (apk). Callers keep policy decisions; this file only hides
# command syntax differences.

pkg_manager_detect() {
	if command -v apk >/dev/null 2>&1 &&
		{ [ -r /etc/apk/repositories ] || [ -d /etc/apk/repositories.d ]; }; then
		printf 'apk\n'
	elif command -v opkg >/dev/null 2>&1; then
		printf 'opkg\n'
	elif command -v apk >/dev/null 2>&1; then
		printf 'apk\n'
	else
		printf 'missing\n'
	fi
}

pkg_manager_name() {
	printf '%s\n' "${IKEV2_PACKAGE_MANAGER:-$(pkg_manager_detect)}"
}

pkg_manager_supported() {
	case "$(pkg_manager_name)" in
		opkg | apk) return 0 ;;
		*) return 1 ;;
	esac
}

pkg_update() {
	case "$(pkg_manager_name)" in
		opkg) opkg update ;;
		apk) apk update ;;
		*) return 1 ;;
	esac
}

pkg_install_plan() {
	case "$(pkg_manager_name)" in
		opkg) opkg install --noaction "$@" ;;
		apk) apk add --simulate "$@" ;;
		*) return 1 ;;
	esac
}

# Dependency repair is allowed to add missing packages, not to use them as a
# reason to upgrade, downgrade or remove an existing runtime. Package-manager
# exit status alone does not express that policy: both apk and opkg happily
# return success for a plan that changes already installed libraries.
pkg_install_plan_safe() {
	local output status bad allow_dns_swap
	allow_dns_swap="${PKG_PLAN_ALLOW_DNSMASQ_SWAP:-0}"
	output="$(pkg_install_plan "$@" 2>&1)" || status=$?
	status="${status:-0}"
	printf '%s\n' "$output"
	[ "$status" -eq 0 ] || return "$status"
	bad="$(printf '%s\n' "$output" | awk -v allow_dns="$allow_dns_swap" '
		{
			line=tolower($0)
			if (line !~ /(upgrad|downgrad|reinstall|replace|remov|purge)/) next
			if (allow_dns == 1 && line ~ /dnsmasq/ && line !~ /(upgrad|downgrad|reinstall)/)
				next
			print
		}
	')"
	[ -z "$bad" ] || {
		printf 'Unsafe package plan changes installed packages:\n%s\n' "$bad" >&2
		return 1
	}
}

pkg_install() {
	case "$(pkg_manager_name)" in
		opkg) opkg install "$@" ;;
		apk) apk add "$@" ;;
		*) return 1 ;;
	esac
}

pkg_remove_runtime() {
	packages=''
	for package in "$@"; do
		if pkg_installed "$package"; then
			packages="${packages}${packages:+ }$package"
		fi
	done
	[ -n "$packages" ] || return 0
	set -- $packages
	case "$(pkg_manager_name)" in
		opkg) opkg remove "$@" ;;
		apk) apk del "$@" ;;
		*) return 1 ;;
	esac
}

pkg_remove_dnsmasq_provider() {
	case "$(pkg_manager_name)" in
		opkg) opkg remove --force-depends "$1" ;;
		apk) apk del "$1" ;;
		*) return 1 ;;
	esac
}

pkg_download() {
	case "$(pkg_manager_name)" in
		opkg) opkg download "$@" ;;
		apk) apk fetch "$@" ;;
		*) return 1 ;;
	esac
}

pkg_installed() {
	case "$(pkg_manager_name)" in
		opkg) opkg list-installed "$1" 2>/dev/null | grep -q "^$1 " ;;
		apk) apk info -e "$1" >/dev/null 2>&1 ;;
		*) return 1 ;;
	esac
}

pkg_list_installed_names() {
	case "$(pkg_manager_name)" in
		opkg) listing="$(opkg list-installed 2>/dev/null)" || return 1 ;;
		apk) listing="$(apk list --installed --manifest 2>/dev/null)" || return 1 ;;
		*) return 1 ;;
	esac
	[ -n "$listing" ] || return 1
	printf '%s\n' "$listing" | awk 'NF { print $1 }' | sort -u
}

pkg_added_since() {
	snapshot="$1"
	[ -s "$snapshot" ] || return 1
	current="${snapshot}.current.$$"
	pkg_list_installed_names >"$current" || { rm -f "$current"; return 1; }
	awk 'NR == FNR { before[$1] = 1; next } !before[$1] { print $1 }' \
		"$snapshot" "$current"
	rm -f "$current"
}

pkg_remove_added_since() {
	snapshot="$1"
	added="$(pkg_added_since "$snapshot")" || return 1
	[ -z "$added" ] || pkg_remove_runtime $added
}

pkg_version() {
	case "$(pkg_manager_name)" in
		opkg)
			opkg status "$1" 2>/dev/null | sed -n 's/^Version: //p' | head -n1
			;;
		apk)
			apk list --installed --manifest "$1" 2>/dev/null |
				awk -v package="$1" '$1 == package { print $2; exit }'
			;;
	esac
}

pkg_version_at_least() {
	local package minimum installed
	package="$1"
	minimum="$2"
	installed="$(pkg_version "$package")"
	[ -n "$installed" ] || return 1
	case "$(pkg_manager_name)" in
		opkg) opkg compare-versions "$installed" ge "$minimum" ;;
		apk) [ "$(apk version -t "$installed" "$minimum" 2>/dev/null)" != '<' ] ;;
		*) return 1 ;;
	esac
}

pkg_package_file() {
	dir="$1"
	name="$2"
	case "$(pkg_manager_name)" in
		opkg) find "$dir" -name "${name}_*.ipk" -print 2>/dev/null | head -n1 ;;
		apk)
			prefix="${name}-"
			find "$dir" -name "${name}-*.apk" -print 2>/dev/null |
				while IFS= read -r package_file; do
					file_name="${package_file##*/}"
					version="${file_name#$prefix}"
					case "$version" in
						[0-9]*) printf '%s\n' "$package_file"; break ;;
					esac
				done
			;;
	esac
}

pkg_dnsmasq_provider() {
	for package in dnsmasq-full dnsmasq-dhcpv6 dnsmasq; do
		if pkg_installed "$package"; then
			printf '%s\n' "$package"
			return 0
		fi
	done
	return 1
}

pkg_dnsmasq_has_nftset() {
	dnsmasq -v 2>&1 | tr ' ' '\n' | grep -qx nftset
}

pkg_switch_dnsmasq_full() {
	cache="$1"
	current_provider="$2"
	case "$(pkg_manager_name)" in
		opkg)
			full_pkg="$(pkg_package_file "$cache" dnsmasq-full)"
			[ -n "$full_pkg" ] && [ -s "$full_pkg" ] || return 1
				pkg_remove_dnsmasq_provider "$current_provider" && pkg_install "$full_pkg"
			;;
		apk)
			# Installing by feed package name keeps repository trust. A file
			# produced by `apk fetch` is treated as a standalone package and
			# is rejected as untrusted even when its feed index was trusted.
			pkg_install dnsmasq-full
			;;
		*) return 1 ;;
	esac
}

pkg_restore_dnsmasq() {
	cache="$1"
	previous_provider="$2"
	case "$(pkg_manager_name)" in
		opkg)
			previous_pkg="$(pkg_package_file "$cache" "$previous_provider")"
			[ -n "$previous_pkg" ] && [ -s "$previous_pkg" ] || return 1
			if pkg_installed dnsmasq-full; then
					pkg_remove_dnsmasq_provider dnsmasq-full || return 1
			fi
			pkg_install "$previous_pkg"
			;;
		apk)
			# Let apk solve the provider replacement before removing anything.
			# This avoids leaving the router without DNS if repository access or
			# dependency resolution fails while restoring the original package.
			pkg_installed "$previous_provider" ||
				pkg_install "$previous_provider" || return 1
			if [ "$previous_provider" != dnsmasq-full ] && pkg_installed dnsmasq-full; then
				pkg_remove_dnsmasq_provider dnsmasq-full || return 1
			fi
			pkg_installed "$previous_provider"
			;;
		*) return 1 ;;
	esac
}

pkg_feed_file_matches() {
	pattern="$1"
	shift
	for file in "$@"; do
		[ -r "$file" ] || continue
		grep -qE "$pattern" "$file" && return 0
	done
	return 1
}

pkg_release_feed_ok() {
	release="$1"
	case "$(pkg_manager_name):$release" in
		opkg:24.10.*)
			pkg_feed_file_matches 'downloads\.openwrt\.org/releases/24\.10\.' \
				/etc/opkg/distfeeds.conf
			;;
		apk:25.12.*)
			pkg_feed_file_matches \
				'downloads\.openwrt\.org/releases/(25\.12\.|packages-25\.12)' \
				/etc/apk/repositories /etc/apk/repositories.d/*
			;;
		*) return 1 ;;
	esac
}
