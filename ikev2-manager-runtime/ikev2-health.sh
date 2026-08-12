#!/bin/sh

status_file='/var/run/ikev2-health.status'
volatile_set_dump='/var/run/pbr-ikev2-set4.dump'
persistent_set_dump='/etc/ikev2-manager/pbr-set4.dump'
volatile_set6_dump='/var/run/pbr-ikev2-set6.dump'
persistent_set6_dump='/etc/ikev2-manager/pbr-set6.dump'
probe_state='/var/run/ikev2-health-probe.state'
probe_interval=20
dns_probe_state='/var/run/ikev2-dns-segments-probe.state'
dns_probe_interval=60
pbr_dump_state='/var/run/ikev2-pbr-dump.state'
pbr_dump_interval=60

has_proxy4() {
	printf '%s' "$1" | grep -q 'name=proxy4[^{}]* state=INSTALLED'
}

tunnel_probe() {
	# Both endpoints can stall. The loop also refreshes the inbound user policy,
	# whose nftables entries expire on a timer, so the probe budget is kept
	# short enough that a slow cycle cannot outlast those entries.
	curl -4fsS --interface ipsec-out \
		--connect-timeout 3 --max-time 5 \
		https://1.1.1.1/cdn-cgi/trace 2>/dev/null |
		grep -q '^ip=[0-9]' && return 0
	curl -4fsS --interface ipsec-out \
		--connect-timeout 3 --max-time 5 \
		https://checkip.amazonaws.com 2>/dev/null |
		grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+'
}

probe_due() {
	now="$1"
	last="$(sed -n 's/^last=//p' "$probe_state" 2>/dev/null | tail -n1)"
	case "$last" in '' | *[!0-9]*) last=0 ;; esac
	[ $((now - last)) -ge "$probe_interval" ]
}

probe_failures() {
	value="$(sed -n 's/^failures=//p' "$probe_state" 2>/dev/null | tail -n1)"
	case "$value" in '' | *[!0-9]*) value=0 ;; esac
	printf '%s\n' "$value"
}

save_probe() {
	{
		printf 'last=%s\n' "$1"
		printf 'failures=%s\n' "$2"
	} >"${probe_state}.new"
	mv "${probe_state}.new" "$probe_state"
}

periodic_due() {
	now="$1"
	state="$2"
	interval="$3"
	last="$(cat "$state" 2>/dev/null || echo 0)"
	case "$last" in '' | *[!0-9]*) last=0 ;; esac
	[ $((now - last)) -ge "$interval" ]
}

mark_periodic() {
	printf '%s\n' "$1" >"${2}.new"
	mv "${2}.new" "$2"
}

domain_set_name() {
	local family="$1"
	nft list table inet fw4 2>/dev/null |
		sed -n "s/^[[:space:]]*set \(pbr_ikev2out_${family}_dst_ip_[^[:space:]]*\) {.*/\1/p" |
		grep -v '_user$' | head -n1
}

# Persist the PBR domain set so pbr.user.ikev2out can restore it after a
# firewall/pbr restart. Without this, clients with warm DNS caches can bypass
# policy until dnsmasq repopulates the IPv4 and IPv6 sets.
dump_pbr_set() {
	local family="$1" dump="$2" set_name
	set_name="$(domain_set_name "$family")"
	[ -n "$set_name" ] || return 0
	nft list set inet fw4 "$set_name" 2>/dev/null |
		sed -n '/elements = {/,/}/p' | tr -d '\n\t' |
		sed 's/.*{//; s/}.*//' | tr ',' '\n' |
		tr -d ' ' | grep -v '^$' >"${dump}.new" || :
	if [ -s "${dump}.new" ]; then
		mv "${dump}.new" "$dump"
	else
		rm -f "${dump}.new"
	fi
}

dump_pbr_sets() {
	dump_pbr_set 4 "$volatile_set_dump"
	dump_pbr_set 6 "$volatile_set6_dump"
}

persist_pbr_sets() {
	dump_pbr_sets
	mkdir -p "${persistent_set_dump%/*}"
	if [ -s "$volatile_set_dump" ]; then
		cp "$volatile_set_dump" "${persistent_set_dump}.new"
		chmod 600 "${persistent_set_dump}.new"
		mv "${persistent_set_dump}.new" "$persistent_set_dump"
	fi
	if [ -s "$volatile_set6_dump" ]; then
		cp "$volatile_set6_dump" "${persistent_set6_dump}.new"
		chmod 600 "${persistent_set6_dump}.new"
		mv "${persistent_set6_dump}.new" "$persistent_set6_dump"
	fi
}

service_cidr_policy_healthy() {
	[ -s /etc/pbr-ikev2-service-cidrs.txt ] || return 0
	[ "$(uci -q get pbr.ikev2pbr_service_cidrs.enabled)" = 1 ] || return 1
	nft list chain inet fw4 pbr_prerouting 2>/dev/null |
		grep -q 'comment "IKEv2 PBR service networks"'
}

ensure_service_cidr_policy() {
	service_cidr_policy_healthy && return 0
	[ ! -d /var/run/ikev2-action.lock ] || return 0
	/usr/libexec/ikev2-domains-restart >/dev/null 2>&1 || :
}

