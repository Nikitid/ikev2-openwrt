# Architecture

## Traffic paths

```text
Selected domain
client -> dnsmasq -> sing-box FakeIP -> nftables TProxy
       -> source policy -> PBR mark -> ipsec-out -> IKEv2 gateway

Selected IPv4/CIDR
client -> PBR destination rule -> ipsec-out -> IKEv2 gateway

Ordinary destination
client -> normal OpenWrt routing -> WAN
```

Selected domain suffixes receive persistent addresses from `198.18.0.0/15`.
Only that range is intercepted by TProxy. sing-box checks the original source
network and binds its outbound connection to `ipsec-out`.

Direct-IP service networks and administrator-defined IPv4/CIDR entries use a
separate PBR destination policy. Both paths share the same covered networks,
device exclusions and fail-closed routing table.

When Discord is selected, its UDP voice IP-discovery packet is classified
before routing. The exact destination IPv4 address and UDP port are retained in
a timeout-backed nftables set and marked for the same fail-closed PBR table.
This covers literal media endpoints without static Discord or Cloudflare
address ranges and without routing unrelated traffic hosted by Cloudflare.

Full route and Exclude device overrides are persisted only in application-owned
`device_policy` sections and compiled into the `inet ikev2_device_policy`
nftables table. Its prerouting hook runs immediately before PBR and sets the
active WAN or `pbr_ikev2out` mark. PBR retains ownership of routing tables and
the fail-closed default, but no duplicate per-device PBR policies enlarge a
global rebuild. A single device change does not require a service, DNS, XFRM or
tunnel restart.

## Fail-closed boundary

PBR table `pbr_ikev2out` always contains an unreachable default. A lower-metric
default through `ipsec-out` exists only while the outbound CHILD_SA and virtual
IPv4 are usable.

When the tunnel route disappears, marked traffic terminates at the unreachable
route and cannot fall through to the WAN table. A stale route without a
matching SA is additionally rejected by the kernel XFRM policy.

```text
ipsec-out  if_id 42  outbound client
ipsec-in   if_id 43  inbound server
```

strongSwan does not install routes into the main table. The runtime owns the
XFRM interfaces, synchronizes virtual addresses and lets PBR own route
selection.

Shutdown removes live PBR and firewall references before bringing XFRM links
down. Runtime and package cleanup do not require `ip link del`: deleting an
XFRM link can block in kernel D-state on the validated OpenWrt 25 kernel. Down
links cannot forward and are discarded when the module unloads or the router
reboots.

## DNS

`dnsmasq-full` remains the resolver for LAN and inbound VPN clients:

```text
client -> dnsmasq-full -> sing-box DNS -> dnsproxy or existing resolver
```

When plain-DNS enforcement is enabled, TCP/UDP port 53 from every protected
local zone is redirected to dnsmasq. If the inbound VPN server is selected as a
protected network, the same redirect is installed for `ipsec-in`; a client
cannot obtain a real address from an external plain-DNS resolver and bypass
FakeIP domain routing.

Reliable mode disables the dnsmasq cache and stores FakeIP mappings in
`/etc/ikev2-manager/domain-router-cache.db`. Existing mappings therefore
survive service restarts and boots. Only `A` queries for selected domains enter
the FakeIP transport. Their `AAAA` and HTTPS queries receive a successful empty
answer, so clients fall back to the routed IPv4 address instead of receiving a
real IPv6 address or HTTPS address hint that could bypass the IPv4-only
outbound tunnel. Every DNS record type for ordinary domains and non-address
record types for selected domains continue to the normal upstream.

Managed DNS is optional. `dnsproxy` supports UDP, TCP, DoT, DoH, HTTP/3, DoQ
and DNSCrypt. Multiple primary resolvers can use load balancing, parallel
queries or fastest-address selection. Bootstrap and fallback resolvers are
managed independently. Standard DoH over TCP/443 is the default because it
crosses the broadest range of access networks; DoQ and forced HTTP/3 are
advanced UDP transports. Resolver changes are validated and rolled back on
failure.

Both the primary and the fallback group may mix transports. Filtering is
applied per protocol per provider rather than to a provider as a whole, so a
group that combines DoH, DoQ and DNSCrypt keeps working where a group built on
one protocol does not. The protocol setting selects the interface preset and
the HTTP/3 flag; each endpoint is validated against the transport its own
scheme names.

