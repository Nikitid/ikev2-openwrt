# Repository Guidelines

## Scope

These instructions apply to the `ikev2-openwrt` repository. Follow the
current user request first. Use only the current project name; do not restore
legacy names, compatibility aliases, symlinks, or migration scaffolding unless
explicitly requested.

## Start of Work

- Read `docs/MAP.md` to find the files a task touches, and `docs/TRAPS.md`
  before changing runtime or LuCI code. Both are short and both are load-bearing.
- Locate a function with `grep -n <name> docs/INDEX.md` rather than reading a
  file whole. Four source files here cost 13k-47k tokens each to read.
- Open a section of `docs/ARCHITECTURE.md` or `docs/OPERATIONS.md` when the task
  needs it. Do not read either end to end, and do not read `CHANGELOG.md` for
  orientation - it is release history, not documentation.
- Read the `AGENTS.md` in the directory you are editing. Each one carries the
  rules that directory has already been burned by.
- Run `git status -sb`, inspect the current branch and remotes, and preserve
  unrelated user changes.
- Search for existing implementations with `rg` before introducing a new
  pattern.

## Development and Verification

- Keep changes scoped and consistent with existing shell, JavaScript, LuCI,
  OpenWrt, and packaging conventions.
- Before changing UI, inspect adjacent project tabs, pages, and components.
  Match existing UX/UI patterns for structure, spacing, button order, text,
  form behavior, validation errors, and save/apply/cancel flows. Do not
  introduce a new design or UX pattern unless explicitly requested.
- Use repository checks and build scripts rather than ad hoc substitutes:
  `scripts/ci-check.sh` for the full suite, `scripts/release.sh` to release,
  `scripts/deploy-luci.sh` to try a page on a router without a release, and
  `scripts/health-check.sh` for a read-only sweep.
- Router-side scripts run against BusyBox applets, not GNU coreutils. Developer
  and CI machines provide the GNU versions, so a GNU-only option passes every
  test and then behaves differently on the router. Verify option support on a
  router before using it and extend `scripts/check-busybox-compat.sh`.
- Do not assign `window._`. Each LuCI resource shadows the project translator
  locally, otherwise the project map replaces strings in every other
  application on pages that load our resources.
- Run narrow checks while iterating and the broadest relevant check before
  completion. Update documentation and the changelog when behavior,
  configuration, deployment, or operator workflow changes.
- Mutate a new check before trusting it: break what it guards, watch it fail,
  restore. Regenerate `docs/INDEX.md` with `scripts/gen-index.sh` when you add
  or rename a function in a large file, and add to `docs/TRAPS.md` whenever a
  bug takes more than an hour to find.
- For LuCI long-running actions, use the established detached-job,
  status-file polling, inline-result, and guaranteed busy-state cleanup
  patterns.

## Router Safety and Deployment

- The standing rule is: do not reboot the router and do not restart WAN.
- Preserve the active management path. Avoid disruptive changes to routing,
  VPN, firewall, Wi-Fi, SSH, and management interfaces.
- Deploy project changes to the target host or router for testing without
  waiting for additional approval.
- Deploy with the repository build/check workflow, copy IPKs with `scp -O`
  where required, install with `opkg`, and verify the installed package
  version and preserved configuration.
- After deployment, verify relevant service health, PBR/FakeIP state, and
  active inbound/outbound IKEv2 SAs. Domain-routing checks must cover
  DNS/FakeIP or nftset population, route/mark behavior, and real data-plane
  traffic—not only generated list files.

## Documentation Split

- Documentation committed here is public. Keep router names, addresses,
  hostnames, key paths and deployment state out of it.
- Site-specific runbooks belong in `docs/private/`, which is ignored and which
  `scripts/check-public-tree.sh` refuses to let become tracked.

## Git, Releases, and Secrets

- Do not commit, push, tag, publish releases, or deploy unless explicitly
  requested.
- Before publishing, inspect the full diff, untracked and ignored files, build
  artifacts, and Git history; run relevant tests and secret scanning.
- Never print or commit VPN credentials, tokens, private keys, certificates,
  router backups, or private network identifiers.
- Use concise outcome-based commit messages. Verify local and remote HEAD after
  pushing, and verify release artifacts and checksums when publishing.
