# Operations

## CLI installation and upgrade

The preferred installation path is LuCI package upload. For CLI installation
with dependency preparation:

```sh
scp -O dist/luci-app-ikev2-manager_*_all.ipk root@router:/tmp/
scp -O scripts/install.sh root@router:/tmp/
ssh root@router
chmod +x /tmp/install.sh
/tmp/install.sh /tmp/luci-app-ikev2-manager_*_all.ipk
```

Upgrade an existing public package with:

```sh
opkg install /tmp/luci-app-ikev2-manager_*_all.ipk
```

Configuration, users, custom destinations, cached service lists and
certificates are preserved.

### OpenWrt 25.12 signed feed

The supported first-install path for OpenWrt 25.12 is:

```sh
wget -O /tmp/install-ikev2-manager.sh \
  https://github.com/Nikitid/ikev2-openwrt/releases/latest/download/install-openwrt25.sh
sh /tmp/install-ikev2-manager.sh
```

This installs the project public key and signed stable feed before adding or
upgrading the package.
It requires working HTTPS access to GitHub Releases and the official OpenWrt
feeds. It does not enable VPN, PBR, DNS replacement or firewall rules.
When migrating a package previously installed from a local APK, it removes only
the application's identity-hash constraint before the scoped upgrade; other
packages are not upgraded.

Subsequent updates use:

```sh
apk update
apk upgrade luci-app-ikev2-manager
```

### Repository rename

The project repository was renamed from `ikev2-manager-openwrt` to
`ikev2-openwrt`. GitHub keeps serving the previous paths, so existing
installations are not interrupted: `raw.githubusercontent.com` returns the
signed index under the old name directly, and release downloads redirect. That
alias is not a guarantee and stops working if the old name is ever reused, so
installations are moved off it rather than left to depend on it.

The package postinst rewrites `/etc/apk/repositories.d/ikev2-manager.list` when,
and only when, it still contains exactly the previous project URL. A list an
operator or another project points elsewhere is left untouched, and a missing
list is not created. Re-running `install-openwrt25.sh` performs the same
migration.

Verify a migrated router with:

```sh
cat /etc/apk/repositories.d/ikev2-manager.list
apk update
```

## Diagnostics

```sh
/usr/libexec/ikev2-manager-system doctor
/usr/libexec/ikev2-manager overview
/usr/libexec/ikev2-manager-system failclosed-check
/usr/libexec/ikev2-domain-router status
/usr/libexec/ikev2-user-policy check
/etc/init.d/pbr status
swanctl --list-sas
```

Healthy outbound routing has:

- an installed `proxy4` CHILD_SA;
- the assigned virtual IPv4 on `ipsec-out`;
- a tunnel default and unreachable fallback in `pbr_ikev2out`;
- PBR, FakeIP and health services running.

The health watcher performs a small data-plane probe through `ipsec-out`. Two
failed probe cycles trigger the serialized reconnect action. The reconnect
cooldown is configurable under the outbound tunnel settings.

## Destination updates

```sh
/usr/libexec/ikev2-domains-community apply
/usr/libexec/ikev2-domain-router status
```

Selected services, custom domains and custom IPv4/CIDR entries are rebuilt
atomically. Existing matching conntrack sessions are removed after a successful
update so they cannot retain an older WAN route.

Clients must use router DNS for domain routing. Custom IPv4/CIDR entries and
direct-service networks do not depend on DNS.

For the selected Discord service, literal UDP voice endpoints are learned from
Discord's IP-discovery packet and routed as exact IPv4-address/port pairs. The
runtime set is rebuilt automatically after a policy or firewall restart:

```sh
/usr/libexec/ikev2-discord-voice status
nft list set inet ikev2_discord_voice voice_endpoints
```

Full route and Exclude rules are applied atomically and can be checked without
restarting PBR:

```sh
/usr/libexec/ikev2-device-routing check
nft list table inet ikev2_device_policy
```

The LuCI picker lists active local IPv4 neighbours and enriches them with DHCP
names. Use Custom for a sleeping client, a static address or a subnet.

## Inbound user access

Inbound Server access settings are global defaults. The VPN Users page can
override each managed EAP user:

- router access: inherit, allow or deny;
- additional TCP/UDP router ports or ranges that remain reachable while router
  access is denied;
- Internet access: inherit, allow or deny;
- local access: inherit, all configured local zones, selected IPv4/CIDR
  destinations or deny;
- PBR: inherit the project domain policy or use direct WAN.

DNS on the router remains reachable for authenticated inbound clients even
when router access is denied. An additional router-port allowlist can expose a
specific same-router public service, for example TCP/UDP 1443, without allowing
other router services. Other traffic is denied until the active EAP identity is
associated with its current virtual address. Inspect the runtime without
changing it:

```sh
/usr/libexec/ikev2-user-policy check
nft list table inet ikev2_user_policy
```

Policy allow entries have a timeout and are refreshed by the health watcher.
Deleting a user or losing the identity-to-address mapping therefore fails
closed. The timeout is only a backstop for a stalled watcher: the watcher
rewrites the table about every 15 seconds and drops addresses whose SA is gone,
so it is set well above the slowest watcher cycle. An entry that expires while
the watcher is merely slow would disconnect every active client at once.

An address claimed by two identities at the same time — a stale SA still
holding an address the pool has already reissued — is denied rather than
granted the union of both policies. Custom inbound profiles do not use the
managed per-user policy.

## Status Overview widget

The package installs `06_ikev2-manager.js` in the LuCI Status Overview include
directory, before the standard system widgets that start at `10`. Its three
summary blocks cover the outbound tunnel, policy routing and inbound server.
They report live outbound SA state, PBR/domain-routing and fail-closed state,
policy counts, inbound-server readiness and the active inbound-session count.
The outbound traffic counters are the accumulated `ipsec-out` interface RX/TX
totals and survive CHILD_SA rekeys; they reset when the interface is recreated.

