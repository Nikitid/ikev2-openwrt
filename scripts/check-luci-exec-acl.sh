#!/bin/sh

set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
setup="$root/luci-ikev2-manager/setup.js"
acl="$root/luci-ikev2-manager/acl.json"

# Keep the readiness command covered explicitly. LuCI's file RPC checks the
# executable and argument string as one ACL key, so allowing the related
# full doctor command does not authorize doctor-ui.
grep -Fq "fs.exec(helper, [ 'doctor-ui' ])" "$setup"
grep -Fq '"/usr/libexec/ikev2-manager-system doctor-ui": [ "exec" ]' "$acl"

printf '%s\n' 'LuCI exec ACL checks OK'
