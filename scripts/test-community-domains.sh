#!/bin/sh

set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM

mkdir -p "$tmp/bin" "$tmp/local" "$tmp/user" "$tmp/cache" "$tmp/runtime"
cp "$root/ikev2-manager-runtime/lib/actions.sh" "$tmp/runtime/actions.sh"

cat >"$tmp/bin/uclient-fetch" <<'EOF'
#!/bin/sh
output=''
url=''
while [ "$#" -gt 0 ]; do
	case "$1" in
		-O)
			output="$2"
			shift 2
			;;
		-q|-T)
			[ "$1" = -T ] && shift
			shift
			;;
		*)
			url="$1"
			shift
			;;
	esac
done
case "$url" in
	# Networks are published in a separate tree; the same service name there
	# must contribute CIDRs, not domains.
	*/Subnets/IPv4/remote.lst)
		# Only the narrow public range is eligible. Broad cloud ranges, private
		# space and a default route must never become PBR policy implicitly.
		printf '%s\n' 0.0.0.0/0 10.0.0.0/8 8.0.0.0/8 8.8.8.0/24 >"$output"
		;;
	*/remote.lst)
		printf '%s\n' remote.example >"$output"
		;;
	*/unsafe.lst)
		printf '%s\n' com safe.example >"$output"
		;;
	*)
		exit 1
		;;
esac
EOF
chmod 755 "$tmp/bin/uclient-fetch"
cat >"$tmp/bin/restart-helper" <<'EOF'
#!/bin/sh
[ "$1" != --check ] || exit "${TEST_RESTART_CHECK_RC:-0}"
printf '%s\n' "$*" >>"$TEST_RESTART_LOG"
[ ! -f "$TEST_RESTART_FAIL" ] || {
	rm -f "$TEST_RESTART_FAIL"
	exit 1
}
exit 0
EOF
chmod 755 "$tmp/bin/restart-helper"

printf '%s\n' local.example >"$tmp/local/local.lst"
printf '%s\n' direct.example >"$tmp/local/direct.lst"
cat >"$tmp/local/direct.cidrs" <<'EOF'
# Direct protocol networks
91.108.4.0/22
149.154.160.0/20
EOF
printf '%s\n' direct local remote >"$tmp/selected"
printf '%s\n' direct local remote unsafe >"$tmp/catalog"
: >"$tmp/manual"
printf '%s\n' 203.0.113.10 198.51.100.0/24 >"$tmp/manual-cidrs"

run_helper() (
	PATH="$tmp/bin:$PATH" \
	IKEV2_MANUAL_FILE="$tmp/manual" \
	IKEV2_MANUAL_CIDR_FILE="$tmp/manual-cidrs" \
	IKEV2_SELECTED_FILE="$tmp/selected" \
	IKEV2_FINAL_FILE="$tmp/domains" \
	IKEV2_CIDR_FILE="$tmp/cidrs" \
	IKEV2_CACHE_DIR="$tmp/cache" \
	IKEV2_STATUS_FILE="$tmp/status" \
	IKEV2_STATUS_DIR="$tmp/status.d" \
	IKEV2_LOG_FILE="$tmp/log" \
	IKEV2_LOCK_DIR="$tmp/lock" \
	IKEV2_PENDING_DIR="$tmp/pending.d" \
	IKEV2_INPUT_PREFIX="$tmp/input" \
	IKEV2_RESTART_HELPER="$tmp/bin/restart-helper" \
	IKEV2_RUNTIME_LIB_DIR="$tmp/runtime" \
	IKEV2_LOCAL_SERVICES_DIR="$tmp/local" \
	IKEV2_USER_SERVICES_DIR="$tmp/user" \
	IKEV2_SERVICE_INPUT_PREFIX="$tmp/service-input" \
	IKEV2_CATALOG_FILE="$tmp/catalog" \
	IKEV2_RAW_BASE=https://lists.invalid \
	IKEV2_SUBNET_RAW_BASE=https://lists.invalid/Subnets/IPv4 \
	IKEV2_SUBNET_CATALOG_FILE="$tmp/subnet-catalog" \
	IKEV2_SUBNET_CATALOG_URL=https://subnets.invalid/catalog \
	TEST_RESTART_FAIL="$tmp/restart.fail" \
	TEST_RESTART_LOG="$tmp/restart.log" \
	TEST_RESTART_CHECK_RC="${TEST_RESTART_CHECK_RC:-0}" \
	IKEV2_ACTION_LOCK_HELD="${IKEV2_ACTION_LOCK_HELD:-0}" \
	IKEV2_APPLY_FAILURE_FILE="$tmp/apply.failure" \
		sh "$root/luci-ikev2-domains/community-domains.sh" "$@"
)

