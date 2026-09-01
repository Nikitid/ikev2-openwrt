# Runtime helpers

POSIX shell that runs on the router as root. Read `../docs/TRAPS.md` before
changing anything here; most of its entries were paid for in this directory.

Locate a function with `grep -n <name> ../docs/INDEX.md` instead of reading a
file whole - `ikev2-manager-system.sh` alone is 4000 lines.

## Rules

- Target BusyBox applets, not coreutils. There is no `timeout`; use the
  `bounded_*` pattern. Verify an option on a router before relying on it, and
  extend `scripts/check-busybox-compat.sh`.
- Pass a function name to `with_lock`, never a command line.
- Keep every state change reversible: take a snapshot, validate, roll back on
  failure. `rollback_dns_transaction` is the reference shape.
- Report through `key=value` lines on stdout. The pages parse them; free prose
  is not a status.
- Run anything slow detached, write progress to an action status file, and let
  the page poll it. Never block an rpcd call.
- Guard state the health watcher repairs, or it reverts you within seconds.
- Do not restart WAN, PBR or the router as a side effect of an apply.

## Adding a subcommand

1. Add the case to the helper's dispatcher.
2. Grant it in `luci-ikev2-manager/acl.json`, or the page gets `Permission
   denied` - `scripts/check-luci-exec-acl.sh` fails when you forget.
3. Install the file from **both** `scripts/stage-package.sh` and the SDK
   `Makefile`.
4. Cover it in `scripts/test-*.sh` and mutate the test to prove it fails.
