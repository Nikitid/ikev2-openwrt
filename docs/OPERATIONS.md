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

The supported first-install path for OpenWrt 25.12 is the shared feed
bootstrap:

```sh
wget -O /tmp/nikitid-feed.sh \
  https://raw.githubusercontent.com/Nikitid/openwrt-feed/feed/install.sh
sh /tmp/nikitid-feed.sh luci-app-ikev2-manager
```

It checks the exact OpenWrt release, target and architecture, verifies the
publisher public-key checksum against a pinned value, installs the key under
`/etc/apk/keys/`, writes `/etc/apk/repositories.d/nikitid-openwrt.list`,
retires the superseded per-application list and key, refreshes the indexes and
simulates the transaction before installing or upgrading. Only the packages
named on its command line are touched; it never upgrades unrelated packages and
does not enable VPN, PBR, DNS replacement or firewall rules. It requires working
HTTPS access to GitHub and the official OpenWrt feeds.

Subsequent updates use:

```sh
apk update
apk upgrade luci-app-ikev2-manager
```

### Repository rename and feed move

The project repository was renamed from `ikev2-manager-openwrt` to
`ikev2-openwrt`, and the signed feed then moved out of this repository into
`Nikitid/openwrt-feed`. GitHub keeps serving the previous paths, so existing
installations were never interrupted, but that alias is not a guarantee and
stops working if an old name is reused.

The package postinst therefore moves an installation off the superseded list.
It rewrites `/etc/apk/repositories.d/ikev2-manager.list` to the shared
`nikitid-openwrt.list` when, and only when, it still holds one of this
project's own previous URLs. A list an operator or another project points
elsewhere is left untouched, an existing shared list is never overwritten, and
a missing list is not created. Trusted keys are not touched: the key material
is identical under either file name.

Verify a migrated router with:

```sh
cat /etc/apk/repositories.d/nikitid-openwrt.list
apk update
```

### Never install the package from a file

```sh
apk add /tmp/luci-app-ikev2-manager-1.2.3.apk     # do not do this
```

apk records an identity constraint in `/etc/apk/world` that pins the package to
that exact build. The feed publishes a different build, so the constraint keeps
the router on the file it was given, and it does so silently: `apk update`
succeeds, `apk upgrade luci-app-ikev2-manager` reports nothing to do, and the
router looks healthy while never receiving another fix.

Check for it with:

```sh
grep '><Q' /etc/apk/world
```

A package name followed by `><Q...` is pinned. Running the shared feed
installer with that package name releases the constraint and then upgrades
normally. Install from the feed instead:

```sh
apk update
apk upgrade luci-app-ikev2-manager
```

Always name the package. A bare `apk upgrade` would touch every installed
package on the router, including kernel modules tied to the running kernel.

### Controlled runtime updates

Dependency installation fills missing packages; it deliberately does not
upgrade an already installed runtime. Review runtime updates separately and
test them on a non-office router before promotion. Do not use a bare
`apk upgrade` as part of application maintenance.

On apk firmware, dependency repair pins any missing strongSwan component to the
already installed strongSwan version and refuses a mixed cohort before changing
the package database. opkg cannot express that exact constraint reliably, so an
incomplete pre-existing strongSwan cohort on 24.10 is not repaired
automatically. A missing same-version component is therefore an explicit repair
failure, not permission to advance part of the runtime.

strongSwan is not one independently replaceable binary in OpenWrt. The base
package, `strongswan-charon`, `strongswan-swanctl` and every installed
`strongswan-mod-*` package share one build and must come from the same SDK,
target and version. The OpenWrt 25.12 packages branch currently carries 6.0.3,
while the development packages branch carries 6.0.7. A security backport must
therefore publish and simulate the complete installed strongSwan subset as one
transaction. Installing only `strongswan` can leave charon or its plugins on a
different ABI and is unsupported.

The promotion sequence is: build the matched package subset with the exact
release SDK, verify every package version and signature, simulate the named
transaction, snapshot configuration, install on the test router, restart only
strongSwan, and exercise outbound, inbound and Site Link SAs. Promote the same
artifacts to other routers only after a soak period. Kernel packages are never
mixed across firmware builds.

### Fast repeat APK builds