A bootstrap entry may be an `IPv4:port` resolver or a DoH, DoT or DoQ endpoint
whose authority is a literal IPv4 address. Only literal authorities qualify,
because a bootstrap entry must not need a resolver of its own. Without this the
whole ladder rests on plaintext UDP/53: when those datagrams are dropped, no
group can resolve its own endpoint names and every tier fails together.

The fallback group is proven before it is committed to. Its endpoints are run
by a short-lived `dnsproxy` bound to an application-owned loopback address, and
one query must succeed. The ordinary health query cannot establish this,
because the primary group answers it — a fallback that has been unreachable for
months otherwise reports healthy until the exact moment it is needed. The time
of the last successful proof is reported beside the configuration, as is the
effective resolver timeout, which is bounded by sing-box's own deadline and can
therefore be lower than the stored value.

An optional WAN-provider fallback appends the IPv4 resolvers published by
netifd for the configured WAN interface to dnsproxy's fallback group. It is an
explicit plaintext downgrade and is never used for tunnel-selected
destinations. DHCP/PPPoE updates reconcile only dnsproxy and destination
segment workers; an empty transitional netifd result keeps the last validated
group, and a failed refresh restores the previous resolver state.

DNS-segment health checks probe one representative suffix through both the
segment listener and the normal dnsmasq path. All suffixes in a segment share
those components, so diagnostic work stays bounded. Inbound session policy is
maintained by a separate event watcher and cannot be delayed by DNS or tunnel
probes.

Destination resolution follows the selected traffic path. The direct outbound
uses the ordinary WAN upstream. The IKEv2 outbound uses an in-process DoH
resolver bound to `ipsec-out`, so the address returned for a selected service
comes from the same network geography as its connection. Its bootstrap DNS is
also bound to `ipsec-out` and does not change global client DNS behavior. The
configured DoH servers are ordered. The existing health loop probes the active
server once per minute and switches only after two consecutive failures and a
successful tunnel-bound TLS probe of the next server. Before the disruptive
sing-box refresh it also proves unrelated HTTPS data-plane traffic through
`ipsec-out`. A ten-minute return dampener requires four failures before
switching back to the previous endpoint, preventing transient path degradation
from repeatedly restarting active proxied connections. The selected request
remains fail-closed while no configured resolver is healthy; no WAN resolver is
used as a recovery path. The active choice is runtime state, while the ordered
list remains UCI configuration, so reboot and manual reordering return to the
administrator's primary server.

Destination DNS segments are explicit, locally maintained suffix lists. Each
enabled segment runs an application-owned loopback dnsproxy instance with its
own protocol and selection mode. In Standard mode dnsmasq selects the worker
with its domain-specific server syntax. In Reliable mode sing-box routes the
suffix directly to the segment worker, avoiding a second dnsproxy deadline
around its primary and fallback attempts. The global upstream remains the
default for every other name. Segment state lives in `dns_segment` UCI sections
and is therefore independent of generated PBR and FakeIP rule files. Each
segment has an optional fallback group; when it is empty, it inherits both the
global fallback and the global primary group.
Enabled segments must have disjoint suffix trees and are limited to eight
concurrent dnsproxy instances to bound router resource use. Segment workers run
as the unprivileged `dnsproxy` account. They do not add another cache: dnsmasq
owns it in Standard mode and sing-box owns it in Reliable mode.
Browser compatibility is enabled per segment by default. In Reliable mode it
returns a successful empty HTTPS resource-record response for the segment
suffixes, allowing Chromium-family clients to fall back to ordinary A/AAAA
resolution when an authoritative server mishandles HTTPS queries. It does not
alter A/AAAA answers, the selected segment upstreams or DNS behavior outside
those suffixes, and is inactive while managed DNS is disabled.

Each segment gives its primary group three seconds and, when necessary, its
fallback group another three seconds. The main resolver is bounded to eight
seconds without fallback and four seconds per group with fallback. These
budgets leave time inside sing-box's ten-second DNS deadline instead of letting
an inner resolver begin recovery after the outer request has already expired.
Reliable mode uses an explicit 8192-entry DNS cache; persistent FakeIP mappings
remain stored separately in the application cache database.

