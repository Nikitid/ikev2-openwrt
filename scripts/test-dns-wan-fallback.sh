#!/bin/sh

set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
system="$root/ikev2-manager-runtime/ikev2-manager-system.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM

sed -n '/^dns_wan_fallback_refresh() {/,/^}/p' "$system" >"$tmp/function.sh"
{
	sed -n '/^valid_dns_ipv4() {/,/^}/p' "$system"
	sed -n '/^dns_wan_reachable_fallbacks() {/,/^}/p' "$system"
} >"$tmp/probe-functions.sh"

mkdir -p "$tmp/bin"
cat >"$tmp/bin/nslookup" <<'EOF'
#!/bin/sh
[ "${2:-}" = 192.0.2.53 ] || exit 1
cat <<'ANSWER'
Name: openwrt.org
Address 1: 64.226.122.113
ANSWER
EOF
chmod 755 "$tmp/bin/nslookup"
(
	PATH="$tmp/bin:/usr/bin:/bin"
	export PATH
	. "$root/ikev2-manager-runtime/lib/package-manager.sh"
	. "$tmp/probe-functions.sh"
	result="$(dns_wan_reachable_fallbacks \
		'udp://192.0.2.53:53 udp://198.51.100.53:53 invalid')"
	[ "$result" = 'udp://192.0.2.53:53' ]
)

run_case() (
	case_name="$1"
	TEST_PROVIDER="$2"
	TEST_QUERY_OK="$3"
	expected="$4"
	TEST_SEGMENTS_OK="${5:-1}"
	case_dir="$tmp/$case_name"
	mkdir -p "$case_dir"
	action_lock_status="$case_dir/action.status"
	action_lock_dir="$case_dir/action.lock"
	TEST_CURRENT='udp://203.0.113.53:53'
	TEST_CONFIGURED='https://fallback.example/dns-query'
	TEST_UPSTREAM='https://primary.example/dns-query'

	defaultv() {
		case "$1.$2" in
			dns.managed | dns.wan_fallback) printf '1\n' ;;
			*) printf '%s\n' "$3" ;;
		esac
	}
	action_lock_busy() { return 1; }
	acquire_action_lock() {
		mkdir "$action_lock_dir"
		: >"$action_lock_status"
	}
	wan_dns_fallbacks() { printf '%s\n' "$TEST_PROVIDER"; }
	dns_wan_reachable_fallbacks() { printf '%s\n' "$1"; }
	getv() {
		case "$1.$2" in
			dns.fallback) printf '%s\n' "$TEST_CONFIGURED" ;;
			dns.upstream) printf '%s\n' "$TEST_UPSTREAM" ;;
		esac
	}
	list_without() {
		candidates="$1"
		excluded="$2"
		result=''
		for item in $candidates; do
			duplicate=0
			for seen in $excluded $result; do
				[ "$seen" != "$item" ] || { duplicate=1; break; }
			done
			[ "$duplicate" = 0 ] || continue
			result="${result:+$result }$item"
		done
		printf '%s\n' "$result"
	}
	normalize_list() { printf '%s\n' "$1"; }
	uci() {
		case "$*" in
			'-q get dnsproxy.servers.fallback') printf '%s\n' "$TEST_CURRENT" ;;
			'commit dnsproxy') return 0 ;;
			*) return 1 ;;
		esac
	}
	save_dns_state() {
		mkdir -p "$1"
		printf 'segments_enabled=1\nsegments_running=1\n' >"$1/service.state"
		printf 'saved\n' >>"$case_dir/events"
	}
	set_uci_list() {
		current="$4"
		printf 'set=%s\n' "$current" >>"$case_dir/events"
	}
	dns_wan_restart_segments() { printf 'segments-restart\n' >>"$case_dir/events"; }
	dns_wan_restart_proxy() { printf 'proxy-restart\n' >>"$case_dir/events"; }
	dns_query_ok() { [ "$TEST_QUERY_OK" = 1 ]; }
	dns_segments_check() { [ "$TEST_SEGMENTS_OK" = 1 ]; }
	restore_dns_state() { printf 'dns-restored\n' >>"$case_dir/events"; }
	restore_dns_segment_service_state() { printf 'segments-restored\n' >>"$case_dir/events"; }
	release_action_lock() { rm -f "$action_lock_status"; rmdir "$action_lock_dir"; }
	logger() { :; }

	. "$tmp/function.sh"
	dns_wan_fallback_refresh ||
		{ [ "$TEST_QUERY_OK" = 0 ] || [ "$TEST_SEGMENTS_OK" = 0 ]; }
	grep -Fxq "set=$expected" "$case_dir/events"
	if [ "$TEST_QUERY_OK" = 1 ] && [ "$TEST_SEGMENTS_OK" = 1 ]; then
		grep -Fxq 'segments-restart' "$case_dir/events"
		grep -Fxq 'proxy-restart' "$case_dir/events"
		! grep -q 'restored' "$case_dir/events"
	else
		grep -Fxq 'dns-restored' "$case_dir/events"
		grep -Fxq 'segments-restored' "$case_dir/events"
	fi
)

