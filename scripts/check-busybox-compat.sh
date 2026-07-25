#!/bin/sh

# Router-side scripts run against BusyBox applets, not GNU coreutils. Developer
# machines and CI runners provide the GNU versions, so a GNU-only option is
# accepted locally and every test passes while the router silently does
# something else. The confirmed example is `sort -o`: BusyBox is built without
# CONFIG_FEATURE_SORT_BIG, ignores the option, leaves the target file untouched
# and writes the sorted result to stdout instead. That corrupted the inbound
# user-policy sets and leaked list contents into command output.
#
# Only patterns verified against the supported OpenWrt BusyBox build belong
# here.

set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
cd "$root"

status=0

report() {
	printf 'busybox-compat: %s\n' "$1" >&2
	status=1
}

shipped_scripts() {
	find ikev2-manager-runtime luci-ikev2-manager luci-ikev2-domains \
		-type f \( -name '*.sh' -o -name '*.init' -o -name 'pbr.user.*' \) |
		sort
}

check_pattern() {
	pattern="$1"
	message="$2"
	exclude="${3:-}"
	shipped_scripts | while IFS= read -r file; do
		grep -nE "$pattern" "$file" | while IFS= read -r hit; do
			[ -n "$exclude" ] &&
				printf '%s' "$hit" | grep -qE "$exclude" && continue
			printf '%s:%s\n' "$file" "$hit"
		done
	done >"$work/hits"
	[ -s "$work/hits" ] || return 0
	while IFS= read -r hit; do
		report "$message: $hit"
	done <"$work/hits"
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT INT TERM

# BusyBox sort: Usage: sort [-nru] [FILE]...
check_pattern '(^|[;&|[:space:]])sort([[:space:]]+-[A-Za-z]+)*[^|;&]*[[:space:]]-o([[:space:]]|$)' \
	'BusyBox sort does not support -o; write to a temporary file and mv it'

# BusyBox grep has no PCRE support.
check_pattern '(^|[;&|[:space:]])grep([[:space:]]+-[A-Za-z]*P)' \
	'BusyBox grep does not support -P'

# BusyBox find has no -printf.
check_pattern '(^|[;&|[:space:]])find[^|;&]*[[:space:]]-printf([[:space:]]|$)' \
	'BusyBox find does not support -printf'

# The base64 applet is not present in the supported build; openssl provides it.
check_pattern '(^|[;&|[:space:]])base64([[:space:]]|$)' \
	'the base64 applet is unavailable on OpenWrt; use openssl base64' \
	'openssl[[:space:]]+base64'

if [ "$status" = 0 ]; then
	printf 'busybox-compat OK\n'
fi

exit "$status"
