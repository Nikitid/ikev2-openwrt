#!/bin/sh
# Input validators shared by the system helper, the LuCI backend and the inbound
# policy runtime. Each succeeds only for a value it accepts; none print.

# Turn a comma- or space-separated list into single-space-separated words.
normalize_list() {
	printf '%s' "$1" | tr ',' ' ' | tr -s ' ' | sed 's/^ //;s/ $//'
}

# Up to 64 ports or ascending ranges, each within 1-65535. Empty is valid.
valid_port_list() {
	local value count=0 item start end
	value="$(normalize_list "$1")"
	[ -z "$value" ] && return 0
	for item in $value; do
		count=$((count + 1))
		[ "$count" -le 64 ] || return 1
		printf '%s' "$item" | grep -Eq '^[0-9]+(-[0-9]+)?$' || return 1
		start="${item%%-*}"
		end="${item#*-}"
		[ "$start" -ge 1 ] && [ "$start" -le 65535 ] || return 1
		[ "$end" -ge "$start" ] && [ "$end" -le 65535 ] || return 1
	done
}

valid_name() {
	[ -n "$1" ] && [ "${#1}" -le 32 ] &&
		printf '%s' "$1" | grep -Eq '^[A-Za-z0-9_.-]+$'
}

valid_user() {
	[ -n "$1" ] && [ "${#1}" -le 64 ] &&
		printf '%s' "$1" | grep -Eq '^[A-Za-z0-9_.@-]+$'
}

valid_ipv4() {
	printf '%s\n' "$1" | awk -F. '
		NF != 4 { exit 1 }
		{
			for (i = 1; i <= 4; i++)
				if ($i !~ /^[0-9]+$/ || $i < 0 || $i > 255)
					exit 1
		}
	'
}
