#!/bin/sh

set -u

manual_file="${IKEV2_MANUAL_FILE:-/etc/pbr-ikev2-domains.manual.txt}"
manual_cidr_file="${IKEV2_MANUAL_CIDR_FILE:-/etc/pbr-ikev2-addresses.manual.txt}"
selected_file="${IKEV2_SELECTED_FILE:-/etc/pbr-ikev2-community-selected.txt}"
final_file="${IKEV2_FINAL_FILE:-/etc/pbr-ikev2-domains.txt}"
cidr_file="${IKEV2_CIDR_FILE:-/etc/pbr-ikev2-service-cidrs.txt}"
catalog_file="${IKEV2_CATALOG_FILE:-/usr/share/ikev2-domains/community-services}"
subnet_catalog_file="${IKEV2_SUBNET_CATALOG_FILE:-/etc/pbr-ikev2-community-subnet-services}"
cache_dir="${IKEV2_CACHE_DIR:-/etc/pbr-ikev2-community-cache}"
status_file="${IKEV2_STATUS_FILE:-/tmp/ikev2-domains-community.status}"
status_dir="${IKEV2_STATUS_DIR:-/var/run/ikev2-domains-community-actions}"
log_file="${IKEV2_LOG_FILE:-/tmp/ikev2-domains-community.log}"
lock_dir="${IKEV2_LOCK_DIR:-/var/run/ikev2-domains-community.lock}"
pending_dir="${IKEV2_PENDING_DIR:-/var/run/ikev2-domains-community.pending.d}"
input_prefix="${IKEV2_INPUT_PREFIX:-/tmp/ikev2-domains-input}"
restart_helper="${IKEV2_RESTART_HELPER:-/usr/libexec/ikev2-domains-restart}"
runtime_lib_dir="${IKEV2_RUNTIME_LIB_DIR:-/usr/libexec/ikev2-manager.d}"
catalog_url="${IKEV2_CATALOG_URL:-https://api.github.com/repos/itdoginfo/allow-domains/contents/Services}"
subnet_catalog_url="${IKEV2_SUBNET_CATALOG_URL:-https://api.github.com/repos/itdoginfo/allow-domains/contents/Subnets/IPv4}"
raw_base="${IKEV2_RAW_BASE:-https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Services}"
# Same publisher as the domain lists, separate tree. Telegram and a few other
# services are reached by address rather than by name, so their networks must be
# refreshable instead of frozen into the package.
subnet_raw_base="${IKEV2_SUBNET_RAW_BASE:-https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Subnets/IPv4}"
local_services_dir="${IKEV2_LOCAL_SERVICES_DIR:-/usr/share/ikev2-domains/local-services}"
max_catalog_bytes="${IKEV2_MAX_CATALOG_BYTES:-1048576}"
max_service_bytes="${IKEV2_MAX_SERVICE_BYTES:-1048576}"
max_selected_services="${IKEV2_MAX_SELECTED_SERVICES:-64}"
max_total_bytes="${IKEV2_MAX_TOTAL_BYTES:-8388608}"
max_total_domains="${IKEV2_MAX_TOTAL_DOMAINS:-200000}"
max_parallel_downloads="${IKEV2_MAX_PARALLEL_DOWNLOADS:-4}"

. "$runtime_lib_dir/actions.sh"

positive_uint() {
	case "$1" in
		'' | 0 | *[!0-9]*) return 1 ;;
		*) return 0 ;;
	esac
}

validate_resource_limits() {
	for limit in "$max_catalog_bytes" "$max_service_bytes" \
		"$max_selected_services" "$max_total_bytes" \
		"$max_total_domains" "$max_parallel_downloads"; do
		positive_uint "$limit" || {
			echo 'invalid community resource limits' >&2
			return 1
		}
	done
}

valid_input_token() {
	case "$1" in
		'' | *[!A-Za-z0-9-]*) return 1 ;;
	esac
	[ "${#1}" -ge 8 ] && [ "${#1}" -le 64 ]
}

input_file() {
	printf '%s-%s.%s\n' "$input_prefix" "$1" "$2"
}

