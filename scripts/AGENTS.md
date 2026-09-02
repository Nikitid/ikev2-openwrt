# Checks

`ci-check.sh` runs all of them. Two families: `check-*.sh` for invariants that
hold regardless of behaviour, `test-*` for behaviour against stubbed UCI and a
stubbed LuCI environment.

## Rules

- Mutate every new check before trusting it. Break the thing it guards, watch
  it fail, restore. A check that has never failed is decoration - several here
  passed for months while the bug they covered was live.
- Assert the invariant, not the wording. A check pinned to an exact line breaks
  on reformatting and teaches people to edit the check instead of the code.
- Add the check in the same change as the fix, and name the failure it would
  have caught in a comment.
- Keep them POSIX and offline: no network, no router, no clock.
- Wire new checks into `ci-check.sh` or nothing runs them.

## Generated files

`docs/INDEX.md` comes from `gen-index.sh`; `check-index.sh` fails when the
committed copy has drifted. Regenerate and commit it when you add or rename a
function in a file over 300 lines.

## Shared scripts

`gen-index.sh` and `check-index.sh` carry a `# template:` marker and are
vendored from `repo-templates/templates/shared/`. Each repository keeps its own
copy so it stays buildable alone, which means a fix applied only here leaves
the siblings behind. Change the template, then run
`repo-templates/scripts/sync-templates.sh --update`.