: >"$tmp/restart.log"
run_helper apply
[ "$(wc -l <"$tmp/restart.log" | tr -d ' ')" = 1 ]
printf '%s\n' direct.example local.example remote.example |
	cmp -s - "$tmp/domains"
# 8.8.8.0/24 comes from the published subnet tree for the "remote" service:
# networks refresh alongside domains instead of being frozen into the package.
# Unsafe broad/private downloaded ranges are ignored.
printf '%s\n' 149.154.160.0/20 198.51.100.0/24 203.0.113.10/32 8.8.8.0/24 \
	91.108.4.0/22 | cmp -s - "$tmp/cidrs"
grep -q '^services=3$' "$tmp/status"
grep -q '^domains=3$' "$tmp/status"
grep -q '^cidrs=5$' "$tmp/status"
grep -q '^custom_cidrs=2$' "$tmp/status"
grep -q '^selected=direct,local,remote$' "$tmp/status"
[ "$(run_helper ip-services)" = direct ]

# Provider content is untrusted. A top-level public suffix would route an
# unrelated fraction of the Internet, so the whole downloaded revision is
# rejected rather than partially accepted.
printf '%s\n' unsafe >"$tmp/selected"
if run_helper apply >/dev/null 2>&1; then
	printf 'unsafe remote service unexpectedly succeeded\n' >&2
	exit 1
fi
printf '%s\n' direct local remote >"$tmp/selected"

# An identical policy with a healthy runtime must not restart PBR. If the
# health check fails, the same input must still take the full repair path.
run_helper apply
[ "$(wc -l <"$tmp/restart.log" | tr -d ' ')" = 1 ]
TEST_RESTART_CHECK_RC=1 run_helper apply
[ "$(wc -l <"$tmp/restart.log" | tr -d ' ')" = 2 ]

printf '%s\n' held.example >"$tmp/manual"
IKEV2_ACTION_LOCK_HELD=1 run_helper apply
[ "$(tail -n1 "$tmp/restart.log")" = '--wait --lock-held' ]
printf '%s\n' local.example >"$tmp/manual"

cp "$tmp/domains" "$tmp/domains.before"
cp "$tmp/cidrs" "$tmp/cidrs.before"
printf '%s\n' '999.1.1.1/33' >"$tmp/local/direct.cidrs"
if run_helper apply >/dev/null 2>&1; then
	printf 'invalid CIDR unexpectedly succeeded\n' >&2
	exit 1
fi
cmp -s "$tmp/domains.before" "$tmp/domains"
cmp -s "$tmp/cidrs.before" "$tmp/cidrs"
cat >"$tmp/local/direct.cidrs" <<'EOF'
91.108.4.0/22
149.154.160.0/20
EOF

printf '%s\n' direct.example >"$tmp/local/direct.lst"
printf '%s\n' '.invalid.example' >"$tmp/manual"
if run_helper apply >/dev/null 2>&1; then
	printf 'invalid domain unexpectedly succeeded\n' >&2
	exit 1
fi
cmp -s "$tmp/domains.before" "$tmp/domains"
printf '%s\n' local.example >"$tmp/manual"

if IKEV2_MAX_SELECTED_SERVICES=2 run_helper apply >/dev/null 2>&1; then
	printf 'selected-service resource limit unexpectedly succeeded\n' >&2
	exit 1
fi
unset IKEV2_MAX_SELECTED_SERVICES
cmp -s "$tmp/domains.before" "$tmp/domains"

printf '%s\n' changed.example >"$tmp/local/local.lst"
: >"$tmp/restart.fail"
if run_helper apply >/dev/null 2>&1; then
	printf 'failed PBR restart unexpectedly succeeded\n' >&2
	exit 1
fi
cmp -s "$tmp/domains.before" "$tmp/domains"
cmp -s "$tmp/cidrs.before" "$tmp/cidrs"

printf '%s\n' local.example >"$tmp/local/local.lst"
printf '%s\n' staged.example >"$tmp/input-12345678.domains"
printf '%s\n' 192.0.2.0/24 >"$tmp/input-12345678.cidrs"
printf '%s\n' local >"$tmp/input-12345678.services"
run_helper _apply-input 100-1 12345678
printf '%s\n' local.example staged.example | cmp -s - "$tmp/domains"
printf '%s\n' 192.0.2.0/24 | cmp -s - "$tmp/cidrs"
printf '%s\n' staged.example | cmp -s - "$tmp/manual"
printf '%s\n' 192.0.2.0/24 | cmp -s - "$tmp/manual-cidrs"
printf '%s\n' local | cmp -s - "$tmp/selected"
[ ! -e "$tmp/input-12345678.domains" ]
[ ! -e "$tmp/input-12345678.cidrs" ]
[ ! -e "$tmp/input-12345678.services" ]