normalize_domains() {
	local normalized rc
	normalized="$(mktemp)" || return 1
	if ! awk '
		{
			gsub(/\r/, "")
			gsub(/^[ \t]+|[ \t]+$/, "")
			line = tolower($0)
			if (line == "" || substr(line, 1, 1) == "#")
				next
			if (length(line) > 253 || line !~ /^[a-z0-9._-]+$/ ||
			    line ~ /^\./ || line ~ /\.$/ || line ~ /\.\./) {
				printf "invalid domain: %s\n", line > "/dev/stderr"
				exit 1
			}
			count = split(line, labels, ".")
			for (i = 1; i <= count; i++) {
				if (length(labels[i]) < 1 || length(labels[i]) > 63 ||
				    labels[i] ~ /^-/ || labels[i] ~ /-$/) {
					printf "invalid domain: %s\n", line > "/dev/stderr"
					exit 1
				}
			}
			print line
		}
	' "$1" >"$normalized"; then
		rm -f "$normalized"
		return 1
	fi
	sort -u "$normalized"
	rc=$?
	rm -f "$normalized"
	return "$rc"
}

normalize_services() {
	local normalized rc
	normalized="$(mktemp)" || return 1
	if ! awk '
		{
			gsub(/\r/, "")
			gsub(/^[ \t]+|[ \t]+$/, "")
			line = tolower($0)
			if (line == "")
				next
			if (line !~ /^[a-z0-9_]+$/) {
				printf "invalid service: %s\n", line > "/dev/stderr"
				exit 1
			}
			print line
		}
	' "$1" >"$normalized"; then
		rm -f "$normalized"
		return 1
	fi
	sort -u "$normalized"
	rc=$?
	rm -f "$normalized"
	return "$rc"
}

normalize_cidrs() {
	awk '
		{
			gsub(/\r/, "")
			gsub(/^[ \t]+|[ \t]+$/, "")
			if ($0 == "" || substr($0, 1, 1) == "#")
				next
			if ($0 !~ /^[0-9.]+(\/[0-9]+)?$/) {
				printf "invalid IPv4 CIDR: %s\n", $0 > "/dev/stderr"
				exit 1
			}
			split($0, cidr, "/")
			prefix = (cidr[2] == "" ? 32 : cidr[2])
			if (prefix < 0 || prefix > 32 ||
			    split(cidr[1], octets, ".") != 4) {
				printf "invalid IPv4 CIDR: %s\n", $0 > "/dev/stderr"
				exit 1
			}
			for (i = 1; i <= 4; i++) {
				if (octets[i] !~ /^[0-9]+$/ ||
				    octets[i] < 0 || octets[i] > 255) {
					printf "invalid IPv4 CIDR: %s\n", $0 > "/dev/stderr"
					exit 1
				}
			}
			printf "%s/%d\n", cidr[1], prefix
		}
	' "$1"
}

# Runtime community lists are not a trust boundary: a compromised or mistaken
# upstream file must not turn one service into a route for a cloud provider or
# the entire Internet.  Locally curated and manually entered CIDRs keep their
# existing behavior; only downloaded service networks receive these limits.
normalize_service_cidrs() {
	local normalized rc
	normalized="$(mktemp)" || return 1
	if ! normalize_cidrs "$1" >"$normalized"; then
		rm -f "$normalized"
		return 1
	fi
	awk '
		BEGIN { total = 0; max_total = 65536 }
		{
			split($0, cidr, "/")
			prefix = cidr[2] + 0
			split(cidr[1], o, ".")
			global = 1
			if (o[1] == 0 || o[1] == 10 || o[1] == 127 || o[1] >= 224 ||
			    (o[1] == 100 && o[2] >= 64 && o[2] <= 127) ||
			    (o[1] == 169 && o[2] == 254) ||
			    (o[1] == 172 && o[2] >= 16 && o[2] <= 31) ||
			    (o[1] == 192 && o[2] == 0 && o[3] == 2) ||
			    (o[1] == 192 && o[2] == 168) ||
			    (o[1] == 198 && (o[2] == 18 || o[2] == 19)) ||
			    (o[1] == 198 && o[2] == 51 && o[3] == 100) ||
			    (o[1] == 203 && o[2] == 0 && o[3] == 113))
				global = 0
			size = 2 ^ (32 - prefix)
			if (!global || prefix < 16 || total + size > max_total) {
				printf "ignored unsafe community service CIDR: %s\n", $0 > "/dev/stderr"
				next
			}
			total += size
			print
		}
	' "$normalized"
	rc=$?
	rm -f "$normalized"
	return "$rc"
}

