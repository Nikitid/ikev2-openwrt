#!/bin/sh

set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
router="$root/ikev2-manager-runtime/ikev2-domain-router.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM

sed -n '/^with_lock() {/,/^}/p' "$router" >"$tmp/function.sh"

# A transient health owner releases the lock during the bounded wait. The
# foreground transaction must then run exactly once and release its own lock.
(
	lock_dir="$tmp/transient.lock"
	state_file="$tmp/transient.status"
	attempts_file="$tmp/transient.attempts"
	: >"$attempts_file"
	pid_lock_acquire() {
		printf 'try\n' >>"$attempts_file"
		[ "$(wc -l <"$attempts_file" | tr -d ' ')" -ge 3 ]
	}
	pid_lock_release() { printf 'released\n' >>"$attempts_file"; }
	write_status() { printf '%s:%s\n' "$1" "$2" >"$state_file"; }
	sleep() { :; }
	operation() { printf 'ran\n' >>"$attempts_file"; }
	. "$tmp/function.sh"
	IKEV2_DOMAIN_LOCK_WAIT_SECONDS=3 with_lock operation
	[ "$(grep -c '^try$' "$attempts_file")" -eq 3 ]
	grep -Fxq 'ran' "$attempts_file"
	grep -Fxq 'released' "$attempts_file"
	[ ! -e "$state_file" ]
)

# A persistent owner remains a visible error after the configured bound; the
# protected operation must never execute.
(
	lock_dir="$tmp/stuck.lock"
	state_file="$tmp/stuck.status"
	attempts_file="$tmp/stuck.attempts"
	: >"$attempts_file"
	pid_lock_acquire() { printf 'try\n' >>"$attempts_file"; return 1; }
	pid_lock_release() { printf 'released\n' >>"$attempts_file"; }
	write_status() { printf '%s:%s\n' "$1" "$2" >"$state_file"; }
	sleep() { :; }
	operation() { printf 'ran\n' >>"$attempts_file"; }
	. "$tmp/function.sh"
	if IKEV2_DOMAIN_LOCK_WAIT_SECONDS=2 with_lock operation; then
		printf '%s\n' 'stuck domain lock was accepted' >&2
		exit 1
	fi
	[ "$(grep -c '^try$' "$attempts_file")" -eq 3 ]
	grep -Fxq 'error:Another domain-routing action is already running' "$state_file"
	! grep -q '^ran$' "$attempts_file"
	! grep -q '^released$' "$attempts_file"
)

printf '%s\n' 'domain lock serialization tests OK'
