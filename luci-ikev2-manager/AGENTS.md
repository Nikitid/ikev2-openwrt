# LuCI pages

Five views plus a status widget, built on `shared.js` rather than stock CBI.
Read `../docs/TRAPS.md` first - four of its entries are about this directory.

Locate a function with `grep -n <name> ../docs/INDEX.md`; `shared.js` is 2400
lines and reading it whole costs more than the change usually does.

## Rules

- Name every view and the shared module with a `-vN` suffix, and bump it when
  the file changes shape. LuCI's cache key does not move when this package is
  upgraded, so a stable name serves stale code to the browser.
- Keep `menu.json`, `acl.json` and the `Makefile` agreeing on that name.
- Grant every helper call and input-file write in `acl.json`. rpcd resolves a
  path before checking it, so a `/var/...` grant needs its `/tmp/...` twin.
- Call LuCI's global `_()`; never assign `window._` or keep a dictionary in a
  page. The language is the one LuCI uses, not a per-page setting.
- Add a Russian entry to `../po/ru/ikev2-manager.po` for every new string,
  including labels that reach `_()` through a variable and backend messages the
  page shows. An id must not start or end with a space: LuCI trims it before
  the lookup, so such an entry is never found. Use a `%s` placeholder instead.
- Run actions through `common.runAction` / `common.runJob`. They own the busy
  state, the spinner and the inline result; a bare `fs.exec` owns none of it.
  The busy label belongs in the button; show a backend step beside it with
  `common.showProgress`, which drops what the button already says. Relabel or
  disable a button in `onSuccess`, never inside `run`: the button is restored
  between the two. A system action reports through `action-status`, so it
  goes through `runJob`; `runDepsJob` polls the dependency installer only.
- Tie every Save or Apply button to its form with `common.trackChanges` and
  call `reset()` after a successful save. It stays grey while nothing it would
  send has changed; `scripts/check-luci-ui-contract.sh` lists them.
- Report failures in the section's own inline result, never a global
  notification.
- Scope a component's CSS as `.ikev2-page .ikev2-thing`. A bare class loses to
  the page-wide control rules, and an override must come after what it narrows.
- Prefer one grid over nested flex containers when rows must line up: a wrapper
  sized by its own content misaligns every row differently.

## Before you call it done

Render it. `scripts/test-luci-client-ui.sh` stubs the LuCI environment and
calls `render()`; a page that parses can still die there. Add new pages to the
harness, and add a contract assertion for whatever you just fixed - then break
it deliberately and confirm the check fails.
