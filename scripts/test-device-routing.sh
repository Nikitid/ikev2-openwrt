#!/bin/sh

set -eu

root="$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)"
helper="$root/ikev2-manager-runtime/ikev2-device-routing.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM
mkdir -p "$tmp/bin"

cat >"$tmp/bin/uci" <<'EOF'
#!/bin/sh
case "$*" in
	'-q get ikev2-manager.globals.configured') echo 1 ;;
	'show pbr')
		echo 'pbr.pbr_dev_fr_192_168_50_4=policy'
		echo 'pbr.pbr_dev_ex_192_168_50_9=policy'
		;;
	'-q get pbr.pbr_dev_fr_192_168_50_4.name') echo 'VPN Full Route: 192.168.50.4' ;;
	'-q get pbr.pbr_dev_fr_192_168_50_4.enabled') echo 1 ;;
	'-q get pbr.pbr_dev_fr_192_168_50_4.src_addr') echo '192.168.50.4' ;;
	'-q get pbr.pbr_dev_ex_192_168_50_9.name') echo 'VPN Exclude: 192.168.50.9' ;;
	'-q get pbr.pbr_dev_ex_192_168_50_9.enabled') echo 1 ;;
	'-q get pbr.pbr_dev_ex_192_168_50_9.src_addr') echo '192.168.50.9' ;;
	*) exit 1 ;;
esac
EOF

cat >"$tmp/bin/ip" <<'EOF'
#!/bin/sh
case "$*" in
	'-4 rule show')
		echo '30000: from all fwmark 0x10000/0xff0000 lookup pbr_wan'
		echo '29999: from all fwmark 0x20000/0xff0000 lookup pbr_ikev2out'
		;;
	'-4 route show table main default')
		[ "${TEST_DEFAULT_ROUTE_DOWN:-0}" = 1 ] ||
			echo "default via 192.0.2.1 dev ${TEST_DEFAULT_DEVICE:-eth0}"
		;;
	*) exit 1 ;;
esac
EOF

cat >"$tmp/bin/ipcalc.sh" <<'EOF'
#!/bin/sh
case "$1" in 192.168.50.4/32 | 192.168.50.9/32) exit 0 ;; *) exit 1 ;; esac
EOF

cat >"$tmp/bin/nft" <<'EOF'
#!/bin/sh
case "$*" in
	'list table inet ikev2_device_policy_test')
		[ -s "$TEST_NFT_STATE" ] || exit 1
		cat "$TEST_NFT_RULESET"
		;;
	'list set inet ikev2_device_policy_test '*)
		[ -s "$TEST_NFT_STATE" ] || exit 1
		set_name="${5:-}"
		awk -v wanted="$set_name" '
			$0 ~ ("set " wanted " ") { active=1 }
			active { print }
			active && /^  }/ { exit }
		' "$TEST_NFT_RULESET"
		;;
	'list chain inet ikev2_device_policy_test '*)
		[ -s "$TEST_NFT_STATE" ] || exit 1
		chain="${5:-}"
		grep -Fq "chain $chain" "$TEST_NFT_RULESET" || exit 1
		awk -v wanted="$chain" '
			$0 ~ ("chain " wanted " ") { active=1 }
			active { print }
			active && /^  }/ { exit }
		' "$TEST_NFT_RULESET"
		;;
	'delete table inet ikev2_device_policy_test') rm -f "$TEST_NFT_STATE" ;;
	'-c -f '*) exit 0 ;;
	'-f '*)
		cp "$2" "$TEST_NFT_RULESET"
		printf x >"$TEST_NFT_STATE"
		printf 'apply\n' >>"$TEST_NFT_LOG"
		;;
	*) exit 1 ;;
esac
EOF
chmod 755 "$tmp/bin/uci" "$tmp/bin/ip" "$tmp/bin/ipcalc.sh" "$tmp/bin/nft"

: >"$tmp/nft.log"
export PATH="$tmp/bin:$PATH"
export TEST_NFT_STATE="$tmp/nft.state"
export TEST_NFT_RULESET="$tmp/rules.nft"
export TEST_NFT_LOG="$tmp/nft.log"
export IKEV2_NFT="$tmp/bin/nft"
export IKEV2_DEVICE_TABLE='ikev2_device_policy_test'
export IKEV2_DEVICE_SIGNATURE="$tmp/signature"
export IKEV2_RUNTIME_LIB_DIR="$root/ikev2-manager-runtime/lib"

