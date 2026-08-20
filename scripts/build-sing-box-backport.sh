#!/bin/sh

set -eu

fail() {
	printf 'build-sing-box-backport: %s\n' "$*" >&2
	exit 1
}

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
. "$root/apk-feed.env"

sdk="${OPENWRT_SDK_DIR:-}"
signing_key="${OPENWRT_APK_SIGNING_KEY:-}"
public_key="$root/$OPENWRT_APK_KEY_FILE"
package_source=''
package_link=''

[ -n "$sdk" ] && [ -d "$sdk" ] || fail 'OPENWRT_SDK_DIR is required'
[ -n "$signing_key" ] && [ -r "$signing_key" ] ||
	fail 'OPENWRT_APK_SIGNING_KEY is required'
[ -r "$public_key" ] || fail 'tracked public key is missing'

package_source="$sdk/feeds/packages/net/sing-box"
package_link="$sdk/package/feeds/packages/sing-box"
[ -f "$package_source/Makefile" ] || fail 'the SDK packages feed is missing sing-box'
grep -Fxq 'PKG_VERSION:=1.12.17' "$package_source/Makefile" ||
	fail 'the backport is restricted to sing-box 1.12.17'

[ -e "$package_link" ] || "$sdk/scripts/feeds" install -p packages sing-box >/dev/null
[ -e "$package_link" ] || fail 'unable to register the sing-box package'

mkdir -p "$package_source/patches"
cp "$root"/patches/sing-box-1.12/*.patch "$package_source/patches/"
if grep -Fxq 'PKG_RELEASE:=1' "$package_source/Makefile"; then
	sed -i.bak 's/^PKG_RELEASE:=1$/PKG_RELEASE:=2/' "$package_source/Makefile"
fi
grep -Fxq 'PKG_RELEASE:=2' "$package_source/Makefile" ||
	fail 'unable to set the backport package release'

set -- "$sdk"/staging_dir/target-*/stamp/.package_prereq
[ "$#" -eq 1 ] && [ -e "$1" ] ||
	fail 'the prepared SDK target prerequisite stamp is missing'
host_make() {
	package="$1"
	shift
	[ -e "$sdk/package/feeds/packages/$package" ] ||
		fail "the SDK packages feed is missing $package"
	PATH="$sdk/staging_dir/host/bin:$PATH" \
		HOST_OS=Linux HOST_ARCH=x86_64 GNU_HOST_NAME=x86_64-pc-linux-gnu \
		make -C "$sdk/package/feeds/packages/$package" \
		TOPDIR="$sdk" SDK=1 host-compile V=s "$@"
}
if [ ! -x "$sdk/staging_dir/hostpkg/lib/go-1.26/bin/go" ]; then
	# Building a feed package directly avoids OpenWrt's expensive full-tree
	# prerequisite walk. Go 1.26 requires Go 1.24.6 or later to bootstrap; use
	# one pinned official toolchain instead of the legacy multi-stage bootstrap,
	# which is incompatible with some current Linux kernels.
	go_bootstrap="${OPENWRT_GO_BOOTSTRAP_DIR:-$sdk/staging_dir/host-bootstrap/go1.24.13}"
	if [ ! -x "$go_bootstrap/bin/go" ]; then
		archive="$sdk/dl/go1.24.13.linux-amd64.tar.gz"
		mkdir -p "$sdk/dl" "$(dirname "$go_bootstrap")"
		"$sdk/scripts/download.pl" "$sdk/dl" \
			"$(basename "$archive")" \
			'1fc94b57134d51669c72173ad5d49fd62afb0f1db9bf3f798fd98ee423f8d730' \
			'' 'https://go.dev/dl/'
		printf '%s  %s\n' \
			'1fc94b57134d51669c72173ad5d49fd62afb0f1db9bf3f798fd98ee423f8d730' \
			"$archive" | sha256sum -c -
		tmp_bootstrap="${go_bootstrap}.new.$$"
		rm -rf "$tmp_bootstrap"
		mkdir -p "$tmp_bootstrap"
		tar -C "$tmp_bootstrap" --strip-components=1 -xzf "$archive"
		mv "$tmp_bootstrap" "$go_bootstrap"
	fi
	"$go_bootstrap/bin/go" version | grep -Fq 'go1.24.13 ' ||
		fail 'the Go bootstrap must be the pinned 1.24.13 toolchain'
	PATH="$go_bootstrap/bin:$PATH" \
		host_make golang1.26 "BOOTSTRAP_DIR=$go_bootstrap"
fi
run_make() {
	target="${1##*/}"
	shift
	PATH="$sdk/staging_dir/host/bin:$PATH" make -C "$package_link" \
		TOPDIR="$sdk" SDK=1 \
		BUILD_SUBDIR=package/feeds/packages/sing-box \
		BUILD_VARIANT= ALL_VARIANTS= "$target" "$@"
}
run_make package/sing-box/clean V=s
run_make package/sing-box/compile \
	'CONFIG_PACKAGE_sing-box=m' \
	BUILD_KEY_APK_SEC="$signing_key" \
	BUILD_KEY_APK_PUB="$public_key" \
	V=s

apk_tool="$sdk/staging_dir/host/bin/apk"
[ -x "$apk_tool" ] || fail 'SDK apk tool is missing'
package_path="$(find "$sdk/bin/packages" -type f \
	-name 'sing-box-1.12.17-r2.apk' -print -quit)"
[ -n "$package_path" ] || fail 'the patched sing-box APK was not built'

"$apk_tool" --allow-untrusted adbsign --sign-key "$signing_key" "$package_path"
"$apk_tool" --keys-dir "$root/keys" verify "$package_path"

output="$root/dist/compat"
mkdir -p "$output"
cp "$package_path" "$output/$(basename "$package_path")"
(
	cd "$output"
	sha256sum "$(basename "$package_path")" >SHA256SUMS
)
printf 'signed FakeIP backport built in %s\n' "$output"
