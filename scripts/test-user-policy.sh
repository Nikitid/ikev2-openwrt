#!/bin/sh

set -eu

root="$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
export IKEV2_USER_POLICY_LOCK="$tmp/user-policy.lock"
cleanup() {
	if [ "${KEEP_TEST_TMP:-0}" = 1 ]; then
		printf 'test_tmp=%s\n' "$tmp" >&2
	else
		rm -rf "$tmp"
	fi
}
trap cleanup EXIT INT TERM

mkdir -p \
	"$tmp/root/etc/config" \
	"$tmp/root/etc/ikev2-manager" \
	"$tmp/root/etc/swanctl/conf.d" \
	"$tmp/root/usr/libexec/ikev2-manager.d" \
	"$tmp/bin"
cp "$root/ikev2-manager-runtime/lib/actions.sh" \
	"$tmp/root/usr/libexec/ikev2-manager.d/actions.sh"
uci_db="$tmp/root/etc/config/ikev2-manager"
: >"$uci_db"

cat >"$tmp/bin/uci" <<EOF
#!/bin/sh
db='$uci_db'
while [ "\${1:-}" = -c ] || [ "\${1:-}" = -q ]; do
	[ "\$1" = -c ] && shift 2 || shift
done
command="\${1:-}"
shift || true
case "\$command" in
	get)
		key="\${1:-}"
		value="\$(awk -v key="\$key" '
			index(\$0, key "=") == 1 { value = substr(\$0, length(key) + 2) }
			END { print value }
		' "\$db")"
		printf '%s\\n' "\$value"
		[ -n "\$value" ]
		;;
	set)
		assignment="\${1:-}"
		key="\${assignment%%=*}"
		value="\${assignment#*=}"
		grep -v "^\${key}=" "\$db" >"\$db.new" || true
		printf '%s=%s\\n' "\$key" "\$value" >>"\$db.new"
		mv "\$db.new" "\$db"
		;;
	delete)
		key="\${1:-}"
		grep -v "^\${key}=" "\$db" >"\$db.new" || true
		mv "\$db.new" "\$db"
		;;
	add_list)
		assignment="\${1:-}"
		key="\${assignment%%=*}"
		value="\${assignment#*=}"
		current="\$(sed -n "s|^\${key}=||p" "\$db" | tail -n 1)"
		"\$0" set "\$key=\${current:+\$current }\$value"
		;;
	show)
		prefix="\${1:-}"
		[ -n "\$prefix" ] && grep "^\${prefix}\\." "\$db" || cat "\$db"
		;;
	commit | revert) ;;
	*) exit 1 ;;
esac
EOF
chmod 755 "$tmp/bin/uci"

cat >"$tmp/bin/swanctl" <<EOF
#!/bin/sh
if [ "\$*" = '--list-sas --ike ikev2-in --raw' ] && [ -r '$tmp/swanctl.raw' ]; then
	cat '$tmp/swanctl.raw'
	exit 0
fi
printf '%s\\n' "\$*" >>'$tmp/swanctl.log'
exit 0
EOF
cat >"$tmp/bin/ip" <<'EOF'
#!/bin/sh
if [ "$*" = '-4 rule show' ]; then
	[ "${MOCK_WAN_MARK_MISSING:-0}" = 1 ] ||
		echo '30000: from all fwmark 0x10000/0xff0000 lookup pbr_wan'
fi
EOF
cat >"$tmp/bin/nft" <<'EOF'
#!/bin/sh
exit 1
EOF
cat >"$tmp/bin/fw4" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod 755 "$tmp/bin/swanctl" "$tmp/bin/ip" "$tmp/bin/nft" "$tmp/bin/fw4"

cat >"$uci_db" <<'EOF'
ikev2-manager.globals=globals
ikev2-manager.globals.schema_version=1
ikev2-manager.globals.configured=0
ikev2-manager.server=server
ikev2-manager.server.enabled=0
ikev2-manager.server.allow_router=0
ikev2-manager.server.allow_internet=1
ikev2-manager.server.allow_lan=1
ikev2-manager.domains=domains
ikev2-manager.domains.engine=fakeip
ikev2-manager.domains.fakeip_range=198.18.0.0/15
EOF
printf 'alice\t0sc2VjcmV0\n' >"$tmp/root/etc/ikev2-manager/users.db"
cat >"$tmp/policy.in" <<'EOF'
policy
alice