For a persistent build machine, prepare the SDK once with its normal
`make defconfig` and prerequisite stages. Subsequent package-only builds can
reuse that state:

```sh
OPENWRT_SDK_DIR=/path/to/openwrt-sdk \
OPENWRT_APK_SIGNING_KEY=/path/to/release-private.pem \
OPENWRT_SDK_PREPARED=1 \
./scripts/build-apk.sh
```

This mode validates the SDK configuration and target prerequisite stamp, then
cleans and compiles only `luci-app-ikev2-manager`. Omit
`OPENWRT_SDK_PREPARED` for clean release or CI builds that must run the full SDK
preparation path. Prepared mode checks the exact mediatek/filogic target values
rather than timestamps because registering a feed can touch `.config` without
changing the already-prepared target toolchain.

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

The inbound policy watcher consumes strongSwan `child-updown` events and then
reconciles the complete authenticated-session snapshot into one atomic
nftables transaction. Its 30-second snapshot is a recovery and timeout-refresh
backstop, not the admission path. The generated server configuration replaces
a stale SA when the same device-specific EAP account reconnects; do not reuse
one inbound username on multiple devices.

Healthy outbound routing has:

- an installed `proxy4` CHILD_SA;
- the assigned virtual IPv4 on `ipsec-out`;
- a tunnel default and unreachable fallback in `pbr_ikev2out`;
- PBR, FakeIP and health services running.

The health watcher performs a small data-plane probe through `ipsec-out`.
Probe failures are telemetry only: public check endpoints can fail independently
and never tear down an installed CHILD_SA. Missing SAs are recovered through
the serialized, rate-limited `ensure-client` action; its reconnect cooldown is
configurable under the outbound tunnel settings.

The same page stores an ordered tunnel-DNS DoH list and IPv4 bootstrap
resolvers. The first DoH endpoint is primary. Once per minute the existing
health process verifies its TLS path through `ipsec-out`; after two consecutive
failures it probes the remaining endpoints in order and refreshes sing-box only
after one succeeds. A different healthy bootstrap winner for the same endpoint
updates telemetry without restarting sing-box. A failed check never changes the
IKEv2 SA and never enables a WAN resolver for selected destinations. Reordering
the configured list makes the new first entry primary on the next check.

If strongSwan starts before WAN source-address selection is ready, the watcher
discards only a `proxy-out` IKE_SA that is still `CONNECTING` from a loopback
address and retries after gateway DNS is available. A handshake already using
a real local address is left alone. During shutdown the watcher stops before
the DNS, domain-router, XFRM and network services, with a five-second procd
termination bound, so it cannot recreate dependencies while the router stops.

## Destination updates

```sh
/usr/libexec/ikev2-domains-community apply
/usr/libexec/ikev2-domain-router status
```

Selected services, custom domains and custom IPv4/CIDR entries are rebuilt
atomically. In Reliable mode, a domain-only change hot-reloads the local
sing-box rule-set without restarting DNS or rebuilding PBR. Changes to service
networks or shared interfaces still reload PBR. Per-device overrides use the
independent early nftables table and do not reload PBR. Existing
matching conntrack sessions are removed after a successful update so they
cannot retain an older WAN route.

Prepared services are edited from **Manage services**. This stores a complete
local override; **Restore prepared service** removes only that override after
confirmation. **Add service** creates a separately named domain/CIDR list, so
large definitions do not accumulate in the common custom-domain field. The
editor changes definitions only. Service chips stage policy selection and the
page-level **Save** applies that selection. Definitions live in
`/etc/ikev2-manager/services.d/` and are included in sysupgrade preservation.

Clients must use router DNS for domain routing. Custom IPv4/CIDR entries and
direct-service networks do not depend on DNS.

Managed DNS keeps one cache owner: dnsmasq in Standard mode or sing-box in
Reliable mode. The main and per-segment dnsproxy processes do not use
optimistic caches. In Reliable mode sing-box connects directly to each segment
worker; Standard mode lets dnsmasq select the same worker directly. Enabled
destination segments are probed once per minute at both the worker listener and
the complete client-facing path;

