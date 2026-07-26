#!/bin/sh

set -eu

fail() {
	printf 'build-apk: %s\n' "$*" >&2
	exit 1
}

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
. "$root/release.env"
. "$root/apk-feed.env"

sdk="${OPENWRT_SDK_DIR:-}"
signing_key="${OPENWRT_APK_SIGNING_KEY:-}"
public_key="$root/$OPENWRT_APK_KEY_FILE"

[ -n "$sdk" ] || fail 'OPENWRT_SDK_DIR is required'
[ -d "$sdk" ] || fail "SDK directory not found: $sdk"
[ -n "$signing_key" ] || fail 'OPENWRT_APK_SIGNING_KEY is required'
[ -r "$signing_key" ] || fail "signing key not readable: $signing_key"
[ -r "$public_key" ] || fail "public key not found: $public_key"

case "$(basename "$sdk")" in
	"${OPENWRT_APK_SDK_ARCHIVE%.tar.zst}") ;;
	*) fail "unexpected SDK directory: $(basename "$sdk")" ;;
esac

for command in make openssl python3 rsync sha256sum; do
	command -v "$command" >/dev/null 2>&1 || fail "required command is missing: $command"
done

actual_key_hash="$(sha256sum "$public_key" | awk '{ print $1 }')"
[ "$actual_key_hash" = "$OPENWRT_APK_TRUST_SHA256" ] ||
	fail "public key checksum mismatch: $actual_key_hash"

tmp="$(mktemp -d)"
cleanup() {
	rm -rf "$tmp"
}
trap cleanup EXIT HUP INT TERM

openssl ec -in "$signing_key" -pubout -out "$tmp/derived-public.pem" >/dev/null 2>&1 ||
	fail 'invalid EC signing key'
cmp -s "$tmp/derived-public.pem" "$public_key" ||
	fail 'signing key does not match the tracked public release key'

sdk_package="$sdk/package/luci-app-ikev2-manager"
rm -rf "$sdk_package"
mkdir -p "$sdk_package"
rsync -a --delete \
	--exclude .git \
	--exclude build \
	--exclude dist \
	--exclude .DS_Store \
	"$root/" "$sdk_package/"

"$root/scripts/check-version-sync.sh"
make -C "$sdk" defconfig
make -C "$sdk" package/luci-app-ikev2-manager/clean V=s
make -C "$sdk" \
	BUILD_KEY_APK_SEC="$signing_key" \
	BUILD_KEY_APK_PUB="$public_key" \
	package/luci-app-ikev2-manager/compile V=s

apk_tool="$sdk/staging_dir/host/bin/apk"
[ -x "$apk_tool" ] || fail "SDK apk tool not found: $apk_tool"

package_path="$(find "$sdk/bin/packages" -type f \
	-name "${PKG_NAME}-${PKG_VERSION}.apk" -print -quit)"
[ -n "$package_path" ] || fail 'built APK was not found'

"$apk_tool" --allow-untrusted adbsign \
	--sign-key "$signing_key" "$package_path"
"$apk_tool" --keys-dir "$root/keys" verify "$package_path"
"$apk_tool" --keys-dir "$root/keys" adbdump --format json \
	"$package_path" >"$tmp/package.json"
python3 - "$tmp/package.json" >"$tmp/pre-deinstall" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as package_file:
    package = json.load(package_file)
print(package.get("scripts", {}).get("pre-deinstall", ""), end="")
PY
grep -Fq 'PKG_UPGRADE:-0' "$tmp/pre-deinstall" &&
grep -Fq 'upgrade) exit 0' "$tmp/pre-deinstall" &&
grep -Fq 'cleanup helper is missing; package removal stopped before changing files' \
	"$tmp/pre-deinstall" &&
grep -Fq 'unable to restore managed router state; package removal stopped before changing files' \
	"$tmp/pre-deinstall" ||
	fail 'built APK does not contain the guarded removal cleanup'
if grep -Fq '*) exit 0' "$tmp/pre-deinstall"; then
	fail 'built APK pre-deinstall rejects the apk old-version argument'
fi
if grep -Fq '/etc/init.d/rpcd restart' "$tmp/pre-deinstall"; then
	fail 'built APK restarts rpcd during its package transaction'
fi

output="$root/dist/apk"
mkdir -p "$output"
rm -f "$output"/*.apk
cp "$package_path" "$output/$(basename "$package_path")"
(
	cd "$output"
	sha256sum "$(basename "$package_path")" >SHA256SUMS.apk
)

printf 'signed APK built in %s\n' "$output"
