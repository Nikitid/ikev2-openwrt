# Changelog

This project follows semantic versioning for the application and release tags.

## 1.5.3 - 2026-08-30

- Stopped the health watcher from repairing through a pause. It restores the
  FakeIP runtime and the device policy every cycle, so a pause was undone within
  seconds: the action reported success, the policies stayed disabled, and
  selected traffic kept using the tunnel through the restored interception.

## 1.5.2 - 2026-08-30

- Fixed pausing tunnel routing, which could not work: the lock helper runs its
  first argument as a command, and it was given the action label instead of the
  function, so the shell looked for a program named `pause`.
- Made a failed pause restore the previous state. It disabled the routing
  policies first and aborted on the next failing step, leaving the router
  routing nothing through the tunnel while still intercepting selected names.
- Added a check that every lock helper target is a function defined in the same
  file, which is the class of mistake that caused this.

## 1.5.1 - 2026-08-30

- Reported the paused state from the configuration reporter the page actually
  reads. It was emitted from the diagnostic report instead, which shares its
  first line, so the overview always saw routing as running.

## 1.5.0 - 2026-08-30

- Added Pause and Resume for tunnel routing, the reversible counterpart of
  resetting the application. Pause stops the three things that put traffic into
  the tunnel — the PBR policies, the FakeIP interception and the device policy
  runtime — and deletes nothing: policies, lists, DNS settings and device
  overrides stay exactly as configured. Resume restores them.
- Said plainly that pausing gives up the fail-closed guarantee for as long as it
  lasts. Selected destinations leave through WAN while paused, which is the
  point of pausing and not something to discover afterwards.
- Kept the domain routing engine untouched across a pause, so Resume restores
  the mode that was configured rather than a different one.
- Extended the render harness to the overview page, which owns the new control.

## 1.4.14 - 2026-08-30

- Showed a spinner while a button's action is running. A button that only goes
  grey reads as broken, with nothing to say the click was accepted rather than
  swallowed. Every action that uses the shared busy state gains it; the
  animation is dropped under reduced-motion preferences.

## 1.4.13 - 2026-08-30

- Fixed the device policy runtime reporting itself missing while it was
  installed and working. nftables lists `!= 0` back as `!= 0x00000000`, and the
  DPI-restore rule was verified only against the written form, so readiness went
  degraded on any router that has a device with DPI passthrough and uses the
  zapret2 backend. The mark comparisons alongside it already allowed for the
  same canonicalisation.

## 1.4.12 - 2026-08-30

- Gave the tunnel DNS block its own Apply. Its servers used to be stored only by
  the outbound tunnel's Save, so changing a resolver meant saving the whole
  connection. The block now applies as one action: the servers are written with
  the client profile in save mode, which does not reconnect, and the resolution
  path is applied only when it actually changed.
- Moved destination DNS segments out of a disclosure inside the router resolver
  and into their own section. A segment resolves on its own terms whatever the
  rest of the policy does — including while every other name goes through the
  tunnel — so presenting it as a detail of the resolver it bypasses was wrong.
  The section reports whether it is active or waiting for managed DNS.
- Said plainly in the router DNS section when client queries are resolving
  through the tunnel and therefore not using that resolver at all.
- Added a render harness for the outbound tunnel view. A parse check passes
  while a page dies at render time, and nothing in the suite caught that.

## 1.4.11 - 2026-08-30

- Put the tunnel resolution switch on the outbound tunnel page, next to the
  tunnel DoH servers it belongs with. It was reachable only from the command
  line, which is the wrong place for a setting that takes DNS away from every
  client when the tunnel is down. The control states that consequence, applies
  through the same validated and self-restoring helper, and returns to the
  router's actual state when the change is rejected.

## 1.4.10 - 2026-08-30

- Made ordinary name resolution through the tunnel available as an explicit
  choice (`ikev2-domain-router tunnel-resolve 1`). The WAN path is where
  per-protocol DNS filtering is applied; the tunnel-bound resolver avoids it,
  at the cost of coupling every lookup to tunnel health. It refuses to engage
  without an enabled outbound client and rolls back when the refreshed runtime
  cannot resolve.
- Stopped describing the WAN provider resolvers as a tier below the fallback
  group. They are appended to that group and selected on equal terms with it,
  which is what the interface now says.
- Reported the fallback a destination segment actually uses. An empty field
  inherits both global groups, so it was the widest setting while reading as
  none.

## 1.4.9 - 2026-08-29

- Allowed the primary resolver group to mix transports, as the fallback group
  already did. Blocking is applied per protocol per provider, so a group
  combining DoH, DoQ and DNSCrypt survives what a single-protocol group cannot.
- Accepted DoH, DoT and DoQ bootstrap entries with a literal IPv4 authority, so
  the resolver ladder no longer depends on plaintext UDP/53 to resolve its own
  endpoint names.
- Verified the fallback resolver group before committing to it. The ordinary
  health query is answered by the primary group, so a dead recovery path used to
  stay invisible until the moment it was needed.
- Reported the effective resolver timeout beside the stored one, and recorded
  when the fallback group was last proven to answer.

## 1.4.8 - 2026-08-28

- Fixed the LuCI readiness ACL and cached its expensive read-only report.
- Bound repository refreshes without relying on the optional BusyBox `timeout`
  applet, and made the shared action lock follow the live process identity
  instead of expiring an active operation by age.
- Validated provider DNS before admission and made WAN fallback refresh verify
  the main resolver and every enabled destination segment before commit.
- Replaced an unsupported BusyBox `nslookup -port` segment probe with a
  listener check plus an end-to-end query through dnsmasq.
