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
	"$tmp/dnsapi" "$tmp/bin"
cp "$root"/ikev2-manager-runtime/lib/*.sh "$tmp/root/usr/libexec/ikev2-manager.d/"
: >"$tmp/dnsapi/dns_timeweb.sh"

cat >"$tmp/bin/uci" <<'EOF'
#!/bin/sh
while [ "$#" -gt 0 ]; do
	case "$1" in
		-c) shift 2 ;;
		-q) shift ;;
		*) break ;;
	esac
done
command="${1:-}"
[ "$#" -eq 0 ] || shift
case "$command" in
	get)
		case "${1:-}" in
			ikev2-manager.globals|ikev2-manager.server|ikev2-manager.client|ikev2-manager.dns)
				exit 0
				;;
			ikev2-manager.server.identity)
				printf '%s\n' vpn.example.test
				;;
			acme.@acme[0]|acme.ikev2)
				exit 0
				;;
			acme.ikev2.dns)
				printf '%s\n' dns_timeweb
				;;
			acme.ikev2.credentials)
				printf '%s\n' 'TW_Token="stored-token"'
				;;
			*) exit 1 ;;
		esac
		;;
	set|add_list|delete)
		printf '%s %s\n' "$command" "$*" >>"$TEST_UCI_LOG"
		;;
	add)
		printf '%s %s\n' "$command" "$*" >>"$TEST_UCI_LOG"
		printf '%s\n' cfg000001
		;;
	commit)
		printf '%s %s\n' "$command" "$*" >>"$TEST_UCI_LOG"
		if [ "${1:-}" = acme ] && [ -f "$TEST_FAIL_COMMIT" ]; then
			printf '%s\n' CORRUPTED >"$TEST_CONFIG_DIR/acme"
			exit 1
		fi
		;;
	revert)
		printf '%s %s\n' "$command" "$*" >>"$TEST_UCI_LOG"
		;;
	show)
		exit 0
		;;
esac
EOF
chmod 755 "$tmp/bin/uci"

run_manager() {
	TEST_UCI_LOG="$tmp/uci.log" \
	TEST_FAIL_COMMIT="$tmp/fail-commit" \
	TEST_CONFIG_DIR="$tmp/root/etc/config" \
	IKEV2_ROOT="$tmp/root" \
	IKEV2_UCI_CONFIG_DIR="$tmp/root/etc/config" \
	IKEV2_UCI_BIN="$tmp/bin/uci" \
	IKEV2_ACME_INPUT="$tmp/acme.in" \
	IKEV2_ACME_DNSAPI="$tmp/dnsapi" \
	IKEV2_CONFIG_LOCK="$tmp/config.lock" \
	IKEV2_RUNTIME_LIB_DIR="$tmp/root/usr/libexec/ikev2-manager.d" \
		sh "$root/luci-ikev2-manager/ikev2-manager.sh" acme-set
}

printf '%s\n' ORIGINAL >"$tmp/root/etc/config/acme"
cat >"$tmp/acme.in" <<'EOF'
admin@example.test
dns
dns_timeweb
1
token-123
EOF
: >"$tmp/uci.log"
run_manager
grep -Fq 'add_list acme.ikev2.credentials=TW_Token="token-123"' "$tmp/uci.log"
grep -Fq 'set acme.ikev2.validation_method=dns' "$tmp/uci.log"
if grep -Eq '^delete acme\.ikev2$' "$tmp/uci.log"; then
	printf 'ACME cert section was deleted instead of updated in place\n' >&2
	exit 1
fi

cat >"$tmp/acme.in" <<'EOF'
admin@example.test
dns
dns_timeweb
0

EOF
: >"$tmp/uci.log"
run_manager
if grep -Fq 'delete acme.ikev2.credentials' "$tmp/uci.log"; then
	printf 'empty credentials unexpectedly deleted the stored token\n' >&2
	exit 1
fi

cat >"$tmp/acme.in" <<'EOF'
admin@example.test
dns
dns_timeweb
0
TW_Token=$(touch /tmp/not-allowed)
EOF
: >"$tmp/uci.log"
if run_manager >/dev/null 2>&1; then
	printf 'unsafe ACME credential unexpectedly succeeded\n' >&2
	exit 1
fi
if grep -Eq '^(set|add_list|delete) acme\.' "$tmp/uci.log"; then
	printf 'invalid ACME input mutated UCI before validation\n' >&2
	exit 1
fi

cat >"$tmp/acme.in" <<'EOF'
admin@example.test
http
dns_timeweb
0

EOF
: >"$tmp/uci.log"
run_manager
grep -Fq 'set acme.ikev2.validation_method=webroot' "$tmp/uci.log"
grep -Fq 'delete acme.ikev2.credentials' "$tmp/uci.log"

printf '%s\n' ORIGINAL >"$tmp/root/etc/config/acme"
cp "$tmp/root/etc/config/acme" "$tmp/acme.before"
cat >"$tmp/acme.in" <<'EOF'
admin@example.test
dns
dns_timeweb
0
replacement-token
EOF
: >"$tmp/fail-commit"
: >"$tmp/uci.log"
if run_manager >/dev/null 2>&1; then
	printf 'failed ACME commit unexpectedly succeeded\n' >&2
	exit 1
fi
cmp -s "$tmp/acme.before" "$tmp/root/etc/config/acme"

printf 'ACME settings tests OK\n'
