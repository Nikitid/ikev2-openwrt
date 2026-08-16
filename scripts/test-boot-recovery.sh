#!/bin/sh

# A boot-time start_action may run before WAN source-address selection is
# possible. Verify that recovery recognises only the resulting loopback-bound
# outbound IKE_SA and leaves legitimate handshakes untouched.

set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM

sed -n '/^has_loopback_connecting_outbound() {/,/^}/p' \
	"$root/luci-ikev2-manager/ikev2-manager.sh" >"$tmp/detect.sh"
[ -s "$tmp/detect.sh" ] || {
	printf 'boot-stall detector is missing\n' >&2
	exit 1
}
sh -n "$tmp/detect.sh"
. "$tmp/detect.sh"

must_match() {
	has_loopback_connecting_outbound "$1" || {
		printf 'boot-stall fixture was not recognised: %s\n' "$1" >&2
		exit 1
	}
}

must_not_match() {
	if has_loopback_connecting_outbound "$1"; then
		printf 'healthy/unrelated fixture was misclassified: %s\n' "$1" >&2
		exit 1
	fi
}

must_match 'list-sa event {proxy-out {uniqueid=2 version=2 state=CONNECTING local-host=127.0.0.1 local-port=500 remote-host=45.91.236.41 remote-port=500}}'
must_match 'list-sa event {proxy-out {uniqueid=8 version=2 state=CONNECTING local-host=::1 local-port=500 remote-host=2001:db8::1 remote-port=500}}'

must_not_match 'list-sa event {proxy-out {uniqueid=5 version=2 state=CONNECTING local-host=37.204.226.48 local-port=500 remote-host=45.91.236.41 remote-port=500}}'
must_not_match 'list-sa event {proxy-out {uniqueid=5 version=2 state=ESTABLISHED local-host=127.0.0.1 local-port=4500 child-sas {proxy4-2 {name=proxy4 state=INSTALLED}}}}'
must_not_match 'list-sa event {ikev2-in {uniqueid=4 version=2 state=CONNECTING local-host=127.0.0.1 local-port=500}}'
must_not_match 'list-sa event {proxy-out {uniqueid=9 version=2 state=CONNECTING local-host=0.0.0.0 local-port=500}}'

ensure_body="$(sed -n '/^ensure_client_action() {/,/^}/p' \
	"$root/luci-ikev2-manager/ikev2-manager.sh")"
printf '%s\n' "$ensure_body" | grep -Fq 'outbound_peer_resolves || return 1' || {
	printf 'recovery no longer waits for boot-time DNS\n' >&2
	exit 1
}
printf '%s\n' "$ensure_body" | grep -Fq 'has_loopback_connecting_outbound "$raw"' || {
	printf 'ensure-client does not use the boot-stall detector\n' >&2
	exit 1
}
printf '%s\n' "$ensure_body" | grep -Fq 'swanctl_quiet --terminate --ike proxy-out --timeout 5' || {
	printf 'ensure-client does not discard the stalled outbound IKE_SA\n' >&2
	exit 1
}
printf '%s\n' "$ensure_body" | grep -Fq '/usr/libexec/ikev2-sync-vips || return 1' || {
	printf 'an automatic replacement would not synchronise its virtual IP\n' >&2
	exit 1
}
printf '%s\n' "$ensure_body" | grep -Fq '/usr/share/pbr/pbr.user.ikev2out || return 1' || {
	printf 'an automatic replacement would not restore its PBR route\n' >&2
	exit 1
}

grep -Fq 'STOP=02' "$root/ikev2-manager-runtime/ikev2-health.init" || {
	printf 'health watcher does not stop before dependent services\n' >&2
	exit 1
}
grep -Fq 'procd_set_param term_timeout 5' \
	"$root/ikev2-manager-runtime/ikev2-health.init" || {
	printf 'health watcher shutdown is not explicitly bounded\n' >&2
	exit 1
}

printf 'boot recovery and shutdown-bound tests OK\n'