allow
deny
limited
exclude
192.168.1.20 192.168.50.0/24
1443,8443-8445
EOF

PATH="$tmp/bin:$PATH" \
IKEV2_ROOT="$tmp/root" \
IKEV2_UCI_BIN="$tmp/bin/uci" \
IKEV2_USER_INPUT="$tmp/policy.in" \
IKEV2_RUNTIME_LIB_DIR="$tmp/root/usr/libexec/ikev2-manager.d" \
	sh "$root/luci-ikev2-manager/ikev2-manager.sh" user-secret-set

section="user_$(printf '%s' alice | sha256sum | awk '{ print substr($1, 1, 16) }')"
grep -Fxq "ikev2-manager.$section=user_policy" "$uci_db"
grep -Fxq "ikev2-manager.$section.username=alice" "$uci_db"
grep -Fxq "ikev2-manager.$section.router_access=allow" "$uci_db"
grep -Fxq "ikev2-manager.$section.internet_access=deny" "$uci_db"
grep -Fxq "ikev2-manager.$section.lan_access=limited" "$uci_db"
grep -Fxq "ikev2-manager.$section.pbr_mode=exclude" "$uci_db"
grep -Fxq "ikev2-manager.$section.lan_targets=192.168.1.20/32 192.168.50.0/24" "$uci_db"
grep -Fxq "ikev2-manager.$section.public_ports=1443 8443-8445" "$uci_db"

cat >"$tmp/invalid.in" <<'EOF'
policy
alice

inherit
inherit
limited
inherit

EOF
if PATH="$tmp/bin:$PATH" \
	IKEV2_ROOT="$tmp/root" \
	IKEV2_UCI_BIN="$tmp/bin/uci" \
	IKEV2_USER_INPUT="$tmp/invalid.in" \
	IKEV2_RUNTIME_LIB_DIR="$tmp/root/usr/libexec/ikev2-manager.d" \
	sh "$root/luci-ikev2-manager/ikev2-manager.sh" user-secret-set >/dev/null 2>&1; then
	printf '%s\n' 'empty limited-access policy was accepted' >&2
	exit 1
fi
grep -Fxq "ikev2-manager.$section.lan_access=limited" "$uci_db"

cat >"$tmp/invalid-ports.in" <<'EOF'
policy
alice

deny
inherit
deny
inherit

0 1443
EOF
if PATH="$tmp/bin:$PATH" \
	IKEV2_ROOT="$tmp/root" \
	IKEV2_UCI_BIN="$tmp/bin/uci" \
	IKEV2_USER_INPUT="$tmp/invalid-ports.in" \
	IKEV2_RUNTIME_LIB_DIR="$tmp/root/usr/libexec/ikev2-manager.d" \
	sh "$root/luci-ikev2-manager/ikev2-manager.sh" user-secret-set >/dev/null 2>&1; then
	printf '%s\n' 'invalid public router port was accepted' >&2
	exit 1
fi
grep -Fxq "ikev2-manager.$section.public_ports=1443 8443-8445" "$uci_db"

"$tmp/bin/uci" set ikev2-manager.globals.configured=1
"$tmp/bin/uci" set ikev2-manager.server.enabled=1
cat >"$tmp/bin/system-fail" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod 755 "$tmp/bin/system-fail"
cat >"$tmp/rollback.in" <<'EOF'
policy
alice

deny
allow
deny
inherit

