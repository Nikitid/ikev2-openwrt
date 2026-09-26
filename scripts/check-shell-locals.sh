#!/bin/sh

# BusyBox ash scopes variables dynamically: a function that assigns a name
# without `local` writes into whichever caller has a variable of that name.
# Validators and small helpers are called directly inside conditions, not in a
# $(...) subshell, so they write into the caller. dns_segment_update stored the
# protocol of the last endpoint it validated instead of the one chosen, because
# valid_dns_endpoint_any assigned its own "protocol".
#
# Every variable such a helper assigns - by `name=`, `for name in` or
# `read name` - must be declared local in it. The helpers are matched by name.

set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
status=0

for file in "$root"/ikev2-manager-runtime/*.sh "$root"/ikev2-manager-runtime/lib/*.sh \
	"$root"/luci-ikev2-manager/*.sh "$root"/luci-ikev2-domains/*.sh; do
	awk -v file="${file#"$root"/}" '
		function helper(name) {
			return name ~ /^(valid_|normalize_|dns_suffixes_overlap$|router_dns_ready$|wait_for_router_dns$|set_uci_list$|set_list$|add_list_unique$|delete_prefixed_sections$|delete_sections$|port_range_contains$|zone_|managed_zone_name_available$|next_dns_segment_port$|network_device$|in_range$)/
		}
		function note(name) {
			if (name == "" || name ~ /^[0-9]/ || name in locals || name in reported) return
			reported[name] = 1
			printf "%s:%d: %s assigns \"%s\" without local\n", file, NR, fn, name
			bad = 1
		}
		/^[a-z_][a-z0-9_]*\(\) *[{(]/ {
			name = $0; sub(/\(.*/, "", name)
			fn = helper(name) ? name : ""
			delete locals; delete reported
			next
		}
		fn == "" { next }
		/^[})]$/ { fn = ""; next }
		{
			line = $0
			sub(/^[[:space:]]+/, "", line)
			if (line ~ /^local /) {
				rest = substr(line, 7)
				count = split(rest, words, /[[:space:]]+/)
				for (i = 1; i <= count; i++) {
					word = words[i]; sub(/=.*/, "", word)
					if (word ~ /^[A-Za-z_][A-Za-z0-9_]*$/) locals[word] = 1
				}
				next
			}
			if (line ~ /^[A-Za-z_][A-Za-z0-9_]*=/) {
				word = line; sub(/=.*/, "", word); note(word)
			}
			if (line ~ /^for [A-Za-z_][A-Za-z0-9_]* in /) {
				split(line, words, /[[:space:]]+/); note(words[2])
			}
			if (match(line, /read( -r)? [A-Za-z_][A-Za-z0-9_ ]*/)) {
				rest = substr(line, RSTART, RLENGTH)
				sub(/^read( -r)? /, "", rest)
				count = split(rest, words, /[[:space:]]+/)
				for (i = 1; i <= count; i++) note(words[i])
			}
		}
		END { exit bad }
	' "$file" || status=1
done

[ "$status" -eq 0 ] && printf '%s\n' 'shell helper locals OK'
exit "$status"
