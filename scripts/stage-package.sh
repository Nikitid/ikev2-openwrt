#!/bin/sh

set -eu

[ "$#" -eq 1 ] || {
	printf 'Usage: %s STAGING_DIRECTORY\n' "$0" >&2
	exit 1
}

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
stage="$1"

# Package identity comes from release.env (single source of truth; B3).
. "$root/release.env"

rm -rf "$stage"
mkdir -p "$stage/CONTROL"

install_file() {
	mode="$1"
	source="$2"
	target="$stage$3"
	mkdir -p "${target%/*}"
	install -m "$mode" "$root/$source" "$target"
}

install_file 600 openwrt/files/etc/config/ikev2-manager /etc/config/ikev2-manager
install_file 755 ikev2-manager-runtime/ikev2-xfrm.init /etc/init.d/ikev2-xfrm
install_file 755 ikev2-manager-runtime/ikev2-health.init /etc/init.d/ikev2-health
install_file 755 ikev2-manager-runtime/ikev2-domain-router.init /etc/init.d/ikev2-domain-router
install_file 755 ikev2-manager-runtime/90-ikev2-wan /etc/hotplug.d/iface/90-ikev2-manager
install_file 755 ikev2-manager-runtime/90-ikev2-acme /etc/hotplug.d/acme/90-ikev2-manager
install_file 600 ikev2-manager-runtime/20-router-xfrm.conf /etc/strongswan.d/charon/20-ikev2-manager.conf
install_file 644 openwrt/files/etc/ikev2-manager/README /etc/ikev2-manager/README
install_file 600 openwrt/files/etc/config/ikev2-manager /usr/share/ikev2-manager/defaults/ikev2-manager
install_file 600 openwrt/files/etc/pbr-ikev2-domains.manual.txt /etc/pbr-ikev2-domains.manual.txt
install_file 600 openwrt/files/etc/pbr-ikev2-addresses.manual.txt /etc/pbr-ikev2-addresses.manual.txt
install_file 644 openwrt/files/lib/upgrade/keep.d/ikev2-manager /lib/upgrade/keep.d/ikev2-manager

install_file 755 luci-ikev2-manager/ikev2-manager.sh /usr/libexec/ikev2-manager
install_file 755 ikev2-manager-runtime/ikev2-manager-system.sh /usr/libexec/ikev2-manager-system
install_file 644 ikev2-manager-runtime/lib/actions.sh /usr/libexec/ikev2-manager.d/actions.sh
install_file 644 ikev2-manager-runtime/lib/package-manager.sh /usr/libexec/ikev2-manager.d/package-manager.sh
install_file 644 ikev2-manager-runtime/lib/dependency-state.sh /usr/libexec/ikev2-manager.d/dependency-state.sh
install_file 644 ikev2-manager-runtime/lib/routing.sh /usr/libexec/ikev2-manager.d/routing.sh
install_file 755 ikev2-manager-runtime/ikev2-health.sh /usr/libexec/ikev2-health
install_file 755 ikev2-manager-runtime/ikev2-sync-vips.sh /usr/libexec/ikev2-sync-vips
install_file 755 ikev2-manager-runtime/ikev2-domain-router.sh /usr/libexec/ikev2-domain-router
install_file 755 ikev2-manager-runtime/ikev2-discord-voice.sh /usr/libexec/ikev2-discord-voice
install_file 755 ikev2-manager-runtime/ikev2-device-routing.sh /usr/libexec/ikev2-device-routing
install_file 755 ikev2-manager-runtime/ikev2-user-policy.sh /usr/libexec/ikev2-user-policy
install_file 755 luci-ikev2-domains/community-domains.sh /usr/libexec/ikev2-domains-community
install_file 755 luci-ikev2-domains/restart-pbr.sh /usr/libexec/ikev2-domains-restart
install_file 755 luci-ikev2-domains/ikev2-devices.sh /usr/libexec/ikev2-devices
install_file 755 ikev2-manager-runtime/pbr.user.ikev2out /usr/share/pbr/pbr.user.ikev2out

install_file 644 ikev2-manager-runtime/ca/isrg-root-x1.pem /usr/share/ikev2-manager/ca/isrg-root-x1.pem
install_file 644 ikev2-manager-runtime/ca/isrg-root-x2.pem /usr/share/ikev2-manager/ca/isrg-root-x2.pem

install_file 644 LICENSE /usr/share/licenses/luci-app-ikev2-manager/LICENSE
install_file 644 NOTICE /usr/share/licenses/luci-app-ikev2-manager/NOTICE

install_file 644 luci-ikev2-domains/community-services.txt /usr/share/ikev2-domains/community-services
for source in "$root"/luci-ikev2-domains/local-services/*.lst; do
	install_file 644 "${source#"$root/"}" "/usr/share/ikev2-domains/local-services/${source##*/}"
done
for source in "$root"/luci-ikev2-domains/local-services/*.cidrs; do
	install_file 644 "${source#"$root/"}" "/usr/share/ikev2-domains/local-services/${source##*/}"
done

install_file 644 luci-ikev2-manager/menu.json /usr/share/luci/menu.d/luci-app-ikev2-manager.json
install_file 644 luci-ikev2-manager/acl.json /usr/share/rpcd/acl.d/luci-app-ikev2-manager.json
install_file 644 luci-ikev2-manager/shared.js /www/luci-static/resources/ikev2-manager/shared.js
install_file 644 luci-ikev2-manager/status-widget.js \
	/www/luci-static/resources/view/status/include/06_ikev2-manager.js
