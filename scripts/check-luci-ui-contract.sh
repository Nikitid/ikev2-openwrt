#!/bin/sh

set -eu

files="luci-ikev2-manager luci-ikev2-domains"

if grep -R -n --include='*.js' 'ui\.addNotification' $files; then
	printf '%s\n' 'LuCI actions must report through an inline result, not global notifications' >&2
	exit 1
fi

if grep -R -n --include='*.js' "dispatchEvent(new Event('ikev2-.*-updated" $files; then
	printf '%s\n' 'LuCI actions must refresh their concrete state instead of emitting unhandled update events' >&2
	exit 1
fi

if grep -R -n --include='*.js' -E 'please reload the page|Reload the Overview|reload in a moment' $files; then
	printf '%s\n' 'LuCI actions must not require a manual page reload to expose their result' >&2
	exit 1
fi

# The project ships its own Russian map because no luci-i18n-*-ru catalog is
# installed on the supported targets. Assigning window._ would apply that map to
# every other LuCI application on any page that loads one of our resources,
# including the router-wide Status Overview. Each module shadows _() locally
# instead.
if grep -R -n --include='*.js' -E '(^|[^.\w])window\._[[:space:]]*=' $files; then
	printf '%s\n' 'the project translator must not replace the global window._' >&2
	exit 1
fi
for consumer in \
	luci-ikev2-manager/setup.js \
	luci-ikev2-manager/client.js \
	luci-ikev2-manager/settings.js \
	luci-ikev2-manager/users.js \
	luci-ikev2-manager/status-widget.js \
	luci-ikev2-domains/editor.js; do
	grep -Fq 'var _ = common.t;' "$consumer" || {
		printf 'missing local translator shadow: %s\n' "$consumer" >&2
		exit 1
	}
done
grep -Fq 'var _ = translate;' 'luci-ikev2-manager/shared.js'
grep -Fq 't: translate,' 'luci-ikev2-manager/shared.js'

acl='luci-ikev2-manager/acl.json'
for broad_rule in \
	'"/usr/libexec/ikev2-manager *"' \
	'"/usr/libexec/ikev2-manager-system *"' \
	'"/usr/libexec/ikev2-domains-community *"' \
	'"/usr/libexec/ikev2-domain-router *"' \
	'"/usr/libexec/ikev2-devices *"'; do
	if grep -Fq "$broad_rule" "$acl"; then
		printf 'broad LuCI exec ACL is forbidden: %s\n' "$broad_rule" >&2
		exit 1
	fi
done

if grep -R -n --include='*.js' 'advanced-start.*encodeBase64' $files; then
	printf '%s\n' 'custom strongSwan profiles must use one-shot input files, not argv' >&2
	exit 1
fi
grep -Fq '"/var/run/ikev2-manager-profile-*.in": [ "write" ]' "$acl"
if grep -Fq 'Blocked — strongSwan upgrade required' \
	'luci-ikev2-manager/settings.js'; then
	printf '%s\n' 'inbound strongSwan advisory must not be rendered as a runtime block' >&2
	exit 1