# The stub exposes only the previous representation, so this run also covers
# the compatibility path taken between a package upgrade and the first apply.
"$helper" sync
grep -Fq 'chain ikev2_manager_owned' "$tmp/rules.nft"
grep -Fq 'elements = { 192.168.50.4 }' "$tmp/rules.nft"
grep -Fq 'elements = { 192.168.50.9 }' "$tmp/rules.nft"
grep -Fq 'ip saddr 192.168.50.9 meta mark set meta mark & 0xff00ffff | 0x00010000 counter accept comment "ikev2-device:exclude:192.168.50.9"' "$tmp/rules.nft"
grep -Fq 'ip saddr 192.168.50.4 meta mark set meta mark & 0xff00ffff | 0x00020000 counter accept comment "ikev2-device:fullroute:192.168.50.4"' "$tmp/rules.nft"
"$helper" check
"$helper" sync
[ "$(wc -l <"$tmp/nft.log" | tr -d ' ')" = 1 ]

# Second phase: the migrated schema is authoritative and the previous
# representation is absent. Different addresses prove the rules were rewritten
# rather than served from the unchanged-signature shortcut.
cat >"$tmp/bin/uci" <<'EOF'
#!/bin/sh
case "$*" in
	'-q get ikev2-manager.globals.configured') echo 1 ;;
	'-q get ikev2-manager.globals.device_schema') echo 2 ;;
	'-q get ikev2-manager.globals.dns_enforce') echo 1 ;;
	'-q get ikev2-manager.globals.block_dot') echo 1 ;;
	'-q get ikev2-manager.globals.source_interface') echo lan ;;
	'-q get ikev2-manager.globals.source_include_vpn') echo 1 ;;
	'-q get ikev2-manager.globals.wan_interface') echo "${TEST_MANAGER_WAN:-wan}" ;;
	'-q get ikev2-manager.server.enabled') echo 1 ;;
	'-q get network.lan.device') echo br-lan ;;
	'-q get network.wan.device') [ "${TEST_WAN_DOWN:-0}" != 1 ] && echo eth0 ;;
	'show ikev2-manager')
		echo 'ikev2-manager.device_192_168_60_5=device_policy'
		echo 'ikev2-manager.device_192_168_60_9=device_policy'
		;;
	'-q get ikev2-manager.device_192_168_60_5.address') echo '192.168.60.5' ;;
	'-q get ikev2-manager.device_192_168_60_5.route_mode') echo 'fullroute' ;;
	'-q get ikev2-manager.device_192_168_60_5.dns_passthrough') echo 1 ;;
	'-q get ikev2-manager.device_192_168_60_9.address') echo '192.168.60.9' ;;
	'-q get ikev2-manager.device_192_168_60_9.route_mode') echo 'exclude' ;;
	'-q get ikev2-manager.device_192_168_60_9.dns_passthrough') echo 1 ;;
	'-q get ikev2-manager.device_192_168_60_9.dpi_passthrough') echo 1 ;;
	'-q get zapret.config.DESYNC_MARK') echo '0x40000000' ;;
	*) exit 1 ;;
esac
EOF
cat >"$tmp/bin/ipcalc.sh" <<'EOF'
#!/bin/sh
case "$1" in
	192.168.50.4/32 | 192.168.50.9/32 | 192.168.60.5/32 | 192.168.60.9/32) exit 0 ;;
	*) exit 1 ;;
esac
EOF
chmod 755 "$tmp/bin/uci" "$tmp/bin/ipcalc.sh"

"$helper" sync
grep -Fq 'elements = { 192.168.60.5 }' "$tmp/rules.nft"
grep -Fq 'elements = { 192.168.60.9 }' "$tmp/rules.nft"
grep -Fq 'ip saddr 192.168.60.9 meta mark set meta mark | 0x40000000 counter comment "ikev2-device:dpi:192.168.60.9"' "$tmp/rules.nft"
grep -Fq 'ip saddr 192.168.60.9 meta mark set meta mark & 0xff00ffff | 0x00010000 counter accept comment "ikev2-device:exclude:192.168.60.9"' "$tmp/rules.nft"
grep -Fq 'ip saddr 192.168.60.5 meta mark set meta mark & 0xff00ffff | 0x00020000 counter accept comment "ikev2-device:fullroute:192.168.60.5"' "$tmp/rules.nft"
grep -Fq 'elements = { 192.168.60.5, 192.168.60.9 }' "$tmp/rules.nft"
grep -Fq 'elements = { "br-lan", "ipsec-in" }' "$tmp/rules.nft"
grep -Fq 'elements = { "eth0" }' "$tmp/rules.nft"
grep -Fq 'redirect to :53 comment "ikev2-device:dns-enforce"' "$tmp/rules.nft"
grep -Fq 'reject comment "ikev2-device:dot-block"' "$tmp/rules.nft"
"$helper" check

# Real nftables retains a mark bit in the AND mask when the following OR sets
# that same bit. Both renderings are equivalent and must pass the health check.
sed -e 's/0xff00ffff | 0x00010000/0xff01ffff | 0x00010000/g' \
	-e 's/0xff00ffff | 0x00020000/0xff02ffff | 0x00020000/g' \
	"$tmp/rules.nft" >"$tmp/rules.canonical"
