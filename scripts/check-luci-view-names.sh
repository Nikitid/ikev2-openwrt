#!/bin/sh

# Every page the menu opens must be installed under that exact name by both
# packaging paths - the IPK staging and the SDK Makefile - and must not be in
# either post-install removal list. 1.14.0 shipped an IPK that installed two
# pages under an older name and then removed them, so neither page opened.

set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
menu="$root/luci-ikev2-manager/menu.json"
stage="$root/scripts/stage-package.sh"
makefile="$root/Makefile"

fail() {
	printf 'check-luci-view-names: %s\n' "$*" >&2
	exit 1
}

paths="$(sed -n 's/.*"path": "\(ikev2-[a-z-]*\/[a-z-]*-v[0-9]*\)".*/\1/p' "$menu" | sort -u)"
[ -n "$paths" ] || fail 'no versioned views found in the menu'

# The removal lists: every line of an `rm -f` continuation block.
removed() {
	awk '
		/^[[:space:]]*rm -f \/www\/luci-static/ { block = 1 }
		block { print }
		block && !/\\$/ { block = 0 }
	' "$1"
}

for path in $paths; do
	file="/www/luci-static/resources/view/$path.js"
	grep -Fq "$file" "$stage" || fail "the IPK does not install $file"
	grep -Fq "$file" "$makefile" || fail "the SDK package does not install $file"
	if removed "$stage" | grep -Fq "$file"; then
		fail "the IPK post-install removes the page it installs: $file"
	fi
	if removed "$makefile" | grep -Fq "$file"; then
		fail "the SDK post-install removes the page it installs: $file"
	fi
done

# The shared module every page requires.
for shared in $(sed -n "s/^'require ikev2-manager\.\(shared-v[0-9]*\) as common';$/\1/p" \
	"$root"/luci-ikev2-manager/*.js "$root"/luci-ikev2-domains/*.js | sort -u); do
	file="/www/luci-static/resources/ikev2-manager/$shared.js"
	grep -Fq "$file" "$stage" || fail "the IPK does not install $file"
	grep -Fq "$file" "$makefile" || fail "the SDK package does not install $file"
	if removed "$stage" | grep -Fq "$file" || removed "$makefile" | grep -Fq "$file"; then
		fail "a post-install removes the shared module the pages require: $file"
	fi
done

printf 'check-luci-view-names OK: %s views\n' "$(printf '%s\n' "$paths" | wc -l | tr -d ' ')"
