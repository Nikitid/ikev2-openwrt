#!/bin/sh
#
# template: check-index v1 (repo-templates)
# Do not edit in place: change templates/shared/ in repo-templates
# and run scripts/sync-templates.sh --update.
#
# docs/INDEX.md is only useful while it matches the code. Regenerate it into a
# scratch file and fail when the committed copy has drifted.

set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT INT TERM

"$root/scripts/gen-index.sh" "$tmp" >/dev/null

if ! cmp -s "$tmp" "$root/docs/INDEX.md"; then
	printf 'docs/INDEX.md is stale. Run scripts/gen-index.sh and commit the result.\n' >&2
	diff -u "$root/docs/INDEX.md" "$tmp" 2>/dev/null | head -20 >&2 || true
	exit 1
fi

printf 'function index OK: %s entries\n' \
	"$(grep -cE '^[0-9]+  ' "$root/docs/INDEX.md")"