EOF
if PATH="$tmp/bin:$PATH" \
	IKEV2_ROOT="$tmp/root" \
	IKEV2_UCI_BIN="$tmp/bin/uci" \
	IKEV2_USER_INPUT="$tmp/rollback.in" \
	IKEV2_RUNTIME_LIB_DIR="$tmp/root/usr/libexec/ikev2-manager.d" \
	IKEV2_SYSTEM_HELPER="$tmp/bin/system-fail" \
	sh "$root/luci-ikev2-manager/ikev2-manager.sh" user-secret-set >/dev/null 2>&1; then
	printf '%s\n' 'failed runtime apply was reported as successful' >&2
	exit 1
fi
grep -Fxq "ikev2-manager.$section.router_access=allow" "$uci_db"
grep -Fxq "ikev2-manager.$section.internet_access=deny" "$uci_db"
grep -Fxq "ikev2-manager.$section.lan_access=limited" "$uci_db"
cat >"$tmp/add-rollback.in" <<'EOF'
add
charlie
temporary-secret
deny
deny
deny
exclude

EOF
if PATH="$tmp/bin:$PATH" \
	IKEV2_ROOT="$tmp/root" \
	IKEV2_UCI_BIN="$tmp/bin/uci" \
	IKEV2_USER_INPUT="$tmp/add-rollback.in" \
	IKEV2_RUNTIME_LIB_DIR="$tmp/root/usr/libexec/ikev2-manager.d" \
	IKEV2_SYSTEM_HELPER="$tmp/bin/system-fail" \
	sh "$root/luci-ikev2-manager/ikev2-manager.sh" user-secret-set >/dev/null 2>&1; then
	printf '%s\n' 'new user survived a failed policy runtime apply' >&2
	exit 1
fi
if grep -q '^charlie	' "$tmp/root/etc/ikev2-manager/users.db"; then
	printf '%s\n' 'new credential survived a failed policy runtime apply' >&2
	exit 1
fi
charlie_section="user_$(printf '%s' charlie | sha256sum |
	awk '{ print substr($1, 1, 16) }')"
if grep -Fq "ikev2-manager.$charlie_section=" "$uci_db"; then
	printf '%s\n' 'new-user policy survived a failed runtime apply' >&2
	exit 1
fi
"$tmp/bin/uci" set ikev2-manager.globals.configured=0
"$tmp/bin/uci" set ikev2-manager.server.enabled=0

cat >>"$uci_db" <<EOF
ikev2-manager.globals.configured=1
ikev2-manager.server.enabled=1
ikev2-manager.server.custom_config=0
ikev2-manager.server.pool4=10.20.30.10-10.20.30.100
ikev2-manager.server.lan_zone=lan
firewall.@zone[0]=zone
firewall.@zone[0].name=lan
firewall.@zone[0].network=lan
firewall.@zone[1]=zone
firewall.@zone[1].name=ikev2in
firewall.@zone[1].network=ikev2in
firewall.ikev2in=zone
firewall.ikev2in.name='ikev2in'
network.lan.device=br-lan
EOF
printf 'bob\t0sYm9i\n' >>"$tmp/root/etc/ikev2-manager/users.db"

"$tmp/bin/uci" set ikev2-manager.server.allow_internet=0
"$tmp/bin/uci" set ikev2-manager.server.allow_lan=0
"$tmp/bin/uci" set ikev2-manager.server.allow_router=0
PATH="$tmp/bin:$PATH" \
IKEV2_UCI_BIN="$tmp/bin/uci" \
IKEV2_UCI_CONFIG_DIR="$tmp/root/etc/config" \
IKEV2_RUNTIME_LIB_DIR="$root/ikev2-manager-runtime/lib" \
IKEV2_USER_POLICY_HELPER="$tmp/not-installed" \
	sh "$root/ikev2-manager-runtime/ikev2-manager-system.sh" access-apply
grep -Fxq 'firewall.ikev2access_router=rule' "$uci_db"
grep -Fxq 'firewall.ikev2access_in_lan=forwarding' "$uci_db"
grep -Fxq 'firewall.ikev2access_public=rule' "$uci_db"
grep -Fxq 'firewall.ikev2access_public.dest_port=1443 8443-8445' "$uci_db"
if grep -Fq 'firewall.ikev2access_in_wan=forwarding' "$uci_db"; then
	printf '%s\n' 'per-user Internet deny opened the underlying WAN forwarding' >&2
	exit 1
