#!/bin/sh

# Installed nftables tables were verified by searching nft's text listing for
# the rules as written, and nft prints some rules back in another form. The
# fingerprint of the kernel's own JSON listing replaces that; it must move
# with the program and stay still under traffic.

set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
state="$root/ikev2-manager-runtime/lib/nft-state.uc"
tmp="$(mktemp -d)"
finished=0
trap 'rm -rf "$tmp"; [ "$finished" = 1 ] || exit 1' EXIT
trap 'exit 1' INT TERM

fail() {
	printf '%s\n' "$*" >&2
	exit 1
}

# listing HANDLE PACKETS EXPIRES DYNAMIC-ELEMENT STATIC-ELEMENT MARK
listing() {
	cat <<EOF
{"nftables": [{"metainfo": {"version": "1.1.6", "json_schema_version": 1}},
 {"table": {"family": "inet", "name": "t", "handle": $1}},
 {"set": {"family": "inet", "name": "clients", "table": "t", "type": "ipv4_addr", "handle": $(($1 + 1)),
   "flags": ["timeout"], "timeout": 120,
   "elem": [{"elem": {"val": "$5", "timeout": 120, "expires": $3}}]}},
 {"set": {"family": "inet", "name": "seen", "table": "t", "type": "ipv4_addr", "handle": $(($1 + 2)),
   "flags": ["timeout", "dynamic"], "timeout": 3600, "elem": [{"elem": {"val": "$4", "timeout": 3600, "expires": $3}}]}},
 {"rule": {"family": "inet", "table": "t", "chain": "c", "handle": $(($1 + 3)),
   "expr": [{"match": {"op": "==", "left": {"meta": {"key": "mark"}}, "right": $6}},
            {"counter": {"packets": $2, "bytes": $(($2 * 60))}}, {"accept": null}]}}]}
EOF
}
fingerprint() { ucode "$state" fingerprint; }

listing 10 0 119 192.0.2.1 10.0.0.2 1 | fingerprint >"$tmp/a"
[ -s "$tmp/a" ] || fail 'no fingerprint was printed'
listing 90 5000 3 192.0.2.77 10.0.0.2 1 | fingerprint >"$tmp/b"
cmp -s "$tmp/a" "$tmp/b" || fail 'handles, counters, expiry or dynamic elements moved the fingerprint'
listing 10 0 119 192.0.2.1 10.0.0.3 1 | fingerprint >"$tmp/c"
cmp -s "$tmp/a" "$tmp/c" && fail 'a changed static element kept the fingerprint'
listing 10 0 119 192.0.2.1 10.0.0.2 2 | fingerprint >"$tmp/d"
cmp -s "$tmp/a" "$tmp/d" && fail 'a changed rule kept the fingerprint'

# Sets a resolver fills are named, and their elements left out too.
listing 10 0 119 192.0.2.1 10.0.0.2 1 | ucode "$state" fingerprint clients >"$tmp/v1"
listing 10 0 119 192.0.2.1 10.0.0.9 1 | ucode "$state" fingerprint clients >"$tmp/v2"
cmp -s "$tmp/v1" "$tmp/v2" || fail 'elements of a named volatile set moved the fingerprint'
listing 10 0 119 192.0.2.1 10.0.0.9 2 | ucode "$state" fingerprint clients >"$tmp/v3"
cmp -s "$tmp/v1" "$tmp/v3" && fail 'a volatile set hid a changed rule'

# Key order in the listing is nft's business, not a change.
listing 10 0 119 192.0.2.1 10.0.0.2 1 |
	python3 -c 'import json, sys
d = json.load(sys.stdin)
def rev(v):
    if isinstance(v, dict): return {k: rev(v[k]) for k in reversed(list(v))}
    if isinstance(v, list): return [rev(x) for x in v]
    return v
json.dump(rev(d), sys.stdout)' | fingerprint >"$tmp/e"
cmp -s "$tmp/a" "$tmp/e" || fail 'key order moved the fingerprint'

# An unreadable or empty listing has no fingerprint.
status() {
	local rc=0
	printf '%s' "$1" | fingerprint >/dev/null 2>&1 || rc=$?
	printf '%s\n' "$rc"
}
[ "$(status '')" = 2 ] || fail 'an empty listing was fingerprinted'
[ "$(status '{"nftables": [')" = 2 ] || fail 'a truncated listing was fingerprinted'
[ "$(status '{"nftables": [{"metainfo": {}}]}')" = 2 ] || fail 'a listing without a table was fingerprinted'

# The runtime helpers record and compare through it.
(
	nft_bin="$tmp/nft"
	table=t
	ucode_bin=ucode
	runtime_lib_dir="$root/ikev2-manager-runtime/lib"
	printf '#!/bin/sh\ncat "%s/listing"\n' "$tmp" >"$nft_bin"
	chmod 755 "$nft_bin"
	. "$runtime_lib_dir/nft-runtime.sh"
	listing 10 0 119 192.0.2.1 10.0.0.2 1 >"$tmp/listing"
	record_runtime "$tmp/state/runtime" wanted || fail 'the runtime was not recorded'
	[ "$(sed -n 1p "$tmp/state/runtime")" = wanted ] || fail 'the signature was not recorded'
	listing 11 9 50 192.0.2.9 10.0.0.2 1 >"$tmp/listing"
	runtime_unchanged "$tmp/state/runtime" || fail 'traffic read as a changed runtime'
	listing 11 9 50 192.0.2.9 10.0.0.2 3 >"$tmp/listing"
	runtime_unchanged "$tmp/state/runtime" && fail 'a changed rule read as the installed runtime'
	: >"$tmp/listing"
	runtime_unchanged "$tmp/state/runtime" && fail 'an unreadable runtime read as unchanged'
	exit 0
)

finished=1
printf '%s\n' 'nft state tests OK'