for name in manual manual-cidrs selected domains cidrs; do
	cp "$tmp/$name" "$tmp/$name.staged-before"
done
printf '%s\n' rejected.example >"$tmp/input-abcdefgh.domains"
printf '%s\n' 198.51.100.0/24 >"$tmp/input-abcdefgh.cidrs"
: >"$tmp/input-abcdefgh.services"
: >"$tmp/restart.fail"
if run_helper _apply-input 100-2 abcdefgh >/dev/null 2>&1; then
	printf 'failed staged update unexpectedly succeeded\n' >&2
	exit 1
fi
for name in manual manual-cidrs selected domains cidrs; do
	cmp -s "$tmp/$name.staged-before" "$tmp/$name"
done

# Every rejection used to return silently, so the operator saw "Community
# update failed" with an empty log and no way to tell which check refused the
# input. Each abort must name itself.
rm -f "$tmp/apply.failure"
if run_helper _apply-input 100-3 'not a token' >"$tmp/reject.out" 2>&1; then
	printf 'a malformed input token was accepted\n' >&2
	exit 1
fi
grep -Fq 'apply rejected:' "$tmp/reject.out" || {
	printf 'a rejected token produced no diagnostic\n' >&2
	exit 1
}
grep -Fq 'input token is malformed' "$tmp/apply.failure" || {
	printf 'the rejection reason was not recorded for the status message\n' >&2
	exit 1
}

rm -f "$tmp/apply.failure" "$tmp/input-bcdefghi.domains" \
	"$tmp/input-bcdefghi.cidrs" "$tmp/input-bcdefghi.services"
if run_helper _apply-input 100-4 bcdefghi >"$tmp/reject.out" 2>&1; then
	printf 'a staged update with no input files was accepted\n' >&2
	exit 1
fi
grep -Fq 'is missing or not a regular file' "$tmp/apply.failure" || {
	printf 'a missing staged input was not named\n' >&2
	exit 1
}

# A custom service is stored independently of the common manual list and can
# be enabled in the same atomic operation that creates it.
cat >"$tmp/service-input-cust0001.meta" <<'EOF'
operation=save
id=customsvc
label=Custom service
selected=1
EOF
printf '%s\n' custom.example >"$tmp/service-input-cust0001.domains"
printf '%s\n' 203.0.113.0/24 >"$tmp/service-input-cust0001.cidrs"
run_helper _apply-service 200-1 cust0001
run_helper services >"$tmp/services.out"
grep -Fxq 'customsvc|Custom service|custom|1|1' "$tmp/services.out"
grep -Fxq customsvc "$tmp/selected"
grep -Fxq custom.example "$tmp/domains"
grep -Fxq 203.0.113.0/24 "$tmp/cidrs"
[ ! -e "$tmp/service-input-cust0001.meta" ]
run_helper service-read customsvc >"$tmp/custom.read"
grep -Fxq 'label=Custom service' "$tmp/custom.read"
grep -Fxq custom.example "$tmp/custom.read"

# Editing a definition must preserve policy selection. Selection belongs to
# the chips and the page-level Save action, not to the service editor.
cat >"$tmp/service-input-keep0001.meta" <<'EOF'
operation=save
id=customsvc
label=Renamed custom service
selected=keep
EOF
printf '%s\n' custom-renamed.example >"$tmp/service-input-keep0001.domains"
: >"$tmp/service-input-keep0001.cidrs"
run_helper _apply-service 200-keep keep0001
grep -Fxq customsvc "$tmp/selected"
grep -Fxq custom-renamed.example "$tmp/domains"

# A newly created service stays disabled until the page-level policy Save.
cat >"$tmp/service-input-off00001.meta" <<'EOF'
operation=save
id=customoff
label=Disabled custom service
selected=keep
EOF
printf '%s\n' disabled.example >"$tmp/service-input-off00001.domains"
: >"$tmp/service-input-off00001.cidrs"
run_helper _apply-service 200-off off00001
if grep -Fxq customoff "$tmp/selected" || grep -Fxq disabled.example "$tmp/domains"; then
	printf 'service editor unexpectedly changed policy selection\n' >&2
	exit 1
fi

