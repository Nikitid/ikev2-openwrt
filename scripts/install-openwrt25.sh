#!/bin/sh

set -eu

OPENWRT_APK_TRUST_SHA256=f27474d9261f1084350cf4ba34ecdff29e533769c36483d8dd85566e30a6a703
OPENWRT_APK_RELEASE_BASE=https://github.com/Nikitid/ikev2-openwrt/releases/latest/download
OPENWRT_APK_CHANNEL_BASE=https://raw.githubusercontent.com/Nikitid/ikev2-openwrt/apk-feed
OPENWRT_APK_RELEASE_BASE="${IKEV2_APK_RELEASE_BASE:-$OPENWRT_APK_RELEASE_BASE}"
OPENWRT_APK_CHANNEL_BASE="${IKEV2_APK_CHANNEL_BASE:-$OPENWRT_APK_CHANNEL_BASE}"
OPENWRT_APK_FEED_URL="$OPENWRT_APK_CHANNEL_BASE/packages.adb"
OPENWRT_APK_KEY_URL="$OPENWRT_APK_RELEASE_BASE/ikev2-manager-release.pem"
PACKAGE_NAME=luci-app-ikev2-manager

fail() {
	printf 'IKEv2 Manager installer: %s\n' "$*" >&2
	exit 1
}

install_root="${IKEV2_INSTALL_ROOT:-}"
[ -n "$install_root" ] || [ "$(id -u)" -eq 0 ] ||
	fail 'run this installer as root'
release_file="$install_root/etc/openwrt_release"
[ -r "$release_file" ] || fail 'OpenWrt is required'
. "$release_file"

[ "${DISTRIB_ID:-}" = OpenWrt ] ||
	fail "official OpenWrt is required; found ${DISTRIB_ID:-unknown vendor firmware}"
case "${DISTRIB_RELEASE:-}" in
	25.12.*) ;;
	*) fail "OpenWrt 25.12.x is required; found ${DISTRIB_RELEASE:-unknown}" ;;
esac
[ "${DISTRIB_TARGET:-}" = mediatek/filogic ] ||
	fail "this feed currently supports mediatek/filogic; found ${DISTRIB_TARGET:-unknown}"
[ "${DISTRIB_ARCH:-}" = aarch64_cortex-a53 ] ||
	fail "this feed currently supports aarch64_cortex-a53; found ${DISTRIB_ARCH:-unknown}"

for command in apk sha256sum wget; do
	command -v "$command" >/dev/null 2>&1 || fail "required command is missing: $command"
done

tmp="$(mktemp -d)"
key_path="$install_root/etc/apk/keys/ikev2-manager-release.pem"
repo_path="$install_root/etc/apk/repositories.d/ikev2-manager.list"
world_path="$install_root/etc/apk/world"
key_added=0
repo_changed=0
world_changed=0
committed=0

cleanup() {
	rc=$?
	if [ "$rc" -ne 0 ] && [ "$committed" -eq 0 ]; then
		[ "$key_added" -eq 0 ] || rm -f "$key_path"
		if [ "$repo_changed" -eq 1 ]; then
			if [ -f "$tmp/repository.previous" ]; then
				cp "$tmp/repository.previous" "$repo_path"
			else
				rm -f "$repo_path"
			fi
		fi
		if [ "$world_changed" -eq 1 ] && [ -f "$tmp/world.previous" ]; then
			cp "$tmp/world.previous" "$world_path"
		fi
	fi
	rm -rf "$tmp"
	trap - EXIT HUP INT TERM
	exit "$rc"
}
trap cleanup EXIT HUP INT TERM

if [ -e "$key_path" ]; then
	existing_hash="$(sha256sum "$key_path" | awk '{ print $1 }')"
	[ "$existing_hash" = "$OPENWRT_APK_TRUST_SHA256" ] ||
		fail "a different key already exists at $key_path"
else
	wget -q -O "$tmp/release-key.pem" "$OPENWRT_APK_KEY_URL" ||
		fail 'unable to download the release public key'
	downloaded_hash="$(sha256sum "$tmp/release-key.pem" | awk '{ print $1 }')"
	[ "$downloaded_hash" = "$OPENWRT_APK_TRUST_SHA256" ] ||
		fail "release public-key checksum mismatch: $downloaded_hash"
	mkdir -p "$install_root/etc/apk/keys"
	cp "$tmp/release-key.pem" "$key_path"
	chmod 0644 "$key_path"
	key_added=1
fi

mkdir -p "$install_root/etc/apk/repositories.d"
if [ -f "$repo_path" ]; then
	cp "$repo_path" "$tmp/repository.previous"
fi
current_repo="$(sed -n '1p' "$repo_path" 2>/dev/null || true)"
if [ "$current_repo" != "$OPENWRT_APK_FEED_URL" ]; then
	printf '%s\n' "$OPENWRT_APK_FEED_URL" >"$repo_path"
	chmod 0644 "$repo_path"
	repo_changed=1
fi

if [ -r "$world_path" ] && grep -q "^${PACKAGE_NAME}><Q" "$world_path"; then
	cp "$world_path" "$tmp/world.previous"
	awk -v package="$PACKAGE_NAME" '
		index($0, package "><Q") == 1 { print package; next }
		{ print }
	' "$world_path" >"${world_path}.new"
	chmod 0644 "${world_path}.new"
	mv "${world_path}.new" "$world_path"
	world_changed=1
fi

apk update || fail 'package indexes could not be updated; no package was installed'
if apk info --installed "$PACKAGE_NAME" >/dev/null 2>&1; then
	apk upgrade --simulate "$PACKAGE_NAME" ||
		fail 'package upgrade validation failed; the installed package was not changed'
	apk upgrade "$PACKAGE_NAME" || fail 'package upgrade failed'
else
	apk add --simulate "$PACKAGE_NAME" ||
		fail 'package transaction validation failed; no package was installed'
	apk add "$PACKAGE_NAME" || fail 'package installation failed'
fi

committed=1
printf '\nIKEv2 Manager installation complete.\n'
printf 'Open LuCI -> Services -> IKEv2 Manager.\n'
