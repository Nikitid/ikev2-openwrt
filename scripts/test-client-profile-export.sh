#!/bin/sh

set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM

mkdir -p \
	"$tmp/root/etc/config" \
	"$tmp/root/etc/ikev2-manager" \
	"$tmp/root/usr/libexec/ikev2-manager.d" \
	"$tmp/bin"
cp "$root/ikev2-manager-runtime/lib/actions.sh" \
	"$tmp/root/usr/libexec/ikev2-manager.d/actions.sh"

cat >"$tmp/bin/uci" <<'EOF'
#!/bin/sh
key=
command=
for argument in "$@"; do
	key="$argument"
	case "$argument" in get | set | commit | add_list | delete) command="$argument" ;; esac
done
[ "$command" = get ] || exit 0
case "$key" in
	ikev2-manager.server.enabled) echo 1 ;;
	ikev2-manager.server.identity) echo 'vpn.example.test' ;;
	ikev2-manager.server.dns4) echo '10.20.30.1' ;;
	ikev2-manager.server.mtu) echo 1400 ;;
	ikev2-manager.server.local_ts) echo '0.0.0.0/0' ;;
	*) exit 1 ;;
esac
EOF
chmod 755 "$tmp/bin/uci"

password='p&<secret>"'"'"''
encoded="$(printf '%s' "$password" | openssl base64 -A)"
printf 'user.name@example\t0s%s\n' "$encoded" \
	>"$tmp/root/etc/ikev2-manager/users.db"

export_profile() {
	platform="$1"
	PATH="$tmp/bin:$PATH" \
	IKEV2_ROOT="$tmp/root" \
	IKEV2_UCI_BIN="$tmp/bin/uci" \
	IKEV2_RUNTIME_LIB_DIR="$tmp/root/usr/libexec/ikev2-manager.d" \
		sh "$root/luci-ikev2-manager/ikev2-manager.sh" \
		profile-export "$platform" user.name@example
}

export_profile apple >"$tmp/apple.mobileconfig"
export_profile windows >"$tmp/windows.xml"
export_profile android >"$tmp/android.txt"

python3 - "$tmp/apple.mobileconfig" "$tmp/windows.xml" <<'PY'
import sys
import xml.etree.ElementTree as ET

for filename in sys.argv[1:]:
    ET.parse(filename)
PY

grep -Fq '<key>AuthPassword</key><string>p&amp;&lt;secret&gt;&quot;&apos;</string>' \
	"$tmp/apple.mobileconfig"
grep -Fq '<key>AuthName</key><string>user.name@example</string>' \
	"$tmp/apple.mobileconfig"
if grep -Fq '<key>DNS</key>' "$tmp/apple.mobileconfig"; then
	printf 'Apple profile contains an unsupported embedded DNS dictionary\n' >&2
	exit 1
fi

grep -Fq '<DomainName>.</DomainName>' "$tmp/windows.xml"
grep -Fq '<DnsServers>10.20.30.1</DnsServers>' "$tmp/windows.xml"
grep -Fq '<ProfileName>vpn.example.test</ProfileName>' "$tmp/windows.xml"
grep -Fq '<Persistent>false</Persistent>' "$tmp/windows.xml"
grep -Fq '<AutoTrigger>false</AutoTrigger>' "$tmp/windows.xml"
if grep -Fq "$password" "$tmp/windows.xml" || grep -Fq "$encoded" "$tmp/windows.xml"; then
	printf 'Windows VPNv2 profile unexpectedly contains the user password\n' >&2
	exit 1
fi
grep -Fq "Password: $password" "$tmp/android.txt"
if grep -Fq "Password: 0s$encoded" "$tmp/android.txt"; then
	printf 'Android instructions contain the encoded strongSwan secret\n' >&2
	exit 1
fi

printf 'client profile export tests OK\n'
