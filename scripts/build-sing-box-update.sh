#!/bin/sh

set -eu

fail() {
	printf 'build-sing-box-update: %s\n' "$*" >&2
	exit 1
}

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
. "$root/apk-feed.env"

sdk="${OPENWRT_SDK_DIR:-}"
signing_key="${OPENWRT_APK_SIGNING_KEY:-}"
public_key="$root/$OPENWRT_APK_KEY_FILE"
package_source=''
package_link=''
target_version=1.13.19
target_release=2
target_hash=abc2f4805b3fd088c18a5694b51fed6f0e1d06632fae98029d6bf7bd79a1b3a2
recipe_commit=e99adbc49f7a11d0377c8135fe706c7757b9e68c
recipe_hash=b3ec2cb62ed6b0661f9ab9d566301f84385db01fe9365ab0d823a624cd5e0aac
recipe_tmp="$(mktemp)"
trap 'rm -f "$recipe_tmp"' EXIT INT TERM

[ -n "$sdk" ] && [ -d "$sdk" ] || fail 'OPENWRT_SDK_DIR is required'
[ -z "$signing_key" ] || [ -r "$signing_key" ] ||
	fail 'OPENWRT_APK_SIGNING_KEY is not readable'
[ -r "$public_key" ] || fail 'tracked public key is missing'

package_source="$sdk/feeds/packages/net/sing-box"
package_link="$sdk/package/feeds/packages/sing-box"
[ -d "$package_source" ] || fail 'the SDK packages feed is missing sing-box'

# Pin the official OpenWrt 1.13.x package recipe instead of adapting whatever
# happens to be present in a cached SDK. Only the upstream version, source hash
# and local release number differ from that reviewed recipe.
curl -fsSL \
	"https://raw.githubusercontent.com/openwrt/packages/$recipe_commit/net/sing-box/Makefile" \
	-o "$recipe_tmp"
printf '%s  %s\n' "$recipe_hash" "$recipe_tmp" | sha256sum -c - >/dev/null ||
	fail 'the pinned OpenWrt sing-box recipe failed verification'
cp "$recipe_tmp" "$package_source/Makefile"
sed -i.bak \
	-e "s/^PKG_VERSION:=1\.13\.18$/PKG_VERSION:=$target_version/" \
	-e "s/^PKG_RELEASE:=1$/PKG_RELEASE:=$target_release/" \
	-e "s/^PKG_HASH:=.*/PKG_HASH:=$target_hash/" \
	"$package_source/Makefile"
rm -f "$package_source/Makefile.bak"
grep -Fxq "PKG_VERSION:=$target_version" "$package_source/Makefile" ||
	fail 'unable to set the target version'
grep -Fxq "PKG_RELEASE:=$target_release" "$package_source/Makefile" ||
	fail 'unable to set the package release'
grep -Fxq "PKG_HASH:=$target_hash" "$package_source/Makefile" ||
	fail 'unable to pin the source archive hash'

# These patches targeted the removed 1.12 allocator and must never be applied
# to the upstream 1.13 implementation.
rm -f "$package_source/patches/100-serialize-fakeip-allocation.patch"
rm -f "$package_source/patches/110-fix-fakeip-range-boundaries.patch"

[ -e "$package_link" ] || "$sdk/scripts/feeds" install -p packages sing-box >/dev/null
[ -e "$package_link" ] || fail 'unable to register the sing-box package'

set -- "$sdk"/staging_dir/target-*/stamp/.package_prereq
[ "$#" -eq 1 ] && [ -e "$1" ] ||
	fail 'the prepared SDK target prerequisite stamp is missing'
target_stage="${1%/stamp/.package_prereq}"
# A prepared SDK can retain the target prerequisite stamp while its pkginfo
# directory is incomplete (for example after a package-only clean). OpenWrt's
# shared-library verifier then reports libc.so/libgcc_s.so.1 as missing even
# though both are present in the target toolchain. Rebuild the official
# toolchain metadata, rather than disabling dependency verification.
if [ ! -s "$target_stage/pkginfo/libc.provides" ] ||
   [ ! -s "$target_stage/pkginfo/libgcc.provides" ]; then
	PATH="$sdk/staging_dir/host/bin:$PATH" \
		make -C "$sdk/package/toolchain" TOPDIR="$sdk" SDK=1 compile V=s
fi
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
	go_bootstrap="${OPENWRT_GO_BOOTSTRAP_DIR:-$sdk/staging_dir/host-bootstrap/go1.24.13}"
	if [ ! -x "$go_bootstrap/bin/go" ]; then
		archive="$sdk/dl/go1.24.13.linux-amd64.tar.gz"
		mkdir -p "$sdk/dl" "$(dirname "$go_bootstrap")"
		archive_tmp="${archive}.new.$$"
		curl -fsSL 'https://go.dev/dl/go1.24.13.linux-amd64.tar.gz' -o "$archive_tmp"
		printf '%s  %s\n' \
			'1fc94b57134d51669c72173ad5d49fd62afb0f1db9bf3f798fd98ee423f8d730' \
			"$archive_tmp" | sha256sum -c -
		mv "$archive_tmp" "$archive"
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
if [ -n "$signing_key" ]; then
	run_make package/sing-box/compile \
		'CONFIG_PACKAGE_sing-box=m' \
		'CONFIG_SINGBOX_WITH_CLASH_API=y' \
		'CONFIG_SINGBOX_WITH_GVISOR=y' \
		'CONFIG_SINGBOX_WITH_QUIC=y' \
		'CONFIG_SINGBOX_WITH_UTLS=y' \
		'CONFIG_SINGBOX_WITH_WIREGUARD=y' \
		BUILD_KEY_APK_SEC="$signing_key" \
		BUILD_KEY_APK_PUB="$public_key" V=s
else
	run_make package/sing-box/compile \
		'CONFIG_PACKAGE_sing-box=m' \
		'CONFIG_SINGBOX_WITH_CLASH_API=y' \
		'CONFIG_SINGBOX_WITH_GVISOR=y' \
		'CONFIG_SINGBOX_WITH_QUIC=y' \
		'CONFIG_SINGBOX_WITH_UTLS=y' \
		'CONFIG_SINGBOX_WITH_WIREGUARD=y' V=s
fi

apk_tool="$sdk/staging_dir/host/bin/apk"
[ -x "$apk_tool" ] || fail 'SDK apk tool is missing'
package_path="$(find "$sdk/bin" -type f \
	-name "sing-box-$target_version-r$target_release.apk" -print -quit)"
[ -n "$package_path" ] || fail 'the updated sing-box APK was not built'

if [ -n "$signing_key" ]; then
	"$apk_tool" --allow-untrusted adbsign --sign-key "$signing_key" "$package_path"
	"$apk_tool" --keys-dir "$root/keys" verify "$package_path"
fi

output="$root/dist/compat"
mkdir -p "$output"
rm -f "$output"/sing-box-*.apk "$output/SHA256SUMS"
cp "$package_path" "$output/$(basename "$package_path")"
(
	cd "$output"
	sha256sum "$(basename "$package_path")" >SHA256SUMS
)
if [ -n "$signing_key" ]; then
	printf 'signed sing-box %s built in %s\n' "$target_version" "$output"
else
	printf 'unsigned test sing-box %s built in %s\n' "$target_version" "$output"
fi