fi
"$tmp/bin/uci" set ikev2-manager.server.allow_internet=1
"$tmp/bin/uci" set ikev2-manager.server.allow_lan=1

cat >"$tmp/sessions" <<'EOF'
alice	10.20.30.10
bob	10.20.30.11
unknown	10.20.30.12
EOF

PATH="$tmp/bin:$PATH" \
IKEV2_UCI_BIN="$tmp/bin/uci" \
IKEV2_UCI_CONFIG_DIR="$tmp/root/etc/config" \
IKEV2_USERS_DB="$tmp/root/etc/ikev2-manager/users.db" \
IKEV2_SESSIONS_FILE="$tmp/sessions" \
IKEV2_NFT="$tmp/bin/nft" \
IKEV2_RULES_OUT="$tmp/rules.nft" \
	sh "$root/ikev2-manager-runtime/ikev2-user-policy.sh" sync >/dev/null

grep -Fq 'elements = { 10.20.30.10-10.20.30.100 }' "$tmp/rules.nft"
grep -A5 'set router_allowed' "$tmp/rules.nft" | grep -Fq '10.20.30.10'
grep -A5 'set internet_allowed' "$tmp/rules.nft" | grep -Fq '10.20.30.11'
grep -A5 'set lan_full' "$tmp/rules.nft" | grep -Fq '10.20.30.11'
grep -A5 'set pbr_excluded' "$tmp/rules.nft" | grep -Fq '10.20.30.10'
grep -Fq 'ip saddr @lan_limited_1 ip daddr { 192.168.1.20/32, 192.168.50.0/24 } return' \
	"$tmp/rules.nft"
grep -Fq 'meta l4proto { tcp, udp } th dport 53 return' "$tmp/rules.nft"
grep -Fq 'ip saddr @inbound_pool counter drop' "$tmp/rules.nft"
grep -A5 'set public_client_1' "$tmp/rules.nft" | grep -Fq '10.20.30.10'
grep -Fq 'iifname "ipsec-in" ip saddr @public_client_1 meta l4proto { tcp, udp } th dport { 1443, 8443-8445 } return' \
	"$tmp/rules.nft"
grep -Fq 'meta mark set meta mark & 0xff00ffff | 0x00010000' "$tmp/rules.nft"
grep -Fq 'tproxy ip to 127.0.0.1:1603' "$tmp/rules.nft"
grep -Fq 'type filter hook prerouting priority -149' "$tmp/rules.nft"
grep -Fq 'meta mark & 0x00ff0000 != 0x00400000' "$tmp/rules.nft"
grep -Fq 'meta mark & 0x00ff0000 == 0x00400000 ip saddr @internet_allowed return' \
	"$tmp/rules.nft"
grep -Fq 'meta mark & 0x00ff0000 == 0x00400000 counter drop' "$tmp/rules.nft"
grep -Fq 'ip daddr @inbound_pool counter drop' "$tmp/rules.nft"
grep -A4 'set lan_devices' "$tmp/rules.nft" | grep -Fq '"br-lan"'
if grep -Fq '10.20.30.12' "$tmp/rules.nft"; then
	printf '%s\n' 'unknown authenticated identity entered the allow rules' >&2
	exit 1
fi

: >"$tmp/sessions"
PATH="$tmp/bin:$PATH" \
IKEV2_UCI_BIN="$tmp/bin/uci" \
IKEV2_UCI_CONFIG_DIR="$tmp/root/etc/config" \
IKEV2_USERS_DB="$tmp/root/etc/ikev2-manager/users.db" \
IKEV2_SESSIONS_FILE="$tmp/sessions" \
IKEV2_NFT="$tmp/bin/nft" \
IKEV2_RULES_OUT="$tmp/rules-empty.nft" \
	sh "$root/ikev2-manager-runtime/ikev2-user-policy.sh" sync >/dev/null
