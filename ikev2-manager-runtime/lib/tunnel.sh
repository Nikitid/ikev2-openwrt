#!/bin/sh
# Outbound tunnel data-path probe shared by the watcher and the domain router.

# Succeed when HTTPS crosses ipsec-out. Binding by device is the only reliable
# way to use the tunnel from the router: binding the tunnel address still routes
# over WAN. The IP-literal endpoint goes first, so the probe does not depend on
# DNS; both endpoints are third parties and either can fail on its own.
# Arguments: connect timeout and total time per endpoint, in seconds.
tunnel_https_reachable() {
	local connect="${1:-3}" total="${2:-5}"
	curl -4fsS --interface ipsec-out \
		--connect-timeout "$connect" --max-time "$total" \
		https://1.1.1.1/cdn-cgi/trace 2>/dev/null |
		grep -q '^ip=[0-9]' && return 0
	curl -4fsS --interface ipsec-out \
		--connect-timeout "$connect" --max-time "$total" \
		https://checkip.amazonaws.com 2>/dev/null |
		grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+'
}