**Use WAN-provided DNS** adds the IPv4 resolvers currently published by netifd
for the configured WAN as dnsproxy fallbacks. It is deliberately off by
default because fallback queries are unencrypted. Lease changes update only
the resolver workers and retain the previous validated group while WAN DNS is
temporarily absent. This fallback is not available to tunnel-selected domains.

Applying a resolver now fails if the fallback group cannot answer. The check
runs the configured fallback endpoints by themselves and requires one
successful query, because the ordinary health query is served by the primary
group and therefore proves nothing about the recovery path. When an apply is
rejected for this reason, the previous configuration is untouched: correct the
fallback endpoints, or empty the group if no recovery path is wanted, and apply
again. `dns-get` reports `fallback_verified` with the time of the last
successful proof, and `timeout_effective` beside the stored `timeout`, which is
bounded by sing-box's own deadline and is commonly lower than the stored value.

Both resolver groups accept mixed transports. Filtering is applied per protocol
per provider, so a primary group combining, for example, DoH and DoQ to
different providers keeps resolving where a single-protocol group stops. A
bootstrap entry may also be a DoH, DoT or DoQ endpoint whose authority is a
literal IPv4 address, which removes the ladder's dependence on plaintext
UDP/53.

Ordinary names are resolved over WAN, where per-protocol DNS filtering is
applied. To send them through the tunnel-bound resolver instead:

```sh
/usr/libexec/ikev2-domain-router tunnel-resolve 1
```

This is deliberately not a default. It removes the WAN exposure but couples
every lookup to tunnel health: while the tunnel is down, no name resolves at
all, for every client. The command refuses to engage without an enabled
outbound client, validates the refreshed runtime and restores the previous
setting when it cannot resolve. `dns-get` reports the current value as
`tunnel_resolve`.

A destination segment with an empty fallback field inherits the global fallback
group and then the global primary group. The segment editor shows that
effective list, because an empty field is the widest inheritance rather than
none - with **Use WAN-provided DNS** enabled it includes the provider's
plaintext resolver. Set an explicit segment fallback to stop inheriting.

inspect their state without changing configuration with:

```sh
/usr/libexec/ikev2-manager-system dns-segments-check
/usr/libexec/ikev2-manager-system dns-get
/usr/libexec/ikev2-manager-system dns-buffer-status
```

`dns-buffer-status` is read-only. It reports the total malformed UDP/53
counter, one expiring counter per source IPv4 address and the number of current
`dns: buffer size too small` messages in the system-log ring. If both counts
grow together, a listed client is sending datagrams too short to contain a DNS
header. If only the sing-box count grows, inspect local/TCP/alternate DNS paths;
the client guard is not the source. The diagnostic stores neither payloads nor
queried domain names.