refresh_catalog() {
	local tmp_json tmp_catalog downloaded_size

	tmp_json="$(mktemp)"
	tmp_catalog="$(mktemp)"

	if uclient-fetch -q -T 15 -O "$tmp_json" "$catalog_url"; then
		downloaded_size="$(wc -c < "$tmp_json" | tr -d ' ')"
	else
		downloaded_size=0
	fi

	if [ "$downloaded_size" -gt 0 ] &&
		[ "$downloaded_size" -le "$max_catalog_bytes" ] &&
		jsonfilter -i "$tmp_json" -e '@[*].name' |
			sed -n 's/\.lst$//p' |
			awk '/^[a-z0-9_]+$/' |
			sort -u > "$tmp_catalog" &&
		[ -s "$tmp_catalog" ]; then
		mv "$tmp_catalog" "$catalog_file"
	else
		rm -f "$tmp_catalog"
		if [ "$downloaded_size" -gt "$max_catalog_bytes" ]; then
			echo 'downloaded service catalog exceeds size limit' >&2
		fi
	fi

	rm -f "$tmp_json"
}

# Which services publish networks. Only drives the "also brings networks" mark
# in the editor, so a failed refresh degrades to the bundled files rather than
# failing anything.
refresh_subnet_catalog() {
	local tmp_json tmp_catalog downloaded_size

	tmp_json="$(mktemp)"
	tmp_catalog="$(mktemp)"

	if uclient-fetch -q -T 15 -O "$tmp_json" "$subnet_catalog_url"; then
		downloaded_size="$(wc -c < "$tmp_json" | tr -d ' ')"
	else
		downloaded_size=0
	fi

	if [ "$downloaded_size" -gt 0 ] &&
		[ "$downloaded_size" -le "$max_catalog_bytes" ] &&
		jsonfilter -i "$tmp_json" -e '@[*].name' |
			sed -n 's/\.lst$//p' |
			awk '/^[a-z0-9_]+$/' |
			sort -u > "$tmp_catalog" &&
		[ -s "$tmp_catalog" ]; then
		cp "$tmp_catalog" "$subnet_catalog_file.tmp" &&
			chmod 600 "$subnet_catalog_file.tmp" &&
			mv "$subnet_catalog_file.tmp" "$subnet_catalog_file"
	fi

	rm -f "$tmp_json" "$tmp_catalog" "$subnet_catalog_file.tmp"
}

download_service() {
	local service="$1" destination="$2" cached
	cached="$cache_dir/$service.lst"
	local downloaded normalized downloaded_size

	# Check local bundled services first, but validate them exactly like remote
	# content so a packaging mistake cannot poison the active ruleset.
	if [ -s "$local_services_dir/$service.lst" ]; then
		normalized="$(mktemp)"
		if normalize_domains "$local_services_dir/$service.lst" \
			>"$normalized" && [ -s "$normalized" ]; then
			mv "$normalized" "$destination"
			return 0
		fi
		rm -f "$normalized"
		return 1
	fi

	downloaded="$(mktemp)"
	normalized="$(mktemp)"

	if uclient-fetch -q -T 20 -O "$downloaded" "$raw_base/$service.lst"; then
		downloaded_size="$(wc -c < "$downloaded" | tr -d ' ')"
	else
		downloaded_size=0
	fi

	if [ "$downloaded_size" -gt 0 ] &&
		[ "$downloaded_size" -le "$max_service_bytes" ] &&
		normalize_domains "$downloaded" > "$normalized" &&
		[ -s "$normalized" ]; then
		mkdir -p "$cache_dir"
		cp "$normalized" "$cached.tmp"
		mv "$cached.tmp" "$cached"
		cp "$normalized" "$destination"
		rm -f "$downloaded" "$normalized"
		return 0
	fi

	if [ "$downloaded_size" -gt "$max_service_bytes" ]; then
		echo "downloaded service exceeds size limit: $service" >&2
	fi

	rm -f "$downloaded" "$normalized"
	if [ -s "$cached" ]; then
		cp "$cached" "$destination"
		echo "$service" >> "$destination.stale"
		return 0
	fi

	echo "unable to download service without cache: $service" >&2
	return 1
}

