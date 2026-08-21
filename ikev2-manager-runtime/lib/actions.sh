#!/bin/sh
# Shared detached-action primitives for IKEv2 Manager backends.
#
# Callers provide:
#   action_status_file, action_status_dir, action_lock_dir, action_lock_status
#   run_action(), die()

action_status() {
	mkdir -p "$action_status_dir"
	{
		printf 'action_id=%s\n' "$1"
		printf 'state=%s\n' "$2"
		printf 'updated=%s\n' "$(date +%s)"
		[ -z "${3:-}" ] || printf 'message=%s\n' "$3"
	} >"$action_status_dir/$1.status.new"
	mv "$action_status_dir/$1.status.new" "$action_status_dir/$1.status"
	cp "$action_status_dir/$1.status" "${action_status_file}.new"
	mv "${action_status_file}.new" "$action_status_file"
}

# PID-backed lock directories for small workers that do not use the global
# action lock. A dead worker must not disable updates until the next reboot.
pid_lock_acquire() {
	local dir="$1" pid
	if ! mkdir "$dir" 2>/dev/null; then
		pid="$(cat "$dir/pid" 2>/dev/null || true)"
		if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
			return 1
		fi
		rm -f "$dir/pid"
		rmdir "$dir" 2>/dev/null || return 1
		mkdir "$dir" 2>/dev/null || return 1
	fi
	printf '%s\n' "$$" >"$dir/pid"
}

pid_lock_busy() {
	local dir="$1" pid
	[ -d "$dir" ] || return 1
	pid="$(cat "$dir/pid" 2>/dev/null || true)"
	if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
		return 0
	fi
	rm -f "$dir/pid"
	rmdir "$dir" 2>/dev/null || return 0
	return 1
}

pid_lock_release() {
	local dir="$1"
	rm -f "$dir/pid"
	rmdir "$dir" 2>/dev/null || true
}

# Non-blocking inspection for the global action lock.  Health reconciliation
# must not race a real configuration transaction, but a worker killed between
# actions must not suppress self-healing until the next reboot either.
action_lock_busy() {
	local pid updated now created
	[ -d "$action_lock_dir" ] || return 1
	pid="$(sed -n 's/^pid=//p' "$action_lock_status" 2>/dev/null | tail -1)"
	updated="$(sed -n 's/^updated=//p' "$action_lock_status" 2>/dev/null | tail -1)"
	now="$(date +%s)"
	if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
		case "$updated" in
			'' | *[!0-9]*) return 0 ;;
		esac
		[ $((now - updated)) -gt 3600 ] || return 0
	elif [ -z "$pid" ]; then
		# mkdir() precedes publishing the status file.  Preserve a fresh empty
		# lock so the health loop cannot delete it in that short hand-off window.
		created="$(stat -c %Y "$action_lock_dir" 2>/dev/null || true)"
		case "$created" in
			'' | *[!0-9]*) return 0 ;;
		esac
		[ $((now - created)) -gt 5 ] || return 0
	fi
	rm -f "$action_lock_status"
	rmdir "$action_lock_dir" 2>/dev/null || return 0
	return 1
}

acquire_action_lock() {
	owner="$1"
	id="$2"
	tries=0
	max_tries="${IKEV2_ACTION_LOCK_WAIT_SECONDS:-5}"
	case "$max_tries" in
		'' | *[!0-9]*) max_tries=5 ;;
	esac
	while ! mkdir "$action_lock_dir" 2>/dev/null; do
		updated="$(sed -n 's/^updated=//p' "$action_lock_status" 2>/dev/null | tail -1)"
		pid="$(sed -n 's/^pid=//p' "$action_lock_status" 2>/dev/null | tail -1)"
		now="$(date +%s)"
		# mkdir() and publishing the owner file are separate operations. Give a
		# new owner a short grace period instead of deleting its lock in that gap.
		if [ -z "$pid" ] && [ "$tries" -lt 3 ]; then
			tries=$((tries + 1))
			sleep 1
			continue
		fi
		if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null ||
		   { [ -n "$updated" ] && [ $((now - updated)) -gt 3600 ]; }; then
			rm -f "$action_lock_status"
			rmdir "$action_lock_dir" 2>/dev/null || :
			continue
		fi
		tries=$((tries + 1))
		[ "$tries" -lt "$max_tries" ] || return 1
		sleep 1
	done
	lock_status_tmp="${action_lock_status}.new.$$"
	printf 'owner=%s\naction_id=%s\npid=%s\nupdated=%s\n' \
		"$owner" "$id" "$$" "$(date +%s)" >"$lock_status_tmp"
	mv "$lock_status_tmp" "$action_lock_status"
}

start_action() {
	kind="$1"
	shift
	id="$(date +%s)-$$"
	find "$action_status_dir" -type f -mtime +7 -exec rm -f {} \; 2>/dev/null || :
	action_status "$id" running 'Queued...'
	if command -v start-stop-daemon >/dev/null 2>&1; then
		if ! start-stop-daemon -b -q -S -x "$0" -- _action-run "$id" "$kind" "$@"; then
			action_status "$id" error 'Unable to start background action.'
			die 'Unable to start background action'
		fi
	else
		setsid "$0" _action-run "$id" "$kind" "$@" </dev/null >/dev/null 2>&1 &
	fi
	printf 'action_id=%s\n' "$id"
}