- Reconciled DNS/FakeIP runtime only when its schema changes, so UI-only package
  updates do not restart resolver processes.
- Required sing-box 1.13.19 for Reliable mode and added a reproducible build of
  the upstream FakeIP metadata-save fix.
- Verified PBR completion from live forwarding state instead of trusting the
  init-script exit status.

## 1.4.7 - 2026-08-27

- Serialized transient domain-router health work with configuration
  transactions, so a DNS apply cannot fail merely because the periodic watcher
  acquired the local runtime lock in the same instant.

## 1.4.6 - 2026-08-27

- Added an explicit WAN-provider DNS fallback for the ordinary resolver path,
  with netifd lease reconciliation that does not restart PBR, sing-box,
  strongSwan or WAN.
- Prevented tunnel-DNS failover during a general tunnel data-plane failure and
  dampened rapid switches back to the previous endpoint; switch logs now retain
  the actual endpoints across the transactional sing-box refresh.
- Kept structured readiness results available to LuCI when a runtime check is
  degraded, and extended the Anthropic service definition for current Claude
  application and content domains.

## 1.4.5 - 2026-08-27

- Replaced the two-second inbound session poll with strongSwan VICI
  `child-updown` events while retaining a periodic authoritative reconciliation
  and the existing atomic fail-closed nftables update.
- Replaced stale inbound SAs for the same device-specific EAP identity so rapid
  Android reconnects cannot retain conflicting virtual addresses.
- Declared the PTY event adapter as an explicit package and runtime dependency;
  this prevents stdio buffering from delaying `swanctl --monitor-sa` events.

## 1.4.4 - 2026-08-25

- Made stale action-lock inspection use the BusyBox-supported `date -r`
  interface instead of requiring an unavailable standalone `stat` command.

## 1.4.3 - 2026-08-25

- Removed duplicate per-device PBR policies; the existing early nftables table
  is now the sole full-route/exclusion classifier and legacy sections are
  cleared with one checked migration rebuild on the next device update.
- Prevented health reconciliation and false non-zero reload results from
  causing repeated global PBR rebuilds. Network actions now leave an initiator
  trail in syslog.
- Made DNS rollback restore application and segment state before rebuilding
  FakeIP, with a validated last-known-good runtime snapshot as the fallback.
  Tunnel outbound hostname resolution is IPv4-only and healthy bootstrap
  rotation no longer restarts sing-box.
- Dropped UDP/53 datagrams too short to contain a DNS header before sing-box.
  Bounded, expiring per-source counters and a read-only diagnostic command now
  distinguish that client traffic from unrelated sing-box parser errors.
- Distinguished an unavailable readiness RPC from genuinely missing runtime
  dependencies in LuCI.
- Kept dependency repair on the installed strongSwan version cohort instead of
  allowing one missing plugin to trigger a partial daemon/library upgrade.
- Preserved the global PBR/DNS contract, certificate renewal material and
  shared runtime packages while an applied Site Link role still consumes them.
- Rejected package-manager repair plans that upgrade, downgrade, replace or
  remove an installed runtime, and stopped failed PBR reloads from launching a
  second overlapping rebuild.
- Made Reliable mode reject sing-box versions with the known concurrent FakeIP
  allocator bug instead of reporting a working but unsafe runtime.

## 1.4.2 - 2026-08-21

- Corrected the fast readiness report so a successfully checked DNS segment
  with runtime state `up` is shown as healthy instead of not yet checked.

## 1.4.1 - 2026-08-21

- Moved inbound per-user access updates from the general health coordinator to
  a dedicated procd watcher. New and removed SAs are reflected in the
  fail-closed nftables table within about two seconds and are no longer delayed
  by tunnel or DNS probes.
- Hot-reloaded Reliable-mode domain-only edits through the local sing-box
  rule-set. PBR is rebuilt only when its effective UCI, device, interface,
  mode or CIDR state changes; failed hot reloads restore the previous rule-set
  before the existing transactional fallback.
- Reduced LuCI startup and polling work by using bounded UI diagnostics,
  caching the static Overview snapshot, batching VPN-user configuration reads
  and polling only live data after the VPN Users page is rendered.
- Simplified readiness and policy-routing layouts, removed repetitive status
  notices and fixed action, toggle and editor layout at desktop and mobile
  widths.
- Added current provider presets for DoQ, forced HTTP/3 and DNSCrypt while
  retaining ordinary DoH over TCP/443 as the reliable default.
- Cached validated community service downloads for one hour and avoided
  network requests for services that have no address inventory.

## 1.4.0 - 2026-08-21

- Added editable prepared services and separate user-created domain/CIDR
  services. Definitions, selection changes and policy rebuilds are validated
  transactionally and restored together after a failed runtime update.
- Added a project-maintained TikTok manifest with the current image-delivery
  suffixes while excluding unrelated products and shared CDN parent domains.
  Untrusted provider revisions containing a top-level suffix are now rejected.
- Resolved selected outbound destinations through DoH bound to `ipsec-out`,
  keeping DNS geography aligned with the VPN path without changing direct or
  client-wide DNS policy.
- Added ordered tunnel-bound DoH and bootstrap settings to the Outbound page.
  The health loop changes resolver only after two failed checks and a
  successful tunnel-bound probe of the next configured server; it never falls
  back to WAN. Resolver probes remain bounded on minimal OpenWrt images that do
  not provide the optional BusyBox `timeout` applet.