ensure_discord_voice_policy() {
	[ -x /usr/libexec/ikev2-discord-voice ] || return 0
	/usr/libexec/ikev2-discord-voice check >/dev/null 2>&1 && return 0
	[ ! -d /var/run/ikev2-action.lock ] || return 0
	/usr/libexec/ikev2-discord-voice sync >/dev/null 2>&1 || :
}

ensure_device_routing_policy() {
	[ -x /usr/libexec/ikev2-device-routing ] || return 0
	/usr/libexec/ikev2-device-routing check >/dev/null 2>&1 && return 0
	[ ! -d /var/run/ikev2-action.lock ] || return 0
	/usr/libexec/ikev2-device-routing sync >/dev/null 2>&1 || :
}

refresh_inbound_user_policy() {
	[ -x /usr/libexec/ikev2-user-policy ] || return 0
	/usr/libexec/ikev2-user-policy sync >/dev/null 2>&1 || :
}

# Persist once during an orderly reboot/service stop. Keeping the hot runtime
# dump in /var/run avoids flash writes every 15 seconds, while the shutdown
# snapshot lets warm client DNS caches survive the next boot without leaking.
trap 'persist_pbr_sets; exit 0' INT TERM

while true; do
	if [ "$(uci -q get ikev2-manager.globals.configured)" != 1 ]; then
		printf 'state=disabled updated=%s\n' "$(date +%s)" >"$status_file"
		sleep 60
		continue
	fi

	if [ "$(uci -q get ikev2-manager.domains.engine)" = fakeip ] &&
	   [ -x /usr/libexec/ikev2-domain-router ]; then
		/usr/libexec/ikev2-domain-router ensure >/dev/null 2>&1 || :
	fi
	ensure_service_cidr_policy
	ensure_discord_voice_policy
	ensure_device_routing_policy

	/etc/init.d/ikev2-xfrm start

	client_enabled="$(uci -q get ikev2-manager.client.enabled || echo 0)"
	raw="$(swanctl --list-sas --raw 2>/dev/null || true)"
	if [ "$client_enabled" != 1 ]; then
		rm -f /var/run/ikev2-vip4
		/usr/share/pbr/pbr.user.ikev2out || :
		printf 'state=client-disabled updated=%s\n' "$(date +%s)" >"$status_file"
	fi

	# strongSwan normally owns reconnects. Its boot-time start_action can run
	# before WAN is usable, however, and that initial failure is not reliably
	# retried. ensure-client is idempotent, locked and rate-limited, so the
	# watcher safely fills that gap without racing manual actions or hotplug.
	if [ "$client_enabled" = 1 ] && ! has_proxy4 "$raw"; then
		/usr/libexec/ikev2-manager ensure-client >/dev/null 2>&1 || :
		raw="$(swanctl --list-sas --raw 2>/dev/null || true)"
	fi

	if [ "$client_enabled" = 1 ] && has_proxy4 "$raw"; then
		if /usr/libexec/ikev2-sync-vips &&
			/usr/share/pbr/pbr.user.ikev2out; then
			now="$(date +%s)"
			failures="$(probe_failures)"
			if probe_due "$now"; then
				if tunnel_probe; then
					failures=0
				else
					failures=$((failures + 1))
				fi
				save_probe "$now" "$failures"
			fi
			# Public endpoints are independent third parties. Probe failures are
			# telemetry only and must not tear down an otherwise installed SA.
			printf 'state=up updated=%s probe_failures=%s\n' \
				"$now" "$failures" >"$status_file"
		else
			printf 'state=degraded updated=%s\n' "$(date +%s)" >"$status_file"
		fi
	elif [ "$client_enabled" = 1 ]; then
		rm -f "$probe_state"
		rm -f /var/run/ikev2-vip4
		/usr/share/pbr/pbr.user.ikev2out || :
		printf 'state=down updated=%s\n' "$(date +%s)" >"$status_file"
	fi

	# Self-heal the inbound server if it drifted: enabled in config but the
	# ikev2-in connection is not loaded into charon (e.g. strongSwan reinstall
	# cleared /etc/swanctl, or a partial swanctl reload left the pool/cert
	# unloaded). server-ensure re-syncs the cert and reloads; it is a no-op when
	# already healthy, so this only acts when the server is actually broken.
	if [ "$(uci -q get ikev2-manager.server.enabled)" = 1 ] &&
		! swanctl --list-conns 2>/dev/null | grep -q 'ikev2-in:'; then
		/usr/libexec/ikev2-manager server-ensure >/dev/null 2>&1 || :
	fi

	loop_now="$(date +%s)"
	if periodic_due "$loop_now" "$dns_probe_state" "$dns_probe_interval"; then
		/usr/libexec/ikev2-manager-system dns-segments-check >/dev/null 2>&1 || :
		mark_periodic "$loop_now" "$dns_probe_state"
	fi
	if periodic_due "$loop_now" "$pbr_dump_state" "$pbr_dump_interval"; then
		dump_pbr_sets
		mark_periodic "$loop_now" "$pbr_dump_state"
	fi
	# Refresh again at the end of the cycle. The reconnect, probe and
	# DNS checks above can take much longer than the sleep.  The inbound policy
	# entries expire on a timer, so the last thing done before sleeping is to
	# renew them once.  A second unconditional rebuild at the start only churned
	# the same atomic nftables table without improving the timeout margin.
	refresh_inbound_user_policy
	sleep 15
done
