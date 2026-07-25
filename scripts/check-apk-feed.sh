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
shared_workflow="$root/.github/workflows/shared-apk-feed.yml"
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

grep -q "OPENWRT_APK_TRUST_SHA256=$OPENWRT_APK_TRUST_SHA256" \
	"$root/scripts/install-openwrt25.sh" ||
	fail 'bootstrap public-key checksum is out of sync'
grep -q "OPENWRT_APK_RELEASE_BASE=$OPENWRT_APK_RELEASE_BASE" \
	"$root/scripts/install-openwrt25.sh" ||
	fail 'bootstrap stable release base is out of sync'
grep -q "OPENWRT_APK_CHANNEL_BASE=$OPENWRT_APK_CHANNEL_BASE" \
	"$root/scripts/install-openwrt25.sh" ||
	fail 'bootstrap stable feed channel is out of sync'
grep -Fq 'OPENWRT_APK_FEED_URL="$OPENWRT_APK_CHANNEL_BASE/packages.adb"' \
	"$root/scripts/install-openwrt25.sh" ||
	fail 'bootstrap feed URL is not derived from the release channel'

# Routers that never re-run the bootstrap installer are moved onto the current
# feed by the package itself, so both packaging paths must carry the same target
# URL as the release channel.
for packaging in Makefile scripts/stage-package.sh; do
	grep -Fq "ikev2_feed_new=$OPENWRT_APK_FEED_URL" "$root/$packaging" ||
		fail "postinst feed migration target is out of sync: $packaging"
done
grep -Fq 'git -C "$channel_dir" push origin HEAD:apk-feed' "$release_workflow" ||
	fail 'release workflow does not publish the stable APK channel'
grep -Fq '"$OPENWRT_OVERVIEW_REPOSITORY"' "$release_workflow" ||
	fail 'release workflow does not download Overview Manager'
grep -Fq 'dist/apk-feed/nikitid-openwrt-release.pem' "$release_workflow" ||
	fail 'release workflow does not publish the generic key alias'
grep -Fq 'types:' "$shared_workflow" &&
grep -Fq 'overview-manager-release' "$shared_workflow" ||
	fail 'shared feed workflow cannot be triggered by Overview Manager'
grep -Fq '"$OPENWRT_IKEV2_REPOSITORY"' "$shared_workflow" &&
grep -Fq '"$OPENWRT_OVERVIEW_REPOSITORY"' "$shared_workflow" ||
	fail 'shared feed workflow does not retain both applications'
grep -Fq './scripts/assemble-shared-apk-feed.sh' "$shared_workflow" ||
	fail 'shared feed workflow does not use the verified assembler'
grep -Fq 'verify "$ikev2_apk"' "$root/scripts/assemble-shared-apk-feed.sh" &&
grep -Fq 'verify "$overview_apk"' "$root/scripts/assemble-shared-apk-feed.sh" ||
	fail 'shared feed assembler does not verify both APK signatures'
for prerelease in _rc _beta _alpha; do
	grep -Fq "contains(github.ref_name, '$prerelease')" "$release_workflow" ||
		fail "release workflow does not exclude $prerelease tags from the stable APK channel"
done

printf 'check-apk-feed OK\n'