Detailed inbound rows are rendered only for established `ikev2-in` sessions
with an installed CHILD_SA. Each row contains the EAP identity, assigned VPN
address, current connection duration and traffic counters from the client's
perspective. Offline accounts and incomplete IKE handshakes are omitted.
`ikev2-manager widget-status` supplies the inexpensive read-only project
summary; `swanmon list-sas` supplies live SA state.

Overview discovers widget files automatically and sorts them lexicographically,
so the numeric filename prefix controls the router-wide order. The page's
Show/Hide control stores visibility in browser local storage for the current
browser profile; it does not change UCI or package configuration. This LuCI
page does not provide drag-and-drop reordering.

## Background actions

Long LuCI operations continue in serialized workers:

```sh
/usr/libexec/ikev2-manager action-status
/usr/libexec/ikev2-manager-system action-status
/usr/libexec/ikev2-manager-system deps-status
```

Logs:

```text
/tmp/ikev2-manager-action.log
/tmp/ikev2-system-action.log
/tmp/ikev2-domains-community.log
/tmp/ikev2-domains-pbr-restart.log
```

Each worker publishes an action ID, state, update time and current phase. The
terminal states are `ok` and `error`. LuCI polls the worker and refreshes the
affected counters, lists and runtime state without a page reload.

Router-changing actions share one lock. A competing action is rejected after a
short wait instead of remaining queued behind an unknown operation. A browser
timeout does not cancel an already running router-side worker.

Observed times on the validated `mediatek/filogic` router are approximately
1 second for an unchanged managed setup, 2 seconds for an unchanged policy,
5-7 seconds for Reliable-mode or managed-mode disable, 12 seconds for a policy
restart or full dependency reset, 17-27 seconds for a full managed enable and
31 seconds for dependency installation with current package indexes. Feed
refreshes, downloads and ACME issuance can take longer. Treat an unchanged
phase for more than two minutes as a fault and inspect the status, logs and
process state before retrying the action.

Policy-list rebuild phases are preparation, optional service-list download,
combined-list generation and PBR restart. The PBR restart is normally the
longest phase and can take tens of seconds. Saving an unchanged managed setup
or unchanged policy list returns after a live health check instead of restarting
PBR; a failed health check automatically falls back to the full apply path.

## UPnP and dynamic DNS

`miniupnpd-nftables` can coexist with the manager because it uses dedicated
firewall4 chains. When the inbound server is enabled, UPnP permission rules
must reserve UDP 500 and 4500 before any broad allow range. The dependency
doctor warns when either port remains available to UPnP and reports an active
mapping on either port as a conflict. Reserve ports owned by adjacent services,
such as an MTProto redirect, in the same way.

A dynamic-DNS hostname must publish the router's direct public address; an
HTTP-only proxy cannot carry IKEv2. Keep the inbound certificate identity equal
to that hostname. DNS-01 ACME avoids sharing TCP 80 with router web services or
other port-forwarding features.

## Certificates

Inspect the active inbound certificate:

```sh
openssl x509 -in /etc/swanctl/x509/ikev2.pem \
  -noout -subject -issuer -dates -fingerprint -sha256
```

The ACME hotplug hook reloads renewed credentials automatically. Certificate
identity must match the public DNS name used by clients.

## Backup and recovery

```sh
sysupgrade -b /tmp/ikev2-manager-backup.tar.gz
gzip -t /tmp/ikev2-manager-backup.tar.gz
```

Backups contain reversible VPN credentials and private keys. Store them as
secrets and never attach them to public issues.

Recovery sequence:

1. disable managed mode in Overview;
2. confirm ordinary WAN access;
3. run the dependency doctor;
4. re-enable managed mode and the outbound client;
5. verify one selected and one ordinary destination;
6. enable the inbound server only after certificate validation.

## Dependency reset and package removal

The Overview action that removes runtime dependencies is a full application
reset. It first restores the DNS/DHCP state captured before dependency
installation, disables managed routing, then asks the package manager to remove
only packages recorded as application-owned. Packages that another installed
application still requires are retained and reported as shared.

After a successful package transaction, the reset restores the packaged
default configuration and removes application users, submitted client secrets,
generated strongSwan profiles, copied certificate material, generated policy
lists, caches and the application's ACME section. External certificate source
files and unrelated ACME accounts are not deleted because ownership cannot be
proven safely.

Original DNS restoration is validated before any package is removed. A legacy
snapshot containing the application FakeIP resolver `127.0.0.42` is repaired
only from the domain router's saved upstream or from the saved configuration of
a dnsproxy service that was already running before management began. If neither
source is available, the reset stops and keeps the working managed DNS state.

XFRM interfaces are brought down after live PBR, firewall and strongSwan
references are removed. They are not forcibly deleted during a live cleanup:
on affected OpenWrt 25 kernels, `ip link del` can block in kernel D-state. A
down interface has no forwarding path and disappears when its package/module
is unloaded or at the next reboot.

Removing the package disables managed mode first and removes generated runtime
state, including rendered strongSwan profiles and copied certificate material.
Package-owned files are removed by the active package manager. User
configuration, credentials, source certificates, custom destination lists,
cached service lists and sysupgrade backups are preserved. This is intentionally
different from the full dependency-reset action. If managed mode is still
enabled and cleanup cannot run, package removal stops before files are changed.

OpenWrt 24.10:

```sh
opkg remove luci-app-ikev2-manager
```

OpenWrt 25.12:

```sh
apk del luci-app-ikev2-manager
```