The main dnsproxy and segment workers keep caching disabled to avoid retaining
and amplifying transient upstream `SERVFAIL` responses through multiple cache
layers. Applying the primary resolver restarts its process. The operation is
transactional and validates both the global path and every enabled destination
segment after cutover, but it is not a zero-downtime resolver handoff; LuCI
warns about the brief interruption before the action is started.

The DNS-enforcement hook discards UDP/53 datagrams whose payload is shorter
than the 12-byte DNS header before redirecting them to sing-box. Such datagrams
cannot contain a complete DNS header and are one known source of
`dns: buffer size too small` noise. The owned nftables rule has a counter so
their rate remains observable without logging every packet. A dynamic set keeps
only the source IPv4 address and packet/byte counters for at most 256 sources;
entries expire after one hour and no DNS payload or queried name is retained.
If the sing-box error count grows while this counter is stable, the packet did
not arrive through the protected client UDP/53 path and the remaining local,
TCP or alternate-listener source must be investigated separately.

Before the first managed-DNS change, the runtime records the existing
`dnsproxy`, `dnsmasq` and service state. Reliable mode temporarily points
dnsmasq at `127.0.0.42`; that application-owned endpoint is never accepted as
an original upstream. Legacy snapshots containing it are repaired only from a
saved pre-FakeIP upstream or an already-running saved loopback dnsproxy.

Reliable mode requires sing-box 1.13.19 or later. Version 1.13.19 fixes the
upstream asynchronous FakeIP metadata-save race that could remove allocator
metadata across process restarts while cached client addresses were still in
use. The project builds the unmodified upstream release from a pinned official
OpenWrt package recipe until that version reaches the target release feed.

## Destination lifecycle

The active policy is built from:

- selected service domain lists;
- selected service IPv4/CIDR lists;
- `/etc/pbr-ikev2-domains.manual.txt`;
- `/etc/pbr-ikev2-addresses.manual.txt`.

Every input is normalized in a temporary directory. Service downloads are
size-limited, validated and cached. Downloaded service-network lists may contain
only bounded public prefixes and are capped per service, so an upstream list
cannot silently turn one selection into a cloud-wide or default route. Bundled
and administrator-entered CIDRs remain trusted inputs. Bare custom IPv4
addresses become `/32`. The active domain and CIDR files are replaced only
after the complete build succeeds.

Optional external lists come from `itdoginfo/allow-domains` at runtime. They
are not redistributed by this project. Packaged `.lst` and `.cidrs` files are
project-maintained and covered by the project license. Remote domain revisions
containing a single-label public suffix are rejected as a unit; a cached,
previously validated revision remains eligible.

Prepared service identifiers come from the package-owned catalog. A packaged
definition has priority over its optional provider list. Editing a prepared
service creates a complete local override in
`/etc/ikev2-manager/services.d/`; it is never merged with later provider
changes. User-created services use the same directory and remain distinct from
the common manual domain list. Definition changes preserve the independently
staged service selection; deleting a custom service also removes it from that
selection. Saving, resetting or deleting a definition rebuilds the active
policy under one lock. If validation or the routing restart fails, both the
service definition and selection are restored.

## Ownership and recovery

The inbound user-policy nftables table is also an early boot guard. It is
installed before strongSwan can accept inbound clients, initially with empty
session sets. A dedicated watcher subscribes to strongSwan's VICI
`child-updown` events and immediately performs the same complete, validated,
atomic reconciliation used by manual policy changes. Events are triggers, not
an authorization source: the reconciliation reads the current EAP identities
and virtual addresses back from strongSwan. A periodic full snapshot refreshes
timeout-backed entries and recovers from a lost event. During
managed shutdown it remains installed until broad fw4 forwarding has been
removed and the XFRM interfaces are down. This prevents a boot or teardown
window in which per-user access limits are absent.

Persistent settings live in `/etc/config/ikev2-manager`. Generated UCI sections
use the `ikev2pbr_` prefix. Disabling managed mode removes generated network,
firewall and PBR state while preserving user settings, certificates and
destination lists.

Per-device intent is stored in application-owned `device_policy` sections.
The earlier prerouting table applies direct/full-route marks and the validated
Zapret bypass mark; legacy generated PBR sections are removed after migration.
The same owned,
atomically replaced nftables table redirects plain DNS, rejects outbound DoT
and holds the shared per-device DNS-bypass set; it does not encode a list in a
scalar firewall redirect option. Explicit routing rules carry counters per
address. The Unmanaged preset is only a convenience that
sets direct routing, DNS passthrough and DPI passthrough; the three settings
remain independently editable.