fi
grep -Fq "notice ? 'info'" 'luci-ikev2-manager/setup.js'
grep -Fq "Reset app and remove dependencies" 'luci-ikev2-manager/setup.js'
dns_toggle_line="$(grep -n "common.toggleRow(blockDot" 'luci-ikev2-manager/setup.js' | cut -d: -f1)"
apply_bar_line="$(grep -n "applyResult.node" 'luci-ikev2-manager/setup.js' | tail -n1 | cut -d: -f1)"
[ -n "$dns_toggle_line" ] && [ -n "$apply_bar_line" ] &&
	[ "$apply_bar_line" -gt "$dns_toggle_line" ] || {
	printf '%s\n' 'Overview Apply must follow the managed, network and DNS controls' >&2
	exit 1
}
grep -Fq "Network and DNS changes are applied together by the button at the bottom." \
	'luci-ikev2-manager/setup.js'
grep -Fq "dependencyOverview(depRows)" 'luci-ikev2-manager/setup.js'
grep -Fq "_('Technical details')" 'luci-ikev2-manager/setup.js'
grep -Fq "diagnostic_status=unavailable\\ndependencies_ok=unknown" \
	'luci-ikev2-manager/setup.js'
grep -Fq "installDeps.style.display = known && !ready ? '' : 'none'" \
	'luci-ikev2-manager/setup.js'
for noisy_copy in \
	'Clients must use router DNS.' \
	'Online shows only IKEv2 sessions' \
	'Current upstream:' \
	'This is a router-wide resolver setting.' \
	'Applying DNS restarts the managed resolver.'; do
	if grep -R -Fq --include='*.js' "$noisy_copy" \
		luci-ikev2-manager luci-ikev2-domains; then
		printf 'retired explanatory plaque returned: %s\n' "$noisy_copy" >&2
		exit 1
	fi
done
grep -Fq "Allow all router ports" 'luci-ikev2-manager/settings.js'
grep -Fq "routerPorts.disabled = !allowRouter.checked || allowAllRouterPorts.checked" \
	'luci-ikev2-manager/settings.js'
grep -Fq "Keep LuCI and SSH ports in this list" 'luci-ikev2-manager/settings.js'
grep -Fq '"/usr/libexec/ikev2-devices zones": [ "exec" ]' "$acl"
grep -Fq '"/usr/libexec/ikev2-devices clients": [ "exec" ]' "$acl"
grep -Fq '"/usr/libexec/ikev2-manager-system device-async set-exclusions *": [ "exec" ]' "$acl"
grep -Fq '"/usr/libexec/ikev2-manager-system device-async set-included *": [ "exec" ]' "$acl"
grep -Fq '"/usr/libexec/ikev2-manager-system device-async clear-policy *": [ "exec" ]' "$acl"
grep -Fq 'set-included | clear-policy)' \
	'ikev2-manager-runtime/ikev2-manager-system.sh'
grep -Fq 'set-exclusions)' 'ikev2-manager-runtime/ikev2-manager-system.sh'
grep -Fq 'set-exclusions)   cmd_set_exclusions' \
	'luci-ikev2-domains/ikev2-devices.sh'
grep -Fq 'set-included)     cmd_set_included' \
	'luci-ikev2-domains/ikev2-devices.sh'
grep -Fq 'clear-policy)     cmd_clear_policy' \
	'luci-ikev2-domains/ikev2-devices.sh'
grep -Fq "common.choiceWithCustom(choices.length" 'luci-ikev2-manager/setup.js'
grep -Fq "common.multiChoiceWithCustom(access.lan_zones" \
	'luci-ikev2-manager/settings.js'
grep -Fq "addressPlanPicker" 'luci-ikev2-manager/settings.js'
grep -Fq "choiceWithCustom" 'luci-ikev2-manager/client.js'
grep -Fq "choiceWithCustom(value.wan_interface" 'luci-ikev2-manager/setup.js'
grep -Fq "renderDevicePolicies(data[3].stdout, data[4].stdout, data[5].stdout)" \
	'luci-ikev2-manager/setup.js'
grep -Fq "[ 'set-exclusions', entry.addr" 'luci-ikev2-manager/setup.js'
if grep -Fq "self.renderFlagExemptions(" 'luci-ikev2-manager/setup.js' ||
   grep -Fq "self.renderExceptions(" 'luci-ikev2-manager/setup.js'; then
	printf '%s\n' 'setup still renders separate device exception lists' >&2
	exit 1
fi
grep -Fq "E('option', { 'value': customValue }" 'luci-ikev2-manager/shared.js'
grep -Fq "Date.now() + 120000" 'luci-ikev2-domains/editor.js'
grep -Fq "result.busy(_(st.message))" 'luci-ikev2-domains/editor.js'
for phase in \
	'Preparing selected domain lists...' \
	'Downloading selected service lists...' \
	'Building the combined policy list...' \
	'Restarting policy routing...'; do
	grep -Fq "$phase" 'luci-ikev2-domains/community-domains.sh'
done

# Prepared and custom services use narrow ACL entries and independent files;
# they must not fall back to the common free-form domain list.
grep -Fq '"/usr/libexec/ikev2-domains-community services": [ "exec" ]' "$acl"
grep -Fq '"/usr/libexec/ikev2-domains-community service-read *": [ "exec" ]' "$acl"
grep -Fq '"/usr/libexec/ikev2-domains-community service-schedule *": [ "exec" ]' "$acl"
grep -Fq '"/tmp/ikev2-service-input-*.meta": [ "write" ]' "$acl"
grep -Fq "common.execChecked(communityHelper, [ 'service-read', record.id ]" \
	'luci-ikev2-domains/editor.js'
grep -Fq "runServiceOperation('save')" 'luci-ikev2-domains/editor.js'
grep -Fq "runServiceOperation('reset')" 'luci-ikev2-domains/editor.js'
grep -Fq "runServiceOperation('delete')" 'luci-ikev2-domains/editor.js'
grep -Fq "_('Manage services')" 'luci-ikev2-domains/editor.js'
grep -Fq "'selected=' + (operation === 'delete' ? '0' : 'keep')" \
	'luci-ikev2-domains/editor.js'
grep -Fq 'function runPageAction(options)' 'luci-ikev2-domains/editor.js'
grep -Fq "_('Discard unsaved service changes?')" 'luci-ikev2-domains/editor.js'
if grep -Fq "common.fieldLabel(_('Enabled in policy'))" \
	'luci-ikev2-domains/editor.js'; then
	printf '%s\n' 'service editor must not bypass the page-level policy save' >&2
	exit 1
fi
if grep -Eq 'ikev2-chip-(edit|wrap)' \
	'luci-ikev2-domains/editor.js' 'luci-ikev2-manager/shared.js'; then
	printf '%s\n' 'per-service edit controls must not be rendered inside service chips' >&2
	exit 1
fi
grep -Fq 'user_services_dir="${IKEV2_USER_SERVICES_DIR:-/etc/ikev2-manager/services.d}"' \
	'luci-ikev2-domains/community-domains.sh'

printf '%s\n' 'luci UI contract OK'
