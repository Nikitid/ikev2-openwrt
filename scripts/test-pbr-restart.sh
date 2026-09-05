#!/bin/sh

set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM
mkdir -p "$tmp/bin" "$tmp/runtime"
cp "$root/ikev2-manager-runtime/lib/actions.sh" "$tmp/runtime/actions.sh"
cp "$root/ikev2-manager-runtime/lib/routing.sh" "$tmp/runtime/routing.sh"

cat >"$tmp/bin/uci" <<'EOF'
#!/bin/sh
while [ "${1:-}" = -q ]; do shift; done
case "${1:-}:${2:-}" in
	get:ikev2-manager.globals.configured) echo 1 ;;
	get:ikev2-manager.client.enabled) echo 0 ;;
	get:ikev2-manager.domains.engine) echo fakeip ;;
	export:pbr) printf 'config pbr config\n\toption enabled 1\n' ;;
	*) exit 1 ;;
esac
EOF
cat >"$tmp/bin/pbr-init" <<'EOF'
#!/bin/sh
printf '%s\n' "$1" >>"$TEST_PBR_LOG"
case "$1" in
reload) exit "${TEST_RELOAD_RC:-0}" ;;
restart) : >"${TEST_PBR_STATE:-/tmp/test-pbr-state}"; exit 0 ;;
running)
	[ "${TEST_RUNTIME_DOWN_UNTIL_RESTART:-0}" != 1 ] ||
		[ -e "${TEST_PBR_STATE:-/tmp/test-pbr-state}" ]
	;;
*) exit 1 ;;
esac
EOF
cat >"$tmp/bin/system" <<'EOF'
#!/bin/sh
case "$1" in _sync-pbr | failclosed-check) exit 0 ;; *) exit 1 ;; esac
EOF
cat >"$tmp/bin/domain-router" <<'EOF'
#!/bin/sh
printf '%s\n' "$1" >>"$TEST_DOMAIN_LOG"
[ "$1" = refresh-rules ]
EOF
cat >"$tmp/bin/xfrm" <<'EOF'
#!/bin/sh
[ "$1" = start ]
EOF
cat >"$tmp/bin/nslookup" <<'EOF'
#!/bin/sh
printf 'Name: %s\nAddress 1: 192.0.2.1\n' "$1"
EOF
cat >"$tmp/bin/nft" <<'EOF'
#!/bin/sh
case "$*" in
	'list chain inet fw4 forward') echo 'jump forward_lan' ;;
	'list chain inet fw4 pbr_prerouting') echo 'chain pbr_prerouting' ;;
	*) exit 1 ;;
esac
EOF
cat >"$tmp/bin/pbr-user" <<'EOF'
#!/bin/sh
exit 0
EOF
cat >"$tmp/bin/discord" <<'EOF'
#!/bin/sh
[ "$1" = sync ]
EOF
chmod 755 "$tmp/bin"/*
# Keep chmod confined to test stubs; flock remains owned by the host system.
ln -s "$(command -v flock)" "$tmp/bin/flock"

run_restart() {
	PATH="$tmp/bin:/usr/bin:/sbin:/bin" \
	TEST_PBR_LOG="$tmp/pbr.log" \
	TEST_DOMAIN_LOG="$tmp/domain.log" \
	TEST_RELOAD_RC="${TEST_RELOAD_RC:-0}" \
	TEST_RUNTIME_DOWN_UNTIL_RESTART="${TEST_RUNTIME_DOWN_UNTIL_RESTART:-0}" \
	TEST_PBR_STATE="$tmp/pbr.state" \
	IKEV2_PBR_RESTART_LOCK="$tmp/restart.lock" \
	IKEV2_ACTION_LOCK="$tmp/action.lock" \
	IKEV2_ACTION_LOCK_STATUS="$tmp/action.status" \
	IKEV2_PBR_RESTART_LOG="$tmp/restart.log" \
	IKEV2_PBR_WAIT_SECONDS=1 \
	IKEV2_PBR_SIGNATURE="$tmp/pbr.signature" \
	IKEV2_DOMAIN_FILE="$tmp/domains.txt" \
	IKEV2_SERVICE_CIDR_FILE="$tmp/cidrs.txt" \
	IKEV2_RUNTIME_LIB_DIR="$tmp/runtime" \
	IKEV2_SYSTEM_HELPER="$tmp/bin/system" \
	IKEV2_DOMAIN_ROUTER_HELPER="$tmp/bin/domain-router" \
	IKEV2_XFRM_INIT="$tmp/bin/xfrm" \
	IKEV2_PBR_INIT="$tmp/bin/pbr-init" \
	IKEV2_SYNC_VIPS="$tmp/bin/unused-sync-vips" \
	IKEV2_PBR_USER="$tmp/bin/pbr-user" \
	IKEV2_DISCORD_VOICE="$tmp/bin/discord" \
		sh "$root/luci-ikev2-domains/restart-pbr.sh" --wait
}

: >"$tmp/pbr.log"
: >"$tmp/domain.log"
run_restart
grep -Fxq refresh-rules "$tmp/domain.log"
[ "$(grep -c '^reload$' "$tmp/pbr.log")" = 1 ]
if grep -Fxq restart "$tmp/pbr.log"; then
	printf '%s\n' 'successful PBR reload unnecessarily used the stop/start path' >&2
	exit 1
fi

# Reliable-mode domain-only edits hot-reload the sing-box ruleset. They do not
# change the PBR policy signature and must not rebuild PBR a second time.
: >"$tmp/pbr.log"
printf '%s\n' example.net >"$tmp/domains.txt"
run_restart
if grep -Eq '^(reload|restart)$' "$tmp/pbr.log"; then
	printf '%s\n' 'domain-only reliable-mode update rebuilt PBR' >&2
	exit 1
fi

: >"$tmp/pbr.log"
rm -f "$tmp/pbr.signature"
TEST_RELOAD_RC=1 run_restart
[ "$(sed -n '1p' "$tmp/pbr.log")" = reload ]
if grep -Fxq restart "$tmp/pbr.log"; then
	printf '%s\n' 'non-zero reload result caused a redundant restart despite healthy runtime' >&2
	exit 1
fi

# A genuinely absent runtime fails without starting a second overlapping
# rebuild. The operator can retry after the first reload has settled.
: >"$tmp/pbr.log"
rm -f "$tmp/pbr.signature" "$tmp/pbr.state"
if TEST_RELOAD_RC=1 TEST_RUNTIME_DOWN_UNTIL_RESTART=1 run_restart; then
	printf '%s\n' 'missing PBR runtime was accepted after reload' >&2
	exit 1
fi
if grep -Fxq restart "$tmp/pbr.log"; then
	printf '%s\n' 'failed reload triggered a second PBR rebuild' >&2
	exit 1
fi

printf '%s\n' 'PBR restart tests OK'
