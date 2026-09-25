#!/bin/sh
# ACME certificate settings and issuance for the inbound server. Sourced by
# ikev2-manager, whose configuration helpers and globals it uses.

# ACME issuance for the inbound server certificate. The app owns the
# /etc/config/acme cert section so the UI can pick HTTP-01 or DNS-01 without
# touching luci-app-acme. The acme hotplug (90-ikev2-acme) and acme-issue both
# sync the issued cert into swanctl.
acme_server_cert_path() {
	cert_source="$(getv server cert_source)"
	[ -n "$cert_source" ] || cert_source='/etc/ssl/acme'
	printf '%s/%s.fullchain.crt' "$cert_source" "$(getv server identity)"
}

acme_emit() {
	identity="$(getv server identity)"
	section="acme.$acme_cert_section"
	method="$(uci -q get "$section.validation_method" 2>/dev/null || true)"
	case "$method" in
		dns) printf 'method=dns\n' ;;
		*) printf 'method=http\n' ;;
	esac
	email="$(uci -q get acme.@acme[0].account_email 2>/dev/null || true)"
	[ "$email" = 'email@example.org' ] && email=''
	printf 'email=%s\n' "$email"
	printf 'dns_provider=%s\n' "$(uci -q get "$section.dns" 2>/dev/null || true)"
	printf 'staging=%s\n' "$(uci -q get "$section.staging" 2>/dev/null || echo 0)"
	[ -n "$(uci -q get "$section.credentials" 2>/dev/null || true)" ] &&
		printf 'has_credentials=1\n' || printf 'has_credentials=0\n'
	printf 'providers='
	for d in "$acme_dnsapi_dir"/dns_*.sh; do
		[ -e "$d" ] || continue
		b="${d##*/}"
		printf '%s ' "${b%.sh}"
	done
	printf '\n'
	printf 'identities='
	identity_candidates=''
	for section_name in $(uci show acme 2>/dev/null \
		| sed -n 's/^acme\.\([^.=]*\)=cert$/\1/p'); do
		[ "$(uci -q get "acme.$section_name.enabled" 2>/dev/null || echo 0)" = 1 ] || continue
		for domain in $(uci -q get "acme.$section_name.domains" 2>/dev/null || true); do
			case "$domain" in \*.*|'') continue ;; esac
			case " $identity_candidates " in *" $domain "*) continue ;; esac
			if valid_host "$domain"; then
				printf '%s ' "$domain"
				identity_candidates="${identity_candidates:+$identity_candidates }$domain"
			fi
		done
	done
	printf '\n'
	cert="$(acme_server_cert_path)"
	if [ -n "$identity" ] && [ -s "$cert" ]; then
		printf 'cert_present=1\n'
		printf 'cert_expiry=%s\n' "$(openssl x509 -in "$cert" -noout -enddate 2>/dev/null | cut -d= -f2-)"
		printf 'cert_subject=%s\n' "$(openssl x509 -in "$cert" -noout -subject 2>/dev/null | sed 's/^subject=//')"
	else
		printf 'cert_present=0\n'
	fi
	# Runtime truth for the Inbound Server page: is the conn actually loaded into
	# charon? Lets the UI distinguish "enabled with a cert" from "actually serving".
	printf 'conn_loaded=%s\n' "$([ -z "$root" ] && swanctl --list-conns 2>/dev/null | grep -q 'ikev2-in:' && echo 1 || echo 0)"
}

# Primary env var for single-credential DNS providers, so a user can paste just
# the token instead of the exact `VAR="value"` acme.sh syntax.
acme_primary_var() {
	case "$1" in
		dns_timeweb) echo 'TW_Token' ;;
		dns_cf) echo 'CF_Token' ;;
		dns_duckdns) echo 'DuckDNS_Token' ;;
		dns_dynv6) echo 'DYNV6_TOKEN' ;;
		dns_desec) echo 'DEDYN_TOKEN' ;;
		dns_hetzner) echo 'HETZNER_Token' ;;
		dns_njalla) echo 'NJALLA_Token' ;;
		dns_vultr) echo 'VULTR_API_KEY' ;;
		dns_gcore) echo 'GCORE_Key' ;;
		dns_namesilo) echo 'Namesilo_Key' ;;
		dns_linode_v4) echo 'LINODE_V4_API_KEY' ;;
		dns_dynu) echo 'Dynu_ClientId' ;;
		*) echo '' ;;
	esac
}

