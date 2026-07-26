#!/bin/sh

# The feed moved out of this repository into Nikitid/openwrt-feed. Routers that
# only run `apk update && apk upgrade <package>` never re-run a bootstrap
# installer, so the package postinst is what actually moves them. Both packaging
# paths carry the same block; run it against a sandbox root.

set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM

. "$root/apk-feed.env"

previous_urls="https://raw.githubusercontent.com/Nikitid/ikev2-manager-openwrt/apk-feed/packages.adb
https://raw.githubusercontent.com/Nikitid/ikev2-openwrt/apk-feed/packages.adb"

feed_dir="$tmp/repositories.d"
old_list="$feed_dir/ikev2-manager.list"
new_list="$feed_dir/nikitid-openwrt.list"

extract() {
	source="$1"
	unescape="$2"
	sed -n '/# feed-migration begin/,/# feed-migration end/p' "$source" >"$tmp/block"
	[ -s "$tmp/block" ] || {
		printf 'no feed-migration block in %s\n' "$source" >&2
		exit 1
	}
	if [ "$unescape" = 1 ]; then
		sed 's/\$\$/$/g' "$tmp/block" >"$tmp/block.sh"
	else
		cp "$tmp/block" "$tmp/block.sh"
	fi
	sh -n "$tmp/block.sh"
}

run() {
	IKEV2_FEED_DIR="$feed_dir" sh "$tmp/block.sh" >"$tmp/out" 2>&1
}

reset_dir() {
	rm -rf "$feed_dir"
	mkdir -p "$feed_dir"
}

for source in Makefile scripts/stage-package.sh; do
	case "$source" in
		Makefile) extract "$root/$source" 1 ;;
		*) extract "$root/$source" 0 ;;
	esac

	# Every URL this project ever wrote is migrated onto the shared feed. The
	# loop must not sit behind a pipe: a failure inside a subshell would only
	# end the subshell and the test would report success.
	printf '%s\n' "$previous_urls" >"$tmp/previous-urls"
	while IFS= read -r url; do
		[ -n "$url" ] || continue
		reset_dir
		printf '%s\n' "$url" >"$old_list"
		run
		[ "$(cat "$new_list")" = "$OPENWRT_FEED_URL" ] || {
			printf '%s did not migrate %s\n' "$source" "$url" >&2
			exit 1
		}
		[ ! -e "$old_list" ] || {
			printf '%s left the previous list in place for %s\n' "$source" "$url" >&2
			exit 1
		}
		[ ! -e "$new_list.tmp" ] || {
			printf '%s left a temporary list behind\n' "$source" >&2
			exit 1
		}
	done <"$tmp/previous-urls"

	# An existing shared list wins; the superseded one is only retired.
	reset_dir
	printf '%s\n' "$OPENWRT_FEED_URL" >"$new_list"
	printf '%s\n' "https://raw.githubusercontent.com/Nikitid/ikev2-openwrt/apk-feed/packages.adb" \
		>"$old_list"
	run
	[ "$(cat "$new_list")" = "$OPENWRT_FEED_URL" ]
	[ ! -e "$old_list" ] || {
		printf '%s kept a superseded list next to the shared one\n' "$source" >&2
		exit 1
	}

	# A list an operator or another project points elsewhere is never touched.
	reset_dir
	foreign='https://example.invalid/custom/packages.adb'
	printf '%s\n' "$foreign" >"$old_list"
	run
	[ "$(cat "$old_list")" = "$foreign" ] || {
		printf '%s rewrote a feed list it does not own\n' "$source" >&2
		exit 1
	}
	[ ! -e "$new_list" ] || {
		printf '%s created a shared list from a foreign one\n' "$source" >&2
		exit 1
	}

	# No list at all is a plain no-op.
	reset_dir
	run
	[ -z "$(ls -A "$feed_dir")" ] || {
		printf '%s created a feed list where none existed\n' "$source" >&2
		exit 1
	}
done

printf 'feed migration tests OK\n'