# Networks for one service, written to $destination. Unlike the domain lists the
# bundled file does not win outright: it is curated but frozen, so it is merged
# with the published list. A range that upstream has not learned about yet is
# still routed, and a range it adds arrives without a package release. On a
# download failure the cache, then the bundled file, keep the previous coverage.
download_service_cidrs() {
	local service="$1" destination="$2"
	local cached="$cache_dir/$service.cidrs"
	local downloaded normalized

	: >"$destination"

	if [ -s "$local_services_dir/$service.cidrs" ]; then
		normalize_cidrs "$local_services_dir/$service.cidrs" >>"$destination" ||
			{ : >"$destination"; return 1; }
	fi

	downloaded="$(mktemp)"
	normalized="$(mktemp)"
	local downloaded_size=0

	if uclient-fetch -q -T 20 -O "$downloaded" "$subnet_raw_base/$service.lst"; then
		downloaded_size="$(wc -c < "$downloaded" | tr -d ' ')"
	fi

	if [ "$downloaded_size" -gt 0 ] &&
		[ "$downloaded_size" -le "$max_service_bytes" ] &&
		normalize_service_cidrs "$downloaded" > "$normalized" 2>/dev/null &&
		[ -s "$normalized" ]; then
		mkdir -p "$cache_dir"
		cp "$normalized" "$cached.tmp"
		mv "$cached.tmp" "$cached"
		cat "$normalized" >>"$destination"
	else
		if [ "$downloaded_size" -gt "$max_service_bytes" ]; then
			echo "downloaded service networks exceed size limit: $service" >&2
		fi
		# A service with no published networks is normal, not an error.
		[ ! -s "$cached" ] || normalize_service_cidrs "$cached" >>"$destination" 2>/dev/null || true
	fi

	rm -f "$downloaded" "$normalized"
	return 0
}

publish_status() {
	local source="$1" action_id="${2:-}" target
	mkdir -p "$status_dir" || return 1
	if [ -n "$action_id" ]; then
		target="$status_dir/$action_id.status"
		cp "$source" "${target}.new" || return 1
		mv "${target}.new" "$target" || return 1
	fi
	cp "$source" "${status_file}.new" || return 1
	mv "${status_file}.new" "$status_file"
}

write_simple_status() {
	local action_id="$1" state="$2" message="${3:-}" tmp
	tmp="$(mktemp)" || return 1
	{
		[ -z "$action_id" ] || echo "action_id=$action_id"
		echo "state=$state"
		echo "updated=$(date '+%Y-%m-%d %H:%M:%S %z')"
		[ -z "$message" ] || echo "message=$message"
	} >"$tmp"
	publish_status "$tmp" "$action_id"
	rm -f "$tmp"
}

restore_output() {
	local backup="$1" destination="$2"
	if [ -f "$backup" ]; then
		cp "$backup" "${destination}.restore" && mv "${destination}.restore" "$destination"
	else
		rm -f "$destination"
	fi
}

restart_policy() {
	if [ "${IKEV2_ACTION_LOCK_HELD:-0}" = 1 ]; then
		"$restart_helper" --wait --lock-held
	else
		"$restart_helper" --wait
	fi
}