grep -Fq 'ip saddr @inbound_pool counter drop' "$tmp/rules-empty.nft"
if grep -A5 'set internet_allowed' "$tmp/rules-empty.nft" | grep -Fq 'elements ='; then
	printf '%s\n' 'offline users left a dynamic Internet allow entry' >&2
	exit 1
fi

cat >"$tmp/swanctl.raw" <<'EOF'
list-sa event {ikev2-in {uniqueid=7 state=ESTABLISHED remote-eap-id=alice remote-vips=[10.20.30.15] child-sas {net-1 {state=INSTALLED}}}}
EOF
PATH="$tmp/bin:$PATH" \
IKEV2_UCI_BIN="$tmp/bin/uci" \
IKEV2_UCI_CONFIG_DIR="$tmp/root/etc/config" \
IKEV2_USERS_DB="$tmp/root/etc/ikev2-manager/users.db" \
IKEV2_SWANCTL_RAW="$tmp/swanctl.raw" \
IKEV2_NFT="$tmp/bin/nft" \
IKEV2_RULES_OUT="$tmp/rules-raw.nft" \
	sh "$root/ikev2-manager-runtime/ikev2-user-policy.sh" sync >/dev/null
grep -A5 'set router_allowed' "$tmp/rules-raw.nft" | grep -Fq '10.20.30.15' || {
	cat "$tmp/rules-raw.nft" >&2
	exit 1
}

# A second, unrelated IKEv2 connection may be listed after the inbound
# sessions. Its virtual IP must never be read as a client's, or the real
# client is left unauthorised and loses all forwarded traffic.
cat >"$tmp/swanctl.raw" <<'EOF'
list-sa event {ikev2-in {uniqueid=7 state=ESTABLISHED remote-eap-id=alice remote-vips=[10.20.30.15] child-sas {net-1 {state=INSTALLED}}}} list-sa event {site-link-in {uniqueid=9 state=ESTABLISHED remote-eap-id=site-link-office remote-vips=[10.253.44.2] child-sas {site-link-net-1 {state=INSTALLED}}}}
EOF
PATH="$tmp/bin:$PATH" \
IKEV2_UCI_BIN="$tmp/bin/uci" \
IKEV2_UCI_CONFIG_DIR="$tmp/root/etc/config" \
IKEV2_USERS_DB="$tmp/root/etc/ikev2-manager/users.db" \
IKEV2_SWANCTL_RAW="$tmp/swanctl.raw" \
IKEV2_NFT="$tmp/bin/nft" \
IKEV2_RULES_OUT="$tmp/rules-foreign-sa.nft" \
	sh "$root/ikev2-manager-runtime/ikev2-user-policy.sh" sync >/dev/null
grep -A5 'set router_allowed' "$tmp/rules-foreign-sa.nft" | grep -Fq '10.20.30.15' || {
	printf '%s\n' 'the client was not authorised alongside a foreign connection' >&2
	cat "$tmp/rules-foreign-sa.nft" >&2
	exit 1
}
if grep -Fq '10.253.44.2' "$tmp/rules-foreign-sa.nft"; then
	printf '%s\n' 'a foreign connection virtual IP was authorised' >&2
	exit 1
fi

"$tmp/bin/uci" set \
	"ikev2-manager.$section.lan_targets=192.168.1.20/32;counter accept"
if PATH="$tmp/bin:$PATH" \
	IKEV2_UCI_BIN="$tmp/bin/uci" \
	IKEV2_UCI_CONFIG_DIR="$tmp/root/etc/config" \
	IKEV2_USERS_DB="$tmp/root/etc/ikev2-manager/users.db" \
	IKEV2_SWANCTL_RAW="$tmp/swanctl.raw" \
	IKEV2_NFT="$tmp/bin/nft" \
	IKEV2_RULES_OUT="$tmp/rules-invalid-target.nft" \
	sh "$root/ikev2-manager-runtime/ikev2-user-policy.sh" sync >/dev/null 2>&1; then
	printf '%s\n' 'invalid UCI local target reached nftables rule generation' >&2
	exit 1
