#!/bin/sh

set -eu

fail() {
	printf 'assemble-shared-apk-feed: %s\n' "$*" >&2
	exit 1
}

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
. "$root/apk-feed.env"

sdk="${OPENWRT_SDK_DIR:-}"
signing_key="${OPENWRT_APK_SIGNING_KEY:-}"
ikev2_apk="${OPENWRT_IKEV2_APK:-}"
overview_apk="${OPENWRT_OVERVIEW_MANAGER_APK:-}"
release_tag="${OPENWRT_APK_RELEASE_TAG:-}"
public_key="$root/$OPENWRT_APK_KEY_FILE"
alias_key="$root/$OPENWRT_APK_KEY_ALIAS"
output="${OPENWRT_APK_FEED_OUTPUT:-$root/dist/apk-feed}"

[ -n "$sdk" ] && [ -d "$sdk" ] || fail 'OPENWRT_SDK_DIR is required'
[ -n "$signing_key" ] && [ -r "$signing_key" ] ||
	fail 'OPENWRT_APK_SIGNING_KEY is required'
[ -n "$ikev2_apk" ] && [ -r "$ikev2_apk" ] ||
	fail 'OPENWRT_IKEV2_APK is required'
[ -n "$overview_apk" ] && [ -r "$overview_apk" ] ||
	fail 'OPENWRT_OVERVIEW_MANAGER_APK is required'
[ -r "$public_key" ] || fail "public key not found: $public_key"
[ -r "$alias_key" ] || fail "public-key alias not found: $alias_key"

case "$(basename "$sdk")" in
	"${OPENWRT_APK_SDK_ARCHIVE%.tar.zst}") ;;
	*) fail "unexpected SDK directory: $(basename "$sdk")" ;;
esac
case "$(basename "$ikev2_apk")" in
	"$OPENWRT_IKEV2_PACKAGE"-*.apk) ;;
	*) fail 'unexpected IKEv2 Manager APK filename' ;;
esac
case "$(basename "$overview_apk")" in
	"$OPENWRT_OVERVIEW_PACKAGE"-*.apk) ;;
	*) fail 'unexpected Overview Manager APK filename' ;;
esac
case "$release_tag" in
	'') ;;
	*[!A-Za-z0-9._-]*) fail 'invalid APK release tag' ;;
esac

output_parent="$(dirname "$output")"
output_name="$(basename "$output")"
[ "$output_name" != . ] && [ "$output_name" != / ] &&
	[ -n "$output_name" ] ||
	fail 'unsafe APK feed output path'
[ "$output" != "$root" ] && [ "$output" != "$root/" ] ||
	fail 'APK feed output must not replace the repository root'

for command in openssl python3 sha256sum; do
	command -v "$command" >/dev/null 2>&1 ||
		fail "required command is missing: $command"
done

actual_key_hash="$(sha256sum "$public_key" | awk '{ print $1 }')"
[ "$actual_key_hash" = "$OPENWRT_APK_TRUST_SHA256" ] ||
	fail "public key checksum mismatch: $actual_key_hash"
cmp -s "$public_key" "$alias_key" ||
	fail 'public-key alias differs from the legacy release key'

tmp="$(mktemp -d)"
cleanup() {
	rm -rf "$tmp"
}
trap cleanup EXIT HUP INT TERM

openssl ec -in "$signing_key" -pubout -out "$tmp/derived-public.pem" \
	>/dev/null 2>&1 || fail 'invalid EC signing key'
cmp -s "$tmp/derived-public.pem" "$public_key" ||
	fail 'signing key does not match the tracked shared release key'

apk_tool="$sdk/staging_dir/host/bin/apk"
[ -x "$apk_tool" ] || fail "SDK APK tool not found: $apk_tool"

# Both application APKs must already carry a valid signature from the shared
# publisher before they are copied into the central feed.
"$apk_tool" --keys-dir "$root/keys" verify "$ikev2_apk"
"$apk_tool" --keys-dir "$root/keys" verify "$overview_apk"

feed="$tmp/feed"
mkdir -p "$feed"
ikev2_name="$(basename "$ikev2_apk")"
overview_name="$(basename "$overview_apk")"
cp "$ikev2_apk" "$feed/$ikev2_name"
cp "$overview_apk" "$feed/$overview_name"

(
	cd "$feed"
	"$apk_tool" mkndx \
		--keys-dir "$root/keys" \
		--sign-key "$signing_key" \
		--description 'Nikitid OpenWrt applications for OpenWrt 25.12' \
		--output packages.adb \
		"$ikev2_name" "$overview_name"
)

cp "$public_key" "$feed/ikev2-manager-release.pem"
cp "$alias_key" "$feed/nikitid-openwrt-release.pem"
release_base="$OPENWRT_APK_RELEASE_BASE"
if [ -n "$release_tag" ]; then
	release_base="https://github.com/Nikitid/ikev2-openwrt/releases/download/$release_tag"
fi
sed "s|^OPENWRT_APK_RELEASE_BASE=https://.*|OPENWRT_APK_RELEASE_BASE=$release_base|" \
	"$root/scripts/install-openwrt25.sh" >"$feed/install-openwrt25.sh"
chmod 0755 "$feed/install-openwrt25.sh"
(
	cd "$feed"
	sha256sum "$ikev2_name" "$overview_name" packages.adb \
		ikev2-manager-release.pem nikitid-openwrt-release.pem \
		install-openwrt25.sh >SHA256SUMS.apk
)

OPENWRT_APK_TOOL="$apk_tool" \
	"$root/scripts/verify-shared-apk-feed.sh" "$feed"

mkdir -p "$output_parent"
rm -rf "${output_parent:?}/${output_name:?}"
mv "$feed" "$output"

printf 'Shared APK feed assembled in %s\n' "$output"
