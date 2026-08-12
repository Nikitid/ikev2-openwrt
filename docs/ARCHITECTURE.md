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

Full route and Exclude device overrides are persisted as PBR policies and also
compiled into the app-owned `inet ikev2_device_policy` nftables table. Its
prerouting hook runs immediately before PBR and sets the active WAN or
`pbr_ikev2out` mark. PBR therefore keeps ownership of routing tables and the
fail-closed default, while a single device change does not require a service,
DNS, XFRM or tunnel restart.

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
survive service restarts and boots. Only `A` and `AAAA` queries for selected
domains enter the FakeIP transport. HTTPS address hints are rejected only for
those selected domains, while every DNS record type for ordinary domains and
non-address record types for selected domains continue to the normal upstream.
This keeps service discovery and modern DNS records outside FakeIP without
allowing a selected destination to bypass exact domain routing.

Managed DNS is optional. `dnsproxy` supports UDP, TCP, DoT, DoH, HTTP/3, DoQ
and DNSCrypt. Multiple primary resolvers can use load balancing, parallel
queries or fastest-address selection. Bootstrap and fallback resolvers are
managed independently. Standard DoH is the default; HTTP/3 and DoQ remain
experimental. Resolver changes are validated and rolled back on failure.

Destination DNS segments are explicit, locally maintained suffix lists. Each
enabled segment runs an application-owned loopback dnsproxy instance with its
own protocol and selection mode. The primary dnsproxy uses domain-specific
upstream syntax to forward only that segment to the loopback instance; its
global upstream remains the default for every other name. Segment state lives
in `dns_segment` UCI sections and is therefore independent of generated PBR and
FakeIP rule files. Enabled segments must have disjoint suffix lists and are
limited to eight concurrent dnsproxy instances to bound router resource use.
Browser compatibility is enabled per segment by default. In Reliable mode it
rejects only HTTPS resource-record queries for the segment suffixes, allowing
Chromium-family clients to fall back to ordinary A/AAAA resolution when an
authoritative server mishandles HTTPS queries. It does not alter A/AAAA answers,
the selected segment upstreams or DNS behavior outside those suffixes.

Applying the primary resolver still restarts its process and clears its
in-memory optimistic cache. The operation is transactional and validates DNS
after cutover, but it is not a zero-downtime cache handoff; LuCI warns about the
brief interruption before the action is started.

Before the first managed-DNS change, the runtime records the existing
`dnsproxy`, `dnsmasq` and service state. Reliable mode temporarily points
dnsmasq at `127.0.0.42`; that application-owned endpoint is never accepted as
an original upstream. Legacy snapshots containing it are repaired only from a
saved pre-FakeIP upstream or an already-running saved loopback dnsproxy.

## Destination lifecycle

The active policy is built from:

- selected service domain lists;
- packaged direct-service CIDR files;
- `/etc/pbr-ikev2-domains.manual.txt`;
- `/etc/pbr-ikev2-addresses.manual.txt`.

Every input is normalized in a temporary directory. Service downloads are
size-limited, validated and cached. Bare custom IPv4 addresses become `/32`.
The active domain and CIDR files are replaced only after the complete build
succeeds.

Optional external lists come from `itdoginfo/allow-domains` at runtime. They
are not redistributed by this project. Packaged `.lst` and `.cidrs` files are
project-maintained and covered by the project license.

## Ownership and recovery

Persistent settings live in `/etc/config/ikev2-manager`. Generated UCI sections
use the `ikev2pbr_` prefix. Disabling managed mode removes generated network,
firewall and PBR state while preserving user settings, certificates and
destination lists.

Per-device intent is stored in application-owned `device_policy` sections.
PBR policies are derived output, while the earlier prerouting table applies
direct/full-route marks and the validated Zapret bypass mark. The same owned,
atomically replaced nftables table redirects plain DNS, rejects outbound DoT
and holds the shared per-device DNS-bypass set; it does not encode a list in a
scalar firewall redirect option. Explicit routing rules carry counters per
address. The Unmanaged preset is only a convenience that
sets direct routing, DNS passthrough and DPI passthrough; the three settings
remain independently editable.

Router-originated domain routing is disabled by default. When enabled in
Reliable mode, only connections to the reserved FakeIP range enter the output
TProxy path. The IKE transport endpoint and local management addresses are real
addresses, so they cannot match that range or loop through the tunnel.

The health service checks:

- outbound CHILD_SA data-plane reachability;
- virtual IP and fail-closed routes;
- sing-box, dnsmasq, TProxy and policy-rule invariants;
- the direct-service CIDR PBR rule;
- inbound server configuration drift.

Repairs are serialized and avoid restarting WAN or the router.

All mutating LuCI actions use detached workers with per-action status files and
a shared router-action lock. A second action fails promptly instead of queuing
for minutes. UI pages poll the action ID and reload the affected model data in
place after completion.

Dependency installation records the package baseline, DNS provider and every
package added by the transaction. A full dependency reset removes only that
owned set. Package-manager solver dependencies used by other applications are
retained. Package removal itself has a narrower lifecycle contract and
preserves user configuration.

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