apply_once() {
	local work selected normalized_manual service failed stale
	local selected_count domain_count cidr_count custom_cidr_count pids pid action_id
	local batch_count final_bytes
	action_id="${1:-}"
	[ -z "$action_id" ] ||
		write_simple_status "$action_id" running 'Preparing selected domain lists...' || true

	validate_resource_limits || return 1
	work="$(mktemp -d)" || return 1
	selected="$work/selected"
	normalized_manual="$work/manual"
	failed=0
	pids=''
	batch_count=0

	[ -f "$manual_file" ] || cp "$final_file" "$manual_file"
	[ -f "$manual_cidr_file" ] || : >"$manual_cidr_file"
	[ -f "$selected_file" ] || : >"$selected_file"

	if ! normalize_domains "$manual_file" >"$normalized_manual" ||
	   ! normalize_services "$selected_file" >"$selected"; then
		rm -rf "$work"
		return 1
	fi
	selected_count="$(wc -l <"$selected" | tr -d ' ')"
	if [ "$selected_count" -gt "$max_selected_services" ]; then
		echo "too many selected services: $selected_count (limit $max_selected_services)" >&2
		rm -rf "$work"
		return 1
	fi
	[ -z "$action_id" ] ||
		write_simple_status "$action_id" running 'Downloading selected service lists...' || true

	while IFS= read -r service; do
		[ -n "$service" ] || continue
		download_service "$service" "$work/$service.lst" &
		pids="$pids $!"
		batch_count=$((batch_count + 1))
		if [ "$batch_count" -ge "$max_parallel_downloads" ]; then
			for pid in $pids; do wait "$pid" || failed=1; done
			pids=''
			batch_count=0
		fi
	done <"$selected"
	for pid in $pids; do wait "$pid" || failed=1; done
	if [ "$failed" -ne 0 ]; then
		rm -rf "$work"
		return 1
	fi
	[ -z "$action_id" ] ||
		write_simple_status "$action_id" running 'Building the combined policy list...' || true

	{
		cat "$normalized_manual"
		while IFS= read -r service; do
			[ -n "$service" ] && cat "$work/$service.lst"
		done <"$selected"
	} | sort -u >"$work/final"

	if ! normalize_cidrs "$manual_cidr_file" >"$work/manual.cidrs"; then
		rm -rf "$work"
		return 1
	fi
	cp "$work/manual.cidrs" "$work/cidrs.unsorted"
	while IFS= read -r service; do
		[ -n "$service" ] || continue
		if ! download_service_cidrs "$service" "$work/$service.cidrs"; then
			rm -rf "$work"
			return 1
		fi
		[ -s "$work/$service.cidrs" ] || continue
		cat "$work/$service.cidrs" >>"$work/cidrs.unsorted"
	done <"$selected"
	sort -u "$work/cidrs.unsorted" 2>/dev/null >"$work/cidrs"

	if [ ! -s "$work/final" ] && [ -s "$selected" ]; then
		echo 'refusing to install an empty domain list (services selected but no domains resolved)' >&2
		rm -rf "$work"
		return 1
	fi
	domain_count="$(wc -l <"$work/final" | tr -d ' ')"
	final_bytes="$(wc -c <"$work/final" | tr -d ' ')"
	if [ "$domain_count" -gt "$max_total_domains" ] ||
	   [ "$final_bytes" -gt "$max_total_bytes" ]; then
		echo "combined domain list exceeds resource limits: $domain_count entries, $final_bytes bytes" >&2
		rm -rf "$work"
		return 1
	fi

	if [ -e "$final_file" ] && [ -e "$cidr_file" ] &&
	   cmp -s "$work/final" "$final_file" &&
	   cmp -s "$work/cidrs" "$cidr_file" &&
	   "$restart_helper" --check; then
		[ -z "$action_id" ] ||
			write_simple_status "$action_id" running \
				'Policy list unchanged; current routing is healthy.' || true
	else
		[ ! -e "$final_file" ] || cp "$final_file" "$work/final.before"
		[ ! -e "$cidr_file" ] || cp "$cidr_file" "$work/cidrs.before"
		[ -z "$action_id" ] ||
			write_simple_status "$action_id" running 'Restarting policy routing...' || true
		if ! cp "$work/final" "$final_file.tmp" ||
		   ! chmod 600 "$final_file.tmp" || ! mv "$final_file.tmp" "$final_file" ||
		   ! cp "$work/cidrs" "$cidr_file.tmp" ||
		   ! chmod 600 "$cidr_file.tmp" || ! mv "$cidr_file.tmp" "$cidr_file" ||
		   ! restart_policy; then
			restore_output "$work/final.before" "$final_file" || true
			restore_output "$work/cidrs.before" "$cidr_file" || true
			restart_policy >/dev/null 2>&1 || true
			rm -f "$final_file.tmp" "$cidr_file.tmp"
			rm -rf "$work"
			return 1
		fi
	fi

	cidr_count="$(wc -l <"$work/cidrs" | tr -d ' ')"
	custom_cidr_count="$(wc -l <"$work/manual.cidrs" | tr -d ' ')"
	stale="$(cat "$work"/*.stale 2>/dev/null | sort -u | tr '\n' ' ')"
	{
		[ -z "$action_id" ] || echo "action_id=$action_id"
		echo 'state=ok'
		echo "updated=$(date '+%Y-%m-%d %H:%M:%S %z')"
		echo "services=$selected_count"
		echo "domains=$domain_count"
		echo "cidrs=$cidr_count"
		echo "custom_cidrs=$custom_cidr_count"
		echo "selected=$(tr '\n' ',' <"$selected" | sed 's/,$//')"
		[ -z "$stale" ] || echo "cached_services=$stale"
	} >"$work/status"
	publish_status "$work/status" "$action_id" || true
	rm -rf "$work"
}

