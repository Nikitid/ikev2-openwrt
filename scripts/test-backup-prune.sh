#!/bin/sh

# A transaction killed before it finished left its full copy of network, dhcp
# and firewall on flash for good. Such leftovers are removed after a week;
# recent ones and backups made by hand under other names stay.

set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
helper="$root/ikev2-manager-runtime/ikev2-manager-system.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM

fail() {
	printf '%s\n' "$*" >&2
	exit 1
}

awk '
	index($0, "prune_stale_backups() {") == 1 { body = 1 }
	body { print }
	body && $0 == "}" { exit }
' "$helper" >"$tmp/functions.sh"
grep -q '^prune_stale_backups() {' "$tmp/functions.sh" || fail 'prune_stale_backups is missing'
. "$tmp/functions.sh"
backup_root="$tmp/backups"
backup_labels="$(sed -n "s/^backup_labels='\(.*\)'$/\1/p" "$helper")"
[ -n "$backup_labels" ] || fail 'the backup labels are not declared'

mkdir -p "$backup_root"
for name in 20250101-000000-123-apply 20250101-000000-enable-managed \
	20250101-000000-456-disable-managed 20990101-000000-789-apply \
	20250101-000000-doh-cutover manual-before-upgrade; do
	mkdir -p "$backup_root/$name"
done
for name in 20250101-000000-123-apply 20250101-000000-enable-managed \
	20250101-000000-456-disable-managed 20250101-000000-doh-cutover manual-before-upgrade; do
	touch -t 202501010000 "$backup_root/$name"
done
prune_stale_backups
for name in 20250101-000000-123-apply 20250101-000000-enable-managed 20250101-000000-456-disable-managed; do
	[ ! -e "$backup_root/$name" ] || fail "a stale transaction backup survived: $name"
done
for name in 20990101-000000-789-apply 20250101-000000-doh-cutover manual-before-upgrade; do
	[ -d "$backup_root/$name" ] || fail "a backup that is not a stale leftover was removed: $name"
done
# Every label the helper backs up under is one it may prune.
for label in $(grep -o 'backup_uci_state [a-z-]*' "$helper" | awk '{ print $2 }' | sort -u); do
	case " $backup_labels " in *" $label "*) ;; *) fail "backup label $label is never pruned" ;; esac
done

printf '%s\n' 'backup prune tests OK'