fi
"$tmp/bin/uci" set \
	"ikev2-manager.$section.lan_targets=192.168.1.20/32 192.168.50.0/24"

"$tmp/bin/uci" set \
	"ikev2-manager.$section.public_ports=1443;counter accept"
if PATH="$tmp/bin:$PATH" \
	IKEV2_UCI_BIN="$tmp/bin/uci" \
	IKEV2_UCI_CONFIG_DIR="$tmp/root/etc/config" \
	IKEV2_USERS_DB="$tmp/root/etc/ikev2-manager/users.db" \
	IKEV2_SWANCTL_RAW="$tmp/swanctl.raw" \
	IKEV2_NFT="$tmp/bin/nft" \
	IKEV2_RULES_OUT="$tmp/rules-invalid-port.nft" \
	sh "$root/ikev2-manager-runtime/ikev2-user-policy.sh" sync >/dev/null 2>&1; then
	printf '%s\n' 'invalid UCI public router port reached nftables rule generation' >&2
	exit 1
fi
"$tmp/bin/uci" set \
	"ikev2-manager.$section.public_ports=1443 8443-8445"

if PATH="$tmp/bin:$PATH" \
	MOCK_WAN_MARK_MISSING=1 \
	IKEV2_UCI_BIN="$tmp/bin/uci" \
	IKEV2_UCI_CONFIG_DIR="$tmp/root/etc/config" \
	IKEV2_USERS_DB="$tmp/root/etc/ikev2-manager/users.db" \
	IKEV2_SWANCTL_RAW="$tmp/swanctl.raw" \
	IKEV2_NFT="$tmp/bin/nft" \
	IKEV2_RULES_OUT="$tmp/rules-no-wan-mark.nft" \
	sh "$root/ikev2-manager-runtime/ikev2-user-policy.sh" sync >/dev/null 2>&1; then
	printf '%s\n' 'PBR exclusion was accepted without an active WAN mark' >&2
	exit 1
fi

# A reauthenticating or rekeying client is listed twice by swanctl for a short
# while. The duplicate must collapse: a repeated nftables set element aborts the
# whole transaction, after which every active client loses access as soon as its
# timeout entry expires.
set_elements_of() {
	awk -v want="  set $2 {" '
		$0 == want { inside = 1; next }
		inside && /elements = \{/ {
			line = $0
			sub(/.*\{ */, "", line)
			sub(/ *\}.*/, "", line)
			print line
			exit
		}
		inside && /^  \}/ { exit }
	' "$1"
}

cat >"$tmp/sessions-duplicate" <<'EOF'
alice	10.20.30.10
alice	10.20.30.10
bob	10.20.30.11
EOF
PATH="$tmp/bin:$PATH" \
IKEV2_UCI_BIN="$tmp/bin/uci" \
IKEV2_UCI_CONFIG_DIR="$tmp/root/etc/config" \
IKEV2_USERS_DB="$tmp/root/etc/ikev2-manager/users.db" \
IKEV2_SESSIONS_FILE="$tmp/sessions-duplicate" \
IKEV2_NFT="$tmp/bin/nft" \
IKEV2_RULES_OUT="$tmp/rules-duplicate.nft" \
	sh "$root/ikev2-manager-runtime/ikev2-user-policy.sh" sync >"$tmp/duplicate.stdout"
for name in router_allowed pbr_excluded; do
	elements="$(set_elements_of "$tmp/rules-duplicate.nft" "$name")"
	[ "$elements" = '10.20.30.10' ] || {
		printf 'duplicate SA produced "%s" in %s\n' "$elements" "$name" >&2
		exit 1
	}
done
if grep -Fq '10.20.30.10' "$tmp/duplicate.stdout"; then
	printf '%s\n' 'session addresses leaked into the helper stdout' >&2
	exit 1
fi