- Removed the superseded, unbuilt ClickOnce prototype.
- Added an early-boot, fail-closed inbound access guard and kept it installed
  until XFRM shutdown during managed teardown.
- Prevented stale action locks and failed worker launches from suppressing
  runtime recovery, and bounded DNS-segment health probes to one suffix per
  resolver group.

## 1.3.11 - 2026-08-20

- Removed the nested resolver deadline in Reliable mode by routing destination
  DNS segments directly from sing-box to their dedicated loopback workers.
  Standard mode routes the same suffixes from dnsmasq directly to those
  workers. Segment primary and fallback attempts now complete inside the outer
  DNS deadline, and health checks distinguish a failed worker from a failed
  end-to-end resolver path.
- Bounded managed resolver timeouts and increased the explicit sing-box DNS
  cache capacity to 8192 entries. Segment browser compatibility is inactive
  while managed DNS itself is disabled. Duplicate primary/fallback endpoints
  are removed from runtime groups instead of being retried twice.
- Added a reproducible OpenWrt 25.12 build for a minimal sing-box 1.12.17-r2
  backport. It serializes FakeIP allocation, stores a new reverse mapping before
  returning it and applies the upstream address-range boundary correction.
  Runtime diagnostics verify the patched binary rather than trusting only its
  package version.
- Prevented accidental duplicate health watchers with a stale-safe PID lock and
  rejected unsupported command-line arguments before any daemon work starts.
- Made per-device DPI bypass compatible with both Zapret1 and Zapret2. Zapret2
  connections preserve the bypass mark in conntrack and restore it on reply
  packets before Zapret2's pre-NAT hook.
- Routed router-originated Reliable traffic through a dedicated TProxy inbound
  and mark that always selects the IKEv2 outbound, independently of changing
  router addresses and PBR source matching.

## 1.3.10 - 2026-08-16

- Recovered an outbound IKEv2 session that starts before WAN address selection
  and remains bound to loopback. The health watcher discards only this invalid
  `CONNECTING` state after gateway DNS becomes available, then synchronizes the
  replacement virtual address and PBR route without interrupting an ordinary
  handshake or the inbound server.
- Stopped the health watcher before its DNS, domain-router, XFRM and network
  dependencies during router shutdown, bounded its procd termination time and
  migrated existing rc links during package upgrades while preserving disabled
  services.

## 1.3.9 - 2026-08-12

- Bound DNS-over-TLS enforcement to every active IPv4 default-route device in
  addition to the configured logical WAN. A removed or renamed WAN selection
  can no longer leave the firewall rule attached to an obsolete interface;
  during a total WAN outage the last validated device set remains preserved.

## 1.3.8 - 2026-08-12

- Probed every suffix in an enabled destination DNS segment instead of only
  its first suffix, so a partially failing national resolver group is reported
  as degraded.
- Kept the downloaded service-network safety bound compatible with legitimate
  Meta, Telegram and Discord address inventories. Catastrophic, private and
  reserved prefixes remain rejected without truncating normal service lists.

## 1.3.7 - 2026-08-12

- Removed duplicate optimistic DNS caches from the primary dnsproxy and every
  destination-segment worker. Standard mode now leaves caching to dnsmasq and
  Reliable mode to sing-box, preventing a transient upstream `SERVFAIL` from
  being retained and amplified across the resolver chain.
- Added an independent fallback group to each destination DNS segment. An
  empty group safely inherits the global fallback and primary resolvers, and
  the health watcher now probes every enabled segment once per minute and
  exposes degraded segment identifiers in status.
- Changed Reliable-mode HTTPS compatibility from `REFUSED` to a successful
  empty response and limited FakeIP to selected `A` queries. Selected `AAAA`
  queries receive the same empty response, while ordinary domains keep normal
  IPv6 resolution instead of being suppressed globally.
- Rejected parent/child DNS-segment suffix overlap and ran segment resolvers as
  the unprivileged `dnsproxy` account. Resolver updates and package upgrades
  apply the new runtime transactionally and restore the previous configuration
  if global or segment validation fails.
- Reduced background churn by rebuilding inbound user policy once per health
  cycle and snapshotting PBR sets once per minute instead of every 15 seconds.
- Constrained downloaded community service networks to narrow public prefixes
  and a bounded address total. Bundled and administrator-entered CIDRs remain
  unchanged, while an external list can no longer inject private, cloud-wide
  or default routes into the active policy.

## 1.3.6 - 2026-08-12

- Added per-segment browser compatibility, enabled by default, for DNS
  authorities that return `SERVFAIL` for HTTPS resource records. In Reliable
  mode only HTTPS lookups under the segment suffixes are rejected, allowing
  Chromium-family clients to fall back to unchanged A/AAAA answers.
- Kept the compatibility rule scoped to enabled destination DNS segments and
  made it independently configurable in LuCI. Selected PRB domains retain
  their existing anti-bypass rule, while names outside compatible segments
  continue to receive modern HTTPS records normally.
- Preserved existing DNS segments through the new setting with a safe default,
  validated invalid values transactionally and added generated-config and UCI
  regressions for enabled, disabled and legacy segment configurations.

## 1.3.5 - 2026-08-12

- Restricted Reliable-mode FakeIP answers to `A` and `AAAA` lookups for the
  selected domain set. NS, SRV, PTR, TXT and other records now use the normal
  upstream instead of being rejected by the FakeIP transport.
- Scoped HTTPS/SVCB suppression to selected domains. Ordinary destinations no
  longer receive a global `REFUSED` response for modern HTTPS DNS records,
  while selected destinations cannot bypass exact routing through address
  hints.
