#!/bin/sh
#
# Fail if the package identity drifts between the canonical source of truth
# (release.env, used by stage-package.sh) and the secondary OpenWrt SDK Makefile
# literals (B3). Run by scripts/build-ipk.sh before staging so a divergent
# Makefile is caught at build time instead of shipping mismatched packages.
#
# This does not unify the two build paths; it guards the highest-risk metadata
# (name/version/release/arch) so the SDK path stays interchangeable with the
# canonical packer for identity purposes.

set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
. "$root/release.env"

fail=0
note() {
	printf 'check-version-sync: %s\n' "$*" >&2
	fail=1
}

mk="$root/Makefile"
mk_field() { sed -n "s/^$1:=//p" "$mk" | head -n1; }

mk_name="$(mk_field PKG_NAME)"
mk_ver="$(mk_field PKG_VERSION)"
mk_rel="$(mk_field PKG_RELEASE)"
mk_arch="$(mk_field PKGARCH)"

[ "$mk_name" = "$PKG_NAME" ] ||
	note "Makefile PKG_NAME='$mk_name' != release.env PKG_NAME='$PKG_NAME'"
[ "$mk_ver" = "$PKG_VERSION" ] ||
	note "Makefile PKG_VERSION='$mk_ver' != release.env PKG_VERSION='$PKG_VERSION'"
[ "$mk_rel" = "$PKG_RELEASE" ] ||
	note "Makefile PKG_RELEASE='$mk_rel' != release.env PKG_RELEASE='$PKG_RELEASE'"
[ "$mk_arch" = "$PKG_ARCH" ] ||
	note "Makefile PKGARCH='$mk_arch' != release.env PKG_ARCH='$PKG_ARCH'"

# stage-package.sh must derive the version from release.env, not hardcode it.
if grep -Eq '^Version:[[:space:]]*[0-9]' "$root/scripts/stage-package.sh"; then
	note "scripts/stage-package.sh hardcodes a 'Version:' line; it must derive from release.env"
fi

# The overview reads the installed version from a stamp file. Only the canonical
# packer wrote it at first, so releases - which are built from the SDK Makefile -
# shipped without it and the page reported an unknown version. Both paths must
# install it.
grep -Fq "/usr/share/ikev2-manager/version" "$root/scripts/stage-package.sh" ||
	note 'scripts/stage-package.sh does not stamp /usr/share/ikev2-manager/version'
grep -Fq "usr/share/ikev2-manager/version" "$mk" ||
	note 'Makefile does not install /usr/share/ikev2-manager/version'

if [ "$fail" -eq 0 ]; then
	if [ -n "${PKG_RELEASE:-}" ]; then
		version="$PKG_VERSION-r$PKG_RELEASE"
	else
		version="$PKG_VERSION"
	fi
	printf 'check-version-sync OK: %s %s %s\n' \
		"$PKG_NAME" "$version" "$PKG_ARCH"
fi
exit "$fail"
