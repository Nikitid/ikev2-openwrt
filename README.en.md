# IKEv2 Manager for OpenWrt

[Русский](README.md)

[![CI](https://github.com/Nikitid/ikev2-openwrt/actions/workflows/ci.yml/badge.svg)](https://github.com/Nikitid/ikev2-openwrt/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

LuCI application for an outbound IKEv2 tunnel, an inbound IKEv2 server and
selective IPv4 routing on OpenWrt. It can use
[ikev2-manager-ubuntu](https://github.com/Nikitid/ikev2-manager-ubuntu) as the
remote gateway.

## Features

- outbound IKEv2/EAP client over an XFRM interface;
- VPN routing for services, domains, IPv4 addresses and CIDR networks;
- per-device modes for selected domains, full tunnel or direct WAN;
- FakeIP/TProxy domain routing and fail-closed PBR;
- inbound IKEv2/EAP server with global and per-user access to the router,
  selected public router ports, Internet and selected local IPv4 destinations;
- Status Overview widget for the outbound tunnel, PBR and active inbound VPN
  clients;
- DNS upstream over UDP, TCP, DoT, DoH, HTTP/3, DoQ or DNSCrypt;
- ACME and Russian/English LuCI interfaces.

## Requirements

- official OpenWrt `24.10.x`;
- firewall4/nftables, IPv4 WAN and official package feeds;
- storage for strongSwan, PBR, sing-box, `dnsmasq-full` and `dnsproxy`.

OpenWrt `25.12.x` support is experimental and limited to the validated
`mediatek/filogic` and `aarch64_cortex-a53` targets. Vendor firmware, snapshots
and firewall3 are not supported.

## Installation

### OpenWrt 24.10

Download the latest `luci-app-ikev2-manager_*_all.ipk` from
[Releases](https://github.com/Nikitid/ikev2-openwrt/releases) and upload
it through:

```text
System -> Software -> Upload Package
```

Then open:

```text
Services -> IKEv2 Manager -> Overview
```

Install the dependencies, select the WAN and protected networks, enable
managed mode and configure the tunnel. CLI installation, migration and
recovery are covered in [Operations](docs/OPERATIONS.md).

### OpenWrt 25.12

```sh
wget -O /tmp/install-ikev2-manager.sh \
  https://github.com/Nikitid/ikev2-openwrt/releases/latest/download/install-openwrt25.sh
sh /tmp/install-ikev2-manager.sh
```

The installer verifies the release public key and registers the shared signed
stable APK repository for Nikitid OpenWrt applications without redirects. The
legacy key and `/etc/apk/repositories.d/ikev2-manager.list` path remain
compatible. If the application was installed before version `1.1.9`, run these
two commands once more: the installer upgrades the package and moves the
existing installation to the stable repository.

Later updates:

```sh
apk update
apk upgrade luci-app-ikev2-manager
```

This upgrades only IKEv2 Manager, not all system packages.

## Policy routing

Domain rules use sing-box FakeIP and nftables TProxy. IPv4 and CIDR rules work
without DNS. If the outbound tunnel is unavailable, selected traffic is
blocked while unrelated traffic continues through WAN.

Clients must use router DNS for domain routing. Browser DoH, Android Private
DNS and Apple Private Relay can bypass classification.

## Domain lists

Project lists are stored in `luci-ikev2-domains/local-services/`. Optional
lists are downloaded from
[`itdoginfo/allow-domains`](https://github.com/itdoginfo/allow-domains) and are
not included in the IPK. See [NOTICE](NOTICE) for their terms.

## Build

```sh
./scripts/ci-check.sh
```

Artifacts are written to `dist/`.

## Documentation

- [Architecture](docs/ARCHITECTURE.md)
- [Operations](docs/OPERATIONS.md)
- [Shared APK feed](docs/SHARED_APK_FEED.md)
- [Security](SECURITY.md)
- [Contributing](CONTRIBUTING.md)
- [Changelog](CHANGELOG.md)

## License

[MIT](LICENSE). Optional downloaded lists are described in [NOTICE](NOTICE).
