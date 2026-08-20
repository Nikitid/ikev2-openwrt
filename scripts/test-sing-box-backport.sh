#!/bin/sh

set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
allocator="$root/patches/sing-box-1.12/100-serialize-fakeip-allocation.patch"
boundary="$root/patches/sing-box-1.12/110-fix-fakeip-range-boundaries.patch"
builder="$root/scripts/build-sing-box-backport.sh"

grep -Fq 'addressAccess sync.Mutex' "$allocator"
grep -Fq 'Double-check after acquiring lock' "$allocator"
grep -Fq 'FakeIPStore(address, domain)' "$allocator"
grep -Fq 'save FakeIP cache:' "$allocator"
if grep -E '^\+[^+].*FakeIPStoreAsync\(address, domain' "$allocator"; then
	printf 'FakeIP backport still stores new mappings asynchronously\n' >&2
	exit 1
fi
grep -Fq 'broadcastAddress(prefix netip.Prefix)' "$boundary"
grep -Fq 'nextAddress == s.inet4Last' "$boundary"
grep -Fq "grep -Fxq 'PKG_VERSION:=1.12.17'" "$builder"
grep -Fq -- "-name 'sing-box-1.12.17-r2.apk'" "$builder"
grep -Fq 'host_make golang1.26' "$builder"
grep -Fq 'go1.24.13.linux-amd64.tar.gz' "$builder"
grep -Fq '1fc94b57134d51669c72173ad5d49fd62afb0f1db9bf3f798fd98ee423f8d730' "$builder"

printf 'sing-box FakeIP backport checks OK\n'
