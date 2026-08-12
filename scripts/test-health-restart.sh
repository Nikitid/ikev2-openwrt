#!/bin/sh

# The health watcher is a shell script; the running instance keeps executing the
# copy it already read, so after an upgrade it behaves like the previous version
# until something restarts it. Upgrading 1.1.x to 1.2.x that way left the
# inbound user policy never created, because the older watcher has no such step.
#
# Both packaging paths carry the same block; run it against a stub init script.

set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM

# Keep high-frequency policy refreshes separate from periodic diagnostics and
# set snapshots. Duplicate nft rebuilds in one cycle add churn without extending
# the timeout of the final rules.
[ "$(grep -c '^[[:space:]]*refresh_inbound_user_policy$' \
	"$root/ikev2-manager-runtime/ikev2-health.sh")" = 1 ]
grep -Fq 'dns_probe_interval=60' "$root/ikev2-manager-runtime/ikev2-health.sh"
grep -Fq 'pbr_dump_interval=60' "$root/ikev2-manager-runtime/ikev2-health.sh"

cat >"$tmp/init" <<'EOF'
#!/bin/sh
printf '%s\n' "$1" >>"$INIT_LOG"
case "$1" in
	running) exit "${INIT_RUNNING_RC:-0}" ;;
	restart) exit "${INIT_RESTART_RC:-0}" ;;
esac
exit 0
EOF
chmod +x "$tmp/init"

extract() {
	source="$1"
	unescape="$2"
	sed -n '/# health-restart begin/,/# health-restart end/p' "$source" >"$tmp/block"
	[ -s "$tmp/block" ] || {
		printf 'no health-restart block in %s\n' "$source" >&2
		exit 1
	}
	if [ "$unescape" = 1 ]; then
		sed 's/\$\$/$/g' "$tmp/block" >"$tmp/block.sh"
	else
		cp "$tmp/block" "$tmp/block.sh"
	fi
	sh -n "$tmp/block.sh"
}

INIT_RUNNING_RC=0
INIT_RESTART_RC=0

run() {
	: >"$tmp/init.log"
	INIT_LOG="$tmp/init.log" \
	INIT_RUNNING_RC="$INIT_RUNNING_RC" \
	INIT_RESTART_RC="$INIT_RESTART_RC" \
	IKEV2_HEALTH_INIT="$tmp/init" \
		sh "$tmp/block.sh" >"$tmp/out" 2>&1
}

for source in Makefile scripts/stage-package.sh; do
	case "$source" in
		Makefile) extract "$root/$source" 1 ;;
		*) extract "$root/$source" 0 ;;
	esac

	# A running watcher is restarted so it picks up the installed version.
	INIT_RUNNING_RC=0
	run
	grep -qx 'restart' "$tmp/init.log" || {
		printf '%s did not restart a running watcher\n' "$source" >&2
		exit 1
	}
	grep -Fq 'Restarted the health watcher' "$tmp/out" || {
		printf '%s restarted the watcher silently\n' "$source" >&2
		exit 1
	}

	# A stopped watcher is left stopped: an installation that deliberately keeps
	# the runtime down must not be started by a package upgrade.
	INIT_RUNNING_RC=1
	run
	grep -qx 'restart' "$tmp/init.log" && {
		printf '%s started a watcher that was not running\n' "$source" >&2
		exit 1
	}
	INIT_RUNNING_RC=0

	# A failed restart is reported but never fails the package transaction.
	INIT_RESTART_RC=1
	if ! run; then
		printf '%s failed the transaction because a restart failed\n' "$source" >&2
		exit 1
	fi
	grep -Fq 'Could not restart the health watcher' "$tmp/out" || {
		printf '%s hid a failed restart\n' "$source" >&2
		exit 1
	}
	INIT_RESTART_RC=0

	# A missing init script is a plain no-op.
	IKEV2_HEALTH_INIT="$tmp/absent" sh "$tmp/block.sh" >"$tmp/out" 2>&1 || {
		printf '%s failed when the init script is absent\n' "$source" >&2
		exit 1
	}
done

printf 'health watcher restart tests OK\n'
