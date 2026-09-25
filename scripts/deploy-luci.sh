#!/bin/sh
#
# Push the LuCI assets straight to a router for iteration, without cutting a
# version, a tag, a release or a feed rebuild. This is for trying a layout on a
# real page; the feed remains the only way a change reaches a router for good.
#
# The file mapping is read out of the OpenWrt Makefile rather than repeated
# here, so a resource added there is deployed without touching this script.
#
# Usage: scripts/deploy-luci.sh [user@]host [ssh-port]

set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
host="${1:-}"
port="${2:-1111}"

[ -n "$host" ] || {
	printf 'Usage: %s [user@]host [ssh-port]\n' "$0" >&2
	exit 1
}

# The www assets plus the menu and ACL that wire them: a renamed view resource
# is invisible until the menu points at the new name, and a new helper call is
# refused until the ACL lists it. Runtime scripts change behaviour on the router
# and stay out of this - they belong in a package.
mapping="$(sed -n 's|^[[:space:]]*$(INSTALL_DATA)[[:space:]]*\./\([^[:space:]]*\)[[:space:]]*$(1)\(/www/luci-static/[^[:space:]]*\)$|\1 \2|p;
	s|^[[:space:]]*$(INSTALL_DATA)[[:space:]]*\./\([^[:space:]]*\)[[:space:]]*$(1)\(/usr/share/luci/menu\.d/[^[:space:]]*\)$|\1 \2|p;
	s|^[[:space:]]*$(INSTALL_DATA)[[:space:]]*\./\([^[:space:]]*\)[[:space:]]*$(1)\(/usr/share/rpcd/acl\.d/[^[:space:]]*\)$|\1 \2|p' \
	"$root/Makefile")"

[ -n "$mapping" ] || {
	printf 'no LuCI assets found in the Makefile install recipe\n' >&2
	exit 1
}

count=0
printf '%s\n' "$mapping" | while read -r source target; do
	[ -f "$root/$source" ] || {
		printf 'missing source: %s\n' "$source" >&2
		exit 1
	}
	scp -q -O -P "$port" "$root/$source" "$host:$target"
	printf '  %s -> %s\n' "$source" "$target"
	count=$((count + 1))
done

# The pages are translated from the compiled catalog, which the Makefile builds
# rather than copies, so it is compiled and pushed here the same way.
catalog="$(mktemp)"
trap 'rm -f "$catalog"' EXIT
python3 "$root/scripts/po2lmo.py" "$root/po/ru/ikev2-manager.po" "$catalog"
scp -q -O -P "$port" "$catalog" "$host:/usr/lib/lua/luci/i18n/ikev2-manager.ru.lmo"
ssh -p "$port" "$host" 'chmod 644 /usr/lib/lua/luci/i18n/ikev2-manager.ru.lmo'
printf '  %s -> %s\n' po/ru/ikev2-manager.po /usr/lib/lua/luci/i18n/ikev2-manager.ru.lmo

# LuCI caches the compiled dispatch tree and the resource list; without this the
# router keeps serving the previous page until something else invalidates them.
ssh -p "$port" "$host" 'rm -f /tmp/luci-indexcache*; rm -rf /tmp/luci-modulecache
[ ! -x /etc/init.d/rpcd ] || /etc/init.d/rpcd reload >/dev/null 2>&1
exit 0'

printf 'deployed LuCI assets to %s\n' "$host"
