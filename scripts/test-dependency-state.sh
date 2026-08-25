#!/bin/sh

set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM

installed='base-files dnsmasq libc'
TEST_MANAGER=test

pkg_manager_name() { printf '%s\n' "$TEST_MANAGER"; }
pkg_dnsmasq_provider() { printf 'dnsmasq\n'; }
pkg_list_installed_names() {
	for package in $installed; do printf '%s\n' "$package"; done | sort -u
}
pkg_added_since() {
	snapshot="$1"
	current="${snapshot}.current"
	pkg_list_installed_names >"$current"
	awk 'NR == FNR { before[$1] = 1; next } !before[$1] { print $1 }' \
		"$snapshot" "$current"
	rm -f "$current"
}
pkg_installed() {
	case " $installed " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}
pkg_remove_runtime() {
	local next package remove
	next=''
	for package in $installed; do
		remove=0
		for target in "$@"; do
			[ "$package" != "$target" ] || remove=1
		done
		[ "$package" = shared-package ] && remove=0
		[ "$remove" = 1 ] || next="${next}${next:+ }$package"
	done
	installed="$next"
}
runtime_packages() { printf '%s\n' pbr strongswan; }

IKEV2_DEPS_STATE_DIR="$tmp/state"
IKEV2_DEPS_DHCP_FILE="$tmp/dhcp"
IKEV2_OPENWRT_RELEASE_FILE="$tmp/openwrt_release"
export IKEV2_DEPS_STATE_DIR IKEV2_DEPS_DHCP_FILE IKEV2_OPENWRT_RELEASE_FILE
printf 'config dnsmasq\n' >"$IKEV2_DEPS_DHCP_FILE"
cat >"$IKEV2_OPENWRT_RELEASE_FILE" <<'EOF'
DISTRIB_RELEASE='25.12.5'
DISTRIB_TARGET='mediatek/filogic'
EOF

# shellcheck source=/dev/null
. "$root/ikev2-manager-runtime/lib/dependency-state.sh"

deps_state_capture
[ "$(deps_state_version)" = 3 ]
grep -Fxq 'manager=test' "$(deps_state_file metadata)"
grep -Fxq 'release=25.12.5' "$(deps_state_file metadata)"
grep -Fxq 'target=mediatek/filogic' "$(deps_state_file metadata)"
grep -Fxq base-files "$(deps_state_file before-packages)"
grep -Fxq dnsmasq "$(deps_state_file before-packages)"
[ ! -s "$(deps_state_file owned-packages)" ]

operation_snapshot="$tmp/operation.before"
pkg_list_installed_names >"$operation_snapshot"
installed="$installed dnsmasq-full pbr strongswan libtransitive"
deps_state_record_added_since "$operation_snapshot"
for package in dnsmasq-full pbr strongswan libtransitive; do
	grep -Fxq "$package" "$(deps_state_file owned-packages)"
done
if grep -Fxq base-files "$(deps_state_file owned-packages)"; then
	printf '%s\n' 'pre-existing package was marked as application-owned' >&2
	exit 1
fi

installed="$installed admin-tool"
if grep -Fxq admin-tool "$(deps_state_file owned-packages)"; then
	printf '%s\n' 'package installed outside the transaction was marked as application-owned' >&2
	exit 1
fi

repair_snapshot="$tmp/repair.before"
pkg_list_installed_names >"$repair_snapshot"
installed="$installed repair-dependency"
deps_state_record_added_since "$repair_snapshot"
grep -Fxq repair-dependency "$(deps_state_file owned-packages)"
if grep -Fxq admin-tool "$(deps_state_file owned-packages)"; then
	printf '%s\n' 'administrator package was captured during a later repair' >&2
	exit 1
fi

deps_state_mark_installed
deps_state_ready
deps_state_platform_matches
TEST_MANAGER=other
if deps_state_platform_matches; then
	printf '%s\n' 'package-manager change did not invalidate dependency ownership' >&2
	exit 1
fi
TEST_MANAGER=test

# A version-1 state contains only the old explicit package subset. Never diff
# it against the complete package inventory or base system packages look owned.
cat >"$(deps_state_file metadata)" <<'EOF'
version=1
state=installed
dns_provider=dnsmasq
EOF
printf 'pbr\n' >"$(deps_state_file before-packages)"
printf 'strongswan\n' >"$(deps_state_file owned-packages)"
[ "$(cat "$(deps_state_file owned-packages)")" = strongswan ]
deps_state_ready
deps_state_upgrade_v1
[ "$(deps_state_version)" = 3 ]
[ "$(cat "$(deps_state_file owned-packages)")" = strongswan ]

# The package manager may retain an app-installed package after another
# application starts depending on it. That is a safe restore, not a failure.
cat >"$(deps_state_file metadata)" <<'EOF'
version=3
state=installed
dns_provider=dnsmasq
manager=test
release=25.12.5
target=mediatek/filogic
EOF
deps_shared_package_required() { [ "$1" = shared-hook ]; }
printf 'app-only\nshared-hook\nshared-package\n' >"$(deps_state_file owned-packages)"
installed='base-files dnsmasq libc app-only shared-hook shared-package'
deps_state_restore
[ "$deps_state_retained" = "shared-hook
shared-package" ]
if pkg_installed app-only; then
	printf '%s\n' 'application-only package survived dependency restore' >&2
	exit 1
fi
pkg_installed shared-package
pkg_installed shared-hook

sed 's/^version=3$/version=2/' "$(deps_state_file metadata)" >"$(deps_state_file metadata).new"
mv "$(deps_state_file metadata).new" "$(deps_state_file metadata)"
if deps_state_ready || deps_state_platform_matches; then
	printf '%s\n' 'unsafe version-2 ownership record was accepted' >&2
	exit 1
fi

printf '%s\n' 'dependency state tests OK'
