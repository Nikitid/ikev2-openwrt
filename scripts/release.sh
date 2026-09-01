#!/bin/sh
#
# Cut a release and put it on the routers.
#
# The steps are here because the sequence has a hole in it: the release
# workflow's feed notification reports success while the dispatch never
# arrives, so a published tag is invisible to `apk update` until the feed is
# rebuilt by hand. Every release that skipped that step sat unused.
#
# Usage: scripts/release.sh [--deploy host[,host...]]
#
# Run it from a clean tree whose release.env already carries the new version.
# It refuses to invent one: bump release.env, the Makefile literal and the
# changelog first, and commit them.

set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
cd "$root"

deploy=''
while [ $# -gt 0 ]; do
	case "$1" in
		--deploy) deploy="${2:-}"; shift 2 ;;
		*) printf 'Unknown argument: %s\n' "$1" >&2; exit 1 ;;
	esac
done

. ./release.env
tag="v$PKG_VERSION"

[ -z "$(git status --porcelain)" ] ||
	{ printf 'Working tree is dirty; commit before releasing.\n' >&2; exit 1; }
git rev-parse "$tag" >/dev/null 2>&1 &&
	{ printf '%s already exists.\n' "$tag" >&2; exit 1; }
grep -q "^## $PKG_VERSION " CHANGELOG.md ||
	{ printf 'CHANGELOG.md has no entry for %s.\n' "$PKG_VERSION" >&2; exit 1; }

printf '== checks\n'
./scripts/ci-check.sh >/dev/null

printf '== tag %s\n' "$tag"
git push -q origin HEAD
git tag -a "$tag" -m "$PKG_VERSION"
git push -q origin "$tag"

printf '== release workflow\n'
run=''
while [ -z "$run" ]; do
	run="$(gh run list --limit 5 --json databaseId,workflowName,headBranch \
		--jq ".[] | select(.headBranch==\"$tag\" and .workflowName==\"Release\") | .databaseId")"
	[ -n "$run" ] || sleep 5
done
while [ "$(gh run view "$run" --json status --jq .status)" != completed ]; do
	sleep 20
done
[ "$(gh run view "$run" --json conclusion --jq .conclusion)" = success ] ||
	{ printf 'Release run failed: %s\n' "$run" >&2; exit 1; }

# Without this the tag is published and no router can see it.
printf '== feed\n'
gh workflow run "Build feed" --repo Nikitid/openwrt-feed >/dev/null
sleep 12
feed="$(gh api repos/Nikitid/openwrt-feed/actions/runs --jq '.workflow_runs[0].id')"
while [ "$(gh run view "$feed" --repo Nikitid/openwrt-feed --json status --jq .status)" != completed ]; do
	sleep 20
done
[ "$(gh run view "$feed" --repo Nikitid/openwrt-feed --json conclusion --jq .conclusion)" = success ] ||
	{ printf 'Feed build failed: %s\n' "$feed" >&2; exit 1; }

printf '%s released and in the feed.\n' "$tag"

[ -n "$deploy" ] || exit 0
printf '== install\n'
# Only this package is named. A bare upgrade would take every package on the
# router with it.
for host in $(printf '%s' "$deploy" | tr ',' ' '); do
	printf '  %-16s ' "$host"
	ssh -o ConnectTimeout=10 -p "${IKEV2_SSH_PORT:-1111}" "root@$host" \
		"apk update >/dev/null 2>&1
		 apk add --upgrade $PKG_NAME >/dev/null 2>&1
		 printf 'v=%s ' \"\$(cat /usr/share/ikev2-manager/version)\"
		 /usr/libexec/ikev2-manager-system doctor-ui 2>/dev/null | grep -E '^doctor_ok='"
done
