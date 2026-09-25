#!/bin/sh

set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM

mkdir -p \
	"$tmp/root/etc/config" \
	"$tmp/root/etc/ikev2-manager" \
	"$tmp/root/etc/swanctl/conf.d" \
	"$tmp/root/usr/libexec/ikev2-manager.d" \
	"$tmp/bin"
cp "$root"/ikev2-manager-runtime/lib/*.sh "$tmp/root/usr/libexec/ikev2-manager.d/"

cat >"$tmp/bin/uci" <<'EOF'
#!/bin/sh
exit 0
EOF
cat >"$tmp/bin/swanctl" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$tmp/swanctl.log"
exit 0
EOF
chmod 755 "$tmp/bin/uci" "$tmp/bin/swanctl"

cat >"$tmp/user.in" <<'EOF'
add
user.name@example
test password #1
EOF

PATH="$tmp/bin:$PATH" \
IKEV2_ROOT="$tmp/root" \
IKEV2_UCI_BIN="$tmp/bin/uci" \
IKEV2_USER_INPUT="$tmp/user.in" \
IKEV2_RUNTIME_LIB_DIR="$tmp/root/usr/libexec/ikev2-manager.d" \
	sh "$root/luci-ikev2-manager/ikev2-manager.sh" user-secret-set

secrets="$tmp/root/etc/swanctl/conf.d/91-inbound-secrets.conf"
grep -q '^[[:space:]]*eap-1 {' "$secrets"
grep -q '^[[:space:]]*id = "user.name@example"$' "$secrets"
if grep -q 'eap-user.name@example' "$secrets"; then
	printf 'user-controlled EAP section name was generated\n' >&2
	exit 1
fi
grep -q '^--load-creds --clear --noprompt$' "$tmp/swanctl.log"

printf 'user credential tests OK\n'