Ordinary DoH is the default because TCP/443 remains usable on more access
networks. DoQ is standardized by [RFC 9250](https://www.rfc-editor.org/rfc/rfc9250)
and forced HTTP/3 is available for providers that document it, but both depend
on outbound UDP and are advanced choices rather than automatic upgrades. The
provider presets use published Cloudflare, Google, AdGuard, Control D, Mullvad,
Quad9 and Yandex endpoints. DDR/DNR are client resolver-discovery mechanisms,
not another upstream transport, and ODoH is not exposed because the packaged
dnsproxy runtime does not implement it.

`segment_health=degraded` names failed segment identifiers in
`segment_failures`. The status file `/var/run/ikev2-dns-segments.status`
separates `direct_failure_ids` from `path_failure_ids`. A package upgrade
re-applies an already-managed resolver only when the packaged runtime schema
changes. LuCI-only releases therefore do not interrupt DNS. A schema migration
uses the same transactional path, so a failed cutover restores the previous
runtime.

OpenWrt 25.12 currently ships sing-box 1.13.18. Reliable mode should use
1.13.19 or later because 1.13.19 fixes the upstream asynchronous FakeIP
metadata-save race. Build the unmodified upstream update with the same exact
SDK and publisher key used for the application:

```sh
OPENWRT_SDK_DIR=/path/to/openwrt-sdk \
OPENWRT_APK_SIGNING_KEY=/path/to/release-private.pem \
./scripts/build-sing-box-update.sh
```

The builder verifies a pinned official OpenWrt 1.13.x recipe and the upstream
source archive hash, then produces `sing-box-1.13.19-r2.apk` under
`dist/compat`. Without `OPENWRT_APK_SIGNING_KEY` it deliberately produces an
unsigned developer artifact for local testing; feed artifacts must be signed.
When the SDK has no Go host compiler, the builder downloads
the pinned official Go 1.24.13 bootstrap archive and verifies its SHA-256 before
use; `OPENWRT_GO_BOOTSTRAP_DIR` may point to the same exact toolchain locally.

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

When the VPN server is selected under Protected networks and plain-DNS
enforcement is enabled, TCP/UDP port 53 from `ipsec-in` is redirected to the
router resolver. DNS-over-TLS still requires the separate block option, and
endpoint-managed DoH or private-relay features must be disabled or controlled
on the client.

The DNS passthrough flag is independent of a device's route. It excludes the
source from both the port 53 redirect and the managed DoT rejection. It does
not assign a resolver to that device: DHCP, the operating system or the
application must already point it at the intended external DNS service. The DPI
passthrough flag uses the active integration mark published by Zapret1 or an
enabled Zapret2 before its queue hook. With Zapret2 the app stores that mark in
conntrack and restores it on replies before Zapret2's pre-NAT hook, so the
device is bypassed in both directions without changing any Zapret strategy. The
Unmanaged preset combines direct WAN with both flags; the runtime refuses to
install it if neither integration mark can be validated.

The VPN Users page can generate Apple mobileconfig, Android details and a
separate Windows VPNv2 XML for each user. Apple and Android output contains the
current password and must be deleted after use. The Windows XML contains a
catch-all NRPT rule for the VPN resolver but no password and is also suitable
for MDM. Download the reusable `Nikitid-IKEv2-Setup.exe` once from the top of
the page, select any downloaded XML in it and choose Install. It requests UAC
and provisions the selected VPNv2 CSP profile directly through the built-in
WMI Bridge; it doesn't run PowerShell or retain a scheduled task or service. The same UI
can edit the connection name, update or remove the profile, and detailed
failures are written under the user's local application-data directory. The
server domain is used as the default connection name. Plain double-click
installation of CSP XML itself is not supported by Windows.

For an intermittent inbound failure, start the 60-second capture on the VPN
Users page and attempt the connection during that window. It subscribes to the
strongSwan VICI log, writes at most 512 KiB to
`/tmp/ikev2-inbound-diagnostic.log`, stops automatically and does not increase
system-log verbosity. Recognised failures are shown by identity and IKE phase.

Reliable-mode logging normally stays at `warn`. The domain-policy page can run
a separate 60-second FakeIP debug capture; the detached action restores the
selected normal level after its timer or an interruption. Raising and restoring
that level restarts the FakeIP resolver, so the page presents it as a diagnostic
action rather than a harmless log viewer.

Policy allow entries have a timeout and are refreshed by a dedicated session
watcher. Deleting a user or losing the identity-to-address mapping therefore
fails closed. The watcher checks the active-SA signature every two seconds and
also performs a full refresh every 30 seconds. The 90-second timeout is only a
backstop for a stalled watcher; an isolated VICI read failure preserves the
last valid table until the next successful read.

An address claimed by two identities at the same time — a stale SA still
holding an address the pool has already reissued — is denied rather than
granted the union of both policies. Custom inbound profiles do not use the
managed per-user policy.

## Status Overview widget

The package installs `06_ikev2-manager.js` in the LuCI Status Overview include
directory, before the standard system widgets that start at `10`. Its three
summary blocks cover the outbound tunnel, policy routing and inbound server.
They report live outbound SA state, PBR/domain-routing and fail-closed state,
policy and excluded-device counts, excluded traffic, inbound-server readiness
and the active inbound-session count.
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
timeout does not cancel an already running router-side worker. Periodic health
work yields to this lock; a domain-router operation already in flight is given
a bounded interval to finish before the foreground transaction reports a real
lock conflict.

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
lists and caches. If an applied Site Link exit role still consumes the inbound
certificate, its certificate, private key, chain and ACME renewal section are
retained. An applied Site Link source likewise retains the nftset-capable DNS
provider and global PBR contract. External certificate source files and
unrelated ACME accounts are never deleted because ownership cannot be proven
safely.

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