apply_failure_file="${IKEV2_APPLY_FAILURE_FILE:-/var/run/ikev2-domains-community.failure}"

# Every abort below used to return silently, so an operator saw "Community
# update failed" with an empty log and no way to tell which check rejected the
# input. Record the reason for both the log and the status message.
apply_failed() {
	printf 'apply rejected: %s\n' "$1" >&2
	mkdir -p "${apply_failure_file%/*}" 2>/dev/null || :
	printf '%s\n' "$1" >"$apply_failure_file" 2>/dev/null || :
	return 1
}

apply_staged_input() {
	local action_id="$1" token="$2" work kind source destination bytes
	local restore_kind restore_destination
	valid_input_token "$token" || {
		apply_failed 'the submitted input token is malformed'
		return 1
	}
	validate_resource_limits || {
		apply_failed 'configured resource limits are invalid'
		return 1
	}
	work="$(mktemp -d)" || {
		apply_failed 'no writable temporary directory'
		return 1
	}
	for kind in domains cidrs services; do
		source="$(input_file "$token" "$kind")"
		[ -f "$source" ] && [ ! -L "$source" ] || {
			rm -rf "$work"
			apply_failed "submitted $kind input is missing or not a regular file"
			return 1
		}
		bytes="$(wc -c <"$source" | tr -d ' ')"
		case "$kind" in
			domains) [ "$bytes" -le "$max_total_bytes" ] ;;
			cidrs) [ "$bytes" -le 1048576 ] ;;
			services) [ "$bytes" -le 65536 ] ;;
		esac || {
			rm -rf "$work"
			apply_failed "submitted $kind input exceeds its size limit ($bytes bytes)"
			return 1
		}
	done
	# Capture every previous input before replacing any of them. This keeps a
	# failed three-file publish from deleting an input that was not backed up yet.
	for kind in domains cidrs services; do
		case "$kind" in
			domains) destination="$manual_file" ;;
			cidrs) destination="$manual_cidr_file" ;;
			services) destination="$selected_file" ;;
		esac
		[ ! -e "$destination" ] || cp "$destination" "$work/$kind.before" || {
			rm -rf "$work"
			apply_failed "unable to back up the current $kind list"
			return 1
		}
	done
	for kind in domains cidrs services; do
		case "$kind" in
			domains) destination="$manual_file" ;;
			cidrs) destination="$manual_cidr_file" ;;
			services) destination="$selected_file" ;;
		esac
		source="$(input_file "$token" "$kind")"
		if ! cp "$source" "${destination}.new.$$" ||
		   ! chmod 600 "${destination}.new.$$" ||
		   ! mv "${destination}.new.$$" "$destination"; then
			for restore_kind in domains cidrs services; do
				case "$restore_kind" in
					domains) restore_destination="$manual_file" ;;
					cidrs) restore_destination="$manual_cidr_file" ;;
					services) restore_destination="$selected_file" ;;
				esac
				restore_output "$work/$restore_kind.before" "$restore_destination" || true
			done
			rm -f "${destination}.new.$$"
			rm -rf "$work"
			apply_failed "unable to publish the new $kind list"
			return 1
		fi
	done
	for kind in domains cidrs services; do rm -f "$(input_file "$token" "$kind")"; done
	if apply_once "$action_id"; then
		rm -rf "$work"
		return 0
	fi
	restore_output "$work/domains.before" "$manual_file" || true
	restore_output "$work/cidrs.before" "$manual_cidr_file" || true
	restore_output "$work/services.before" "$selected_file" || true
	rm -rf "$work"
	return 1
}