# A stale SA can still hold an address the pool already reissued. Applying both
# identities would give that address the union of two policies.
cat >"$tmp/sessions-conflict" <<'EOF'
alice	10.20.30.10
bob	10.20.30.10
EOF
PATH="$tmp/bin:$PATH" \
IKEV2_UCI_BIN="$tmp/bin/uci" \
IKEV2_UCI_CONFIG_DIR="$tmp/root/etc/config" \
IKEV2_USERS_DB="$tmp/root/etc/ikev2-manager/users.db" \
IKEV2_SESSIONS_FILE="$tmp/sessions-conflict" \
IKEV2_NFT="$tmp/bin/nft" \
IKEV2_RULES_OUT="$tmp/rules-conflict.nft" \
	sh "$root/ikev2-manager-runtime/ikev2-user-policy.sh" sync >/dev/null
for name in router_allowed internet_allowed lan_full pbr_excluded; do
	elements="$(set_elements_of "$tmp/rules-conflict.nft" "$name")"
	[ -z "$elements" ] || {
		printf 'an address claimed by two identities kept %s: %s\n' \
			"$name" "$elements" >&2
		exit 1
	}
done
if grep -Fq 'set lan_limited_1' "$tmp/rules-conflict.nft" ||
	grep -Fq 'set public_client_1' "$tmp/rules-conflict.nft"; then
	printf '%s\n' 'an address claimed by two identities kept a per-user set' >&2
	exit 1
fi

grep -v '^network.lan.device=' "$uci_db" >"$uci_db.new"
mv "$uci_db.new" "$uci_db"
if PATH="$tmp/bin:$PATH" \
	IKEV2_UCI_BIN="$tmp/bin/uci" \
	IKEV2_UCI_CONFIG_DIR="$tmp/root/etc/config" \
	IKEV2_USERS_DB="$tmp/root/etc/ikev2-manager/users.db" \
	IKEV2_SESSIONS_FILE="$tmp/sessions" \
	IKEV2_NFT="$tmp/bin/nft" \
	IKEV2_RULES_OUT="$tmp/rules-no-lan.nft" \
	sh "$root/ikev2-manager-runtime/ikev2-user-policy.sh" sync >/dev/null 2>&1; then
	printf '%s\n' 'LAN access was accepted without a resolvable LAN interface' >&2
	exit 1
fi

# The dedicated watcher must authorize a newly established inbound SA without
# waiting for the slower general health loop. It also has to replace the policy
# when the active identity changes, using a single serialized writer.
printf '%s\n' 'network.lan.device=br-lan' >>"$uci_db"
cat >"$tmp/bin/policy-helper" <<'EOF'
#!/bin/sh
printf '%s\n' "$1" >>"$POLICY_HELPER_LOG"
case "$1" in sync | stop) exit 0 ;; *) exit 1 ;; esac
EOF
cat >"$tmp/bin/policy-init" <<'EOF'
#!/bin/sh
printf '%s\n' "$1" >>"$POLICY_INIT_LOG"
case "$1" in
	running) [ "${POLICY_INIT_RUNNING:-0}" = 1 ] ;;
	enable | disable | start | stop) exit 0 ;;
	*) exit 1 ;;
esac
EOF
chmod 755 "$tmp/bin/policy-helper" "$tmp/bin/policy-init"

# Enabling the generated inbound server must install the fail-closed table and
# start its watcher immediately, not merely arrange for it to start after the
# next reboot. Disabling the server must stop both the service and its table.
: >"$tmp/policy-helper.log"
: >"$tmp/policy-init.log"
POLICY_HELPER_LOG="$tmp/policy-helper.log" \
POLICY_INIT_LOG="$tmp/policy-init.log" \
POLICY_INIT_RUNNING=0 \
PATH="$tmp/bin:$PATH" \
IKEV2_UCI_BIN="$tmp/bin/uci" \
IKEV2_UCI_CONFIG_DIR="$tmp/root/etc/config" \
IKEV2_RUNTIME_LIB_DIR="$root/ikev2-manager-runtime/lib" \
IKEV2_USER_POLICY_HELPER="$tmp/bin/policy-helper" \
IKEV2_USER_POLICY_INIT="$tmp/bin/policy-init" \
IKEV2_DOMAIN_ROUTER_HELPER="$tmp/not-installed" \
	sh "$root/ikev2-manager-runtime/ikev2-manager-system.sh" access-apply
