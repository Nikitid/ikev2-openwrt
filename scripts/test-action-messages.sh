#!/bin/sh

# A failed router action reported "previous managed configuration was
# restored" whatever happened, including when the step itself had just said its
# rollback was incomplete. The action must report the step's own last word.

set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
helper="$root/ikev2-manager-runtime/ikev2-manager-system.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM

fail() {
	printf '%s\n' "$*" >&2
	exit 1
}

awk '
	index($0, "action_error_message() {") == 1 { body = 1 }
	body { print }
	body && $0 == "}" { exit }
' "$helper" >"$tmp/functions.sh"
grep -q '^action_error_message() {' "$tmp/functions.sh" || fail 'action_error_message is missing'
. "$tmp/functions.sh"

printf 'validating\nManaged mode failed and automatic rollback was incomplete\n\n' >"$tmp/error"
[ "$(action_error_message "$tmp/error" fallback 2>/dev/null)" = \
	'Managed mode failed and automatic rollback was incomplete' ] ||
	fail 'an incomplete rollback was not reported as the outcome'
[ ! -e "$tmp/error" ] || fail 'the step error file was left behind'
: >"$tmp/error"
[ "$(action_error_message "$tmp/error" 'the fallback' 2>/dev/null)" = 'the fallback' ] ||
	fail 'a step that said nothing did not get the fallback message'

# Every action that restores state on failure reports through it.
for kind in set_config coverage_add coverage_remove; do
	awk -v fn="$kind" '
		index($0, "( " fn " ") && index($0, "2>\"$step_error\"") { found = 1 }
		END { exit !found }
	' "$helper" || fail "the $kind action does not capture its own outcome"
done
grep -q 'previous managed configuration was restored' "$helper" &&
	fail 'a fixed "restored" message is still reported regardless of the outcome'

printf '%s\n' 'action message tests OK'