- Added generated-configuration regressions that reject a global HTTPS rule or
  an unqualified FakeIP route before packaging.
- Made package upgrades transactionally regenerate an active Reliable-mode
  configuration, so this DNS correction takes effect immediately without a
  WAN, PBR, strongSwan, dnsmasq or firewall4 restart. A failed refresh keeps the
  previous generated configuration and runtime.

## 1.3.4 - 2026-08-10

- Separated installed dependency readiness from managed runtime health, so a
  temporarily unavailable uplink or damaged live rule no longer prompts users
  to reinstall packages. Disabling remains available in degraded mode.
- Preserved the last validated wireless WAN device while its logical network is
  temporarily down, and made failed managed-mode teardown restore all project
  runtimes instead of only their UCI configuration and service flags.

## 1.3.3 - 2026-08-10

- Fixed the device-policy health check treating nftables' canonical rendering
  of an equivalent packet-mark expression as a damaged rule. This prevents the
  health watcher from needlessly replacing an already healthy policy table.

## 1.3.2 - 2026-08-10

- Fixed per-device DNS exclusions invalidating the complete plain-DNS
  redirect in firewall4. DNS interception, DoT blocking and their shared
  bypass list now use the project's atomically replaced nftables runtime, so
  multiple excluded devices remain valid and inbound VPN traffic is covered
  when selected. Package upgrades load the replacement table atomically and
  retire the obsolete generated firewall sections without restarting WAN,
  PBR, strongSwan, dnsmasq or firewall4.
- Made firewall validation reject diagnostics for sections skipped because of
  invalid options even when `fw4 check` returns success. Runtime status now
  verifies the owned DNS and DoT rules instead of inferring them from saved UCI
  sections.

## 1.3.1 - 2026-08-09

- Reloaded rpcd's ACL registry after package installation without restarting
  the daemon. Newly added LuCI operations, including destination DNS segment
  management, are now available to active administrator sessions immediately
  after an upgrade instead of failing with `Permission denied` until a reboot
  or manual rpcd reload.

## 1.3.0 - 2026-08-09

- Stored per-device routing settings in this application's own configuration
  sections instead of encoding them in the name of a routing policy belonging
  to the neighbouring PBR package. Four independent places parsed that name
  prefix, so renaming a policy through that package's own interface silently
  changed which devices were excluded from the tunnel. Policies are now
  rendered from the configuration and repaired on every apply, and the previous
  representation is imported automatically on the first change or apply after
  an upgrade.
- Added a per-device opt-out from DNS interception. Excluding a device only
  changed where its traffic left the router: the port 53 redirect and the
  DNS-over-TLS block match by zone and destination port, never by source, so an
  "excluded" device still could not use its own resolver. The opt-out is
  expressed as a negated source in both rules, and the page states plainly that
  domain routing stops working for such a device because it never enters FakeIP
  classification.
- Added an independent per-device Zapret opt-out and an Unmanaged preset that
  combines direct-WAN routing with DNS and DPI passthrough. The runtime reads
  Zapret's configured desynchronization mark and refuses to apply the opt-out
  when that integration point is missing or invalid.
- Added per-device nftables counters, excluded-device totals and excluded
  traffic to the status view and Status Overview widget.
- Added destination DNS segments. Explicit suffix lists use their own local
  dnsproxy instance, protocol and upstream-selection strategy while all other
  names keep the global resolver policy. The segment configuration is stored
  independently of generated domain-routing files. Enabled suffix lists cannot
  overlap, and concurrent segment resolvers are capped to bound resource use.
- Added an explicit Reliable-mode switch for router-originated selected-domain
  traffic. Only FakeIP destinations are intercepted, so the tunnel transport
  and local management destinations remain outside the policy.
- Added a configurable FakeIP log level with a quiet `warn` default, a warning
  for small system-log buffers and a timed inbound-IKE capture that writes a
  separate bounded file and reports recognised identity, phase and failure.
- Added a 60-second FakeIP debug capture that restores the configured normal
  log level even when the detached diagnostic is interrupted.
- Added per-user Apple mobileconfig, Windows VPNv2 XML with catch-all NRPT and
  Android setup-detail exports. Secret-bearing output is generated only for an
  explicit privileged download and is never staged in the public tree.
- Added a reusable Windows setup application for separately downloaded VPNv2
  XML profiles. It installs, verifies, updates and removes the selected profile
  directly through the built-in WMI Bridge, requests UAC only
  for the profile operation, records actionable errors and doesn't invoke
  PowerShell or leave a task or service behind. The server domain is the
  default Windows connection name and can be edited before installation. The
  setup UI uses a DPI-aware dark layout, a bundled application icon and stable
  fixed-size actions instead of native controls whose widths changed by state.
  Privileged profile changes run in a hidden one-shot worker, so the visible
  window remains in place and receives the result without reopening.
- Made DNS-suffix lowercasing compatible with the supported OpenWrt BusyBox
  `tr`. Its POSIX character-class form converted `ru su xn--p1ai` into
  `rl sl xn--w1ai`, leaving a seemingly valid national segment that never
  matched Russian domains.
- Installed only the leaf server certificate in the strongSwan end-entity
  store, retained intermediate certificates separately and omitted a
  self-signed root. Reissuing a certificate replaces the previous chain.
- Documented that applying managed DNS restarts the resolver, clears its
  in-memory optimistic cache and can briefly pause name resolution. Failed
  applies continue to restore the previous resolver transactionally.
- Rejected a malformed device entry instead of skipping it. An unreadable
  address used to drop out of the exclusion list, quietly moving that device
  back into the tunnel; domain routing and the Discord voice classifier now
  fail loudly rather than acting on a silently shortened list.