grep -Fxq sync "$tmp/policy-helper.log"
for action in enable running start; do grep -Fxq "$action" "$tmp/policy-init.log"; done

"$tmp/bin/uci" set ikev2-manager.server.enabled=0
: >"$tmp/policy-helper.log"
: >"$tmp/policy-init.log"
POLICY_HELPER_LOG="$tmp/policy-helper.log" \
POLICY_INIT_LOG="$tmp/policy-init.log" \
POLICY_INIT_RUNNING=1 \
PATH="$tmp/bin:$PATH" \
IKEV2_UCI_BIN="$tmp/bin/uci" \
IKEV2_UCI_CONFIG_DIR="$tmp/root/etc/config" \
IKEV2_RUNTIME_LIB_DIR="$root/ikev2-manager-runtime/lib" \
IKEV2_USER_POLICY_HELPER="$tmp/bin/policy-helper" \
IKEV2_USER_POLICY_INIT="$tmp/bin/policy-init" \
IKEV2_DOMAIN_ROUTER_HELPER="$tmp/not-installed" \
	sh "$root/ikev2-manager-runtime/ikev2-manager-system.sh" access-apply
grep -Fxq stop "$tmp/policy-helper.log"
for action in running stop disable; do grep -Fxq "$action" "$tmp/policy-init.log"; done
"$tmp/bin/uci" set ikev2-manager.server.enabled=1

cat >"$tmp/swanctl.raw" <<'EOF'
list-sa event {ikev2-in {uniqueid=20 state=ESTABLISHED remote-eap-id=alice remote-vips=[10.20.30.20] child-sas {net-1 {state=INSTALLED}}}}
EOF
PATH="$tmp/bin:$PATH" \
IKEV2_UCI_BIN="$tmp/bin/uci" \
IKEV2_UCI_CONFIG_DIR="$tmp/root/etc/config" \
IKEV2_USERS_DB="$tmp/root/etc/ikev2-manager/users.db" \
IKEV2_NFT="$tmp/bin/nft" \
IKEV2_RULES_OUT="$tmp/rules-watch.nft" \
IKEV2_USER_POLICY_WATCH_INTERVAL=1 \
IKEV2_USER_POLICY_REFRESH_INTERVAL=30 \
	sh "$root/ikev2-manager-runtime/ikev2-user-policy.sh" watch &
watch_pid=$!
watch_cleanup() {
	kill "$watch_pid" >/dev/null 2>&1 || true
	wait "$watch_pid" 2>/dev/null || true
}
trap 'watch_cleanup; cleanup' EXIT INT TERM
attempt=0
while [ "$attempt" -lt 5 ]; do
	grep -A5 'set router_allowed' "$tmp/rules-watch.nft" 2>/dev/null |
		grep -Fq '10.20.30.20' && break
	attempt=$((attempt + 1))
	sleep 1
done
[ "$attempt" -lt 5 ] || {
	printf '%s\n' 'inbound watcher did not authorize a new SA promptly' >&2
	exit 1
}
cat >"$tmp/swanctl.raw.new" <<'EOF'
list-sa event {ikev2-in {uniqueid=21 state=ESTABLISHED remote-eap-id=bob remote-vips=[10.20.30.21] child-sas {net-1 {state=INSTALLED}}}}
EOF
mv "$tmp/swanctl.raw.new" "$tmp/swanctl.raw"
attempt=0
while [ "$attempt" -lt 5 ]; do
	grep -A5 'set internet_allowed' "$tmp/rules-watch.nft" 2>/dev/null |
		grep -Fq '10.20.30.21' && break
	attempt=$((attempt + 1))
	sleep 1
done
[ "$attempt" -lt 5 ] || {
	printf '%s\n' 'inbound watcher did not replace a changed SA promptly' >&2
	exit 1
}
watch_cleanup
trap cleanup EXIT INT TERM

printf '%s\n' 'inbound user policy tests OK'