normalize_acme_credentials() {
	local provider="$1" source="$2" output="$3" primary_var line name value names count backtick
	primary_var="$(acme_primary_var "$provider")"
	backtick="$(printf '\\140')"
	names=''
	count=0
	: >"$output" || return 1
	while IFS= read -r line || [ -n "$line" ]; do
		line="$(printf '%s' "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
		[ -n "$line" ] || continue
		case "$line" in
			*=*)
				name="${line%%=*}"
				value="${line#*=}"
				;;
			*)
				[ -n "$primary_var" ] || return 1
				name="$primary_var"
				value="$line"
				;;
		esac
		printf '%s' "$name" | grep -Eq '^[A-Za-z_][A-Za-z0-9_]*$' || return 1
		case "$value" in
			\"*\") value="${value#\"}"; value="${value%\"}" ;;
			\'*) [ "${value%\'}" != "$value" ] || return 1
				value="${value#\'}"; value="${value%\'}" ;;
		esac
		[ -n "$value" ] && [ "${#value}" -le 4096 ] || return 1
		! printf '%s' "$value" | LC_ALL=C grep -q '[[:cntrl:]]' || return 1
		# acme-common consumes KEY=VAL as shell assignments. Re-quote the value
		# ourselves and reject characters that could escape or expand that quoting.
		! printf '%s' "$value" | grep -q '[\"\\$]' || return 1
		case "$value" in *"$backtick"*) return 1 ;; esac
		case " $names " in *" $name "*) return 1 ;; esac
		names="$names $name"
		count=$((count + 1))
		[ "$count" -le 32 ] || return 1
		printf '%s="%s"\n' "$name" "$value" >>"$output" || return 1
	done <"$source"
}

restore_acme_state() {
	local directory="$1"
	uci -q revert acme >/dev/null 2>&1 || true
	restore_path "$uci_config_dir/acme" "$directory" uci
}

commit_acme_settings() {
	local credential
	uci -q get acme.@acme[0] >/dev/null 2>&1 ||
		uci add acme acme >/dev/null || return 1
	uci set "acme.@acme[0].account_email=$a_email" || return 1
	uci set "acme.$acme_cert_section=cert" || return 1
	uci -q delete "acme.$acme_cert_section.domains" >/dev/null 2>&1 || true
	uci add_list "acme.$acme_cert_section.domains=$identity" || return 1
	uci set "acme.$acme_cert_section.enabled=1" || return 1
	uci set "acme.$acme_cert_section.key_type=rsa2048" || return 1
	uci set "acme.$acme_cert_section.staging=$a_staging" || return 1
	case "$a_method" in
		dns)
			uci set "acme.$acme_cert_section.validation_method=dns" || return 1
			uci set "acme.$acme_cert_section.dns=$a_provider" || return 1
			uci set "acme.$acme_cert_section.dns_wait=120" || return 1
			if [ -s "$acme_work/credentials" ]; then
				uci -q delete "acme.$acme_cert_section.credentials" >/dev/null 2>&1 || true
				while IFS= read -r credential; do
					uci add_list "acme.$acme_cert_section.credentials=$credential" || return 1
				done <"$acme_work/credentials"
			fi
			;;
		http)
			# Webroot avoids colliding with LuCI/uhttpd on local TCP 80. Current
			# acme-common serves /var/run/acme/challenge through the web root.
			uci set "acme.$acme_cert_section.validation_method=webroot" || return 1
			uci -q delete "acme.$acme_cert_section.dns" >/dev/null 2>&1 || true
			uci -q delete "acme.$acme_cert_section.dns_wait" >/dev/null 2>&1 || true
			uci -q delete "acme.$acme_cert_section.credentials" >/dev/null 2>&1 || true
			;;
	esac
	uci commit acme || return 1
	chmod 600 "$uci_config_dir/acme"
}

