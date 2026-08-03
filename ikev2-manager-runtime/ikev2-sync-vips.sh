#!/bin/sh

set -eu

[ "$(uci -q get ikev2-manager.client.enabled)" = 1 ] || exit 1
[ "$(uci -q get ikev2-manager.globals.configured)" = 1 ] ||
	ip link show ipsec-out >/dev/null 2>&1 || exit 1

# Outbound tunnel is IPv4-only (clients have no provider IPv6). Sync just the
# v4 VIP onto ipsec-out.
#
# The SA list must be scoped to this application's own connection. An
# unfiltered list also reports the virtual IPs of any other IKEv2 client on the
# router, and adopting one of those installs a foreign address on ipsec-out,
# which silently breaks every route that points at the outbound tunnel.
interface='ipsec-out'
connection='proxy-out'
raw="$(swanctl --list-sas --ike "$connection" --raw 2>/dev/null)"
vips="$(printf '%s\n' "$raw" |
	sed -n 's/.*local-vips=\[\([^]]*\)\].*/\1/p')"
vip4=''

for address in $vips; do
	case "$address" in
		*:*) ;;
		*/*) vip4="${address%/*}" ;;
		*) vip4="$address" ;;
	esac
done

[ -n "$vip4" ]

current4="$(
	ip -4 -o addr show dev "$interface" scope global |
		awk 'NR == 1 { split($4, address, "/"); print address[1] }'
)"

if [ "$current4" != "$vip4" ]; then
	ip -4 addr flush dev "$interface" scope global
	ip addr add "$vip4/32" dev "$interface"

	# Masqueraded PBR flows retain the old VIP in conntrack after a rekey.
	# Remove only those stale NAT mappings so clients reconnect immediately.
	if [ -n "$current4" ] && command -v conntrack >/dev/null 2>&1; then
		conntrack -D --reply-dst "$current4" >/dev/null 2>&1 || :
	fi
fi

printf '%s\n' "$vip4" >/var/run/ikev2-vip4
