#!/bin/sh

# A stalled mirror used to hold the dependency installer - and the router action
# lock with it - forever: only the package list update was bounded. Every
# downloading transaction must now end, as a failure the caller rolls back.

set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM

fail() {
	printf '%s\n' "$*" >&2
	exit 1
}

mkdir -p "$tmp/bin"
cat >"$tmp/bin/apk" <<STUB
#!/bin/sh
printf '%s\n' "\$\$" >"$tmp/apk.pid"
exec sleep 30
STUB
chmod +x "$tmp/bin/apk"
PATH="$tmp/bin:$PATH"
IKEV2_PACKAGE_MANAGER=apk
IKEV2_PACKAGE_TRANSACTION_TIMEOUT=2
export PATH IKEV2_PACKAGE_MANAGER IKEV2_PACKAGE_TRANSACTION_TIMEOUT
. "$root/ikev2-manager-runtime/lib/package-manager.sh"

for operation in 'pkg_install sing-box' 'pkg_download dnsmasq-full' 'pkg_remove_dnsmasq_provider dnsmasq-full'; do
	started="$(date +%s)"
	if $operation >/dev/null 2>&1; then
		fail "a stalled transaction reported success: $operation"
	fi
	elapsed=$(( $(date +%s) - started ))
	[ "$elapsed" -lt 10 ] || fail "a stalled transaction was not bounded: $operation took ${elapsed}s"
	pid="$(cat "$tmp/apk.pid")"
	if kill -0 "$pid" 2>/dev/null; then
		kill "$pid" 2>/dev/null || :
		fail "the stalled package manager was left running: $operation"
	fi
done

printf '%s\n' 'package transaction timeout tests OK'
