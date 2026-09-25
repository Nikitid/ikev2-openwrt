#!/bin/sh
# Authenticated access to the domain router's sing-box controller on loopback.
# The domain router renders the credential into its configuration; callers read
# it here instead of each parsing the configuration themselves.

controller_address='127.0.0.44:1605'

# Write a curl configuration carrying the credential into DIR/curl.conf, so the
# secret never appears in a process argument list.
controller_curl_config() {
	local dir="$1" secret
	secret="$(jsonfilter -i "${IKEV2_DOMAIN_CONFIG:-/etc/ikev2-manager/domain-router.json}" \
		-e '@.experimental.clash_api.secret' 2>/dev/null)" || return 1
	printf '%s' "$secret" | grep -Eq '^[0-9a-f]{64}$' || return 1
	(
		umask 077
		printf 'header = "Authorization: Bearer %s"\n' "$secret" >"$dir/curl.conf"
	)
}