# Editing a prepared service creates a complete local override. Reset removes
# only the override and reveals the prepared definition again.
cat >"$tmp/service-input-over0001.meta" <<'EOF'
operation=save
id=local
label=Local override
selected=1
EOF
printf '%s\n' override.example >"$tmp/service-input-over0001.domains"
: >"$tmp/service-input-over0001.cidrs"
run_helper _apply-service 200-2 over0001
grep -Fxq override.example "$tmp/domains"
if grep -Fxq local.example "$tmp/domains"; then
	printf 'prepared domains leaked into a complete service override\n' >&2
	exit 1
fi
run_helper services >"$tmp/services.out"
grep -Fxq 'local|Local override|override|1|0' "$tmp/services.out"

cat >"$tmp/service-input-reset001.meta" <<'EOF'
operation=reset
id=local
label=ignored
selected=1
EOF
: >"$tmp/service-input-reset001.domains"
: >"$tmp/service-input-reset001.cidrs"
run_helper _apply-service 200-3 reset001
grep -Fxq local.example "$tmp/domains"
[ ! -e "$tmp/user/local.origin" ]

# A failed policy restart rolls the service files and selection back together.
cp "$tmp/selected" "$tmp/selected.service-before"
cat >"$tmp/service-input-fail0001.meta" <<'EOF'
operation=save
id=local
label=Failed override
selected=1
EOF
printf '%s\n' failed-override.example >"$tmp/service-input-fail0001.domains"
: >"$tmp/service-input-fail0001.cidrs"
: >"$tmp/restart.fail"
if run_helper _apply-service 200-4 fail0001 >/dev/null 2>&1; then
	printf 'service update survived a failed policy restart\n' >&2
	exit 1
fi
[ ! -e "$tmp/user/local.origin" ]
cmp -s "$tmp/selected.service-before" "$tmp/selected"
grep -Fxq local.example "$tmp/domains"

cat >"$tmp/service-input-del00001.meta" <<'EOF'
operation=delete
id=customsvc
label=ignored
selected=0
EOF
: >"$tmp/service-input-del00001.domains"
: >"$tmp/service-input-del00001.cidrs"
run_helper _apply-service 200-5 del00001
[ ! -e "$tmp/user/customsvc.origin" ]
if grep -Fxq customsvc "$tmp/selected"; then
	printf 'deleted custom service remained selected\n' >&2
	exit 1
fi

# A local override whose prepared service was removed by a package upgrade is
# reclassified as custom, so it remains deletable instead of becoming stuck.
printf '%s\n' retired.example >"$tmp/user/retired.lst"
: >"$tmp/user/retired.cidrs"
printf '%s\n' 'Retired override' >"$tmp/user/retired.name"
printf '%s\n' override >"$tmp/user/retired.origin"
run_helper services >"$tmp/services.out"
grep -Fxq 'retired|Retired override|custom|1|0' "$tmp/services.out"
cat >"$tmp/service-input-retire01.meta" <<'EOF'
operation=delete
id=retired
label=ignored
selected=0
EOF
: >"$tmp/service-input-retire01.domains"
: >"$tmp/service-input-retire01.cidrs"
run_helper _apply-service 200-retired retire01
[ ! -e "$tmp/user/retired.lst" ]

# A worker spawn failure must not leave a queued mutation or staged secrets in
# /tmp. The regular and service schedulers have the same cleanup contract.
cat >"$tmp/bin/start-stop-daemon" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod 755 "$tmp/bin/start-stop-daemon"
cat >"$tmp/service-input-spawn001.meta" <<'EOF'
operation=save
id=spawnfail
label=Spawn failure
selected=keep
EOF
printf '%s\n' spawn.example >"$tmp/service-input-spawn001.domains"
: >"$tmp/service-input-spawn001.cidrs"
if run_helper service-schedule spawn001 >/dev/null 2>&1; then
	printf 'service scheduler accepted a worker spawn failure\n' >&2
	exit 1
fi
[ ! -e "$tmp/service-input-spawn001.meta" ]
[ ! -e "$tmp/service-input-spawn001.domains" ]
[ ! -e "$tmp/service-input-spawn001.cidrs" ]
[ -z "$(find "$tmp/pending.d" -type f -print -quit 2>/dev/null)" ]

# The project-owned TikTok manifest covers the image host observed in the
# field without importing unrelated products or shared CDN parent domains.
grep -Fxq ibyteimg.com "$root/luci-ikev2-domains/local-services/tiktok.lst"
for broad in capcut.com trae.ai marscode.com akamai.net fastly.net cloudflare.net; do
	if grep -Fxq "$broad" "$root/luci-ikev2-domains/local-services/tiktok.lst"; then
		printf 'broad TikTok dependency unexpectedly bundled: %s\n' "$broad" >&2
		exit 1
	fi
done

printf 'community domain tests OK\n'