mv "$tmp/rules.canonical" "$tmp/rules.nft"
"$helper" check
"$helper" sync
[ "$(wc -l <"$tmp/nft.log" | tr -d ' ')" = 2 ]

# A removed logical WAN must not leave DoT enforcement bound to its obsolete
# physical interface. The active default route is the authoritative fallback
# and is picked up without changing the saved manager configuration.
TEST_MANAGER_WAN=removed_wwan
TEST_DEFAULT_DEVICE=eth1
export TEST_MANAGER_WAN TEST_DEFAULT_DEVICE
"$helper" sync
grep -Fq 'elements = { "eth1" }' "$tmp/rules.nft"
[ "$(wc -l <"$tmp/nft.log" | tr -d ' ')" = 3 ]
unset TEST_MANAGER_WAN TEST_DEFAULT_DEVICE
"$helper" sync
grep -Fq 'elements = { "eth0" }' "$tmp/rules.nft"
[ "$(wc -l <"$tmp/nft.log" | tr -d ' ')" = 4 ]

# A total WAN outage has neither a runtime l3_device nor a default route.
# Preserve the last validated device set instead of declaring the runtime bad.
TEST_WAN_DOWN=1
TEST_DEFAULT_ROUTE_DOWN=1
export TEST_WAN_DOWN TEST_DEFAULT_ROUTE_DOWN
"$helper" check
"$helper" sync
[ "$(wc -l <"$tmp/nft.log" | tr -d ' ')" = 4 ]
unset TEST_WAN_DOWN TEST_DEFAULT_ROUTE_DOWN

# A matching signature is not enough: runtime health must notice externally
# removed rules and sync must reconstruct them.
sed '/ikev2-device:fullroute:192.168.60.5/d' "$tmp/rules.nft" >"$tmp/rules.corrupt"
mv "$tmp/rules.corrupt" "$tmp/rules.nft"
if "$helper" check >/dev/null 2>&1; then
	printf '%s\n' 'corrupted device-routing runtime passed health check' >&2
	exit 1
fi
"$helper" sync
grep -Fq 'comment "ikev2-device:fullroute:192.168.60.5"' "$tmp/rules.nft"
[ "$(wc -l <"$tmp/nft.log" | tr -d ' ')" = 5 ]
sed 's/0x00020000 counter accept comment "ikev2-device:fullroute:192.168.60.5"/0x00030000 counter accept comment "ikev2-device:fullroute:192.168.60.5"/' \
	"$tmp/rules.nft" >"$tmp/rules.wrong-mark"
mv "$tmp/rules.wrong-mark" "$tmp/rules.nft"
if "$helper" check >/dev/null 2>&1; then
	printf '%s\n' 'device-routing rule with a wrong mark passed health check' >&2
	exit 1
fi
"$helper" sync
[ "$(wc -l <"$tmp/nft.log" | tr -d ' ')" = 6 ]

sed '/ikev2-device:dns-enforce/d' "$tmp/rules.nft" >"$tmp/rules.no-dns"
mv "$tmp/rules.no-dns" "$tmp/rules.nft"
if "$helper" check >/dev/null 2>&1; then
	printf '%s\n' 'missing DNS interception rule passed health check' >&2
	exit 1
fi
"$helper" sync
[ "$(wc -l <"$tmp/nft.log" | tr -d ' ')" = 7 ]

# A configured DPI bypass without Zapret's published mark must fail closed and
# leave the already installed rules untouched.
sed '/zapret.config.DESYNC_MARK/d' "$tmp/bin/uci" >"$tmp/bin/uci.no-mark"
mv "$tmp/bin/uci.no-mark" "$tmp/bin/uci"
chmod 755 "$tmp/bin/uci"
before_rules="$(cat "$tmp/rules.nft")"
if "$helper" sync 2>/dev/null; then
	printf '%s\n' 'DPI passthrough was accepted without a Zapret mark' >&2
	exit 1
fi
[ "$(cat "$tmp/rules.nft")" = "$before_rules" ]

# A malformed entry must fail the sync instead of quietly producing an empty
# set, which would pull an excluded device back into the tunnel.
cat >"$tmp/bin/uci" <<'EOF'
#!/bin/sh
case "$*" in
	'-q get ikev2-manager.globals.configured') echo 1 ;;
	'-q get ikev2-manager.globals.device_schema') echo 2 ;;
	'show ikev2-manager') echo 'ikev2-manager.device_bad=device_policy' ;;
	'-q get ikev2-manager.device_bad.address') echo 'not-an-address' ;;
	'-q get ikev2-manager.device_bad.route_mode') echo 'exclude' ;;
	*) exit 1 ;;
esac
EOF
chmod 755 "$tmp/bin/uci"
if "$helper" sync 2>/dev/null; then
	printf '%s\n' 'malformed device policy was accepted' >&2
	exit 1
fi

printf '%s\n' 'device routing checks OK'