- Consolidated full-VPN inclusions and per-device exclusions into one LuCI
  list. PBR, DNS interception and Zapret bypasses can be changed independently
  in an exclusion row, while access-policy details and direct platform profile
  downloads no longer crowd each VPN-user card.
- Fixed the new device actions being rejected first by rpcd ACLs and then by
  the asynchronous action dispatcher. Also fixed the first non-empty device
  rule producing invalid nftables syntax because its verdict followed the rule
  comment; validation failures now include nftables' actual diagnostic.

## 1.2.8 - 2026-08-03

- Refreshed service networks from the published subnet lists instead of only
  the files bundled with the package. Domains were updated on every run while
  networks were frozen until a release, so a service reached by address rather
  than by name — Telegram above all — drifted out of date and could not be
  corrected without shipping a new package. Networks now come from the same
  publisher as the domains, merged with the bundled and manual entries so a
  failed download or an entry upstream does not know about still routes.
- Listed every service that publishes networks in the editor, not only those
  with a bundled file, so the "also brings networks" mark matches what a
  selection actually adds.

## 1.2.7 - 2026-08-03

- Claimed only this application's own virtual IP when syncing the outbound
  tunnel address. The SA list was scraped without filtering by connection and
  the last match won, so a second IKEv2 client on the same router — a site
  link, for example — had its virtual IP installed on `ipsec-out` instead. The
  outbound tunnel then carried no traffic: selected domains failed to open and
  inbound VPN clients lost the routes that point at it.
- Read only the inbound server's own sessions when authorising VPN clients.
  The session list was scraped across all connections and matched greedily, so
  another IKEv2 connection listed after a client contributed its virtual IP to
  that client's entry. The client's real address was then never authorised and
  every forwarded packet was dropped: the tunnel came up with no connectivity
  behind it.

## 1.2.6 - 2026-07-28

- Redirected inbound VPN clients' plain DNS to the router when the VPN server
  is selected as a protected network and DNS enforcement is enabled. Direct
  external UDP/TCP port 53 previously returned real addresses and let selected
  domains bypass FakeIP routing through the outbound tunnel.

## 1.2.5 - 2026-07-26

- Named the cause when the outbound tunnel fails to come up. strongSwan reports
  the reason to the system log rather than through its control interface, so the
  UI previously showed only "Tunnel did not come up; see the log". Recognised
  causes — an unvalidatable gateway certificate, rejected credentials, no shared
  proposal, unacceptable traffic selectors, an unanswering gateway, no matching
  peer configuration — now appear in the status message itself.
- Named the cause when a policy-routing update is rejected. Every validation in
  the staged apply returned silently, so an operator saw "Community update
  failed" with an empty log and no way to tell which check refused the input.

## 1.2.4 - 2026-07-26

- Fixed every application page failing with `InvalidCharacterError` after
  1.2.2. The stylesheet helper returned an empty string once the sheet moved
  into the document head, and LuCI's `E()` falls through to
  `document.createElement()` for anything that is neither a node nor markup, so
  the empty string aborted rendering.
- Added tests that evaluate `shared.js` itself against LuCI's element dispatch.
  Every other JS test stubbed the module out, which is why nothing caught this.

## 1.2.3 - 2026-07-26

- Restarted the health watcher when a package upgrade replaces it and it was
  already running. The watcher is a shell script, so the running instance kept
  executing the previous version: upgrading 1.1.x to 1.2.x left the inbound
  user policy never created at all, because the older watcher has no such step.
  An installation that deliberately keeps the runtime stopped is still not
  started by an upgrade.

## 1.2.2 - 2026-07-26

- Fixed inbound VPN clients losing all access whenever strongSwan reported the
  same client twice, for example during reauthentication or an IKE rekey. The
  duplicate address aborted the whole nftables transaction, after which every
  connected client was dropped as its policy entry expired. BusyBox `sort` has
  no `-o` option and silently discarded the deduplication that was meant to
  prevent this; the same defect also leaked list contents, including VPN
  credentials, into command output consumed by LuCI.
- Denied an inbound address that two identities claim at once instead of
  granting it the union of both policies, which could happen while a stale SA
  still held an address the pool had reissued.
- Raised the inbound policy expiry backstop and bounded the health probe so a
  slow watcher cycle can no longer outlive the entries it refreshes.
- Stopped replacing the global LuCI translation function. The project map was
  applied to every other application on any page that loaded our resources,
  including the router-wide Status Overview, producing mixed-language pages.
- Installed the application stylesheet once per document instead of rebuilding
  it on every Status Overview poll, which forced a full style recalculation and
  flashed the page.
- Fixed inputs and selects being clipped at the bottom in Edge on Windows: the
  theme pins these controls to a fixed height that the application padding then
  exceeded.
- Granted the read ACL the ubus `file` methods its own paths require, so a
  read-only LuCI account can load the views and the status widget.
- Renamed the project repository to `ikev2-openwrt`. GitHub keeps serving the
  previous paths, so installations are not interrupted; the package moves a
  feed list that still holds the previous project URL onto the current one
  instead of relying on that alias.
- Moved the signed APK feed out of this repository into `Nikitid/openwrt-feed`.
  A URL recorded in `/etc/apk/repositories.d` on every router no longer depends
  on the name or lifetime of one application repository. This repository now
  builds and signs only its own package and publishes it as a release asset, so
  a release no longer depends on a sibling application being ready.
