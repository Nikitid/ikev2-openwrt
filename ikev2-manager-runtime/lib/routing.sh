#!/bin/sh
# Routing invariants shared by apply, doctor and operational self-tests.

# ip route del with metric 0 can match any priority. The flush selector is
# filtered in userspace and removes only the zero-metric PBR default. Install
# and verify our terminal route first; never delete the last guard to repair it.
ensure_failclosed_default() {
	local family="$1" table="$2" routes
	routes="$(ip -"$family" route show table "$table" 2>/dev/null)" || routes=''
	if ! printf '%s\n' "$routes" | grep -Eq '^unreachable default .*metric 32767( |$)'; then
		ip -"$family" route replace unreachable default metric 32767 table "$table" || return 1
	fi
	if [ "$family" = 4 ] && printf '%s\n' "$routes" |
		awk '/^unreachable default/ && !/metric / { found=1 } END { exit !found }'; then
		ip -4 route flush table "$table" type unreachable metric 0 || return 1
	fi
	ip -"$family" route show table "$table" 2>/dev/null |
		grep -Eq '^unreachable default .*metric 32767( |$)'
}

forward_chain_ok() {
	nft list chain inet fw4 forward 2>/dev/null | grep -q 'jump forward_'
}

ensure_forward_chain() {
	forward_chain_ok && return 0
	fw4 -q reload || return 1
	forward_chain_ok
}

router_dns_ready() {
	server="${1:-127.0.0.1}"
	domain="${2:-openwrt.org}"
	nslookup "$domain" "$server" 2>/dev/null |
		awk '
			/^Name:/ { answer = 1; next }
			answer && /^Address[^:]*:/ { found = 1 }
			END { exit found ? 0 : 1 }
		'
}

wait_for_router_dns() {
	server="${1:-127.0.0.1}"
	attempts="${2:-20}"
	domain="${3:-openwrt.org}"
	case "$attempts" in
		'' | *[!0-9]* | 0) return 1 ;;
	esac
	tries=0
	while [ "$tries" -lt "$attempts" ]; do
		router_dns_ready "$server" "$domain" && return 0
		tries=$((tries + 1))
		[ "$tries" -ge "$attempts" ] || sleep 1
	done
	return 1
}

ensure_ipv6_failfast() {
	ip -6 route show default 2>/dev/null | grep -q . && return 0
	ip -6 route replace unreachable default metric 2147483647 2>/dev/null || true
}

failclosed_check() (
	table='pbr_ikev2out'
	test_ip='203.0.113.77'
	routes="$(ip -4 route show table "$table" 2>/dev/null)"

	printf '%s\n' "$routes" |
		grep -Eq '^unreachable default( |$)' || return 1

	# Derive the active PBR mark from the existing rule and query it without
	# creating or deleting any routing objects. Doctor calls this function while
	# rendering LuCI, so validation must be strictly read-only.
	rule="$(ip -4 rule show 2>/dev/null |
		awk -v table="$table" '
			$0 ~ "lookup " table "([[:space:]]|$)" {
				for (i = 1; i <= NF; i++)
					if ($i == "fwmark") { print $(i + 1); exit }
			}
		')"
	[ -n "$rule" ] || return 1
	mark="${rule%%/*}"
	if printf '%s\n' "$routes" | grep -Eq '^default dev ipsec-out( |$)'; then
		output="$(ip -4 route get "$test_ip" mark "$mark" 2>&1)" || return 1
		printf '%s\n' "$output" | grep -Eq '(^|[[:space:]])dev ipsec-out([[:space:]]|$)'
	else
		output="$(ip -4 route get "$test_ip" mark "$mark" 2>&1)" && return 1
		printf '%s\n' "$output" | grep -qi 'unreachable'
	fi
)

failclosed_ipv6_check() (
	table='pbr_ikev2out'
	test_ip='2001:db8::77'

	ip -6 route show table "$table" 2>/dev/null |
		grep -Eq '^unreachable default( |$)' || return 1
	rule="$(ip -6 rule show 2>/dev/null |
		awk -v table="$table" '
			$0 ~ "lookup " table "([[:space:]]|$)" {
				for (i = 1; i <= NF; i++)
					if ($i == "fwmark") { print $(i + 1); exit }
			}
		')"
	[ -n "$rule" ] || return 1
	mark="${rule%%/*}"
	output="$(ip -6 route get "$test_ip" mark "$mark" 2>&1)" && return 1
	printf '%s\n' "$output" | grep -qi 'unreachable'
)