for view in setup users settings client; do
	install_file 644 "luci-ikev2-manager/$view.js" \
		"/www/luci-static/resources/view/ikev2-manager/$view.js"
done
install_file 644 luci-ikev2-domains/editor.js /www/luci-static/resources/view/ikev2-domains/editor.js

install -m 600 /dev/null "$stage/etc/pbr-ikev2-domains.txt"
install -m 600 /dev/null "$stage/etc/pbr-ikev2-community-selected.txt"

# Canonical release control file (built by scripts/build-ipk.sh via pack-ipk.py).
# Package name and Version come from release.env (single source of truth; B3);
# field order is preserved so the artifact stays byte-stable across rebuilds.
# scripts/check-version-sync.sh asserts the SDK Makefile literals still match
# (including Architecture, kept literal below as it is invariant for this pkg).
# Filesystem block allocation differs between macOS and Linux, so `du -sk`
# makes otherwise identical packages produce different control archives.
# Installed-Size is the rounded sum of payload file bytes instead.
installed_size="$(python3 - "$stage" <<'PY'
import os
import sys

total = 0
for directory, directories, files in os.walk(sys.argv[1]):
    directories[:] = [name for name in directories if name != "CONTROL"]
    for name in files:
        total += os.lstat(os.path.join(directory, name)).st_size
print((total + 1023) // 1024)
PY
)"
{
	printf 'Package: %s\n' "$PKG_NAME"
	if [ -n "$PKG_RELEASE" ]; then
		printf 'Version: %s-r%s\n' "$PKG_VERSION" "$PKG_RELEASE"
	else
		printf 'Version: %s\n' "$PKG_VERSION"
	fi
	cat <<'EOF'
Depends: luci-base, rpcd-mod-file, jsonfilter
Section: luci
Architecture: all
Maintainer: nikitid
Homepage: https://github.com/nikitid/ikev2-openwrt
Source: https://github.com/nikitid/ikev2-openwrt
EOF
	printf 'Installed-Size: %s\n' "$installed_size"
	cat <<'EOF'
Description: IKEv2 Manager for OpenWrt
 LuCI application and runtime for an IPv4 IKEv2 client, an optional
 road-warrior IKEv2 server, domain PBR, device overrides and fail-closed
 routing on OpenWrt 24.10 and experimental OpenWrt 25.12/apk.
EOF
} >"$stage/CONTROL/control"

cat >"$stage/CONTROL/conffiles" <<'EOF'
/etc/config/ikev2-manager
/etc/pbr-ikev2-domains.txt
/etc/pbr-ikev2-domains.manual.txt
/etc/pbr-ikev2-addresses.manual.txt
/etc/pbr-ikev2-community-selected.txt
EOF

install -m 755 "$root/scripts/package-preinst.sh" "$stage/CONTROL/preinst"

cat >"$stage/CONTROL/postinst" <<'EOF'
#!/bin/sh
[ -n "${IPKG_INSTROOT:-}" ] && exit 0
rm -f /tmp/luci-indexcache
rm -rf /tmp/luci-modulecache
rm -f /usr/share/nftables.d/chain-pre/forward/20-ikev2-killswitch.nft
# The project repository was renamed from ikev2-manager-openwrt to
# ikev2-openwrt. GitHub still serves the previous raw path today, but that alias
# is not a guarantee and disappears if the old name is ever reused, so an
# installation left pointing at it would silently stop receiving updates. Only
# our own list file holding exactly our own former URL is rewritten.
# feed-migration begin
ikev2_feed_list="${IKEV2_FEED_LIST:-/etc/apk/repositories.d/ikev2-manager.list}"
ikev2_feed_old=https://raw.githubusercontent.com/Nikitid/ikev2-manager-openwrt/apk-feed/packages.adb
ikev2_feed_new=https://raw.githubusercontent.com/Nikitid/ikev2-openwrt/apk-feed/packages.adb
if [ -f "$ikev2_feed_list" ] &&
	[ "$(cat "$ikev2_feed_list")" = "$ikev2_feed_old" ]; then
	if printf '%s\n' "$ikev2_feed_new" >"${ikev2_feed_list}.new" &&
		chmod 0644 "${ikev2_feed_list}.new" &&
		mv "${ikev2_feed_list}.new" "$ikev2_feed_list"; then
		echo "APK feed URL migrated to the renamed project repository."
	else
		rm -f "${ikev2_feed_list}.new"
		echo "Unable to migrate the APK feed URL; re-run install-openwrt25.sh." >&2
	fi
fi
# feed-migration end
if [ "$(uci -q get ikev2-manager.globals.configured)" = 1 ]; then
	fw4 -q reload >/dev/null 2>&1 || true
fi
if [ "$(uci -q get ikev2-manager.globals.configured)" = 1 ] || \
   [ "$(uci -q get ikev2-manager.client.enabled)" = 1 ] || \
   [ "$(uci -q get ikev2-manager.server.enabled)" = 1 ]; then
	echo "Existing configuration detected; runtime was not started automatically."
fi
echo "IKEv2 Manager for OpenWrt installed."
echo "Open LuCI -> Services -> IKEv2 Manager."
exit 0
EOF

install -m 755 "$root/scripts/package-prerm.sh" "$stage/CONTROL/prerm"

chmod 755 "$stage/CONTROL/preinst" "$stage/CONTROL/postinst" "$stage/CONTROL/prerm"