Router-originated domain routing is disabled by default. When enabled in
Reliable mode, only connections to the reserved FakeIP range enter the output
TProxy path. The IKE transport endpoint and local management addresses are real
addresses, so they cannot match that range or loop through the tunnel. The
output hook uses a distinct mark and TProxy inbound that always selects the
IKEv2 outbound. Keeping router traffic on its own inbound avoids dependence on
the router's changing WAN address and does not expand the protected client
source networks.

The health service checks:

- outbound CHILD_SA data-plane reachability;
- virtual IP and fail-closed routes;
- sing-box, dnsmasq, TProxy and policy-rule invariants;
- every enabled destination DNS segment, with per-segment degraded status;
- the direct-service CIDR PBR rule;
- inbound server configuration drift.

Repairs are serialized and avoid restarting WAN or the router. The health loop
never starts a global PBR rebuild: missing PBR state is reported as degraded
until an explicit Apply. PBR set snapshots and destination-segment probes run
once per minute. Inbound identity policy has its own VICI watcher and periodic
reconciliation backstop. The loop yields while a configuration transaction
owns the global action lock. A bounded local domain-router lock then closes the
remaining check-to-lock race without concealing a stuck runtime operation.
The watcher accepts no command-line operations, and a stale-safe PID lock
permits exactly one loop even when it is invoked outside procd. Orderly shutdown
persists the warm PBR sets before releasing that lock.

All mutating LuCI actions use detached workers with per-action status files and
a shared router-action lock. A second action fails promptly instead of queuing
for minutes. UI pages poll the action ID and reload the affected model data in
place after completion.

Dependency installation records the package baseline, DNS provider and every
package added by the transaction. A full dependency reset removes only that
owned set. Package-manager solver dependencies used by other applications are
retained. An applied Site Link role is also an explicit shared consumer: its
PBR, XFRM, strongSwan and certificate/DNS contract survives a Manager reset.
Only Site Link's applied snapshot grants that ownership; an unsaved or failed
candidate does not. Package removal itself has a narrower lifecycle contract
and preserves user configuration.

## Inbound server

The optional inbound server uses certificate authentication for the router and
EAP-MSCHAPv2 for users. Traffic selectors decide what clients send into IKEv2;
firewall permissions independently allow Internet, selected local zones and
router services.

Server access settings are defaults. A managed user can inherit them or
override router access, Internet forwarding and local-network access. Limited
local access accepts IPv4 addresses and CIDR networks. Per-user TCP/UDP router
ports remain available even when general router access is denied. Firewall4
opens only the union of configured ports from the inbound zone; the app-owned
identity-to-address rules narrow that union for each active user. A PBR
exclusion marks that user's Internet traffic for the normal WAN after the
shared classifiers. In FakeIP mode a separate TProxy inbound resolves the
existing FakeIP mapping through the direct outbound. The override does not
weaken the fail-closed route used by other clients.

The runtime maps the authenticated EAP identity from the active IKE SA to its
current virtual IPv4 address. One identity reported by several SAs collapses to
a single mapping; one address reported for several identities is dropped, so a
stale SA cannot lend its policy to the account that now holds that address. Until that mapping exists, the whole inbound pool
is denied except for DNS on the router. Dynamic allow entries expire unless the
health watcher refreshes them, so a disconnected address cannot retain another
user's policy when the pool reuses it. Traffic between client addresses in the
inbound pool remains isolated. The underlying firewall opens only the union
required by global defaults and explicit user overrides; the app-owned nftables
table then narrows access per virtual address.

Raw strongSwan profile overrides are validated, installed atomically and rolled
back when loading fails. Per-user policies remain stored but are not enforced
while a custom inbound profile is active. Credentials remain managed
separately.

The LuCI Status Overview include combines the lightweight, read-only
`ikev2-manager widget-status` summary with `swanmon list-sas`. It reports
outbound SA state, accumulated `ipsec-out` interface traffic, PBR/domain-routing
and fail-closed state, inbound-server readiness and active inbound sessions.
Detailed client rows are rendered only for established inbound SAs that have an
installed CHILD_SA, so configured but offline users and incomplete handshakes
do not consume dashboard space. The widget does not mutate runtime state.
