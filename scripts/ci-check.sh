#!/bin/sh

set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
cd "$root"

./scripts/check-version-sync.sh
./scripts/check-public-tree.sh
./scripts/check-index.sh
./scripts/check-actions-pinned.sh
./scripts/check-apk-feed.sh
./scripts/check-busybox-compat.sh

find luci-ikev2-domains luci-ikev2-manager ikev2-manager-runtime scripts \
	-type f -name '*.sh' -exec sh -n {} +

find luci-ikev2-domains luci-ikev2-manager \
	-type f -name '*.js' -exec node --check {} \;

./scripts/check-luci-ui-contract.sh
./scripts/check-luci-exec-acl.sh
./scripts/test-luci-client-ui.sh
./scripts/test-luci-translations.sh
node ./scripts/test-luci-users-ui.js
node ./scripts/test-luci-shared.js
node ./scripts/test-luci-status-widget.js
./scripts/test-widget-status.sh
./scripts/test-doctor-ui-cache.sh

./scripts/test-package-lifecycle.sh
./scripts/test-upgrade-reconcile.sh

./scripts/test-runtime-modules.sh
./scripts/test-system-validation.sh
./scripts/test-upnp-compatibility.sh
./scripts/test-dependency-state.sh
./scripts/test-device-state.sh
./scripts/test-feed-migration.sh
./scripts/test-health-restart.sh
./scripts/test-health-entrypoint.sh
./scripts/test-boot-recovery.sh
./scripts/test-dns-regressions.sh
./scripts/test-dns-wan-fallback.sh
./scripts/test-domain-lock-serialization.sh
./scripts/test-dns-segments.sh
./scripts/test-sing-box-update.sh
./scripts/test-sync-vips.sh
./scripts/test-community-domains.sh
./scripts/test-pbr-restart.sh
./scripts/test-discord-voice-routing.sh
./scripts/test-device-routing.sh
./scripts/test-user-credentials.sh
./scripts/test-client-profile-export.sh
./scripts/test-windows-profile-installer.sh
./scripts/test-user-policy.sh
./scripts/test-client-transaction.sh
./scripts/test-connect-diagnosis.sh
./scripts/test-acme-settings.sh
./scripts/test-server-transaction.sh
./scripts/test-server-certificate-chain.sh

PYTHONPYCACHEPREFIX="$root/build/pycache" \
	python3 -m py_compile scripts/pack-ipk.py

python3 - <<'PY'
import json
import subprocess
from pathlib import Path

tracked = subprocess.check_output(
    ["git", "ls-files", "*.json"], text=True
).splitlines()
for name in tracked:
    path = Path(name)
    if not path.exists():
        continue
    json.loads(path.read_text())
    print(f"json OK: {path}")
PY

./scripts/build-ipk.sh
first_hash="$(sha256sum dist/*.ipk | awk '{ print $1 }')"
./scripts/build-ipk.sh
second_hash="$(sha256sum dist/*.ipk | awk '{ print $1 }')"
[ "$first_hash" = "$second_hash" ] || {
	printf 'non-deterministic IPK build: %s != %s\n' "$first_hash" "$second_hash" >&2
	exit 1
}
git diff --check

printf 'ci-check OK\n'