run_scheduled() {
	sleep 1
	pid_lock_acquire "$lock_dir" || exit 0
	trap 'pid_lock_release "$lock_dir"' EXIT INT TERM
	idle_passes=0
	while [ "$idle_passes" -lt 2 ]; do
		pending="$(find "$pending_dir" -type f 2>/dev/null | sort | head -n1)"
		if [ -z "$pending" ]; then
			idle_passes=$((idle_passes + 1))
			sleep 1
			continue
		fi
		idle_passes=0
		action_id="${pending##*/}"
		token="$(sed -n '1p' "$pending" 2>/dev/null)"
		rm -f "$pending"
		rm -f "$apply_failure_file"
		if ! apply_staged_input "$action_id" "$token" >>"$log_file" 2>&1; then
			reason="$(sed -n '1p' "$apply_failure_file" 2>/dev/null || true)"
			rm -f "$apply_failure_file"
			if [ -n "$reason" ]; then
				write_simple_status "$action_id" error \
					"Community update failed: $reason; previous combined list preserved" || true
			else
				write_simple_status "$action_id" error \
					'Community update failed; previous combined list preserved' || true
			fi
		fi
	done
}

case "${1:-}" in
	catalog)
		if [ ! -s "$catalog_file" ] ||
			find "$catalog_file" -mtime +0 -print | grep -q .; then
			refresh_catalog
		fi
		{
			cat "$catalog_file" 2>/dev/null
			ls -1 "$local_services_dir"/*.lst 2>/dev/null \
				| sed 's|.*/||;s/\.lst$//'
		} | sort -u
		;;
	ip-services)
		if [ ! -s "$subnet_catalog_file" ] ||
			find "$subnet_catalog_file" -mtime +0 -print 2>/dev/null | grep -q .; then
			refresh_subnet_catalog
		fi
		{
			cat "$subnet_catalog_file" 2>/dev/null
			for source in "$local_services_dir"/*.cidrs; do
				[ -s "$source" ] || continue
				printf '%s\n' "${source##*/}" | sed 's/\.cidrs$//'
			done
		} | sort -u
		;;
	schedule)
		token="${2:-}"
		valid_input_token "$token" || { echo 'invalid input token' >&2; exit 2; }
		for kind in domains cidrs services; do
			path="$(input_file "$token" "$kind")"
			[ -f "$path" ] && [ ! -L "$path" ] || {
				echo "missing staged $kind input" >&2
				exit 1
			}
		done
		action_id="$(date +%s)-$$"
		mkdir -p "$pending_dir"
		find "$status_dir" -type f -mtime +7 -exec rm -f {} \; 2>/dev/null || true
		printf '%s\n' "$token" >"$pending_dir/$action_id"
		write_simple_status "$action_id" running 'Queued...' || {
			rm -f "$pending_dir/$action_id"
			exit 1
		}
		# rpcd's `file exec` reads the child's stdout until EOF, so a plain
		# background/setsid job keeps the pipe open and the caller blocks until
		# the ubus timeout (~30s). start-stop-daemon -b fully daemonizes —
		# closing every inherited descriptor — so rpcd gets EOF immediately and
		# the rebuild proceeds detached.
		if command -v start-stop-daemon >/dev/null 2>&1; then
			if ! start-stop-daemon -b -q -S -x "$0" -- _run; then
				rm -f "$pending_dir/$action_id"
				write_simple_status "$action_id" error 'Unable to start the community update worker' || true
				exit 1
			fi
		else
			setsid "$0" _run </dev/null >/dev/null 2>&1 &
		fi
		printf 'action_id=%s\n' "$action_id"
		;;
	_run)
		run_scheduled
		;;
	apply)
		pid_lock_acquire "$lock_dir" || {
			echo 'another community update is already running' >&2
			exit 1
		}
		trap 'pid_lock_release "$lock_dir"' EXIT INT TERM
		apply_once
		;;
	_apply-input)
		apply_staged_input "${2:-}" "${3:-}"
		;;
	status)
		action_id="${2:-}"
		case "$action_id" in
			'' | *[!0-9-]*) echo 'invalid action id' >&2; exit 2 ;;
		esac
		cat "$status_dir/$action_id.status" 2>/dev/null || printf 'state=idle\n'
		;;
	*)
		echo "usage: $0 {catalog|ip-services|schedule TOKEN|status ACTION_ID|apply}" >&2
		exit 2
		;;
esac
