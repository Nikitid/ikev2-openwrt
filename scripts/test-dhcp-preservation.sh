#!/bin/sh

# Disabling managed DNS and removing the application's dependencies both return
# the resolver to what it was before. They used to copy a whole snapshot of
# /etc/config/dhcp over the live file, taken at install or when managed DNS was
# first enabled, and every static lease added since was lost. Only the three
# resolver options the application changes may come back; everything else in
# the live file must survive.

set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM

fail() {
	printf '%s\n' "$*" >&2
	exit 1
}

# A uci double over one flat store of "key=value" lines, enough for the
# @dnsmasq[0] options. Lists are space-separated values of one key.
store="$tmp/uci.store"
calls="$tmp/uci.calls"
uci() {
	local key value old
	while [ "${1:-}" = -q ]; do shift; done
	printf '%s\n' "$*" >>"$calls"
	case "$1" in
		get)
			value="$(store_get "$2")"
			[ -n "$value" ] || return 1
			printf '%s\n' "$value"
			;;
		set)
			key="${2%%=*}"; value="${2#*=}"
			store_put "$key" "$value"
			;;
		add_list)
			key="${2%%=*}"; value="${2#*=}"
			old="$(store_get "$key")"
			store_put "$key" "${old:+$old }$value"
			;;
		delete) store_put "$2" '' ;;
		commit | revert) ;;
		*) return 1 ;;
	esac
}
# Keys hold brackets, so they are compared as strings, never as patterns.
store_get() {
	awk -v key="$1" 'index($0, key "=") == 1 { value = substr($0, length(key) + 2) } END { print value }' "$store"
}
store_put() {
	awk -v key="$1" 'index($0, key "=") != 1' "$store" >"$store.new"
	[ -z "$2" ] || printf '%s=%s\n' "$1" "$2" >>"$store.new"
	mv "$store.new" "$store"
}

live_file() {
	cat >"$1" <<'EOF'
config dnsmasq
	option noresolv '1'
	list server '127.0.0.1#5453'

config host
	option name 'printer'
	option mac '00:11:22:33:44:55'
	option ip '192.168.1.20'

config host
	option name 'nas'
	option mac '00:11:22:33:44:66'
	option ip '192.168.1.21'
EOF
}

# --- Dependency removal ---------------------------------------------------
pkg_manager_name() { printf 'test\n'; }
pkg_dnsmasq_provider() { printf 'dnsmasq\n'; }
pkg_list_installed_names() { printf 'base-files\ndnsmasq\n'; }
IKEV2_DEPS_STATE_DIR="$tmp/state"
IKEV2_DEPS_DHCP_FILE="$tmp/dhcp"
IKEV2_OPENWRT_RELEASE_FILE="$tmp/openwrt_release"
export IKEV2_DEPS_STATE_DIR IKEV2_DEPS_DHCP_FILE IKEV2_OPENWRT_RELEASE_FILE
printf "DISTRIB_RELEASE='25.12.5'\nDISTRIB_TARGET='x'\n" >"$IKEV2_OPENWRT_RELEASE_FILE"
. "$root/ikev2-manager-runtime/lib/dependency-state.sh"

# Before installation: plain upstream resolver, no noresolv.
printf 'config dnsmasq\n' >"$IKEV2_DEPS_DHCP_FILE"
printf 'dhcp.@dnsmasq[0].server=192.0.2.53\ndhcp.@dnsmasq[0].cachesize=1000\n' >"$store"
deps_state_capture || fail 'dependency state was not captured'
grep -qx 'server=192.0.2.53' "$(deps_state_file dnsmasq.options)" ||
	fail 'the resolver options were not recorded at capture'
grep -qx 'noresolv=' "$(deps_state_file dnsmasq.options)" ||
	fail 'an absent option was not recorded as absent'

# Months later: leases were added, managed DNS changed the resolver options.
live_file "$IKEV2_DEPS_DHCP_FILE"
printf 'dhcp.@dnsmasq[0].server=127.0.0.1#5453\ndhcp.@dnsmasq[0].noresolv=1\ndhcp.@dnsmasq[0].cachesize=0\n' >"$store"
deps_state_restore_dhcp || fail 'the DHCP restore failed'
[ "$(grep -c '^config host' "$IKEV2_DEPS_DHCP_FILE")" = 2 ] ||
	fail 'dependency removal erased static leases added after installation'
[ "$(uci get 'dhcp.@dnsmasq[0].server')" = 192.0.2.53 ] || fail 'the resolver server was not restored'
[ "$(uci get 'dhcp.@dnsmasq[0].cachesize')" = 1000 ] || fail 'the cache size was not restored'
uci get 'dhcp.@dnsmasq[0].noresolv' >/dev/null 2>&1 && fail 'an option absent before installation was kept'

