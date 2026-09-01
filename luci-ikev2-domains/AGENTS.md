# Policy routing page and destination helpers

`editor.js` is the Policy Routing view: it follows `../luci-ikev2-manager/AGENTS.md`
in full, including the `-vN` resource naming and the ACL rules.

The shell files here are runtime helpers despite living beside a view, so
`../ikev2-manager-runtime/AGENTS.md` applies to them.

- `community-domains.sh` owns the service catalogue and the destination lists.
- `ikev2-devices.sh` reports the LAN inventory the pages read.
- `local-services/*.lst` are packaged service definitions; user-created ones
  live on the router and are never overwritten by an update.
