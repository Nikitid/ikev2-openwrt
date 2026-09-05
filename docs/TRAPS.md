# Traps

Failures that looked like something else and cost hours. Each one is here
because the obvious reading of the evidence was wrong, and because nothing in
the code makes the real rule visible at the point where you would break it.

Where a check now guards a trap, it is named. Add to this file whenever a bug
takes more than an hour to locate: the entry is cheaper than the second
investigation.

## rpcd resolves a path before it checks the ACL

OpenWrt symlinks `/var` to `/tmp`. A grant written as
`/var/run/ikev2-manager-client-*.in` is therefore never the path rpcd tests -
it tests `/tmp/run/...` - and every write through it is refused with
`Permission denied`. Grant both forms.

What made this expensive: `ubus call session access` compares the path
**literally**, so it answered `true` for the exact string the real call was
refused on. The permission looked present while it was absent. Verify a
permission by making the call, not by asking `session.access`.

Guarded by `scripts/check-luci-exec-acl.sh`.

## `ubus -S` is silent about failure

`ubus -S call ...` prints nothing on success *and* nothing on a refusal.
Reading an empty result as success turned the trap above into two wrong
diagnoses and two pointless releases. Always check the exit status.

## LuCI resource names must carry a version

LuCI requests a view as `<name>.js?v=<luci version>`, and that version does not
move when this package is upgraded. A resource whose file name never changes is
served from the browser cache across an upgrade: new code, old page - or worse,
new page code against cached stylesheet rules, which renders a layout that
matches neither.

Every view and the shared module carry a `-vN` suffix; bump it when the file
changes shape. Superseded names are deleted in `postinst`, or they accumulate.

Guarded by `scripts/check-luci-ui-contract.sh`, which also fails when pages
disagree about which build of the shared module they want.

## The page-wide control floor outranks a bare class

`shared.js` sets `.ikev2-page textarea { min-height: 6rem }`. That selector is a
class plus an element; a rule written as `.ikev2-domain-editor { min-height:
19rem }` is a class alone and loses. The editors silently stayed at the floor
for two releases while the rule sat there looking correct.

Scope component rules to `.ikev2-page .ikev2-thing`, and when two rules have
equal weight remember that the later one wins - an override must come *after*
the rule it narrows.

## Marks route the tunnel, not source addresses

`ip rule` selects the tunnel table by fwmark. Binding a socket to the tunnel
address does not put it in the tunnel:

```
ip route get 8.8.8.8 from <tunnel vip>  ->  via <wan gateway> dev <wan>
```

Only `SO_BINDTODEVICE` works, which on these routers means `curl --interface
ipsec-out`. A probe that binds the source address instead answers about the WAN
path while looking like it answers about the tunnel - a false healthy. The
tunnel DNS health probe uses a temporary sing-box worker with
both bootstrap and DoH bound to that interface. A successful empty HTTP request
to a DoH endpoint is not a successful DNS query.

## BusyBox is not coreutils

Router scripts run against BusyBox applets. Notably **there is no `timeout`
applet** - see `bounded_nslookup` in `ikev2-domain-router.sh` for the pattern
used instead. `od` and `stat` are absent too. Use `date -r FILE +%s` for file
modification time on the supported router; lock recovery must work without
`stat`. A GNU-only option passes every check on a developer machine and behaves
differently on the router.

Guarded by `scripts/check-busybox-compat.sh`; extend it rather than relying on
review.

## `with_lock` takes a function, not a command line

`with_lock` runs its first argument as a shell function. Writing
`with_lock pause pause_routing` makes the shell look for a program named
`pause`. Pinned by a check that every `with_lock` target is a function defined
in the same file.

## nftables reads its own output back differently

A rule written as `!= 0` is listed back as `!= 0x00000000`. A check that
compares the listed rule to the written string reports a healthy runtime as
missing. Compare canonical forms, or match loosely.

## The health watcher will undo what you just did

`ikev2-health` repairs the FakeIP runtime on its own schedule. Any state change
that looks like breakage - pausing routing, for instance - has to be visible to
the watcher, or it is reverted within seconds and the failure appears to come
from nowhere. Guards for this exist in both the Manager and Site Link watchers;
keep them ahead of the repair, not after it.

## Two build paths ship the package

`scripts/stage-package.sh` builds locally; the release workflow builds from the
SDK `Makefile`. Anything that must reach a router has to be installed by
**both**. The version stamp was added to the packer only, so every release from
1.7.0 to 1.8.0 shipped without it and the page reported an unknown version.

Guarded by `scripts/check-version-sync.sh`.

## A released tag does not reach the routers

`OPENWRT_FEED_DISPATCH_TOKEN` is not configured, so the release workflow's feed
notification step reports success while the dispatch never arrives. Until the
secret exists, the feed must be rebuilt by hand after every tag:

```
gh workflow run "Build feed" --repo Nikitid/openwrt-feed
```

`scripts/release.sh` does this as part of the sequence.

## Verify the page, not the parse

A syntactically valid LuCI view can still die at render: a helper that is not
exported, a control built before its dependency, an option read from the wrong
module. Every command-line check passes while the page shows nothing. The
render harnesses under `scripts/` stub the LuCI environment and actually call
`render()`; add a page to them when you add a page.

## Conntrack deletion does not close a userspace proxy connection

An established TProxy socket can continue on the old outbound after conntrack
is deleted. On the supported kernel, `ss -K` returned success without closing
the socket. Device changes therefore use sing-box's authenticated loopback API
to close matching source connections before clearing conntrack. Test an active
connection and an unrelated control connection; exit status alone proves
neither closure nor isolation.

Guarded by `scripts/test-audit-regressions.py` and router data-plane checks.
