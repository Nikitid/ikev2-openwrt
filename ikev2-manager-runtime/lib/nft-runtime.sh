#!/bin/sh
# Helpers for the runtimes that own an nftables table of their own: device
# routing, inbound user policy and Discord voice. The caller sets $nft_bin and
# $table before using the table helpers.

runtime_exists() {
	"$nft_bin" list table inet "$table" >/dev/null 2>&1
}

# A table is ours only if it carries the ownership marker chain.
runtime_owned() {
	"$nft_bin" list table inet "$table" 2>/dev/null |
		grep -Fq 'chain ikev2_manager_owned'
}

# Print the fwmark/mask of the ip rule that selects PBR routing table TABLE.
pbr_mark_rule() {
	ip -4 rule show 2>/dev/null |
		awk -v table="$1" '
			$0 ~ ("lookup " table "([[:space:]]|$)") {
				for (i = 1; i <= NF; i++)
					if ($i == "fwmark") { print $(i + 1); exit }
			}
		'
}

# Turn MARK/MASK into the "clear set" pair nftables needs to rewrite only the
# masked bits: the inverted mask, then the mark.
mark_values() {
	local rule="$1" mark mask mark_value mask_value clear_value
	case "$rule" in
		0x[0-9A-Fa-f]*/0x[0-9A-Fa-f]*) ;;
		*) return 1 ;;
	esac
	mark="${rule%%/*}"
	mask="${rule#*/}"
	mark_value=$((mark))
	mask_value=$((mask))
	clear_value=$((0xffffffff ^ mask_value))
	printf '%s %s\n' "$(printf '0x%08x' "$clear_value")" \
		"$(printf '0x%08x' "$mark_value")"
}

# Join the non-empty lines of FILE into an nftables element list.
set_elements() {
	local file="$1"
	[ -s "$file" ] || return 0
	awk 'BEGIN { first=1 } NF { if (!first) printf ", "; printf "%s", $0; first=0 }' "$file"
}
