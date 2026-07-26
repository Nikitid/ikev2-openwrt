# Shared OpenWrt 25.12 APK feed

The signed feed for the Nikitid OpenWrt applications lives in its own
repository, [`Nikitid/openwrt-feed`](https://github.com/Nikitid/openwrt-feed).
This repository is a member of that feed, not its owner.

It previously lived on the `apk-feed` branch here. That made a URL recorded in
`/etc/apk/repositories.d` on every installed router depend on the name and
lifetime of one application repository, which the rename to `ikev2-openwrt`
made concrete.

## What this repository does

A stable tag builds and signs `luci-app-ikev2-manager` with the shared
publisher key and publishes the APK as a GitHub Release asset. That is all.
It does not download sibling applications and does not build an index, so a
release no longer depends on any other application being ready.

The release then notifies the feed repository. That notification is best
effort: the feed also rebuilds daily and on manual dispatch, so a missing or
expired token delays the index instead of failing the release.

## What the feed repository does

It downloads the current release APK of every member application, verifies each
signature against the publisher key, builds and signs `packages.adb` over them,
and publishes the result to its `feed` branch. A member without a published
release is skipped.

## Trust identity

One P-256 publisher key signs every member package and the index. apk binds a
key to neither a package nor a repository, so a router needs exactly one trust
anchor for all applications.

```text
SHA-256: f27474d9261f1084350cf4ba34ecdff29e533769c36483d8dd85566e30a6a703
```

`keys/nikitid-openwrt-release.pem` is the tracked public key and
`keys/ikev2-manager-release.pem` is a byte-identical alias kept for
installations that still hold the older file name. The private key is available
only to release automation through the `OPENWRT_APK_SIGNING_KEY` secret, which
must be configured identically in every member repository and in the feed
repository.

## Installation and migration

```sh
wget -O /tmp/nikitid-feed.sh \
  https://raw.githubusercontent.com/Nikitid/openwrt-feed/feed/install.sh
sh /tmp/nikitid-feed.sh luci-app-ikev2-manager
```

Routers installed before the feed moved keep working: the package postinst
rewrites `/etc/apk/repositories.d/ikev2-manager.list` to the shared
`nikitid-openwrt.list` when, and only when, it still holds one of this
project's own previous URLs. A list pointing anywhere else is left untouched,
and an existing shared list is never overwritten. Trusted keys are not touched,
because the material is identical under either file name.

Updates stay scoped to the package:

```sh
apk update
apk upgrade luci-app-ikev2-manager
```

No system-wide `apk upgrade` is required or performed.