- Migrated installations onto the shared feed list from the package itself, and
  only when the existing list still holds one of this project's own previous
  URLs.
- Replaced the per-application bootstrap script with the shared feed installer,
  which configures one trust anchor and one feed entry for every Nikitid
  OpenWrt application and installs only the packages it is given.
- Added checks for BusyBox-incompatible options and for private key material in
  tracked files, and broadened the tracked-key name pattern.

## 1.2.1 - 2026-07-24

- Fixed active inbound clients being rejected by the fail-closed user policy
  when strongSwan reports a virtual address without whitespace before the
  closing `remote-vips` bracket.
- Fixed MTProto firewall status detection for a public TCP 1443 service
  terminated on the router.
- Converted the OpenWrt 25.12 channel into a shared signed application feed
  retaining both IKEv2 Manager and Overview Manager.

## 1.2.0 - 2026-07-24

- Added a Status Overview widget summarizing outbound tunnel connectivity and
  accumulated interface traffic, PBR/domain-routing and fail-closed health,
  inbound-server readiness, and established inbound clients. It is placed
  before the standard system widgets.
- Added per-user inbound access policies with global inheritance, router and
  Internet overrides, full or IPv4/CIDR-limited local access, and optional PBR
  exclusion through direct WAN.
- Added per-user TCP/UDP router-port exceptions so selected public services
  remain reachable while general router access stays denied.
- Mapped authenticated EAP identities to short-lived virtual-address rules so
  new, disconnected and reused pool addresses fail closed.

## 1.1.9 - 2026-07-18

- Migrated the identity-hash constraint left by older local APK installations
  to the signed repository package before a scoped upgrade, with rollback when
  the index refresh or package transaction fails.

## 1.1.8 - 2026-07-18

- Added a redirect-free OpenWrt 25 APK channel that advances only for stable
  releases instead of pinning clients to the bootstrap release, and made repeat
  bootstrap runs upgrade an installed package after transaction simulation.
- Documented the one-time bootstrap refresh required to move older
  installations onto the stable APK channel.

## 1.1.7 - 2026-07-18

- Expanded the connected-device selector so complete device identities remain
  visible and constrained the routing-mode selector to a practical width.

## 1.1.6 - 2026-07-18

- Routed Discord's literal UDP voice endpoints through the selected IKEv2
  policy by learning exact address/port pairs from voice IP discovery, avoiding
  static Discord or Cloudflare address ranges.
- Replaced manual Full route and Exclude address entry with a connected-device
  picker and an explicit Custom fallback.
- Applied device policies atomically through an app-owned nftables classifier,
  without restarting PBR, DNS, XFRM or either IKEv2 tunnel.

## 1.1.5 - 2026-07-17

- Reworked detected network and firewall-zone selectors into consistent
  selectable cards while retaining a separate custom-value fallback.
- Aligned the protected-network cards in one adaptive row and placed the custom
  network option below them.
- Fixed field-label spacing outside the standard form grid.

## 1.1.4 - 2026-07-17

- Shortened the LuCI Services menu title to `IKEv2 Manager` and aligned the
  installation instructions with the new navigation label.

## 1.1.3 - 2026-07-16

- Split outbound traffic reporting into the current CHILD_SA counter, including
  its age since the last rekey, and cumulative `ipsec-out` interface traffic.

## 1.1.2 - 2026-07-16

- Replaced predictable free-text network, firewall-zone, address-plan, MTU,
  timer and certificate-path values with detected or safe presets. Every
  picker keeps a final custom option and preserves unknown existing values.
- Added an explicit inbound-server option to allow every router port. It
  disables the restricted-port field and makes restricted mode require a
  non-empty full allowlist with a management lockout warning.
- Added a readiness diagnostic for active or permitted UPnP mappings that can
  collide with the inbound IKEv2 server on UDP 500/4500.
- Split Overview readiness diagnostics into system checks, target VPN/routing
  packages and shared router packages, with reset ownership explained inline.
- Moved the Overview Apply action below the network and DNS controls so one
  explicit submission applies managed mode, protected networks and both DNS
  policy options together.

## 1.1.1 - 2026-07-16

- Avoided full firewall/PBR rebuilds when managed settings or the combined
  domain/CIDR policy are unchanged and the live runtime passes health checks;
  degraded state still takes the full transactional repair path.
- Fixed OpenWrt 25 package removal cleanup when apk passes the installed
  package version to `pre-deinstall`; upgrades remain non-disruptive through
  the separate upgrade guard.
- Prevented managed enable from waiting on its own global action lock when it
  rebuilds a preserved domain policy after package reinstallation.

- Made router-wide background actions reject a competing operation promptly
  instead of waiting behind it for up to three minutes.
- Added phase updates and a longer status-poll window for policy-list rebuilds;
  a normal PBR restart can take tens of seconds on the router.
- Changed XFRM shutdown ordering so live PBR and firewall references are
  removed before interfaces are stopped. Runtime cleanup no longer depends on
  deleting an XFRM link, which can block inside the OpenWrt 25 kernel.
- Made runtime dependency removal restore the recorded pre-install baseline,
  remove only application-owned packages, retain packages required by other
  software and reset application-owned settings and generated state.
- Repaired legacy original-DNS snapshots that captured the application's
  `127.0.0.42` FakeIP resolver. Restoration uses the domain router's saved
  upstream or a previously running loopback dnsproxy and otherwise stops safely
  before package removal.
- Added regression checks for action-lock contention, XFRM stop ordering,
  shared dependency retention, PBR progress and full application reset.

## 1.1.0 - 2026-07-15