# A package that took the file with it gets the snapshot back whole.
rm -f "$IKEV2_DEPS_DHCP_FILE"
deps_state_restore_dhcp || fail 'the DHCP restore failed without a live file'
cmp -s "$IKEV2_DEPS_DHCP_FILE" "$(deps_state_file dhcp.before)" ||
	fail 'a missing DHCP file was not restored from the snapshot'

# A state recorded before the options existed falls back to reading them out of
# the snapshot, and still keeps the live file.
cat >"$tmp/uci-bin" <<'EOF'
#!/bin/sh
# -c DIR -q get KEY: answer from the snapshot copy in DIR.
dir="$2"; key="$5"
case "$key" in
	dhcp.@dnsmasq\[0\].server) sed -n "s/^[[:space:]]*list server '\\(.*\\)'/\\1/p" "$dir/dhcp" | tr '\n' ' ' | sed 's/ $//' ;;
	*) option="${key##*.}"; sed -n "s/^[[:space:]]*option $option '\\(.*\\)'/\\1/p" "$dir/dhcp" ;;
esac
EOF
chmod +x "$tmp/uci-bin"
uci_binary="$tmp/uci-bin"
printf "config dnsmasq\n\tlist server '198.51.100.1'\n" >"$(deps_state_file dhcp.before)"
rm -f "$(deps_state_file dnsmasq.options)"
live_file "$IKEV2_DEPS_DHCP_FILE"
deps_state_restore_dhcp || fail 'the legacy DHCP restore failed'
[ "$(grep -c '^config host' "$IKEV2_DEPS_DHCP_FILE")" = 2 ] ||
	fail 'a legacy dependency state erased static leases'
[ "$(uci get 'dhcp.@dnsmasq[0].server')" = 198.51.100.1 ] ||
	fail 'the legacy snapshot resolver was not restored'
grep -q 'cp "$(deps_state_file dhcp.before)" "$deps_state_dhcp_file" || return 1' \
	"$root/ikev2-manager-runtime/lib/dependency-state.sh" &&
	fail 'dependency restore still copies the whole DHCP snapshot unconditionally'

# --- Disabling managed DNS ------------------------------------------------
# restore_dns_state with the "options" scope; service calls go to stubs.
mkdir -p "$tmp/init.d" "$tmp/config"
for service in dnsproxy dnsmasq; do
	printf '#!/bin/sh\nexit 0\n' >"$tmp/init.d/$service"
	chmod +x "$tmp/init.d/$service"
done
awk '
	index($0, "restore_dns_state() {") == 1 { body = 1 }
	body { print }
	body && $0 == "}" { exit }
' "$root/ikev2-manager-runtime/lib/system-dns.sh" |
	sed "s|/etc/init.d/|$tmp/init.d/|g" >"$tmp/restore.sh"
grep -q '^restore_dns_state() {' "$tmp/restore.sh" || fail 'restore_dns_state was not found'
. "$tmp/restore.sh"
uci_config_dir="$tmp/config"
original="$tmp/dns-original"
mkdir -p "$original"
printf 'config dnsmasq\n' >"$original/dhcp.config"
printf 'config dnsproxy global\n' >"$original/dnsproxy.config"
printf 'enabled=0\nrunning=0\n' >"$original/service.state"
printf 'server=192.0.2.53\nnoresolv=\ncachesize=150\n' >"$original/dnsmasq.options"
live_file "$uci_config_dir/dhcp"
printf 'dhcp.@dnsmasq[0].server=127.0.0.1#5453\ndhcp.@dnsmasq[0].noresolv=1\n' >"$store"
restore_dns_state "$original" 1 options || fail 'the scoped DNS restore failed'
[ "$(grep -c '^config host' "$uci_config_dir/dhcp")" = 2 ] ||
	fail 'disabling managed DNS erased static leases added since it was enabled'
[ "$(uci get 'dhcp.@dnsmasq[0].server')" = 192.0.2.53 ] || fail 'the original resolver was not restored'
uci get 'dhcp.@dnsmasq[0].noresolv' >/dev/null 2>&1 && fail 'noresolv survived the restore'
cmp -s "$uci_config_dir/dnsproxy" "$original/dnsproxy.config" ||
	fail 'the dnsproxy configuration was not restored'
# The whole-file scope is still what a rollback within one transaction uses.
restore_dns_state "$original" 1 || fail 'the whole-file DNS restore failed'
cmp -s "$uci_config_dir/dhcp" "$original/dhcp.config" || fail 'the whole-file scope did not restore the file'
grep -q 'restore_dns_state "$dns_original_dir" .* options ||' \
	"$root/ikev2-manager-runtime/lib/system-dns.sh" ||
	fail 'disabling managed DNS does not use the scoped restore'

printf '%s\n' 'DHCP preservation tests OK'
