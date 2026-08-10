#!/bin/sh

set -eu

root="$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)"
makefile="$root/Makefile"
prerm="$root/scripts/package-prerm.sh"

PKG_UPGRADE=1 sh "$prerm"
sh "$prerm" upgrade

grep -Fq '[ "$${PKG_UPGRADE:-0}" = 1 ] && exit 0' "$makefile"
grep -Fq 'upgrade) exit 0 ;;' "$makefile"
grep -Fq 'rm -f /tmp/ikev2-manager-dhcp.before-deps' "$makefile"
grep -Fq 'rm -rf /tmp/ikev2-manager-dns-packages' "$makefile"
grep -Fq '/www/luci-static/resources/view/status/include/06_ikev2-manager.js' \
	"$makefile" "$root/scripts/stage-package.sh"
grep -Fq '/etc/init.d/ikev2-dns-segments' \
	"$makefile" "$root/scripts/stage-package.sh"
grep -Fq '/usr/libexec/ikev2-manager.d/devices.sh' \
	"$makefile" "$root/scripts/stage-package.sh"

if sed -n '/case "$${1:-}" in/,/esac/p' "$makefile" |
	grep -Fq '*) exit 0'; then
	printf '%s\n' 'APK pre-deinstall still rejects the old-version argument' >&2
	exit 1
fi

grep -Fq '[ "${PKG_UPGRADE:-0}" = 1 ] && exit 0' "$prerm"
grep -Fq 'upgrade) exit 0 ;;' "$prerm"
if sed -n '/case "${1:-}" in/,/esac/p' "$prerm" | grep -Fq '*) exit 0'; then
	printf '%s\n' 'standalone prerm still rejects the apk old-version argument' >&2
	exit 1
fi

if grep -R -F '/etc/init.d/rpcd restart' "$makefile" "$prerm" "$root/scripts/stage-package.sh"; then
	printf '%s\n' 'package lifecycle scripts must not restart rpcd during apk/opkg transactions' >&2
	exit 1
fi

for packaging in "$makefile" "$root/scripts/stage-package.sh"; do
	grep -Fq '/etc/init.d/rpcd reload' "$packaging" || {
		printf '%s\n' "package postinst does not reload rpcd ACLs: $packaging" >&2
		exit 1
	}
	grep -Fq '_upgrade-reconcile' "$packaging" || {
		printf '%s\n' "package postinst does not reconcile the installed runtime: $packaging" >&2
		exit 1
	}
done

for packaging in "$makefile" "$root/scripts/stage-package.sh"; do
	postinst="$(sed -n '/runtime-reconcile begin/,/runtime-reconcile end/p' "$packaging")"
	printf '%s\n' "$postinst" | grep -Fq '_upgrade-reconcile'
	if printf '%s\n' "$postinst" | sed '/^[[:space:]]*#/d' |
		grep -Eq '/etc/init\.d|fw4[[:space:]]|[[:space:]]restart([[:space:]]|$)'; then
		printf '%s\n' "runtime reconciliation contains a disruptive service action: $packaging" >&2
		exit 1
	fi
done

printf '%s\n' 'package lifecycle tests OK'