- Standardized all LuCI actions on local inline status feedback instead of
  global notifications.
- Refreshed users, counters, runtime state, DNS, ACME and routing status after
  successful actions without requiring a manual page reload.
- Made client, inbound server, DNS, device and dependency changes transactional,
  with validation and rollback to the previous working state on failure.
- Hardened dependency installation and removal for both `opkg` and `apk`,
  including safe restoration of the original dnsmasq provider and settings.
- Added IPv6 fail-closed routing for selected traffic while keeping Reliable DNS
  on IPv4-only upstreams to prevent resolver traffic from bypassing the tunnel.
- Added strongSwan version diagnostics. Older inbound-server versions remain
  available with a non-blocking compatibility notice; unsafe outbound EAP
  client versions are rejected.
- Expanded regression coverage for asynchronous UI actions, ACME settings,
  package state, transactions, runtime validation and certificate chains.

## 1.0.10 - 2026-07-12

- Removed full-page reloads after dependency, DNS, user and coverage actions.
  Each action now keeps its completion state visible in the current view while
  the page remains open.

## 1.0.9 - 2026-07-12

- Fixed ACME issuance: the request action now runs the ACME renewal command
  instead of only enabling its nightly cron schedule.
- Removed the duplicate dependency-complete notification; Overview refreshes
  itself after a completed dependency transaction.

## 1.0.8 - 2026-07-12

- Keep `ca-bundle` installed: APK requires it to securely update HTTPS feeds
  after a dependency reset.
- Remove the application's dnsmasq hand-off to a removed local dnsproxy so a
  clean Install can resolve package feeds through the original WAN resolver.

## 1.0.7 - 2026-07-12

- Do not record `jsonfilter` as a removable runtime package: it is a required
  dependency of the LuCI bootstrap package and must remain installed while the
  application is present.

## 1.0.6 - 2026-07-12

- Runtime dependency installation now records the original DNS/DHCP state and
  every package that was not present before installation.
- Remove restores that saved state and deletes only application-owned runtime
  packages, including DNS, ACME and generic tools when this app installed them.
- Installation rollback now restores the saved baseline when package setup
  fails, instead of leaving a partial dependency stack.


- Fixed LuCI Software installs, upgrades and removals losing their rpcd JSON
  response: package lifecycle scripts no longer restart rpcd while apk or opkg
  is executing.
- Fixed runtime dependency removal on apk: absent optional modules are filtered
  before `apk del`, and the action now reports a failure instead of a false
  success when package removal does not complete.
- Documented the deliberate safety boundary for dependency removal: DNS
  packages, generic shared tools and ACME remain installed to avoid disrupting
  router DNS/DHCP or unrelated services.

## 1.0.4 - 2026-07-12

- Fixed an intentionally empty managed DNS fallback being replaced in LuCI by
  the dnsproxy package default, which could break DNS validation and Reliable
  mode domain routing.
- Added client-side DNS endpoint validation and preserved the exact backend
  failure reason instead of reporting every failure as a completed rollback.
- Replaced the ambiguous Reliable mode warning with the failed runtime
  invariant: service, dnsmasq hand-off/cache, nftables table or policy rule.
- Wait for the router resolver after PBR/community refresh before releasing the
  global action lock, preventing a successful action from briefly returning
  while DNS still refuses connections.
- Verified guarded removal cleanup in the generated APK metadata.

## 1.0.3 - 2026-07-12

- Fixed OpenWrt 25.12 dependency installation rejecting official fetched
  dnsmasq packages as untrusted; apk now switches providers by trusted feed
  name and rolls back through the apk solver.
- Updated installed-version queries for apk-tools 3 and corrected the dnsmasq
  nftset capability check so `no-nftset` is not accepted.
- Preserved the previously installed dnsmasq provider during rollback and
  removed leftover apk/opkg conffile templates after configuration restore.
- Fixed APK removal cleanup: OpenWrt apk runs `pre-deinstall` without the opkg
  `remove` argument, while upgrades are now explicitly skipped through
  `PKG_UPGRADE` so live routing is not torn down.

## 1.0.2 - 2026-07-12

- Added a signed OpenWrt 25.12 APK feed backed by GitHub Release assets.
- Added a one-time bootstrap installer that verifies the project release key,
  registers the feed, simulates the transaction and rolls key/feed changes back
  when installation fails.
- Added release-key/SDK identity checks and CI release assembly for signed APKs
  and `packages.adb` indexes.

## 1.0.1 - 2026-07-07

- Released version `1.0.1`.
- Reworked the outbound DNS editor around addable primary, bootstrap and
  fallback resolver rows, provider presets and native dnsproxy upstream modes.
- Added remove-time cleanup for generated runtime state. Explicit package
  removal now disables managed mode and removes rendered strongSwan profiles
  before files are deleted, while upgrades keep live routing untouched.
- Aligned the SDK Makefile preinstall checks with the canonical IPK preinstall
  guard, including required base commands and persistent-storage preflight.
- Added Mullvad and Yandex resolver presets and allowed fallback resolvers to
  use a transport different from the primary group.
- Added a Russian primary README and retained the English documentation as a
  separate language version.
- Fixed fresh Windows IKEv2 clients rejecting valid credentials when the ACME
  certificate used a new intermediate CA. The server now loads and sends the
  complete certificate chain instead of only the leaf certificate.
- Simplified the Policy Routing page by removing oversized summary cards and
  reducing the domain-routing engine to its status, explanation and mode
  switch.
- Fixed inbound EAP password changes leaving an older credential loaded in
  charon. Credential updates now clear and reload the full set without
  restarting strongSwan or established tunnels.
