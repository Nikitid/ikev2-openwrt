#!/bin/sh

set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
builder="$root/scripts/build-sing-box-update.sh"

grep -Fq 'target_version=1.13.19' "$builder"
grep -Fq 'target_release=2' "$builder"
grep -Fq 'abc2f4805b3fd088c18a5694b51fed6f0e1d06632fae98029d6bf7bd79a1b3a2' "$builder"
grep -Fq 'e99adbc49f7a11d0377c8135fe706c7757b9e68c' "$builder"
grep -Fq 'b3ec2cb62ed6b0661f9ab9d566301f84385db01fe9365ab0d823a624cd5e0aac' "$builder"
grep -Fq 'host_make golang1.26' "$builder"
grep -Fq 'go1.24.13.linux-amd64.tar.gz' "$builder"
grep -Fq -- '-name "sing-box-$target_version-r$target_release.apk"' "$builder"
if grep -Fq 'patches/sing-box-1.12' "$builder"; then
	printf '%s\n' 'obsolete 1.12 patch was included in the 1.13 build' >&2
	exit 1
fi

printf '%s\n' 'sing-box update checks OK'
