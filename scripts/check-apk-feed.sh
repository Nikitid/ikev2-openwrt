#!/bin/sh

set -eu

fail() {
	printf 'check-apk-feed: %s\n' "$*" >&2
	exit 1
}

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
. "$root/apk-feed.env"

public_key="$root/$OPENWRT_APK_KEY_FILE"
alias_key="$root/$OPENWRT_APK_KEY_ALIAS"
release_workflow="$root/.github/workflows/release.yml"
[ -r "$public_key" ] || fail "public key not found: $OPENWRT_APK_KEY_FILE"
[ -r "$alias_key" ] || fail "public-key alias not found: $OPENWRT_APK_KEY_ALIAS"

actual="$(sha256sum "$public_key" | awk '{ print $1 }')"
[ "$actual" = "$OPENWRT_APK_TRUST_SHA256" ] ||
	fail "public key checksum mismatch: $actual"
alias_actual="$(sha256sum "$alias_key" | awk '{ print $1 }')"
[ "$alias_actual" = "$OPENWRT_APK_TRUST_SHA256" ] ||
	fail "public-key alias checksum mismatch: $alias_actual"
cmp -s "$public_key" "$alias_key" ||
	fail 'public-key alias is not byte-for-byte identical'

openssl pkey -pubin -in "$public_key" -noout >/dev/null 2>&1 ||
	fail 'release public key is not a valid PEM public key'

# Match the marker anywhere in the file name, not only at its start: the
# previous anchored pattern accepted names such as release-private.pem, which is
# exactly the form a signing key is usually given. Names are only a hint, so the
# contents of every tracked PEM/key file are checked as well.
git -C "$root" ls-files --cached --others --exclude-standard |
	grep -Ei '(^|/)[^/]*(private|signing|secret)[^/]*\.(pem|key|der)$' &&
	fail 'private signing material is tracked'

key_list="$(mktemp)"
git -C "$root" ls-files --cached --others --exclude-standard |
	grep -Ei '\.(pem|key|der|p8|p12|pfx)$' >"$key_list" || :
while IFS= read -r candidate; do
	[ -f "$root/$candidate" ] || continue
	if grep -qE 'BEGIN ([A-Z0-9 ]+ )?PRIVATE KEY' "$root/$candidate"; then
		rm -f "$key_list"
		fail "tracked file contains private key material: $candidate"
	fi
done <"$key_list"
rm -f "$key_list"

# This repository builds and signs only its own package. The signed index is
# assembled by Nikitid/openwrt-feed from published releases, so nothing here may
# grow its own feed assembly again.
grep -Fq './scripts/build-apk.sh' "$release_workflow" ||
	fail 'release workflow does not build the signed APK'
grep -Fq 'dist/apk/*' "$release_workflow" ||
	fail 'release workflow does not publish the signed APK asset'
for gone in assemble-shared-apk-feed.sh verify-shared-apk-feed.sh \
		download-release-apk.sh install-openwrt25.sh; do
	[ ! -e "$root/scripts/$gone" ] ||
		fail "feed assembly moved to $OPENWRT_FEED_REPOSITORY; remove scripts/$gone"
done
[ ! -e "$root/.github/workflows/shared-apk-feed.yml" ] ||
	fail "feed assembly moved to $OPENWRT_FEED_REPOSITORY; remove the shared-apk-feed workflow"

# Routers that never re-run a bootstrap installer are moved onto the shared feed
# by the package itself, so both packaging paths must carry the same target URL.
for packaging in Makefile scripts/stage-package.sh; do
	grep -Fq "ikev2_feed_url=$OPENWRT_FEED_URL" "$root/$packaging" ||
		fail "postinst feed migration target is out of sync: $packaging"
	# The postinst composes the path from a directory it can override for
	# tests, so check the two halves rather than the joined literal.
	grep -Fq "${OPENWRT_FEED_LIST%/*}" "$root/$packaging" ||
		fail "postinst feed list directory is out of sync: $packaging"
	grep -Fq "${OPENWRT_FEED_LIST##*/}" "$root/$packaging" ||
		fail "postinst feed list name is out of sync: $packaging"
done

for prerelease in _rc _beta _alpha; do
	grep -Fq "contains(github.ref_name, '$prerelease')" "$release_workflow" ||
		fail "release workflow does not exclude $prerelease tags from the shared feed"
done

printf 'check-apk-feed OK\n'