- Switched generated EAP secret sections to stable numeric names so valid user
  identities never become settings-parser section names.

## 1.0.0-r6 - 2026-06-21

- Added an experimental reliable domain-routing engine based on sing-box
  FakeIP and nftables TProxy. Selected domains keep stable virtual addresses,
  while only covered LAN and inbound-IKEv2 sources use the outbound tunnel.
- Kept the existing PBR nftset policy as a migration fallback for connections
  opened before FakeIP activation.
- Added transactional DNS cutover, persistent FakeIP mappings, automatic
  rollback, boot restoration and safe refresh after domain or coverage changes.
- Added a LuCI switch and runtime diagnostics for the domain-routing engine.
- Fixed the LuCI engine card reading the wrong load result, which made an
  active FakeIP backend appear as legacy mode after every page reload.
- Reworked the engine card into a compact technical summary and update its
  status and action immediately after a successful switch.
- Added lightweight FakeIP invariant checks to the health loop. A missing
  sing-box service, nftables TProxy table, policy rule or dnsmasq hand-off is
  repaired without restarting PBR, WAN or the router.
- Updated Overview, dependency diagnostics, DNS upstream help and device-rule
  notifications to reflect the reliable routing engine.
- Kept sing-box and TProxy in the confirmed runtime dependency workflow instead
  of making the passive LuCI bootstrap package install kernel modules eagerly.
- Added a low-frequency outbound data-plane probe so an installed but
  non-forwarding CHILD_SA is recovered after two consecutive failures.
- Tightened the probe interval to 20 seconds and added a second independent
  endpoint, reducing stale-SA recovery time without reacting to one provider
  timeout.
- Avoided false reconnect errors when IKE_AUTH completes just after the VICI
  initiation timeout.
- Added generic per-service IPv4 network targets for applications that bypass
  DNS, with Telegram MTProto data-centre ranges as the first bundled set.
- Fixed LuCI service-chip persistence and exposed the active direct-network
  count alongside domain and service totals.
- Derived direct-IP service metadata from packaged CIDR files, added health
  repair for a missing PBR service-network rule and covered the combined
  domain/CIDR transaction with a standalone regression test.
- Added separate custom IPv4 address and CIDR entries alongside custom domains;
  both remain independent from downloaded service updates.

## 1.0.0-r5 - 2026-06-21

- Added a locked, rate-limited outbound recovery helper used by WAN hotplug
  and the health watcher, so a boot-time initiation attempted before WAN is
  ready is retried automatically once DNS can resolve the configured peer.
- Added an outbound-tunnel setting for the automatic reconnect cooldown
  (15-300 seconds).
- Re-evaluate existing connections after a domain-policy rebuild by dropping
  only conntrack entries whose destinations now belong to the managed PBR set.
  This prevents hardware-offloaded sessions from retaining an earlier WAN
  route after a service is newly selected.
- Preserve the learned domain-IP set once during an orderly shutdown and
  restore it on the next boot, so devices with warm DNS caches do not bypass
  policy routing before repeating their DNS lookups.

## 1.0.0-r4 - 2026-06-19

- Made `Installed-Size` independent of filesystem block allocation so canonical
  builds on macOS and Linux produce the same IPK bytes.
- Replaced the Gitleaks wrapper Action with a checksum-verified Gitleaks CLI
  invocation that correctly scans a repository beginning at a root commit.
- Updated pinned GitHub Actions to their Node.js 24 releases.

## 1.0.0-r3 - 2026-06-19

First public release.

- Consolidated inbound server settings into one compact card with expandable
  access, ACME and advanced connection panels.
- Moved VPN and ACME secret submission to permission-restricted temporary files
  so credentials do not appear in process command lines.
- Added ShellCheck, actionlint and Gitleaks CI checks and pinned every GitHub
  Action to an immutable commit.
- Simplified fail-closed routing to the native PBR unreachable default plus
  XFRM policy enforcement, removing the duplicate nftables drop layer and
  redundant PBR/firewall restarts.
- Made strongSwan the sole owner of automatic outbound reconnects; health
  monitoring now observes and repairs derived state without competing IKE
  initiations.
- Split detached-action and routing-invariant logic into reusable backend
  modules, and fixed nftset discovery for the OpenWrt nft CLI.
- Kept standard DoH as the default and marked HTTP/3/DoQ transports as
  experimental.
- Added opt-in DNS upstream management with provider presets for plain DNS,
  DoT, DoH, HTTP/3, DoQ and DNSCrypt, including live validation and rollback.
- Corrected VPN-user traffic directions so download and upload are shown from
  the remote user's perspective.
- Switched the project license to the MIT License and added complete
  third-party domain-source documentation.
- Stopped bundling the locally cached TikTok list; it is now fetched only
  through the optional external-list integration.
- Aligned the source tree with the `ikev2-manager-openwrt` repository name:
  LuCI domain components and router runtime files now use explicit
  `ikev2-manager` directory names.
- Renamed the sysupgrade keep-file source to `ikev2-manager`.
- Moved the inbound-server state into its configuration card.
- Reworked VPN user rows into compact responsive cards with icon actions and
  clearer session traffic labels.
- Replaced the full dependency matrix with four priority checks and an
  expandable diagnostic report.
- Reviewed Russian UI terminology and removed awkward literal translations.
- Added the public-release compatibility gate, hardware capability report,
  safe dependency preflight, CI and sanitized support documentation.
- Unified long-running LuCI operations around serialized background jobs,
  status polling and reliable button recovery.
