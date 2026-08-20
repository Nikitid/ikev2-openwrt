#!/bin/sh

set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
health="$root/ikev2-manager-runtime/ikev2-health.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM

if IKEV2_RUNTIME_LIB_DIR="$root/ikev2-manager-runtime/lib" \
	sh "$health" status >"$tmp/out" 2>"$tmp/err"; then
	printf '%s\n' 'health watcher accepted an unsupported argument' >&2
	exit 1
else
	status=$?
fi
[ "$status" -eq 2 ]
grep -Fxq 'usage: ikev2-health' "$tmp/err"

lock="$tmp/health.lock"
mkdir "$lock"
printf '%s\n' "$$" >"$lock/pid"
if IKEV2_RUNTIME_LIB_DIR="$root/ikev2-manager-runtime/lib" \
	IKEV2_HEALTH_LOCK="$lock" sh "$health" >"$tmp/out" 2>"$tmp/err"; then
	printf '%s\n' 'health watcher started while a live owner held its lock' >&2
	exit 1
fi
grep -Fxq 'ikev2-health is already running' "$tmp/err"
[ "$(cat "$lock/pid")" = "$$" ]

printf '%s\n' 'health entrypoint checks OK'