run_case success 'udp://192.0.2.53:53 udp://198.51.100.53:53' 1 \
	'https://fallback.example/dns-query udp://192.0.2.53:53 udp://198.51.100.53:53'
run_case rollback 'udp://192.0.2.53:53' 0 \
	'https://fallback.example/dns-query udp://192.0.2.53:53'
run_case segment-rollback 'udp://192.0.2.53:53' 1 \
	'https://fallback.example/dns-query udp://192.0.2.53:53' 0

# A lease transition may temporarily publish no DNS addresses. The reconciler
# must retain the last validated runtime group and avoid all process restarts.
(
	case_dir="$tmp/empty-provider"
	mkdir -p "$case_dir"
	action_lock_status="$case_dir/action.status"
	action_lock_dir="$case_dir/action.lock"
	defaultv() { printf '1\n'; }
	action_lock_busy() { return 1; }
	acquire_action_lock() { mkdir "$action_lock_dir"; : >"$action_lock_status"; }
	wan_dns_fallbacks() { :; }
	getv() { :; }
	logger() { :; }
	. "$tmp/function.sh"
	dns_wan_fallback_refresh
	[ ! -e "$case_dir/events" ]
)

# Repeated health and hotplug events are idempotent when the effective fallback
# group is already current.
(
	case_dir="$tmp/no-change"
	mkdir -p "$case_dir"
	action_lock_status="$case_dir/action.status"
	action_lock_dir="$case_dir/action.lock"
	defaultv() { printf '1\n'; }
	action_lock_busy() { return 1; }
	acquire_action_lock() { mkdir "$action_lock_dir"; : >"$action_lock_status"; }
	wan_dns_fallbacks() { printf '%s\n' 'udp://192.0.2.53:53'; }
	getv() {
		case "$1.$2" in
			dns.fallback) printf '%s\n' 'https://fallback.example/dns-query' ;;
			dns.upstream) printf '%s\n' 'https://primary.example/dns-query' ;;
		esac
	}
	list_without() {
		candidates="$1"
		excluded="$2"
		result=''
		for item in $candidates; do
			case " $excluded $result " in *" $item "*) continue ;; esac
			result="${result:+$result }$item"
		done
		printf '%s\n' "$result"
	}
	normalize_list() { printf '%s\n' "$1"; }
	uci() {
		[ "$*" = '-q get dnsproxy.servers.fallback' ] || return 1
		printf '%s\n' 'https://fallback.example/dns-query udp://192.0.2.53:53'
	}
	save_dns_state() { : >"$case_dir/events"; }
	logger() { :; }
	. "$tmp/function.sh"
	dns_wan_fallback_refresh
	[ ! -e "$case_dir/events" ]
)

printf '%s\n' 'WAN DNS fallback transaction tests OK'
