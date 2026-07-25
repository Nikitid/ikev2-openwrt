# IKEv2 Manager для OpenWrt

[English](README.en.md)

[![CI](https://github.com/Nikitid/ikev2-openwrt/actions/workflows/ci.yml/badge.svg)](https://github.com/Nikitid/ikev2-openwrt/actions/workflows/ci.yml)
[![Лицензия: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

LuCI-приложение для исходящего IKEv2-туннеля, входящего IKEv2-сервера и
выборочной маршрутизации IPv4-трафика в OpenWrt. В качестве удалённого шлюза
можно использовать
[ikev2-manager-ubuntu](https://github.com/Nikitid/ikev2-manager-ubuntu).

## Возможности

- исходящий IKEv2/EAP-клиент через XFRM-интерфейс;
- маршрутизация сервисов, доменов, IPv4-адресов и CIDR через VPN;
- режимы устройств: выбранные домены, весь трафик или прямой WAN;
- FakeIP/TProxy для доменов и fail-closed PBR;
- входящий IKEv2/EAP-сервер с глобальными и индивидуальными правилами доступа
  пользователей к роутеру, отдельным публичным портам, Интернету и локальным
  IPv4-адресам;
- виджет состояния исходящего туннеля, PBR и активных входящих VPN-клиентов
  в Status -> Overview;
- DNS upstream через UDP, TCP, DoT, DoH, HTTP/3, DoQ или DNSCrypt;
- ACME и интерфейс LuCI на русском и английском языках.

## Требования

- официальный OpenWrt `24.10.x`;
- firewall4/nftables, IPv4 WAN и официальные репозитории пакетов;
- место для strongSwan, PBR, sing-box, `dnsmasq-full` и `dnsproxy`.

OpenWrt `25.12.x` поддерживается экспериментально на проверенных целях
`mediatek/filogic` и `aarch64_cortex-a53`. Vendor firmware, snapshots и
firewall3 не поддерживаются.

## Установка

### OpenWrt 24.10

Скачайте последний `luci-app-ikev2-manager_*_all.ipk` из
[Releases](https://github.com/Nikitid/ikev2-openwrt/releases) и
загрузите его через:

```text
System -> Software -> Upload Package
```

После установки откройте:

```text
Services -> IKEv2 Manager -> Overview
```

Установите зависимости, выберите WAN и защищаемые сети, включите управляемый
режим и настройте туннель. CLI-установка, миграция и восстановление описаны в
[Operations](docs/OPERATIONS.md).

### OpenWrt 25.12

```sh
wget -O /tmp/install-ikev2-manager.sh \
  https://github.com/Nikitid/ikev2-openwrt/releases/latest/download/install-openwrt25.sh
sh /tmp/install-ikev2-manager.sh
```

Установщик проверяет публичный ключ релиза и подключает подписанный стабильный
общий APK-репозиторий приложений Nikitid без перенаправлений. Репозиторий
сохраняет совместимость с прежним ключом и путём
`/etc/apk/repositories.d/ikev2-manager.list`. Если приложение было установлено
до версии `1.1.9`, выполните эти две команды ещё один раз: установщик обновит
пакет и переведёт существующую установку на стабильный репозиторий.

Последующие обновления:

```sh
apk update
apk upgrade luci-app-ikev2-manager
```

Команда обновляет только IKEv2 Manager, а не все системные пакеты.

## Маршрутизация

Доменные правила используют sing-box FakeIP и nftables TProxy. Правила для
IPv4-адресов и CIDR работают без DNS. Если исходящий туннель недоступен,
выбранный трафик блокируется, а остальной продолжает идти через WAN.

Для доменной маршрутизации клиенты должны использовать DNS роутера. Browser
DoH, Android Private DNS и Apple Private Relay могут обходить классификацию.

## Списки доменов

Списки проекта находятся в `luci-ikev2-domains/local-services/`.
Дополнительные списки загружаются из
[`itdoginfo/allow-domains`](https://github.com/itdoginfo/allow-domains) и не
входят в IPK. Условия использования описаны в [NOTICE](NOTICE).

## Сборка

```sh
./scripts/ci-check.sh
```

Артефакты создаются в `dist/`.

## Документация

- [Архитектура](docs/ARCHITECTURE.md)
- [Эксплуатация](docs/OPERATIONS.md)
- [Общий APK-репозиторий](docs/SHARED_APK_FEED.md)
- [Безопасность](SECURITY.md)
- [Участие в разработке](CONTRIBUTING.md)
- [Журнал изменений](CHANGELOG.md)

## Лицензия

[MIT](LICENSE). Дополнительные загружаемые списки описаны в [NOTICE](NOTICE).