acme_set() {
	# Settings arrive through a token-addressed file written with fs.write. Only
	# the short random token is passed on the command line, so credentials never
	# enter rpcd ACL matching or the process list. Layout: line1=email,
	# line2=method, line3=provider, line4=staging, line5+=credentials.
	infile="$acme_input_file"
	[ -s "$infile" ] || die 'No ACME settings received'
	[ ! -L "$infile" ] || die 'ACME settings input must not be a symbolic link'
	input_bytes="$(wc -c <"$infile" | tr -d ' ')"
	case "$input_bytes" in '' | *[!0-9]*) die 'Invalid ACME input size' ;; esac
	[ "$input_bytes" -le 65536 ] || {
		rm -f "$infile"
		die 'ACME settings input is too large'
	}
	chmod 600 "$infile" || die 'Unable to protect ACME settings input'
	acme_work="$(mktemp -d)" || die 'Unable to prepare ACME settings'
	a_email="$(sed -n '1p' "$infile")"
	a_method="$(sed -n '2p' "$infile")"
	a_provider="$(sed -n '3p' "$infile")"
	a_staging="$(sed -n '4p' "$infile")"
	sed -n '5,$p' "$infile" >"$acme_work/credentials.raw" || {
		rm -rf "$acme_work"
		die 'Unable to read ACME credentials'
	}
	rm -f "$infile"
	identity="$(getv server identity)"
	[ -n "$identity" ] || { rm -rf "$acme_work"; die 'Set the server public identity first'; }
	valid_host "$identity" || { rm -rf "$acme_work"; die 'Invalid server identity'; }
	printf '%s' "$a_email" | grep -Eq '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' ||
		{ rm -rf "$acme_work"; die 'A valid ACME account email is required'; }
	{ [ "$a_staging" = 0 ] || [ "$a_staging" = 1 ]; } ||
		{ rm -rf "$acme_work"; die 'Invalid staging value'; }

	case "$a_method" in
		dns)
			printf '%s' "$a_provider" | grep -Eq '^dns_[a-z0-9_]+$' ||
				{ rm -rf "$acme_work"; die 'Invalid DNS provider'; }
			[ -e "$acme_dnsapi_dir/$a_provider.sh" ] ||
				{ rm -rf "$acme_work"; die "DNS provider not installed: $a_provider"; }
			if grep -q '[^[:space:]]' "$acme_work/credentials.raw"; then
				normalize_acme_credentials "$a_provider" "$acme_work/credentials.raw" \
					"$acme_work/credentials" ||
					{ rm -rf "$acme_work"; die 'Invalid DNS provider credentials'; }
			else
				old_provider="$(uci -q get "acme.$acme_cert_section.dns" 2>/dev/null || true)"
				existing_credentials="$(uci -q get "acme.$acme_cert_section.credentials" 2>/dev/null || true)"
				[ "$old_provider" = "$a_provider" ] && [ -n "$existing_credentials" ] ||
					{ rm -rf "$acme_work"; die 'DNS provider credentials are required'; }
			fi
			;;
		http)
			: >"$acme_work/credentials"
			;;
		*)
			rm -rf "$acme_work"
			die 'Invalid challenge method (expected dns or http)'
			;;
	esac
	pid_lock_acquire "$config_lock_dir" || {
		rm -rf "$acme_work"
		die 'Another configuration change is already in progress'
	}
	if ! snapshot_path "$uci_config_dir/acme" "$acme_work" uci; then
		rm -rf "$acme_work"
		pid_lock_release "$config_lock_dir"
		die 'Unable to back up ACME settings'
	fi
	trap 'restore_acme_state "$acme_work"; rm -rf "$acme_work"; pid_lock_release "$config_lock_dir"; exit 1' INT TERM HUP
	if ! commit_acme_settings; then
		acme_restored=0
		restore_acme_state "$acme_work" && acme_restored=1
		rm -rf "$acme_work"
		pid_lock_release "$config_lock_dir"
		trap - INT TERM HUP
		[ "$acme_restored" = 1 ] &&
			die 'Unable to save ACME settings; previous configuration restored'
		die 'Unable to save ACME settings and automatic rollback was incomplete'
	fi
	rm -rf "$acme_work"
	pid_lock_release "$config_lock_dir"
	trap - INT TERM HUP
}

acme_issue_action() {
	local identity cert key attempt
	identity="$(getv server identity)"
	[ -n "$identity" ] || return 1
	cert="$(acme_server_cert_path)"
	key="$(getv server key_file)"
	[ -n "$key" ] || key="$(getv server cert_source)/$identity.key"
	printf '\n=== %s acme issue ===\n' "$(date)" >>"$acme_log_file"
	/etc/init.d/acme renew "$acme_cert_section" >>"$acme_log_file" 2>&1 || return 1
	attempt=0
	while [ "$attempt" -lt 72 ]; do
		if [ -s "$cert" ] && [ -s "$key" ] &&
		   validate_server_certificate_files "$cert" "$key" "$identity"; then
			if [ "$(getv server enabled)" = 1 ]; then
				sync_server_certificate || return 1
				render_server || return 1
				render_users || return 1
				server_apply_action 1 || return 1
			fi
			return 0
		fi
		attempt=$((attempt + 1))
		sleep 5
	done
	return 1
}

acme_issue() {
	local identity
	identity="$(getv server identity)"
	[ -n "$identity" ] || die 'Set the server public identity first'
	uci -q get "acme.$acme_cert_section" >/dev/null 2>&1 ||
		die 'Configure ACME settings first'
	start_action acme-issue
}
