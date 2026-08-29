#!/bin/sh

set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
system="$root/ikev2-manager-runtime/ikev2-manager-system.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM

{
	sed -n '/^doctor_ui_cache_invalidate() {/,/^}/p' "$system"
	sed -n '/^doctor_ui_report() {/,/^}/p' "$system"
} >"$tmp/functions.sh"

doctor_ui_cache_file="$tmp/doctor.cache"
doctor_calls="$tmp/doctor.calls"
doctor() {
	printf '%s\n' call >>"$doctor_calls"
	printf '%s\n' 'dependencies_ok=1'
}

. "$tmp/functions.sh"
doctor_ui_report >"$tmp/first"
doctor_ui_report >"$tmp/second"
cmp -s "$tmp/first" "$tmp/second"
[ "$(wc -l <"$doctor_calls" | tr -d ' ')" = 1 ]
grep -Fxq 'diagnostic_status=ok' "$tmp/second"

doctor_ui_cache_invalidate
doctor_ui_report >"$tmp/third"
[ "$(wc -l <"$doctor_calls" | tr -d ' ')" = 2 ]

printf '%s\n' 'doctor UI cache tests OK'
