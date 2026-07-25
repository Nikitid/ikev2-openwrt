#!/bin/sh

# The project repository was renamed, and apk does not follow the GitHub rename
# redirect for the raw index. Routers that only run `apk update && apk upgrade`
# therefore depend on the package postinst to rewrite their feed list. Both
# packaging paths carry the same block; run it against a sandbox root.

set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM

. "$root/apk-feed.env"
old_feed='https://raw.githubusercontent.com/Nikitid/ikev2-manager-openwrt/apk-feed/packages.adb'

extract() {
	source="$1"
	unescape="$2"
	sed -n '/# feed-migration begin/,/# feed-migration end/p' "$source" >"$tmp/block"
	[ -s "$tmp/block" ] || {
		printf 'no feed-migration block in %s\n' "$source" >&2
		exit 1
	}
	if [ "$unescape" = 1 ]; then
		sed 's/\$\$/$/g; s/[[:space:]]*\\$//' "$tmp/block" >"$tmp/block.sh"
	else
		cp "$tmp/block" "$tmp/block.sh"
	fi
	sh -n "$tmp/block.sh"
}

run() {
	IKEV2_FEED_LIST="$tmp/feed.list" sh "$tmp/block.sh" >"$tmp/out" 2>&1
}

for source in Makefile scripts/stage-package.sh; do
	case "$source" in
		Makefile) extract "$root/$source" 1 ;;
		*) extract "$root/$source" 0 ;;
	esac

	# A router still on the previous repository path is migrated.
	printf '%s\n' "$old_feed" >"$tmp/feed.list"
	run
	[ "$(cat "$tmp/feed.list")" = "$OPENWRT_APK_FEED_URL" ] || {
		printf '%s did not migrate the previous feed URL\n' "$source" >&2
		exit 1
	}
	grep -Fq 'migrated' "$tmp/out" || {
		printf '%s migrated silently\n' "$source" >&2
		exit 1
	}
	[ -e "$tmp/feed.list.new" ] && {
		printf '%s left a temporary feed list behind\n' "$source" >&2
		exit 1
	}

	# An already current list is left untouched and reported as unchanged.
	printf '%s\n' "$OPENWRT_APK_FEED_URL" >"$tmp/feed.list"
	run
	[ "$(cat "$tmp/feed.list")" = "$OPENWRT_APK_FEED_URL" ]
	grep -Fq 'migrated' "$tmp/out" && {
		printf '%s reported a migration it did not perform\n' "$source" >&2
		exit 1
	}

	# A list an operator or another project points elsewhere is never rewritten.
	foreign='https://example.invalid/custom/packages.adb'
	printf '%s\n' "$foreign" >"$tmp/feed.list"
	run
	[ "$(cat "$tmp/feed.list")" = "$foreign" ] || {
		printf '%s rewrote a feed list it does not own\n' "$source" >&2
		exit 1
	}

	# No list at all is a plain no-op.
	rm -f "$tmp/feed.list"
	run
	[ ! -e "$tmp/feed.list" ] || {
		printf '%s created a feed list where none existed\n' "$source" >&2
		exit 1
	}
done

printf 'feed migration tests OK\n'
