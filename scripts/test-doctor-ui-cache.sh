#!/bin/sh

set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM
# The system helper's source is the script plus the libraries it sources.
system="$tmp/system-source.sh"
cat "$root/ikev2-manager-runtime/ikev2-manager-system.sh" \
	"$root"/ikev2-manager-runtime/lib/system-*.sh >"$system"

{
	sed -n '/^doctor_ui_cache_invalidate() {/,/^}/p' "$system"
	sed -n '/^doctor_ui_write_cache() {/,/^}/p' "$system"
	sed -n '/^doctor_ui_report() {/,/^}/p' "$system"
} >"$tmp/functions.sh"

doctor_ui_cache_file="$tmp/doctor.cache"
doctor_calls="$tmp/doctor.calls"
doctor() {
	printf '%s\n' call >>"$doctor_calls"
	printf '%s\n' 'dependencies_ok=1'
}

. "$tmp/functions.sh"
refreshes="$tmp/refresh.calls"
: >"$refreshes"
doctor_ui_refresh_background() { printf '%s\n' refresh >>"$refreshes"; }
doctor_ui_report >"$tmp/first"
doctor_ui_report >"$tmp/second"
cmp -s "$tmp/first" "$tmp/second"
[ "$(wc -l <"$doctor_calls" | tr -d ' ')" = 1 ]
grep -Fxq 'diagnostic_status=ok' "$tmp/second"

doctor_ui_cache_invalidate
doctor_ui_report >"$tmp/third"
[ "$(wc -l <"$doctor_calls" | tr -d ' ')" = 2 ]
[ ! -s "$refreshes" ] || { echo 'a fresh or missing report started a background refresh' >&2; exit 1; }

# An expired report is shown at once and replaced in the background: the page
# does not wait for the full report again.
touch -t 202001010000 "$doctor_ui_cache_file"
doctor_ui_report >"$tmp/stale"
cmp -s "$tmp/third" "$tmp/stale" || { echo 'the expired report was not served' >&2; exit 1; }
[ "$(wc -l <"$doctor_calls" | tr -d ' ')" = 2 ] || {
	echo 'the page waited for a full report although one was stored' >&2
	exit 1
}
[ "$(wc -l <"$refreshes" | tr -d ' ')" = 1 ] || {
	echo 'an expired report was not refreshed in the background' >&2
	exit 1
}

printf '%s\n' 'doctor UI cache tests OK'
