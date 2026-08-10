'use strict';
'require baseclass';
'require fs';

var LANG_KEY = 'ikev2-manager-language';
var nativeTranslate = (typeof window !== 'undefined' && window._) ? window._ : null;

var ru = {
	'%d bypass settings': 'Настроек обхода: %d',
	'%d excluded devices': 'Исключённых устройств: %d',
	'%d packets': '%d пакетов',
	'Android': 'Android',
	'Apple': 'Apple',
	'Windows': 'Windows',
	'Apple and Android downloads contain the VPN password. Store them securely and delete them after installation.': 'Файлы для Apple и Android содержат пароль VPN. Храните их безопасно и удалите после установки.',
	'Applying DNS restarts the managed resolver and clears its in-memory optimistic cache. The previous configuration is restored if validation fails, but name resolution can pause briefly during the switch. Do not use Apply as a connectivity repair action.': 'Применение DNS перезапускает управляемый резолвер и очищает его оптимистичный кэш в памяти. При ошибке предыдущая конфигурация восстановится, но во время переключения разрешение имён может ненадолго прерваться. Не используйте «Применить» как способ починить связь.',
	'Applying DNS segment...': 'Применяю DNS-сегмент...',
	'Capture debug log for 60 seconds': 'Собирать отладочный журнал 60 секунд',
	'Capturing FakeIP diagnostics...': 'Собираю диагностику FakeIP...',
	'Blocked services may stop opening for these devices.': 'На этих устройствах могут перестать открываться заблокированные сервисы.',
	'Capture a short, separate strongSwan trace while the affected client tries to connect. The capture stops automatically and does not increase system-log verbosity.': 'Запишите отдельную короткую трассировку strongSwan во время попытки подключения проблемного клиента. Сбор остановится автоматически и не увеличит подробность системного журнала.',
	'Capture completed.': 'Сбор завершён.',
	'Capture failed.': 'Не удалось собрать диагностику.',
	'Capture for 60 seconds': 'Записать 60 секунд',
	'Capturing inbound IKE attempts...': 'Записываю входящие попытки IKE...',
	'Client profile for %s': 'Профиль клиента %s',
	'Client profiles': 'Профили клиента',
	'Close': 'Закрыть',
	'Could not generate client profile': 'Не удалось создать профиль клиента',
	'Could not read diagnostic report': 'Не удалось прочитать отчёт диагностики',
	'Could not refresh DNS segments': 'Не удалось обновить DNS-сегменты',
	'DNS segment applied.': 'DNS-сегмент применён.',
	'DNS segment failed.': 'Не удалось применить DNS-сегмент.',
	'Diagnostic completed.': 'Диагностика завершена.',
	'Diagnostic failed': 'Диагностика завершилась ошибкой',
	'Diagnostic timed out': 'Диагностика не завершилась вовремя',
	'Debug': 'Отладка',
	'Delete segment': 'Удалить сегмент',
	'Delete this DNS segment?': 'Удалить этот DNS-сегмент?',
	'Destination DNS segments': 'DNS-сегменты назначений',
	'Devices without DPI processing': 'Устройства без обработки DPI',
	'Domain suffixes': 'Суффиксы доменов',
	'Domains, upstreams and bootstrap servers are required.': 'Необходимо указать домены, внешние DNS и bootstrap-серверы.',
	'Download VPNv2 XML': 'Скачать VPNv2 XML',
	'Download application': 'Скачать приложение',
	'Downloading...': 'Скачиваю...',
	'Windows application downloaded.': 'Приложение Windows скачано.',
	'VPN setup for Windows': 'Установка VPN для Windows',
	'Download the application once, then open any downloaded VPNv2 XML profile in it.': 'Скачайте приложение один раз, затем открывайте в нём любые загруженные профили VPNv2 XML.',
	'Download this XML, then select it in Nikitid IKEv2 Setup. The same application works with profiles from any server.': 'Скачайте этот XML и выберите его в Nikitid IKEv2 Setup. Одно приложение работает с профилями любых серверов.',
	'Download mobileconfig': 'Скачать mobileconfig',
	'Download iOS profile': 'Скачать профиль iOS',
	'Download Windows profile': 'Скачать профиль Windows',
	'Download Android profile': 'Скачать профиль Android',
	'Download setup details': 'Скачать параметры',
	'Errors only': 'Только ошибки',
	'Every device follows the active Zapret strategy.': 'Все устройства следуют активной стратегии Zapret.',
	'Excluded traffic: %s': 'Исключённый трафик: %s',
	'FakeIP resolver log level': 'Уровень журнала FakeIP-резолвера',
	'Force a device fully through the VPN, past domain routing, or past every project-managed routing, DNS and DPI mechanism.': 'Направьте устройство целиком через VPN, в обход доменной маршрутизации или выведите его из-под всей управляемой проектом маршрутизации, DNS и DPI.',
	'Generating...': 'Создаю...',
	'Identity': 'Идентичность',
	'In Reliable mode, selected domains requested by services on this router use the outbound tunnel. Tunnel transport and local management addresses remain direct.': 'В надёжном режиме выбранные домены для служб самого роутера идут через исходящий туннель. Транспорт туннеля и локальные адреса управления остаются прямыми.',
	'Inbound connection diagnostics': 'Диагностика входящих подключений',
	'Information': 'Информация',
	'Install the mobileconfig in Settings on iPhone, iPad or macOS.': 'Установите mobileconfig через настройки iPhone, iPad или macOS.',
	'Logging': 'Журналирование',
	'Matched traffic': 'Совпавший трафик',
	'Name': 'Имя',
	'New segment': 'Новый сегмент',
	'No DPI bypasses': 'Нет исключений DPI',
	'No failed attempts captured.': 'Неудачные попытки не зафиксированы.',
	'Phase': 'Фаза',
	'Profile generated. Treat the downloaded file as a password.': 'Профиль создан. Обращайтесь со скачанным файлом как с паролем.',
	'Profile generated.': 'Профиль создан.',
	'Windows VPN package generated.': 'Комплект VPN для Windows создан.',
	'Reason': 'Причина',
	'Route router services by domain policy': 'Маршрутизировать службы роутера по доменной политике',
	'Save segment': 'Сохранить сегмент',
	'Segment': 'Сегмент',
	'Segment name may contain only letters, digits and underscores.': 'Имя сегмента может содержать только буквы, цифры и подчёркивания.',
	'Send explicit domain suffixes to an independent resolver group. Each segment has its own protocol and query strategy; all unlisted names keep the global DNS policy. Suffixes cannot overlap between enabled segments, and at most eight segments can run at once. Lists are stored locally and are not replaced by domain-policy rebuilds.': 'Направляйте явно заданные суффиксы доменов в независимую группу резолверов. У каждого сегмента свой протокол и стратегия запросов; остальные имена используют глобальную DNS-политику. Суффиксы активных сегментов не должны пересекаться, одновременно могут работать не более восьми сегментов. Списки хранятся локально и не заменяются при пересборке доменной политики.',
	'Space-separated, for example: ru su': 'Через пробел, например: ru su',
	'The system log buffer is only %s KiB. Keep the normal level at Warnings and use timed diagnostics for troubleshooting.': 'Системный журнал имеет размер всего %s КиБ. Оставьте обычный уровень «Предупреждения» и используйте временную диагностику для поиска проблем.',
	'Could not download the Windows installer': 'Не удалось скачать установщик Windows',
	'Temporarily switches the FakeIP resolver to debug logging, then restores the selected normal level automatically. Starting and ending the capture restart the resolver.': 'Временно включает отладочный журнал FakeIP-резолвера, а затем автоматически возвращает выбранный обычный уровень. В начале и конце сбора резолвер перезапускается.',
	'Temporary diagnostics': 'Временная диагностика',
	'These devices keep their normal route but skip Zapret packet processing.': 'Эти устройства сохраняют обычный маршрут, но пропускают обработку пакетов Zapret.',
	'Trace': 'Трассировка',
	'Unable to update log level': 'Не удалось изменить уровень журнала',
	'Unable to update router traffic policy': 'Не удалось изменить политику трафика роутера',
	'Unable to start FakeIP diagnostics': 'Не удалось запустить диагностику FakeIP',
	'Unknown failure': 'Неизвестная ошибка',
	'Unmanaged — bypass routing, DNS and DPI': 'Не управлять — обойти маршрутизацию, DNS и DPI',
	'Unmanaged': 'Не управлять',
	'Use these values in the built-in IKEv2 EAP client.': 'Используйте эти значения во встроенном клиенте IKEv2 EAP.',
	'Use this only when the device or its upstream already handles DPI restrictions. Routing policy is not changed.': 'Используйте только если устройство или его вышестоящий канал уже обрабатывает ограничения DPI. Политика маршрутизации не меняется.',
	'VPNv2 XML includes a catch-all NRPT rule for the VPN DNS server. Import it with an MDM or the signed Windows installer; Windows does not safely install CSP XML by double-clicking it.': 'VPNv2 XML содержит общее правило NRPT для DNS VPN. Импортируйте его через MDM или подписанный установщик Windows: безопасной установки CSP XML двойным щелчком Windows не поддерживает.',
	'Warnings (recommended)': 'Предупреждения (рекомендуется)',
	'Warnings are quiet enough for normal operation. Information, debug and trace can quickly evict unrelated system events. Changing this while Reliable mode is active restarts its resolver.': 'Уровень предупреждений достаточно тихий для обычной работы. Информация, отладка и трассировка быстро вытесняют другие системные события. Изменение уровня в надёжном режиме перезапускает его резолвер.',
	'Custom…': 'Своё значение…',
	'Automatic': 'Автоматически',
	'recommended': 'рекомендуется',
	'constrained networks': 'сложные сети',
	'minimum': 'минимум',
	'no reduction': 'без уменьшения',
	'seconds': 'секунд',
	'hour': 'час',
	'hours': 'часов',
	'All IPv4 traffic (full tunnel)': 'Весь IPv4-трафик (полный туннель)',
	'Internal router networks': 'Внутренние сети роутера',
	'VPN address plan': 'Адресный план VPN',
	'Choose a detected ACME name or enter another DNS name.': 'Выберите обнаруженное имя ACME или укажите другое DNS-имя.',
	'Presets that overlap a connected router network are hidden.': 'Варианты, пересекающиеся с подключёнными сетями роутера, скрыты.',
	'Reconnect': 'Переподключить',
	'Reconnected': 'Переподключено',
	'Saving and connecting...': 'Сохраняю и подключаю...',
	'Saving and stopping...': 'Сохраняю и отключаю...',
	'Saved and connected': 'Сохранено и подключено',
	'Saved and disabled': 'Сохранено и отключено',
	'The operation continues in the background. You can use the button again.': 'Операция продолжается в фоне. Кнопкой уже можно пользоваться снова.',
	'The operation is still running in the background.': 'Операция всё ещё выполняется в фоне.',
	'Action did not start': 'Не удалось запустить операцию',
	'Still running': 'Ещё выполняется',
	'Queued...': 'В очереди...',
	'Waiting for other router actions...': 'Ожидаю завершения другой операции роутера...',
	'Another router action is still running.': 'Другая операция роутера ещё выполняется.',
	'Preparing selected domain lists...': 'Подготавливаю выбранные списки доменов...',
	'Downloading selected service lists...': 'Загружаю выбранные списки сервисов...',
	'Building the combined policy list...': 'Собираю общий список маршрутизации...',
	'Restarting policy routing...': 'Перезапускаю policy routing...',
	'Resetting application settings...': 'Сбрасываю настройки приложения...',
	'Router state restored. Shared packages required by other software were kept.': 'Состояние роутера восстановлено. Общие пакеты, нужные другим приложениям, сохранены.',
	'Pre-install packages, settings and managed routing state were restored.': 'Пакеты, настройки и маршрутизация восстановлены к состоянию до установки.',
	'Timed out waiting for another router action.': 'Истекло время ожидания другой операции роутера.',
	'Applying firewall, PBR and strongSwan...': 'Применяю правила межсетевого экрана, PBR и strongSwan...',
	'Applying settings before reconnecting...': 'Применяю настройки перед переподключением...',
	'Applying settings and stopping the tunnel...': 'Применяю настройки и отключаю туннель...',
	'Loading settings and reconnecting the outbound tunnel...': 'Загружаю настройки и переподключаю исходящий туннель...',
	'Stopping the outbound tunnel...': 'Отключаю исходящий туннель...',
	'Applying inbound server settings...': 'Применяю настройки входящего сервера...',
	'Inbound server settings applied.': 'Настройки входящего сервера применены.',
	'Settings saved and tunnel connected.': 'Настройки сохранены, туннель подключён.',
	'Settings saved and tunnel disabled.': 'Настройки сохранены, туннель отключён.',
	'Custom profile loaded.': 'Пользовательский профиль загружен.',
	'Generated profile restored.': 'Сгенерированный профиль восстановлен.',
	'Validating and loading the custom profile...': 'Проверяю и загружаю пользовательский профиль...',
	'Restoring the generated profile...': 'Восстанавливаю сгенерированный профиль...',
	'Applying router configuration...': 'Применяю конфигурацию роутера...',
	'Router configuration applied.': 'Конфигурация роутера применена.',
	'Network added to policy routing.': 'Сеть добавлена в маршрутизацию по правилам.',
	'Network removed from policy routing.': 'Сеть удалена из маршрутизации по правилам.',
	'Certificate request did not start.': 'Не удалось запустить запрос сертификата.',
	'The certificate request continues in the background. You can use the button again.': 'Запрос сертификата продолжается в фоне. Кнопкой уже можно пользоваться снова.',
	'Unable to start the PBR rebuild': 'Не удалось запустить пересборку PBR',
	'Saved; rebuild continues in the background.': 'Сохранено; пересборка продолжается в фоне.',
	'Applying...': 'Применяю...',
	'Saved.': 'Сохранено.',
	'Save failed': 'Не удалось сохранить',
	'Could not refresh device rules': 'Не удалось обновить правила устройств',
	'IPv6 fail-fast': 'Быстрый отказ IPv6',
	'active': 'активно',
	'off': 'выкл',
	'IPv6 WAN present': 'есть IPv6-WAN',
	'Dual-stack clients drop to IPv4 instead of hanging when there is no IPv6 WAN.': 'При отсутствии IPv6 в WAN устройства сразу переходят на IPv4 вместо долгого ожидания.',
	'Rebuilding the PBR list…': 'Пересборка списка PBR…',
	'%s domains active': '%s доменов активно',
	'Saved; rebuild still running — see the status line.': 'Сохранено; пересборка идёт — см. статус-строку.',
	'Rebuild failed: %s': 'Сбой пересборки: %s',
	'Unable to save: %s': 'Не удалось сохранить: %s',
	'Broad — may also route unrelated sites': 'Широкий — может вести и посторонние сайты',
	'ACME certificate': 'Сертификат ACME',
	'Issue and renew the public certificate used by VPN clients.': 'Выпуск и обновление публичного сертификата для VPN-клиентов.',
	'The public identity above must be a DNS name pointing to this router.': 'Публичное имя выше должно быть DNS-именем, указывающим на этот роутер.',
	'ACME settings rejected': 'Настройки ACME отклонены',
	'ACME settings saved.': 'Настройки ACME сохранены.',
	'Account email': 'Электронная почта',
	'Applied': 'Применено',
	'Available after runtime dependencies are installed.': 'Станет доступно после установки системных компонентов.',
	'Certificate issued.': 'Сертификат выпущен.',
	'Certificate present': 'Сертификат действует',
	'Certificate request failed.': 'Не удалось выпустить сертификат.',
	'Challenge method': 'Метод проверки',
	'Creates and owns routing, firewall and PBR on the router.': 'Создаёт и обслуживает правила маршрутизации, межсетевого экрана и PBR.',
	'DNS provider': 'DNS-провайдер',
	'DNS-01 (DNS provider API)': 'DNS-01 (API DNS-провайдера)',
	'DNS-01 works behind NAT and without port 80. HTTP-01 needs inbound TCP 80 to this router.': 'DNS-01 работает за NAT и без порта 80. HTTP-01 требует входящий TCP 80 на роутер.',
	'Done': 'Готово',
	'Failed': 'Ошибка',
	'For Timeweb just paste the API token. Multi-field providers: one VAR="value" per line.': 'Для Timeweb просто вставьте API-токен. Многополевые провайдеры: по одной VAR="value" в строке.',
	'HTTP-01 (webroot, needs inbound port 80)': 'HTTP-01 (webroot, нужен входящий порт 80)',
	'Issue the public TLS certificate remote devices use to trust this server. The identity above must be a public DNS name pointing here.': 'Выпустите публичный TLS-сертификат, которым удалённые устройства доверяют этому серверу. Идентичность выше должна быть публичным DNS-именем, указывающим сюда.',
	'No certificate': 'Сертификата нет',
	'Paste your API token here': 'Вставьте сюда API-токен',
	'Provider credentials': 'Данные DNS-провайдера',
	'Request certificate': 'Запросить сертификат',
	'Requesting...': 'Запрос...',
	'Save ACME settings': 'Сохранить настройки ACME',
	'Save server': 'Сохранить сервер',
	'Saving settings...': 'Сохранение настроек...',
	'Staging': 'Тестовый центр',
	'Stored — leave empty to keep, or paste to replace': 'Сохранено — оставьте пустым чтобы сохранить, или вставьте чтобы заменить',
	'Use the Let\'s Encrypt staging CA for testing (untrusted certs, no rate limits).': 'Использовать тестовый центр Let\'s Encrypt (сертификаты не доверенные, строгих лимитов нет).',
	'Used for the Let\'s Encrypt account and expiry notices.': 'Для аккаунта Let\'s Encrypt и уведомлений об истечении.',
	'acme.sh dns_* plugin. Timeweb needs TW_Token.': 'Плагин acme.sh dns_*. Timeweb требует TW_Token.',
	'Access policy rejected': 'Политика доступа отклонена',
	'Server settings rejected': 'Настройки сервера отклонены',
	'Apply failed': 'Сбой применения',
	'Applying configuration (firewall, PBR, strongSwan)...': 'Применяю конфигурацию межсетевого экрана, PBR и strongSwan...',
	'Configuration applied.': 'Конфигурация применена.',
	'Apply failed; see /tmp/ikev2-apply.log and logread.': 'Сбой применения; см. /tmp/ikev2-apply.log и logread.',
	'Loaded': 'Загружено',
	'Restored': 'Восстановлено',
	'Saved': 'Сохранено',
	'Restoring...': 'Восстановление...',
	'Validating...': 'Проверка...',
	'VPN server': 'VPN-сервер',
	'Inbound clients (ipsec-in)': 'Входящие клиенты (ipsec-in)',
	'Reconnect failed': 'Не удалось переподключить',
	'Session disconnected.': 'Сессия отключена.',
	'Unable to disconnect the session: %s': 'Не удалось отключить сессию: %s',
	'VPN user deleted.': 'Пользователь VPN удалён.',
	'Deleting...': 'Удаление...',
	'Unable to delete the VPN user: %s': 'Не удалось удалить пользователя VPN: %s',
	'All sessions disconnected.': 'Все сессии отключены.',
	'Unable to disconnect sessions: %s': 'Не удалось отключить сессии: %s',
	'PBR version': 'Версия PBR',
	'Fail-closed route': 'Маршрут без утечки',
	'XFRM if_id conflict': 'Конфликт XFRM if_id',
	'XFRM name conflict': 'Конфликт имён XFRM',
	'Firmware source': 'Источник прошивки',
	'Router model': 'Модель роутера',
	'OpenWrt target': 'Платформа OpenWrt',
	'Architecture': 'Архитектура',
	'Kernel': 'Ядро',
	'Package manager': 'Менеджер пакетов',
	'Package feeds': 'Репозитории пакетов',
	'Persistent storage free': 'Свободно в постоянной памяти',
	'Temporary storage free': 'Свободно во временной памяти',
	'Available memory': 'Доступная оперативная память',
	'System clock': 'Системное время',
	'Crypto acceleration': 'Аппаратное ускорение криптографии',
	'Flow offloading': 'Аппаратное ускорение трафика',
	'hardware-enabled': 'включено аппаратно',
	'software-enabled': 'включено программно',
	'detected': 'обнаружено',
	'Reserved resource conflicts': 'Конфликты зарезервированных ресурсов',
	'official': 'официальный источник',
	'ok': 'в норме',
	'none': 'нет',
	'Server saved, but the access policy failed: %s': 'Сервер сохранён, но политика доступа не применилась: %s',
	'apply failed': 'ошибка применения',
	'Enabled — no certificate': 'Включён — нет сертификата',
	'Enabled — not loaded': 'Включён — не загружен',
	'Unknown': 'Неизвестно',
	'healthy': 'в норме',
	'Settings saved.': 'Настройки сохранены.',
	'Choose the WAN uplink and the networks this app protects. Firewall zones are detected automatically.': 'Выберите подключение к интернету и сети, для которых приложение управляет маршрутизацией. Зоны межсетевого экрана определяются автоматически.',
	'The internet uplink. Receives UDP 500/4500 when the inbound server is enabled.': 'Подключение к интернету. При включённом входящем сервере принимает UDP 500 и 4500.',
	'Networks whose selected domains use the outbound tunnel.': 'Сети, чьи выбранные домены идут через исходящий туннель.',
	'Device exceptions': 'Исключения устройств',
	'Device rules': 'Правила устройств',
	'Keep inclusions and exclusions in one list. Excluded devices can independently bypass project PBR, DNS interception and Zapret.': 'Включения и исключения собраны в одном списке. Для исключённого устройства можно независимо отключить PBR проекта, перехват DNS и обработку Zapret.',
	'No device rules': 'Нет индивидуальных правил',
	'All devices use the default PBR, DNS and Zapret policies.': 'Все устройства используют стандартные политики PBR, DNS и Zapret.',
	'Type': 'Тип',
	'Inclusion': 'Включение',
	'Exclusion': 'Исключение',
	'Include — all traffic through VPN': 'Включение — весь трафик через VPN',
	'Exclude from project PBR': 'Исключить из PBR проекта',
	'Use the device DNS without interception': 'Не перехватывать DNS устройства',
	'Bypass Zapret processing': 'Не обрабатывать через Zapret',
	'Force a device fully through the VPN (Full route) or fully past it (Exclude), regardless of the domain list.': 'Направьте весь трафик устройства через VPN или всегда отправляйте его напрямую через WAN независимо от списка доменов.',
	'No device exceptions': 'Нет исключений устройств',
	'Every protected network follows the domain policy. Add a rule only for a device that needs a different mode.': 'Все защищаемые сети следуют доменной политике. Добавляйте правило только для устройства с другим режимом.',
	'This installs PBR, strongSwan, dnsmasq-full and XFRM packages. VPN and routing stay disabled until managed mode is enabled.': 'Устанавливает PBR, strongSwan, dnsmasq-full и XFRM-пакеты. VPN и маршрутизация выключены до включения управляемого режима.',
	'This installs PBR, strongSwan, dnsmasq-full, dnsproxy and XFRM packages. VPN and routing stay disabled until managed mode is enabled.': 'Устанавливает PBR, strongSwan, dnsmasq-full, dnsproxy и XFRM-пакеты. VPN и маршрутизация выключены до включения управляемого режима.',
	'Encrypted DNS proxy': 'Прокси защищённого DNS',
	'No networks available': 'Нет доступных сетей',
	'These networks participate in domain-based VPN routing. Add another router network from the list.': 'Эти сети участвуют в доменной VPN-маршрутизации. Добавьте ещё одну сеть роутера из списка.',
	'Save and connect': 'Сохранить и подключить',
	'missing': 'нет',
	'Creating a recovery backup...': 'Создаю резервную копию...',
	'Updating package lists...': 'Обновляю списки пакетов...',
	'Replacing dnsmasq with dnsmasq-full...': 'Заменяю dnsmasq на dnsmasq-full...',
	'Installing strongSwan, PBR and XFRM packages...': 'Устанавливаю strongSwan, PBR и XFRM-пакеты...',
	'All runtime dependencies installed.': 'Все зависимости установлены.',
	'Dependency repair failed package checks; the previous runtime packages were kept': 'Восстановленные пакеты не прошли проверку зависимостей; предыдущие системные компоненты сохранены.',
	'Installed packages failed dependency checks; the pre-install state was restored': 'Установленные пакеты не прошли проверку зависимостей; исходное состояние восстановлено.',
	'Installed packages failed dependency checks and rollback failed; see /tmp/ikev2-manager-deps.log': 'Установленные пакеты не прошли проверку зависимостей, а откат завершился ошибкой; см. /tmp/ikev2-manager-deps.log.',
	'Packages installed, but some checks still report missing.': 'Пакеты установлены, но часть проверок ещё показывает «нет».',
	'Starting dependency installation...': 'Запускаю установку зависимостей...',
	'Package list update failed; check WAN and DNS connectivity': 'Обновление списка пакетов не удалось; проверьте WAN и DNS.',
	'No supported dnsmasq provider is installed; dependency installation stopped': 'Поддерживаемый вариант dnsmasq не найден; установка зависимостей остановлена.',
	'dnsmasq-full installation failed; previous dnsmasq provider restored': 'Установка dnsmasq-full не удалась; предыдущий вариант dnsmasq восстановлен.',
	'dnsmasq-full verification failed; previous dnsmasq provider restored': 'Проверка dnsmasq-full не пройдена; предыдущий вариант dnsmasq восстановлен.',
	'Package installation failed; see /tmp/ikev2-manager-deps.log': 'Установка пакетов не удалась; см. /tmp/ikev2-manager-deps.log',
	'Disabling managed configuration...': 'Отключаю управляемую конфигурацию...',
	'Removing strongSwan, PBR and XFRM packages...': 'Удаляю strongSwan, PBR и XFRM-пакеты...',
	'Pre-install DNS, package and managed routing state was restored.': 'Восстановлены DNS, пакеты и управляемая маршрутизация в состоянии до установки зависимостей.',
	'Starting dependency removal...': 'Запускаю удаление зависимостей...',
	'Dependency ownership is unavailable; install dependencies once with this version before using Remove': 'Нет данных о владельце зависимостей. Один раз установите зависимости этой версией, затем используйте Remove.',
	'Runtime dependency restore failed; see /tmp/ikev2-manager-deps.log': 'Не удалось восстановить исходные зависимости; см. /tmp/ikev2-manager-deps.log',
	'Unable to save the pre-install package and DNS state': 'Не удалось сохранить исходное состояние пакетов и DNS.',
	'Runtime dependency removal failed; see /tmp/ikev2-manager-deps.log': 'Удаление зависимостей не удалось; см. /tmp/ikev2-manager-deps.log',
	'Some runtime dependencies are still installed; see /tmp/ikev2-manager-deps.log': 'Часть зависимостей всё ещё установлена; см. /tmp/ikev2-manager-deps.log',
	'Reset app and remove dependencies': 'Сбросить приложение и удалить зависимости',
	'Removing dependencies…': 'Удаляю зависимости…',
	'Application reset completed.': 'Сброс приложения завершён.',
	'Remove the strongSwan, PBR and XFRM packages this app installed? The VPN stops and managed configuration is cleared. DNS packages, generic tools and ACME are kept.': 'Удалить пакеты strongSwan, PBR и XFRM, установленные приложением? VPN остановится, управляемая конфигурация очистится. DNS-пакеты, общие утилиты и ACME останутся.',
	'Apply': 'Применить',
	'Let the app manage the router': 'Разрешить приложению управлять роутером',
	'Master switch: lets the app create and own the router routing, firewall and PBR. Off = the app only watches.': 'Главный переключатель: разрешает приложению управлять маршрутизацией, межсетевым экраном и PBR. В выключенном состоянии приложение только наблюдает.',
	'Master switch: lets the app create and own the router routing, firewall and PBR. Network and DNS changes are applied together by the button at the bottom.': 'Главный переключатель разрешает приложению управлять маршрутизацией, межсетевым экраном и PBR. Изменения сети и DNS применяются вместе кнопкой внизу страницы.',
	'Install the runtime dependencies below first — then this switch becomes available.': 'Сначала установите зависимости ниже — после этого выключатель станет доступен.',
	'Outbound Tunnel': 'Исходящий туннель',
	'Inbound Server': 'Входящий сервер',
	'Managed mode': 'Управляемый режим',
	'Master switch for the whole app — lets it own the router routing, firewall and PBR.': 'Главный переключатель приложения — разрешает ему управлять маршрутизацией, межсетевым экраном и PBR.',
	'Runtime dependencies are not installed': 'Системные компоненты не установлены',
	'Install PBR and strongSwan on the Overview page, then this page becomes available.': 'Установите PBR и strongSwan на вкладке «Обзор» — после этого страница станет доступна.',
	'Go to Overview': 'Перейти в Обзор',
	'Enable managed mode': 'Включить управляемый режим',
	'The app takes ownership of the router routing, firewall and PBR sections.': 'Приложение начинает управлять секциями маршрутизации, межсетевого экрана и PBR.',
	'Until enabled, the app only monitors and changes nothing on the router. Enable managed mode to let it create and own the network, firewall and PBR sections that route selected domains through the tunnel. Disabling later removes only those app-owned sections — tunnels, users and domain lists are kept.': 'Пока режим выключен, приложение только наблюдает и ничего не меняет. После включения оно создаёт сетевые правила, правила межсетевого экрана и PBR для выбранных доменов. При последующем отключении удаляются только эти правила; настройки туннелей, пользователи и списки доменов сохраняются.',
	'Installing dependencies… this can take a few minutes.': 'Устанавливаю зависимости… это может занять несколько минут.',
	'Dependencies are installing in the background.': 'Зависимости устанавливаются в фоне.',
	'Working...': 'Выполняется...',
	'Language': 'Язык',
	'English': 'English',
	'Russian': 'Русский',
	'Overview': 'Обзор',
	'Configured': 'Настроено',
	'Not configured': 'Не настроено',
	'Ready': 'Готово к работе',
	'Dependencies missing': 'Не хватает зависимостей',
	'System readiness': 'Системная готовность',
	'Firmware, feeds, storage, memory and reserved network resources.': 'Прошивка, репозитории, хранилище, память и зарезервированные сетевые ресурсы.',
	'Target VPN and routing packages': 'Целевые пакеты VPN и маршрутизации',
	'Components installed specifically for IKEv2, PBR and reliable domain routing.': 'Компоненты, устанавливаемые специально для IKEv2, PBR и надёжной доменной маршрутизации.',
	'Shared router packages': 'Общие пакеты роутера',
	'Components that OpenWrt or other apps may also use. Reset removes them only when this app installed them and no other package still needs them.': 'Компоненты, которые также могут использовать OpenWrt и другие приложения. Сброс удаляет их, только если они установлены этим приложением и больше не нужны другим пакетам.',
	'HTTP client': 'HTTP-клиент',
	'UPnP reservation for IKEv2': 'Резервирование портов IKEv2 в UPnP',
	'not-enabled': 'не включён',
	'UDP-500-and-4500-reserved': 'UDP 500 и 4500 зарезервированы',
	'UDP-4500-available-to-UPnP': 'UDP 4500 доступен для проброса через UPnP',
	'UDP-500,4500-available-to-UPnP': 'UDP 500 и 4500 доступны для проброса через UPnP',
	'active-UDP-500-or-4500-mapping': 'активный UPnP-проброс конфликтует с UDP 500/4500',
	'OpenWrt release': 'Версия OpenWrt',
	'firewall4': 'firewall4',
	'dnsmasq nftset support': 'Поддержка nftset в dnsmasq',
	'PBR service': 'Сервис PBR',
	'XFRM interface module': 'Модуль XFRM-интерфейса',
	'strongSwan swanctl': 'strongSwan swanctl',
	'strongSwan monitoring': 'Мониторинг strongSwan',
	'strongSwan kernel-netlink': 'strongSwan kernel-netlink',
	'strongSwan VICI': 'strongSwan VICI',
	'strongSwan OpenSSL': 'strongSwan OpenSSL',
	'strongSwan EAP-MSCHAPv2': 'strongSwan EAP-MSCHAPv2',
	'Outbound EAP security': 'Безопасность исходящего EAP',
	'Inbound strongSwan version': 'Версия strongSwan для входящего сервера',
	'strongSwan X.509': 'strongSwan X.509',
	'IKEv2 Manager Overview': 'Обзор IKEv2 Manager',
	'Install the app safely, prepare dependencies, then enable the managed routing configuration only when the checks are green.': 'Безопасно установите приложение, подготовьте зависимости и включайте управляемую маршрутизацию только когда проверки зеленые.',
	'Runtime dependencies': 'Системные компоненты',
	'Install runtime dependencies': 'Установить зависимости',
	'Installing dependencies...': 'Устанавливаю зависимости...',
	'Dependencies installed. Rechecking...': 'Зависимости установлены. Перепроверяю...',
	'Dependency installation failed': 'Установка зависимостей не удалась',
	'Reset the app and prepare it for removal? All app functions stop; its settings, users, secrets, generated files and app-owned dependencies are removed. Pre-install DNS/DHCP is restored. Shared packages required by other software are kept.': 'Сбросить приложение и подготовить его к удалению? Все функции приложения будут остановлены; настройки, пользователи, секреты, созданные файлы и собственные зависимости будут удалены. Исходные DNS/DHCP будут восстановлены. Общие пакеты, нужные другим приложениям, останутся.',
	'This installs PBR, strongSwan, sing-box, dnsmasq-full, dnsproxy and XFRM/TProxy packages. Reset stops every app function, restores pre-install DNS/DHCP, removes app-owned packages and clears app settings and secrets. Shared packages used by other software stay installed. Use Reset before uninstalling the app for a clean removal; removing only the package in Software preserves configuration and dependencies for reinstall or upgrade.': 'Устанавливает PBR, strongSwan, sing-box, dnsmasq-full, dnsproxy и XFRM/TProxy-пакеты. Сброс останавливает все функции приложения, восстанавливает исходные DNS/DHCP, удаляет собственные пакеты, настройки и секреты. Общие пакеты других приложений остаются. Используйте сброс перед полным удалением; удаление только пакета через Software сохраняет конфигурацию и зависимости для переустановки или обновления.',
	'This installs PBR, strongSwan, sing-box, dnsmasq-full, dnsproxy and XFRM/TProxy packages. Removing dependencies keeps the DNS packages, generic tools and ACME. VPN and routing stay disabled until managed mode is enabled.': 'Устанавливает PBR, strongSwan, sing-box, dnsmasq-full, dnsproxy и XFRM/TProxy-пакеты. При удалении зависимостей DNS-пакеты, общие утилиты и ACME остаются. VPN и маршрутизация останутся выключены до включения управляемого режима.',
	'Install missing runtime packages now? DNS/DHCP may restart briefly while dnsmasq-full replaces dnsmasq.': 'Установить недостающие системные пакеты? При замене dnsmasq на dnsmasq-full службы DNS и DHCP кратковременно перезапустятся.',
	'System readiness': 'Готовность системы',
	'All required components must pass before managed routing can be enabled.': 'Все обязательные компоненты должны пройти проверку перед включением управляемой маршрутизации.',
	'Network integration': 'Интеграция с сетью',
	'Use logical OpenWrt network names and firewall zone names, not Linux device names. Separate multiple values with spaces.': 'Используйте логические имена сетей OpenWrt и зон межсетевого экрана, а не имена Linux-интерфейсов. Несколько значений разделяйте пробелами.',
	'WAN network': 'WAN-сеть',
	'Usually “wan”; used for hotplug and direct-WAN exceptions.': 'Обычно «wan»; используется при изменении состояния подключения и для прямого выхода через WAN.',
	'WAN firewall zone': 'Зона WAN в межсетевом экране',
	'Usually “wan”; receives UDP 500/4500 when the server is enabled.': 'Обычно “wan”; принимает UDP 500/4500 при включенном сервере.',
	'Protected networks': 'Защищаемые сети',
	'Networks whose selected domains use the outbound tunnel. Example: lan iot.': 'Сети, чьи выбранные домены идут через исходящий туннель. Пример: lan iot.',
	'Protected firewall zones': 'Защищаемые зоны межсетевого экрана',
	'Matching zones used for forwarding and DNS enforcement.': 'Зоны, используемые для перенаправления трафика и принудительного DNS.',
	'DNS policy': 'DNS-политика',
	'Domain routing is deterministic only when clients use the router resolver.': 'Доменная маршрутизация предсказуема только если клиенты используют DNS роутера.',
	'Domain routing is deterministic only when clients use the router resolver. These options take effect only after Apply.': 'Доменная маршрутизация предсказуема только если клиенты используют DNS роутера. Эти параметры вступают в силу только после нажатия «Применить».',
	'Redirect plain DNS': 'Перенаправлять обычный DNS',
	'Redirect TCP/UDP port 53 from protected zones to the router.': 'Перенаправляет TCP/UDP порт 53 из защищаемых зон на роутер.',
	'Block DNS-over-TLS': 'Блокировать DNS-over-TLS',
	'Reject TCP/UDP port 853 from protected zones to WAN.': 'Отклоняет TCP/UDP порт 853 из защищаемых зон в WAN.',
	'Devices with their own resolver': 'Устройства со своим резолвером',
	'These devices are exempt from both the port 53 redirect and the DNS-over-TLS block.': 'Эти устройства не попадают ни под перенаправление порта 53, ни под блокировку DNS-over-TLS.',
	'No devices manage their own DNS': 'Нет устройств со своим DNS',
	'Every device uses the router resolver.': 'Все устройства используют резолвер роутера.',
	'Domain routing stops working for these devices.': 'Для этих устройств перестаёт работать доменная маршрутизация.',
	'A device with its own resolver receives real addresses, so it never enters FakeIP classification. Only address and CIDR rules keep working for it.': 'Устройство со своим резолвером получает настоящие адреса и не попадает в классификацию FakeIP. Для него продолжают работать только правила по IP-адресам и CIDR.',
	'Activation': 'Активация',
	'Enable managed configuration': 'Включить управляемую конфигурацию',
	'Creates the application network, firewall and PBR sections.': 'Создаёт сетевые секции приложения, правила межсетевого экрана и PBR.',
	'Save base configuration': 'Сохранить базовую конфигурацию',
	'Applying configuration...': 'Применяю конфигурацию...',
	'Disabling...': 'Отключаю...',
	'Base routing and firewall configuration applied.': 'Базовые правила маршрутизации и межсетевого экрана применены.',
	'Managed routing and firewall configuration disabled.': 'Управляемые правила маршрутизации и межсетевого экрана отключены.',
	'Browser DoH, Android Private DNS and Apple Private Relay cannot be transparently classified by a DNS-based domain policy.': 'Browser DoH, Android Private DNS и Apple Private Relay нельзя прозрачно классифицировать DNS-доменной политикой.',
	'Outbound IKEv2 Tunnel': 'Исходящий IKEv2-туннель',
	'The router uses this IPv4 IKEv2 tunnel for domains and devices selected on the Policy Routing page.': 'Роутер использует этот IPv4 IKEv2-туннель для доменов и устройств, выбранных на вкладке «Маршрутизация».',
	'Custom config': 'Ручная конфигурация',
	'Connected': 'Подключено',
	'Disconnected': 'Отключено',
	'Remote gateway': 'Удаленный шлюз',
	'Virtual IPv4': 'Виртуальный IPv4',
	'Current SA traffic': 'Трафик текущей SA',
	'Accumulated tunnel traffic': 'Накопительный трафик туннеля',
	'Counter age: %s': 'Возраст счётчика: %s',
	'Since ipsec-out was created': 'С момента создания ipsec-out',
	'ipsec-out is unavailable': 'Интерфейс ipsec-out недоступен',
	'Connection': 'Подключение',
	'Enable client': 'Включить клиент',
	'Remote address': 'Адрес сервера',
	'IPv4 address or hostname': 'IPv4-адрес или hostname',
	'IPv4 address or hostname of the IKEv2 gateway.': 'IPv4-адрес или hostname IKEv2-шлюза.',
	'Remote identity': 'Идентичность сервера',
	'Certificate identity expected from the VPS.': 'Ожидаемая идентичность сертификата VPS.',
	'EAP username': 'EAP-пользователь',
	'New EAP password': 'Новый EAP-пароль',
	'Visible while editing; leave blank to preserve the saved secret.': 'Виден при редактировании; оставьте пустым, чтобы сохранить текущий секрет.',
	'Tunnel profile': 'Профиль туннеля',
	'Advanced connectivity': 'Расширенные параметры связи',
	'DPD interval': 'Интервал DPD',
	'Dead peer detection in seconds.': 'Dead peer detection в секундах.',
	'XFRM MTU': 'XFRM MTU',
	'Keep 1400 unless PMTU diagnostics show a problem.': 'Оставьте 1400, если PMTU-диагностика не показывает проблему.',
	'Reconnect cooldown': 'Пауза между переподключениями',
	'Minimum delay between automatic connection attempts, in seconds.': 'Минимальная пауза между автоматическими попытками подключения, в секундах.',
	'Save and reconnect': 'Сохранить и переподключить',
	'Edit raw config': 'Редактировать raw-конфиг',
	'Save custom config': 'Сохранить ручной конфиг',
	'Reset to generated': 'Вернуть сгенерированный',
	'Generated': 'Сгенерировано',
	'Override active': 'Ручной режим активен',
	'Reconnecting...': 'Переподключаю...',
	'Stopping...': 'Останавливаю...',
	'Outbound tunnel reconnected.': 'Исходящий туннель переподключен.',
	'Outbound tunnel disabled.': 'Исходящий туннель отключен.',
	'No active traffic SA': 'Нет активной traffic SA',
	'Down %s, up %s': 'Получено %s, отправлено %s',
	'online': 'онлайн',
	'Disabling this client intentionally blocks selected domains. The fail-closed route does not fall back to the home WAN.': 'При отключении клиента выбранные домены намеренно блокируются: маршрут без утечки не переключает их на домашний WAN.',
	'Policy Routing': 'Политика маршрутизации',
	'Build the IPv4 VPN policy from curated services, custom destinations and per-device modes.': 'Собирает IPv4 VPN-политику из готовых сервисов, собственных направлений и режимов устройств.',
	'Policy active': 'Политика активна',
	'Policy empty': 'Политика пуста',
	'Community services': 'Готовые сервисы',
	'Domain routing engine': 'Механизм доменной маршрутизации',
	'Reliable mode keeps selected domains on the IKEv2 route even when their public addresses change. Other traffic continues through the normal WAN.': 'Надёжный режим сохраняет маршрут выбранных доменов через IKEv2 даже при смене их публичных адресов. Остальной трафик продолжает идти через обычный WAN.',
	'Reliable mode active': 'Надёжный режим активен',
	'Standard mode active': 'Обычный режим активен',
	'Enable reliable mode': 'Включить надёжный режим',
	'Use standard mode': 'Вернуться к обычному режиму',
	'Selected domains receive stable FakeIP addresses. Only connections to those addresses from covered networks enter the IKEv2 path.': 'Выбранные домены получают стабильные FakeIP-адреса. В IKEv2 попадают только соединения к этим адресам из подключённых к политике сетей.',
	'dnsmasq currently classifies domains by their public IP addresses. Existing connections may keep an earlier WAN route after an address changes.': 'Сейчас dnsmasq определяет домены по публичным IP-адресам. После смены адреса уже открытое соединение может сохранить прежний маршрут через WAN.',
	'Unable to start routing-engine change': 'Не удалось запустить смену механизма маршрутизации',
	'Includes direct service IP networks': 'Включает прямые IP-сети сервиса',
	'Reliable mode needs attention': 'Надёжный режим требует внимания',
	'Reliable mode degraded': 'Надёжный режим нарушен',
	'Reliable domain routing is still updating.': 'Надёжная доменная маршрутизация ещё обновляется.',
	'The reliable domain-router service is stopped.': 'Служба надёжной доменной маршрутизации остановлена.',
	'dnsmasq is not using the FakeIP resolver.': 'dnsmasq не использует FakeIP-резолвер.',
	'dnsmasq caching is still enabled in reliable mode.': 'В надёжном режиме не отключён кеш dnsmasq.',
	'Reliable-mode nftables rules are missing.': 'Отсутствуют правила nftables надёжного режима.',
	'Reliable-mode policy routing rule is missing.': 'Отсутствует правило маршрутизации надёжного режима.',
	'Reliable domain routing failed a runtime health check.': 'Надёжная доменная маршрутизация не прошла проверку состояния.',
	'FakeIP startup failed; previous DNS was restored': 'Не удалось запустить FakeIP; предыдущий DNS восстановлен',
	'DNS upstream update failed; previous FakeIP resolver restored': 'Не удалось обновить DNS; предыдущий FakeIP-резолвер восстановлен',
	'New domain rules failed validation; previous rules remain active': 'Новые доменные правила не прошли проверку; прежние правила остаются активными',
	'New domain rules failed at runtime; previous rules restored': 'Новые доменные правила не запустились; прежние правила восстановлены',
	'sing-box FakeIP and nftables TProxy classify selected services. Configure the engine on the Policy Routing page.': 'sing-box FakeIP и nftables TProxy определяют выбранные сервисы. Настройка механизма находится на странице «Маршрутизация».',
	'PBR currently classifies selected services by their resolved public IP addresses. Configure the engine on the Policy Routing page.': 'Сейчас PBR определяет выбранные сервисы по полученным публичным IP-адресам. Настройка механизма находится на странице «Маршрутизация».',
	'sing-box domain router': 'Доменный маршрутизатор sing-box',
	'nftables TProxy support': 'Поддержка nftables TProxy',
	'Remove strongSwan, PBR, sing-box and XFRM/TProxy packages? The VPN and reliable domain routing stop, and managed configuration is cleared. Generic tools and ACME are kept.': 'Удалить пакеты strongSwan, PBR, sing-box и XFRM/TProxy? VPN и надёжная доменная маршрутизация остановятся, управляемая конфигурация будет очищена. Общие инструменты и ACME останутся.',
	'This installs PBR, strongSwan, sing-box, dnsmasq-full, dnsproxy and XFRM/TProxy packages. VPN and routing stay disabled until managed mode is enabled.': 'Будут установлены PBR, strongSwan, sing-box, dnsmasq-full, dnsproxy и пакеты XFRM/TProxy. VPN и маршрутизация останутся выключенными до включения управляемого режима.',
	'Saved. Domain routing is updating in the background.': 'Сохранено. Доменная маршрутизация обновляется в фоне.',
	'Choose the public DNS upstream. In reliable mode dnsmasq sends public queries through sing-box, which uses dnsproxy as its upstream; in standard mode dnsmasq uses dnsproxy directly.': 'Выберите внешний DNS-сервер. В надёжном режиме dnsmasq передаёт публичные запросы в sing-box, который использует dnsproxy как upstream; в обычном режиме dnsmasq обращается к dnsproxy напрямую.',
	'Custom domains': 'Собственные домены',
	'Custom IP addresses and networks': 'Собственные IP-адреса и сети',
	'Device routing': 'Маршрутизация устройств',
	'Domains': 'Домены',
	'Devices': 'Устройства',
	'Curated targets are cached locally and merged atomically. Services marked IP also include their direct protocol networks. Broad infrastructure groups may route unrelated sites.': 'Готовые наборы кэшируются локально и объединяются атомарно. Сервисы с меткой IP также включают сети своих прямых протоколов. Широкие инфраструктурные группы могут затронуть лишние сайты.',
	'One plain domain per line. Custom entries are never overwritten by service updates.': 'По одному домену на строку. Обновление готовых сервисов не изменяет собственные записи.',
	'One IPv4 address or CIDR network per line. A single address is stored as /32.': 'По одному IPv4-адресу или CIDR-сети на строку. Одиночный адрес сохраняется как /32.',
	'Invalid IPv4 address or network on line %d: %s': 'Некорректный IPv4-адрес или сеть в строке %d: %s',
	'Choose which clients participate in domain routing or override it completely.': 'Выберите клиентов, участвующих в доменной маршрутизации, или задайте им отдельный режим.',
	'Clients must use router DNS. Plain DNS is redirected and DoT is blocked, but browser DoH and Apple Private Relay must still be disabled for deterministic domain routing.': 'Клиенты должны использовать DNS роутера. Обычный DNS перенаправляется, DoT блокируется, но browser DoH и Apple Private Relay нужно отключать отдельно.',
	'Default coverage': 'Покрытие по умолчанию',
	'These network segments already participate in domain-based VPN routing.': 'Эти сетевые сегменты уже участвуют в доменной VPN-маршрутизации.',
	'Custom device rules': 'Правила устройств',
	'Add to domain routing': 'Добавить в доменную маршрутизацию',
	'Subnet or IP participates in domain-based VPN routing.': 'Подсеть или IP участвует в доменной VPN-маршрутизации.',
	'Add device override': 'Добавить исключение устройства',
	'Per-device exception inserted before the base PBR rule.': 'Исключение устройства добавляется перед базовым PBR-правилом.',
	'Full route — all traffic via VPN': 'Весь трафик через VPN',
	'Exclude — always use WAN': 'Всегда напрямую через WAN',
	'Full route': 'Весь трафик через VPN',
	'Connected device': 'Подключённое устройство',
	'Exclude': 'Напрямую через WAN',
	'Add': 'Добавить',
	'Remove': 'Удалить',
	'Actions': 'Действия',
	'Mode': 'Режим',
	'Invalid address': 'Некорректный адрес',
	'No custom device rules': 'Нет пользовательских правил устройств',
	'All default network segments still use domain routing. Add a rule below only when a device needs different behavior.': 'Все базовые сетевые сегменты используют доменную маршрутизацию. Добавляйте правило ниже только если устройству нужен другой режим.',
	'Inbound VPN Server': 'Входящий VPN-сервер',
	'Remote devices connect to the router over IKEv2. Routes advertised by strongSwan and firewall permissions are controlled independently.': 'Удалённые устройства подключаются к роутеру по IKEv2. Объявляемые маршруты и разрешения межсетевого экрана настраиваются независимо.',
	'Enabled': 'Включено',
	'Disabled': 'Выключено',
	'Service': 'VPN-сервер',
	'Configure the public identity, client pool and certificate used by remote devices.': 'Настройте публичное имя сервера, пул адресов и сертификат для удалённых устройств.',
	'Configure the server identity and client address pool. Less common settings are grouped below.': 'Настройте имя сервера и пул адресов клиентов. Остальные параметры сгруппированы ниже.',
	'Enable server': 'Включить сервер',
	'Listen on WAN UDP 500 and 4500.': 'Слушать WAN UDP 500 и 4500.',
	'Public identity': 'Доменное имя сервера',
	'Client IPv4 pool': 'IPv4-пул клиентов',
	'Pool gateway': 'Шлюз пула',
	'Router address and prefix assigned to ipsec-in.': 'Адрес роутера и префикс, назначаемые ipsec-in.',
	'DNS for VPN clients': 'DNS для VPN-клиентов',
	'Client routes and access': 'Маршруты и доступ клиентов',
	'Choose global defaults for inbound clients. Individual overrides are configured on the VPN Users page.': 'Задайте глобальные правила для входящих клиентов. Индивидуальные исключения настраиваются на странице «VPN-пользователи».',
	'Choose what clients send through IKEv2 and where that traffic may go.': 'Выберите, какой трафик клиенты отправляют в IKEv2 и куда ему разрешён доступ.',
	'Traffic selectors decide what clients send into IKEv2. The switches decide what firewall4 permits after it arrives.': 'Список сетей определяет, какой трафик клиенты отправляют в IKEv2. Переключатели ниже задают разрешённые направления.',
	'Advertised IPv4 destinations': 'Доступные клиентам IPv4-сети',
	'Space-separated CIDRs. Use 0.0.0.0/0 for a full-tunnel client route.': 'Укажите CIDR через пробел. Значение 0.0.0.0/0 направляет через VPN весь IPv4-трафик клиента.',
	'Allow Internet': 'Разрешить интернет',
	'Permit forwarding to home WAN and the outbound IKEv2 policy path.': 'Разрешить доступ в интернет через домашний WAN и исходящий IKEv2-туннель.',
	'Allow internal networks': 'Разрешить внутренние сети',
	'Permit forwarding to the LAN firewall zones listed below.': 'Разрешить доступ к перечисленным ниже локальным сетям.',
	'Internal firewall zones': 'Зоны локальных сетей',
	'Allow router itself': 'Разрешить сам роутер',
	'Allows router services on its LAN, VPN and public addresses. This also enables same-router public-IP loopback.': 'Разрешает доступ к службам роутера по его локальным, VPN- и публичным адресам.',
	'Allow all router ports': 'Разрешить все порты роутера',
	'Permit every router service from authenticated inbound VPN clients. The restricted port list is disabled while this is on.': 'Разрешает аутентифицированным входящим VPN-клиентам все сервисы роутера. Пока опция включена, ограниченный список портов недоступен.',
	'Allowed router ports': 'Разрешённые порты роутера',
	'Complete TCP/UDP allowlist used when all ports are off. Keep LuCI and SSH ports in this list or inbound VPN management access will stop.': 'Полный белый список TCP/UDP, используемый когда разрешение всех портов выключено. Оставьте здесь порты LuCI и SSH, иначе управление через входящий VPN перестанет работать.',
	'Enter at least one allowed router port or enable all router ports.': 'Укажите хотя бы один разрешённый порт роутера или включите разрешение всех портов.',
	'Optional TCP/UDP ports or ranges. Leave empty to allow all protocols and services.': 'Опциональные TCP/UDP порты или диапазоны. Пусто означает разрешить все протоколы и сервисы.',
	'Connection behavior': 'Поведение подключения',
	'The defaults are tuned for phones roaming between Wi-Fi and mobile networks.': 'Значения по умолчанию настроены для телефонов, переходящих между Wi-Fi и мобильной сетью.',
	'Connection and advanced settings': 'Подключение и дополнительные параметры',
	'Roaming behavior, timers, certificate paths and raw strongSwan configuration.': 'Роуминг, таймеры, пути сертификатов и ручная конфигурация strongSwan.',
	'Keeps the VPN session when a phone moves between Wi-Fi and mobile data.': 'Сохраняет VPN-сессию при переходе телефона между Wi-Fi и мобильной сетью.',
	'Avoids oversized IKE packets on constrained networks.': 'Предотвращает проблемы с крупными IKE-пакетами в сетях с ограничениями.',
	'Firewall zone integration': 'Интеграция с зонами межсетевого экрана',
	'Inbound VPN zone': 'Зона входящего VPN',
	'Outbound IKEv2 zone': 'Зона исходящего IKEv2',
	'Advanced timers': 'Расширенные таймеры',
	'IKE rekey': 'IKE rekey',
	'CHILD rekey': 'CHILD rekey',
	'Certificate paths': 'Пути сертификатов',
	'ACME certificate directory': 'Каталог ACME-сертификата',
	'Certificate file override': 'Путь к сертификату вручную',
	'Private key override': 'Путь к приватному ключу вручную',
	'Save server settings': 'Сохранить сервер',
	'VPN Users': 'VPN-пользователи',
	'Manage inbound IKEv2 credentials and current sessions. Traffic counters reset when a session reconnects.': 'Управляйте учётными записями входящего IKEv2 и активными подключениями. Счётчики трафика сбрасываются при переподключении.',
	'Access list': 'Список доступа',
	'Passwords are write-only. Set a new password if one is lost; router backups still contain secrets.': 'Пароли доступны только для записи. Если пароль утерян, задайте новый; резервные копии роутера всё равно содержат секреты.',
	'Online shows only IKEv2 sessions terminating on this router. A device connected to the outbound VPS tunnel is shown on the Outbound Tunnel page and is not counted here.': 'Здесь учитываются только входящие IKEv2-подключения к этому роутеру. Состояние исходящего туннеля показано на отдельной вкладке.',
	'User': 'Пользователь',
	'Password': 'Пароль',
	'Current session': 'Активное подключение',
	'Online': 'В сети',
	'Offline': 'Не подключён',
	'Copy': 'Копировать',
	'Copy password': 'Копировать пароль',
	'Password copied.': 'Пароль скопирован.',
	'Change': 'Изменить',
	'Delete': 'Удалить',
	'Add user': 'Добавить пользователя',
	'Disconnect all': 'Отключить всех',
	'Disconnect': 'Отключить',
	'Disconnecting...': 'Отключаю...',
	'Add VPN user': 'Добавить VPN-пользователя',
	'Change password': 'Сменить пароль',
	'Username': 'Имя пользователя',
	'Letters, digits, dot, dash and underscore.': 'Буквы, цифры, точка, дефис и подчеркивание.',
	'Visible by design to LuCI administrators.': 'Специально виден администраторам LuCI.',
	'Cancel': 'Отмена',
	'Save': 'Сохранить',
	'Invalid username.': 'Некорректное имя пользователя.',
	'Password is required.': 'Пароль обязателен.',
	'VPN user added.': 'VPN-пользователь добавлен.',
	'Password changed.': 'Пароль изменен.',
	'Access policy': 'Политика доступа',
	'VPN user access': 'Доступ VPN-пользователя',
	'Individual access policy': 'Индивидуальная политика доступа',
	'Global values remain defaults; choose an override only where this user differs.': 'Глобальные значения остаются настройками по умолчанию; задавайте исключения только там, где пользователь должен отличаться.',
	'A newly connected client is blocked until its authenticated identity is matched to its virtual address.': 'Новый клиент остаётся заблокированным, пока его подтверждённая учётная запись не сопоставлена с виртуальным адресом.',
	'Use global setting': 'Использовать глобальную настройку',
	'Allow': 'Разрешить',
	'Deny': 'Запретить',
	'Router access': 'Доступ к роутеру',
	'DNS remains available even when router access is denied.': 'DNS остаётся доступен, даже если доступ к самому роутеру запрещён.',
	'Public router ports': 'Публичные порты роутера',
	'Additional TCP/UDP ports remain available when router access is denied. Use spaces or commas between ports and ranges.': 'Дополнительные TCP/UDP-порты остаются доступными, когда доступ к роутеру запрещён. Разделяйте порты и диапазоны пробелами или запятыми.',
	'Enter valid public router ports or ranges.': 'Укажите корректные публичные порты роутера или диапазоны.',
	'Internet access': 'Доступ в Интернет',
	'Allows normal WAN traffic and selected destinations through the outbound tunnel.': 'Разрешает обычный WAN-трафик и выбранные направления через исходящий туннель.',
	'Local network access': 'Доступ к локальной сети',
	'Limit access to individual IPv4 addresses or CIDR networks when needed.': 'При необходимости ограничьте доступ отдельными IPv4-адресами или CIDR-сетями.',
	'All local networks': 'Все локальные сети',
	'Only selected addresses': 'Только выбранные адреса',
	'Allowed local addresses': 'Разрешённые локальные адреса',
	'PBR participation': 'Участие в PBR',
	'Use project PBR policy': 'Использовать PBR-политику проекта',
	'Direct WAN — exclude from PBR': 'Прямой WAN — исключить из PBR',
	'Direct WAN bypasses the project domain policy for this VPN user.': 'Прямой WAN обходит доменную политику проекта для этого VPN-пользователя.',
	'Enter at least one allowed local address.': 'Укажите хотя бы один разрешённый локальный адрес.',
	'Access policy saved.': 'Политика доступа сохранена.',
	'Allowed': 'Разрешён',
	'Denied': 'Запрещён',
	'Global: allowed': 'Глобально: разрешён',
	'Global: denied': 'Глобально: запрещён',
	'Selected addresses': 'Выбранные адреса',
	'Direct WAN': 'Прямой WAN',
	'Project policy': 'Политика проекта',
	'Router: %s': 'Роутер: %s',
	'Internet: %s': 'Интернет: %s',
	'LAN: %s': 'LAN: %s',
	'PBR: %s': 'PBR: %s',
	'Public ports: %s': 'Публичные порты: %s',
	'Individual access policies are stored but are not enforced while a custom inbound profile is active.': 'Индивидуальные политики сохраняются, но не применяются, пока активен ручной inbound-профиль.',
	'No VPN users configured.': 'VPN-пользователи не настроены.',
	'%d users': '%d пользователей',
	'%d online': 'подключено: %d',
	'%s online; down %s, up %s': 'В сети %s · получено %s · отправлено %s',
	'Online for %s': 'В сети %s',
	'Received': 'Получено',
	'Sent': 'Отправлено',
	'Received %s': 'Получено %s',
	'Sent %s': 'Отправлено %s',
	'No active sessions': 'Нет активных подключений',
	'%d active sessions': '%d активных подключений',
	'Inbound session data is unavailable.': 'Данные входящих подключений недоступны.',
	'Address unavailable': 'Адрес недоступен',
	'Project status': 'Состояние проекта',
	'Project status is unavailable.': 'Состояние проекта недоступно.',
	'Operational': 'Работает штатно',
	'Unavailable': 'Недоступно',
	'Outbound client is disabled.': 'Исходящий VPN-клиент выключен.',
	'Connection state is unavailable.': 'Состояние подключения недоступно.',
	'Routing state is unavailable.': 'Состояние маршрутизации недоступно.',
	'Server state is unavailable.': 'Состояние сервера недоступно.',
	'No installed outbound CHILD_SA.': 'Нет установленного исходящего CHILD_SA.',
	'Downloaded': 'Получено',
	'Uploaded': 'Отправлено',
	'Policy routing': 'Политика маршрутизации',
	'Managed routing is disabled.': 'Управляемая маршрутизация выключена.',
	'PBR running': 'PBR работает',
	'PBR stopped': 'PBR остановлен',
	'Fail-closed active': 'Fail-closed активен',
	'Fail-closed missing': 'Fail-closed отсутствует',
	'%d service groups': 'наборов сервисов: %d',
	'%d address rules': 'правил адресов: %d',
	'Inbound server': 'Входящий сервер',
	'Inbound server is disabled.': 'Входящий сервер выключен.',
	'Server ready': 'Сервер готов',
	'Server degraded': 'Сервер работает со сбоем',
	'Active inbound clients': 'Активные входящие клиенты',
	'Open IKEv2 Manager': 'Открыть IKEv2 Manager',
	'Key checks': 'Основные проверки',
	'Show %d more diagnostic checks': 'Показать остальные проверки (%d)',
	'Operation failed': 'Операция не удалась',
	'Unable to save the VPN user: %s': 'Не удалось сохранить VPN-пользователя: %s',
	'%d accounts configured': 'учётных записей: %d',
	'%d days left': 'осталось дней: %d',
	'%d domains': 'доменов: %d',
	'%d routed domains are fail-closed through the VPS. Ordinary traffic continues over the home WAN.': '%d доменов направляются через VPS и блокируются при обрыве VPN. Остальной трафик продолжает идти через домашний WAN.',
	'%d service groups + %d manual': 'готовых наборов: %d · собственных доменов: %d',
	'%s; WAN rule %s': '%s; WAN-правило %s',
	'A practical overview of the outbound tunnel, domain routing and inbound VPN access.': 'Практичный обзор исходящего туннеля, доменной маршрутизации и входящего VPN-доступа.',
	'Acceleration for ordinary WAN traffic; policy-routed traffic remains under VPN control.': 'Ускорение обычного WAN-трафика; трафик по правилам маршрутизации остаётся под контролем VPN.',
	'Access policy apply failed': 'Не удалось применить политику доступа',
	'Action required': 'Нужно действие',
	'Active': 'Активно',
	'Address / subnet': 'Адрес / подсеть',
	'Advanced strongSwan configuration': 'Расширенная конфигурация strongSwan',
	'Automatic from identity': 'Автоматически по имени сервера',
	'Certificate': 'Сертификат',
	'Certificate issuer': 'Издатель сертификата',
	'Certificate subject': 'Имя владельца сертификата',
	'Changing these values interrupts routed domains for a few seconds while the tunnel and PBR restart.': 'При изменении этих значений выбранные домены могут быть недоступны несколько секунд, пока перезапускаются туннель и PBR.',
	'Changing these values reloads the tunnel profile and reconnects it. The PBR policy remains loaded.': 'Изменение этих значений перезагружает профиль туннеля и переподключает его. Политика PBR остаётся загруженной.',
	'Check': 'Проверить',
	'Configuration': 'Конфигурация',
	'Cryptography': 'Криптография',
	'Custom configuration was rejected': 'Ручная конфигурация отклонена',
	'Custom inbound configuration loaded.': 'Ручная входящая конфигурация загружена.',
	'Custom mode replaces the generated inbound connection and pool blocks. Normal form values remain stored but do not change the active strongSwan profile until generated mode is restored.': 'Ручной режим заменяет сгенерированное входящее подключение и блоки пулов. Значения формы сохраняются, но не меняют активный профиль strongSwan до возврата в сгенерированный режим.',
	'Custom mode replaces the generated outbound connection. Credentials remain managed separately by the EAP fields above.': 'Ручной режим заменяет сгенерированное исходящее подключение. Учетные данные по-прежнему управляются EAP-полями выше.',
	'Custom outbound configuration loaded.': 'Ручная исходящая конфигурация загружена.',
	'DNS enforcement': 'Принудительный DNS',
	'DNS interception was not detected. Domain routing may miss clients using another DNS server.': 'DNS-перехват не обнаружен. Доменная маршрутизация может пропускать клиентов с другим DNS.',
	'DNS upstream': 'Внешний DNS',
	'Choose how the router resolves public DNS names. dnsmasq-full remains the local resolver and continues populating PBR nftsets.': 'Выберите, как роутер разрешает публичные DNS-имена. dnsmasq-full остаётся локальным резолвером и продолжает наполнять nftset для PBR.',
	'This is a router-wide resolver setting. Upstream DNS connections use the router default route.': 'Это общая настройка DNS для всего роутера. Соединения с внешним DNS используют основной маршрут роутера.',
	'DNS management': 'Управление DNS',
	'Keep existing router DNS': 'Сохранить текущий DNS роутера',
	'Manage DNS upstream': 'Управлять внешним DNS',
	'Existing settings are preserved until managed DNS is enabled.': 'Текущие настройки сохраняются, пока управляемый DNS не включён.',
	'Protocol': 'Протокол',
	'DNS over UDP': 'DNS через UDP',
	'DNS over TCP': 'DNS через TCP',
	'DNS over TLS (DoT)': 'DNS через TLS (DoT)',
	'DNS over HTTPS (DoH)': 'DNS через HTTPS (DoH)',
	'DoH with HTTP/3 preferred — experimental': 'DoH с приоритетом HTTP/3 — экспериментально',
	'DoH over HTTP/3 only — experimental': 'DoH только через HTTP/3 — экспериментально',
	'DNS over QUIC (DoQ) — experimental': 'DNS через QUIC (DoQ) — экспериментально',
	'DNSCrypt': 'DNSCrypt',
	'dnsproxy supports plain DNS, DoT, DoH, HTTP/3, DoQ and DNSCrypt.': 'dnsproxy поддерживает обычный DNS, DoT, DoH, HTTP/3, DoQ и DNSCrypt.',
	'Add provider preset': 'Добавить готовый сервер',
	'Add preset': 'Добавить',
	'Query strategy': 'Стратегия запросов',
	'Load balance': 'Распределять запросы',
	'First response': 'Первый ответ',
	'Fastest address': 'Самый быстрый адрес',
	'Primary DNS servers': 'Основные DNS-серверы',
	'Add DNS server': 'Добавить DNS-сервер',
	'No DNS servers added': 'DNS-серверы не добавлены',
	'Bootstrap DNS': 'Bootstrap DNS',
	'Add bootstrap server': 'Добавить bootstrap-сервер',
	'No bootstrap servers added': 'Bootstrap-серверы не добавлены',
	'Fallback DNS servers': 'Резервные DNS-серверы',
	'Add fallback server': 'Добавить резервный сервер',
	'No fallback servers added': 'Резервные DNS-серверы не добавлены',
	'Apply DNS': 'Применить DNS',
	'Applying and testing DNS...': 'Применяю и проверяю DNS...',
	'Applying and testing DNS settings...': 'Применяю и проверяю настройки DNS...',
	'DNS settings applied.': 'Настройки DNS применены.',
	'DNS apply failed': 'Не удалось применить DNS',
	'DNS apply failed; previous resolver configuration was restored.': 'Не удалось применить DNS; предыдущая конфигурация восстановлена.',
	'Invalid DNS upstream for the selected protocol': 'Основной DNS не соответствует выбранному протоколу',
	'Bootstrap DNS must contain IPv4:port entries': 'Bootstrap DNS должен содержать адреса в формате IPv4:порт',
	'Invalid fallback DNS endpoint': 'Некорректный адрес резервного DNS',
	'Invalid DNS management mode': 'Некорректный режим управления DNS',
	'Invalid DNS provider': 'Некорректный DNS-провайдер',
	'Unsupported DNS protocol': 'Неподдерживаемый DNS-протокол',
	'Unsupported DNS upstream mode': 'Неподдерживаемая стратегия DNS-запросов',
	'dnsproxy is not installed': 'dnsproxy не установлен',
	'DNS validation failed; previous resolver configuration was restored': 'DNS не прошёл проверку; предыдущая конфигурация восстановлена',
	'DNS settings rejected': 'Настройки DNS отклонены',
	'DNS apply did not start': 'Применение DNS не запустилось',
	'DNS apply timed out': 'Проверка DNS не завершилась вовремя',
	'DNS is working': 'DNS работает',
	'Managed': 'Управляется',
	'Stopped': 'Остановлен',
	'Existing settings': 'Текущие настройки',
	'WAN-provided resolvers': 'DNS, полученные от WAN',
	'Delete user %s?': 'Удалить пользователя %s?',
	'Device / IP': 'Устройство / IP',
	'Device overrides': 'Исключения устройств',
	'Disabling removes only UCI sections owned by this application. Stored tunnel settings, users and domain lists are preserved.': 'Отключение удаляет только UCI-секции, принадлежащие приложению. Настройки туннелей, пользователи и списки доменов сохраняются.',
	'Disconnect all active VPN sessions?': 'Отключить все активные VPN-сессии?',
	'Domain policy': 'Доменная политика',
	'Domain routing': 'Доменная маршрутизация',
	'Domain routing sends only listed destinations through the VPS. Full route sends all IPv4 traffic for a device through the VPS. Exclude always uses the home WAN.': 'Доменная маршрутизация отправляет через VPS только выбранные назначения. Режим полного туннеля направляет через VPN весь IPv4-трафик устройства, а прямой режим всегда использует домашний WAN.',
	'Done. The active PBR list now has %s domains.': 'Готово. В активном PBR-списке сейчас %s доменов.',
	'Down': 'Не работает',
	'Edit domains': 'Редактировать домены',
	'Editor is not ready.': 'Редактор не готов.',
	'Policy error': 'Ошибка политики',
	'Current upstream:': 'Текущий DNS:',
	'Unable to refresh configuration': 'Не удалось обновить состояние конфигурации',
	'Unable to refresh system readiness': 'Не удалось обновить состояние системных компонентов',
	'Empty means all router services': 'Пусто означает все сервисы роутера',
	'Encrypted DNS port 853': 'Шифрованный DNS порт 853',
	'Flow offload': 'Ускорение обработки трафика',
	'IKE fragmentation': 'IKE-фрагментация',
	'IKEv2 configuration reloaded.': 'Конфигурация IKEv2 перезагружена.',
	'Inbound VPN': 'Входящий VPN',
	'Inbound XFRM': 'Входящий XFRM',
	'Inbound firewall': 'Межсетевой экран входящего VPN',
	'Inbound server and access policy applied.': 'Входящий сервер и политика доступа применены.',
	'Inbound users': 'Входящие пользователи',
	'Inspect the generated swanctl connection or replace it with a manually maintained profile.': 'Просмотрите сгенерированное swanctl-подключение или замените его ручным профилем.',
	'Installed': 'Установлено',
	'Invalid entry on line %d: %s': 'Некорректная запись в строке %d: %s',
	'Kill-switch': 'Kill-switch',
	'Leave blank to keep the current password': 'Оставьте пустым, чтобы сохранить текущий пароль',
	'Legacy configuration': 'Прежняя конфигурация',
	'MOBIKE': 'MOBIKE',
	'MTProto proxy': 'MTProto proxy',
	'Manage users': 'Управлять пользователями',
	'Managed by app': 'Управляется приложением',
	'Monitoring only': 'Только мониторинг',
	'No active CHILD_SA': 'Нет активной CHILD_SA',
	'Not registered': 'Не зарегистрировано',
	'Off': 'Выкл',
	'On': 'Вкл',
	'OpenWrt package': 'Пакет OpenWrt',
	'Outbound XFRM': 'Исходящий XFRM',
	'Outbound tunnel': 'Исходящий туннель',
	'Overview has not been enabled. The application is monitoring only and does not own the router configuration.': 'Управляемый режим не включён. Приложение только наблюдает и не изменяет конфигурацию роутера.',
	'PBR': 'PBR',
	'PBR or fail-closed protection needs attention.': 'PBR или защита от утечки трафика требуют внимания.',
	'PBR-assigned mark and table / strict enforcement': 'Метка и таблица PBR / строгий контроль маршрута',
	'Performance': 'Производительность',
	'Protected': 'Защищено',
	'Protocol': 'Протокол',
	'Rebuild failed: %s. The previous list is still active.': 'Пересборка не удалась: %s. Предыдущий список все еще активен.',
	'Reconnect tunnel': 'Переподключить туннель',
	'Reload VPN': 'Перезагрузить VPN',
	'Reloading...': 'Перезагружаю...',
	'Reset failed': 'Сброс не удался',
	'Restoring and reconnecting...': 'Восстанавливаю и переподключаю...',
	'Restoring generator...': 'Возвращаю генератор...',
	'Routing': 'Маршрутизация',
	'Routing and services': 'Маршрутизация и сервисы',
	'Runtime mode': 'Текущий режим',
	'SHA-256 fingerprint': 'Отпечаток SHA-256',
	'SafeXcel': 'SafeXcel',
	'Saved. PBR is restarting in the background (~15s).': 'Сохранено. PBR перезапускается в фоне (~15 с).',
	'Saved. Rebuilding the PBR list (manual: %d, services: %d)…': 'Сохранено. Пересобираю PBR-список (вручную: %d, сервисы: %d)…',
	'Saving...': 'Сохраняю...',
	'Server apply failed': 'Не удалось применить сервер',
	'Server disabled': 'Сервер выключен',
	'Software %s, hardware %s': 'Программное %s, аппаратное %s',
	'Some parts of the VPN path need attention': 'Некоторые части VPN-пути требуют внимания',
	'Technical details': 'Технические детали',
	'The VPN path is operating normally': 'VPN-путь работает нормально',
	'The application files are present, but the OpenWrt package is not registered. Package upgrades and dependency checks are not yet reliable.': 'Файлы приложения есть, но пакет OpenWrt не зарегистрирован. Обновления пакета и проверки зависимостей пока ненадежны.',
	'The community catalog is temporarily unavailable. Saved selections and cached lists are preserved.': 'Каталог готовых наборов временно недоступен. Сохранённый выбор и кэшированные списки не изменены.',
	'The components that directly affect client connectivity.': 'Компоненты, напрямую влияющие на подключение клиентов.',
	'The cryptographic and XFRM parameters below are the tested production profile.': 'Ниже указан проверенный рабочий профиль криптографии и XFRM.',
	'The inbound VPN certificate is missing or expires soon.': 'Сертификат входящего VPN отсутствует или скоро истекает.',
	'The outbound tunnel is not carrying IPv4 traffic. Routed domains remain blocked by the kill-switch.': 'Исходящий туннель не передаёт IPv4-трафик. Выбранные домены остаются заблокированы защитой от утечки.',
	'Traffic protected': 'Трафик защищен',
	'Traffic to VPN only for domains in the list.': 'В VPN идет только трафик к доменам из списка.',
	'Unable to save the domain list: %s': 'Не удалось сохранить список доменов: %s',
	'Uptime %s; %s IKE SA': 'Работает %s · IKE SA: %s',
	'Use the checks on the right and the notices below to find the affected component.': 'Используйте проверки справа и уведомления ниже, чтобы найти проблемный компонент.',
	'VPN Control Center': 'Центр управления VPN',
	'Validating and loading...': 'Проверяю и загружаю...',
	'Validating and reconnecting...': 'Проверяю и переподключаю...',
	'XFRM interface': 'XFRM-интерфейс',
	'broad': 'широкий',
	'local': 'локальный',
	'strongSwan': 'strongSwan',
	'unknown error': 'неизвестная ошибка',
	'zapret': 'zapret'
};

function defaultLanguage() {
	if (typeof window === 'undefined')
		return 'en';
	var saved = window.localStorage && window.localStorage.getItem(LANG_KEY);
	if (saved === 'ru' || saved === 'en')
		return saved;
	return (window.navigator && /^ru\b/i.test(window.navigator.language || '')) ? 'ru' : 'en';
}

function translate(text) {
	var value = nativeTranslate ? nativeTranslate(text) : text;
	if (defaultLanguage() === 'ru' && ru[text])
		return ru[text];
	return value;
}

// Every LuCI resource is evaluated inside its own function wrapper, so this
// shadows the global _() for this module only. Assigning window._ instead used
// to leak the map below into every other application: the Status Overview page
// loads our widget, and generic keys such as "Apply", "Actions", "Connected" or
// "Architecture" then replaced the system widgets' own strings whenever the
// browser locale was Russian, regardless of the language LuCI is configured to
// use. Consumers of this module install the same shadow from common.t.
var _ = translate;

function parseKeyValues(text) {
	var result = {};
	(text || '').replace(/\r/g, '').split('\n').forEach(function(line) {
		var p = line.indexOf('=');
		if (p > 0)
			result[line.slice(0, p)] = line.slice(p + 1);
	});
	return result;
}

function parseSwanmon(result) {
	try {
		var parsed = JSON.parse((result && result.stdout) || '{}');
		return parsed.data || [];
	}
	catch (e) {
		return [];
	}
}

function formatBytes(value) {
	var n = Number(value || 0);
	var units = [ 'B', 'KiB', 'MiB', 'GiB', 'TiB' ];
	var i = 0;
	while (n >= 1024 && i < units.length - 1) {
		n /= 1024;
		i++;
	}
	return '%s %s'.format(i ? n.toFixed(1) : n.toFixed(0), units[i]);
}

function formatDuration(value) {
	var seconds = Number(value || 0);
	var days = Math.floor(seconds / 86400);
	var hours = Math.floor(seconds % 86400 / 3600);
	var minutes = Math.floor(seconds % 3600 / 60);
	var russian = defaultLanguage() === 'ru';
	if (days)
		return russian ? '%d д %d ч'.format(days, hours) : '%dd %dh'.format(days, hours);
	if (hours)
		return russian ? '%d ч %d мин'.format(hours, minutes) : '%dh %dm'.format(hours, minutes);
	if (minutes)
		return russian ? '%d мин'.format(minutes) : '%dm'.format(minutes);
	return russian ? '%d с'.format(Math.max(0, seconds)) : '%ds'.format(Math.max(0, seconds));
}

function formatDate(value) {
	var date = new Date(value);
	if (isNaN(date.getTime()))
		return value || _('Unknown');
	return new Intl.DateTimeFormat(defaultLanguage() === 'ru' ? 'ru-RU' : 'en-US', {
		year: 'numeric',
		month: 'short',
		day: 'numeric'
	}).format(date);
}

function daysUntil(value) {
	var date = new Date(value);
	if (isNaN(date.getTime()))
		return null;
	return Math.ceil((date.getTime() - Date.now()) / 86400000);
}

var STYLE_ID = 'ikev2-manager-styles-v4';

var CSS = `
			.ikev2-page {
				--ikev2-accent: #4f7dff;
				--ikev2-accent-2: #8b5cf6;
				--ikev2-grad: linear-gradient(135deg, #4f7dff, #8b5cf6);
				--ikev2-grad-soft: linear-gradient(135deg,
					color-mix(in srgb, #4f7dff 16%, transparent),
					color-mix(in srgb, #8b5cf6 12%, transparent));
				--ikev2-border: rgba(128, 128, 128, .22);
				--ikev2-border-strong: rgba(128, 128, 128, .34);
				--ikev2-surface: rgba(128, 128, 128, .06);
				--ikev2-surface-2: rgba(128, 128, 128, .11);
				--ikev2-muted: rgba(128, 128, 128, .85);
				--ikev2-good: #16a34a;
				--ikev2-warn: #d97706;
				--ikev2-bad: #e11d48;
				--ikev2-info: #2f6fbe;
				--ikev2-radius: 16px;
				--ikev2-radius-sm: 11px;
				--ikev2-shadow: 0 1px 2px rgba(0, 0, 0, .05), 0 10px 30px -18px rgba(0, 0, 0, .45);
				--ikev2-shadow-lg: 0 2px 8px rgba(0, 0, 0, .08), 0 24px 50px -22px rgba(0, 0, 0, .55);
				max-width: 1220px;
				font-feature-settings: "tnum" 0;
			}
			.ikev2-page * { box-sizing: border-box; }

			/* ── Header ─────────────────────────────────────────────── */
			.ikev2-header {
				display: flex;
				align-items: flex-start;
				justify-content: space-between;
				gap: 1.25rem;
				margin: 0 0 1.5rem;
			}
			.ikev2-header h2 {
				margin: 0 0 .35rem;
				font-size: clamp(1.45rem, 2.6vw, 1.85rem);
				font-weight: 750;
				letter-spacing: -.015em;
			}
			.ikev2-subtitle {
				margin: 0;
				max-width: 780px;
				color: var(--ikev2-muted);
				line-height: 1.55;
			}
			.ikev2-header-actions {
				display: flex;
				align-items: center;
				justify-content: flex-end;
				flex-wrap: wrap;
				gap: .55rem;
			}
			.ikev2-language {
				display: inline-flex;
				align-items: center;
				gap: .4rem;
				padding: .2rem .5rem;
				border: 1px solid var(--ikev2-border);
				border-radius: 999px;
				background: var(--ikev2-surface);
				font-size: .78rem;
				white-space: nowrap;
			}
			.ikev2-language select {
				min-width: 5.4rem;
				height: 1.8rem;
				padding: 0 .5rem;
				border-radius: 999px !important;
			}

			/* ── Grid + cards ───────────────────────────────────────── */
			.ikev2-grid {
				display: grid;
				grid-template-columns: repeat(12, minmax(0, 1fr));
				gap: 1rem;
				margin: 1.1rem 0;
			}
			.ikev2-card {
				grid-column: span 3;
				min-width: 0;
				position: relative;
				overflow: hidden;
				padding: 1.1rem 1.15rem;
				border: 1px solid var(--ikev2-border);
				border-radius: var(--ikev2-radius);
				background: var(--ikev2-surface);
				box-shadow: var(--ikev2-shadow);
				transition: transform .16s ease, box-shadow .16s ease, border-color .16s ease;
			}
			.ikev2-card::before {
				content: "";
				position: absolute;
				inset: 0 0 auto 0;
				height: 3px;
				background: var(--ikev2-grad);
				opacity: .25;
				transition: opacity .16s ease;
			}
			.ikev2-card:hover {
				transform: translateY(-3px);
				box-shadow: var(--ikev2-shadow-lg);
				border-color: var(--ikev2-border-strong);
			}
			.ikev2-card:hover::before { opacity: 1; }
			.ikev2-card.wide { grid-column: span 6; }
			.ikev2-card.full { grid-column: 1 / -1; }
			.ikev2-card-label {
				margin-bottom: .5rem;
				font-size: .72rem;
				font-weight: 650;
				letter-spacing: .07em;
				text-transform: uppercase;
				color: var(--ikev2-muted);
			}
			.ikev2-card-value {
				display: flex;
				align-items: center;
				gap: .5rem;
				min-height: 1.8rem;
				font-size: clamp(1.4rem, 2.4vw, 1.7rem);
				font-weight: 740;
				line-height: 1.15;
				letter-spacing: -.02em;
				font-variant-numeric: tabular-nums;
				overflow-wrap: anywhere;
			}
			.ikev2-card-detail {
				margin-top: .5rem;
				font-size: .84rem;
				line-height: 1.5;
				color: var(--ikev2-muted);
				overflow-wrap: anywhere;
			}

			/* ── Hero ───────────────────────────────────────────────── */
			.ikev2-hero {
				display: grid;
				grid-template-columns: minmax(0, 1.6fr) minmax(17rem, .85fr);
				gap: 1.25rem;
				margin: 0 0 1.1rem;
				padding: 1.4rem 1.5rem;
				border: 1px solid var(--ikev2-border);
				border-radius: var(--ikev2-radius);
				background:
					radial-gradient(120% 140% at 0% 0%, color-mix(in srgb, var(--ikev2-accent) 18%, transparent), transparent 55%),
					radial-gradient(120% 160% at 100% 0%, color-mix(in srgb, var(--ikev2-accent-2) 16%, transparent), transparent 55%),
					var(--ikev2-surface);
				box-shadow: var(--ikev2-shadow);
			}
			.ikev2-hero h3 {
				margin: 0 0 .4rem;
				font-size: 1.3rem;
				font-weight: 720;
				letter-spacing: -.01em;
			}
			.ikev2-hero p { margin: 0; color: var(--ikev2-muted); line-height: 1.55; }
			.ikev2-hero-side {
				display: flex;
				flex-direction: column;
				gap: 1rem;
				align-items: center;
				justify-content: center;
			}

			/* ── Gauge (donut) ──────────────────────────────────────── */
			.ikev2-gauge {
				position: relative;
				width: 132px;
				height: 132px;
				flex: none;
			}
			.ikev2-gauge__ring {
				position: absolute;
				inset: 0;
				border-radius: 50%;
				background: conic-gradient(var(--rc, var(--ikev2-good)) calc(var(--val, 0) * 1%),
					var(--ikev2-surface-2) 0);
				-webkit-mask: radial-gradient(farthest-side, transparent 63%, #000 65%);
				mask: radial-gradient(farthest-side, transparent 63%, #000 65%);
				transition: --val .6s ease;
			}
			.ikev2-gauge__center {
				position: absolute;
				inset: 0;
				display: grid;
				place-content: center;
				text-align: center;
			}
			.ikev2-gauge__center b {
				font-size: 1.55rem;
				font-weight: 760;
				line-height: 1;
				font-variant-numeric: tabular-nums;
			}
			.ikev2-gauge__center span {
				display: block;
				margin-top: .2rem;
				font-size: .68rem;
				letter-spacing: .06em;
				text-transform: uppercase;
				color: var(--ikev2-muted);
			}

			/* ── Health list ────────────────────────────────────────── */
			.ikev2-health-list {
				display: grid;
				gap: .15rem;
				width: 100%;
				align-content: center;
			}
			.ikev2-health-row {
				display: flex;
				align-items: center;
				justify-content: space-between;
				gap: 1rem;
				padding: .5rem .15rem;
				border-bottom: 1px solid var(--ikev2-border);
			}
			.ikev2-health-row:last-child { border-bottom: 0; }
			.ikev2-health-copy {
				display: flex;
				flex-direction: column;
				min-width: 0;
			}
			.ikev2-health-copy .ikev2-toggle-sub {
				display: block;
				margin-top: .15rem;
				font-size: .86rem;
				font-weight: 400;
				line-height: 1.45;
				color: var(--ikev2-muted);
			}

			/* ── Issues ─────────────────────────────────────────────── */
			.ikev2-issue-list { display: grid; gap: .6rem; margin: 1.1rem 0; }
			.ikev2-issue {
				padding: .8rem .95rem .8rem 1rem;
				border: 1px solid color-mix(in srgb, var(--ikev2-warn) 32%, var(--ikev2-border));
				border-left: .26rem solid var(--ikev2-warn);
				border-radius: var(--ikev2-radius-sm);
				background: color-mix(in srgb, var(--ikev2-warn) 8%, transparent);
				line-height: 1.5;
			}

			/* ── Quick links ────────────────────────────────────────── */
			.ikev2-quick-link {
				display: inline-flex;
				align-items: center;
				min-height: 2.3rem;
				padding: .45rem .85rem;
				border: 1px solid var(--ikev2-border);
				border-radius: var(--ikev2-radius-sm);
				background: color-mix(in srgb, currentColor 5%, transparent);
				text-decoration: none;
				font-weight: 620;
				transition: background .14s ease, transform .14s ease, border-color .14s ease;
			}
			.ikev2-quick-link:hover {
				background: var(--ikev2-surface-2);
				border-color: var(--ikev2-border-strong);
				transform: translateY(-1px);
			}

			/* ── Pills ──────────────────────────────────────────────── */
			.ikev2-pill {
				display: inline-flex;
				align-items: center;
				gap: .4rem;
				padding: .26rem .65rem;
				border: 1px solid color-mix(in srgb, currentColor 30%, transparent);
				border-radius: 999px;
				background: color-mix(in srgb, currentColor 12%, transparent);
				font-size: .78rem;
				font-weight: 660;
				line-height: 1.2;
				white-space: nowrap;
			}
			.ikev2-pill::before {
				content: "";
				width: .48rem;
				height: .48rem;
				border-radius: 50%;
				background: currentColor;
				box-shadow: 0 0 0 .18rem color-mix(in srgb, currentColor 22%, transparent);
			}
			.ikev2-pill.good { color: var(--ikev2-good); }
			.ikev2-pill.warn { color: var(--ikev2-warn); }
			.ikev2-pill.bad { color: var(--ikev2-bad); }
			.ikev2-pill.info { color: var(--ikev2-info); }
			.ikev2-pill.neutral {
				color: var(--ikev2-muted);
				background: var(--ikev2-surface-2);
				border-color: var(--ikev2-border);
			}

			/* ── Sections ───────────────────────────────────────────── */
			.ikev2-section {
				margin: 1.1rem 0;
				padding: 1.25rem 1.3rem;
				border: 1px solid var(--ikev2-border);
				border-radius: var(--ikev2-radius);
				background: var(--ikev2-surface);
				box-shadow: var(--ikev2-shadow);
			}
			.ikev2-section-head {
				display: flex;
				align-items: flex-start;
				justify-content: space-between;
				gap: 1rem;
				margin-bottom: 1rem;
			}
			.ikev2-section-head h3,
			.ikev2-section-head h4 { margin: 0 0 .3rem; font-weight: 700; letter-spacing: -.01em; }
			.ikev2-section-head p { margin: 0; color: var(--ikev2-muted); line-height: 1.5; }
			.ikev2-engine {
				display: block;
			}
			.ikev2-engine-head {
				display: flex;
				align-items: center;
				justify-content: space-between;
				gap: 1.25rem;
			}
			.ikev2-engine-state {
				display: grid;
				justify-items: start;
				gap: .55rem;
				min-width: 0;
			}
			.ikev2-engine-summary {
				margin: 0;
				max-width: 52rem;
				color: var(--ikev2-muted);
				line-height: 1.5;
			}
			.ikev2-engine-action {
				display: flex;
				align-items: center;
				justify-content: flex-end;
				flex-wrap: wrap;
				gap: .65rem;
				flex: none;
			}
			.ikev2-engine-action .cbi-button {
				min-width: 11.5rem;
			}
			.ikev2-actions {
				display: flex;
				align-items: center;
				flex-wrap: wrap;
				gap: .6rem;
			}
			.ikev2-icon-button {
				display: inline-flex !important;
				align-items: center;
				justify-content: center;
				gap: .42rem;
				min-height: 2.25rem;
				padding: .42rem .72rem !important;
				border-radius: .72rem !important;
				font-weight: 650;
				white-space: nowrap;
			}
			.ikev2-icon {
				width: 1rem;
				height: 1rem;
				flex: none;
				fill: none;
				stroke: currentColor;
				stroke-width: 1.9;
				stroke-linecap: round;
				stroke-linejoin: round;
			}

			/* ── Key/value table ────────────────────────────────────── */
			.ikev2-kv { width: 100%; border-collapse: collapse; }
			.ikev2-kv td {
				padding: .58rem .25rem;
				border-top: 1px solid var(--ikev2-border);
				vertical-align: top;
				line-height: 1.45;
			}
			.ikev2-kv tr:first-child td { border-top: 0; }
			.ikev2-kv td:first-child {
				width: 34%;
				padding-right: 1rem;
				color: var(--ikev2-muted);
			}
			.ikev2-deps-summary {
				padding: .8rem 1rem;
				border: 1px solid var(--ikev2-border);
				border-radius: var(--ikev2-radius-sm);
				background: var(--ikev2-surface-2);
			}
			.ikev2-deps-summary h4 {
				margin: 0 0 .55rem;
				font-size: .82rem;
				color: var(--ikev2-muted);
			}
			.ikev2-diagnostics {
				margin-top: .85rem;
				border: 1px solid var(--ikev2-border);
				border-radius: var(--ikev2-radius-sm);
				background: color-mix(in srgb, var(--ikev2-surface) 80%, transparent);
			}
			.ikev2-diagnostics > summary {
				display: flex;
				align-items: center;
				gap: .5rem;
				padding: .75rem .9rem;
				cursor: pointer;
				font-weight: 650;
				list-style: none;
			}
			.ikev2-diagnostics > summary::-webkit-details-marker { display: none; }
			.ikev2-diagnostics > summary::before {
				content: "\\203A";
				font-size: 1.2rem;
				line-height: 1;
				transition: transform .15s ease;
			}
			.ikev2-diagnostics[open] > summary::before { transform: rotate(90deg); }
			.ikev2-diagnostics-body {
				padding: 0 .9rem .8rem;
				border-top: 1px solid var(--ikev2-border);
			}

			/* ── VPN user cards ─────────────────────────────────────── */
			.ikev2-windows-app {
				display: grid;
				grid-template-columns: auto minmax(12rem, 1fr) auto auto;
				align-items: center;
				gap: .85rem;
				width: 100%;
				margin: 0 0 1rem;
				padding: .7rem .8rem;
				border: 1px solid var(--ikev2-border);
				border-radius: var(--ikev2-radius-sm);
				background: var(--ikev2-surface-2);
			}
			.ikev2-windows-app-mark {
				display: grid;
				place-content: center;
				width: 2.35rem;
				height: 2.35rem;
				border-radius: .72rem;
				background: var(--ikev2-grad-soft);
				color: var(--ikev2-accent);
			}
			.ikev2-windows-app-mark .ikev2-icon { width: 1.15rem; height: 1.15rem; }
			.ikev2-windows-app-copy { display: grid; gap: .14rem; min-width: 0; }
			.ikev2-windows-app-copy span { color: var(--ikev2-muted); font-size: .84rem; }
			.ikev2-user-list { display: grid; gap: .75rem; }
			.ikev2-user-card {
				display: grid;
				grid-template-columns: minmax(10rem, .8fr) minmax(18rem, 1.6fr) auto;
				align-items: center;
				gap: 1rem;
				padding: .9rem 1rem;
				border: 1px solid var(--ikev2-border);
				border-radius: var(--ikev2-radius-sm);
				background: var(--ikev2-surface-2);
			}
			.ikev2-user-identity {
				display: flex;
				align-items: center;
				gap: .65rem;
				min-width: 0;
			}
			.ikev2-user-avatar {
				display: grid;
				place-content: center;
				width: 2.25rem;
				height: 2.25rem;
				flex: none;
				border-radius: .75rem;
				background: var(--ikev2-grad-soft);
				color: var(--ikev2-accent);
				font-weight: 760;
				text-transform: uppercase;
			}
			.ikev2-user-name {
				display: block;
				margin-bottom: .28rem;
				overflow: hidden;
				text-overflow: ellipsis;
			}
			.ikev2-session-list { display: grid; gap: .5rem; min-width: 0; }
			.ikev2-session {
				display: flex;
				align-items: center;
				justify-content: space-between;
				gap: .8rem;
				min-width: 0;
			}
			.ikev2-session-main { min-width: 0; }
			.ikev2-session-address {
				display: block;
				margin-bottom: .2rem;
				font-weight: 650;
				overflow-wrap: anywhere;
			}
			.ikev2-session-meta {
				display: flex;
				align-items: center;
				flex-wrap: wrap;
				gap: .3rem .75rem;
				color: var(--ikev2-muted);
				font-size: .82rem;
			}
			.ikev2-traffic {
				display: inline-flex;
				align-items: center;
				gap: .22rem;
				font-variant-numeric: tabular-nums;
				white-space: nowrap;
			}
			.ikev2-traffic .ikev2-icon {
				width: .78rem;
				height: .78rem;
				stroke-width: 2.25;
			}
			.ikev2-traffic.received { color: color-mix(in srgb, var(--ikev2-good) 78%, var(--ikev2-muted)); }
			.ikev2-traffic.sent { color: color-mix(in srgb, var(--ikev2-info) 82%, var(--ikev2-muted)); }
			.ikev2-user-actions {
				display: flex;
				align-items: center;
				justify-content: flex-end;
				flex-wrap: wrap;
				gap: .45rem;
			}
			.ikev2-profile-actions {
				display: inline-flex;
				align-items: center;
				gap: .35rem;
				padding-right: .55rem;
				margin-right: .1rem;
				border-right: 1px solid var(--ikev2-border);
			}
			.ikev2-platform-action {
				display: inline-grid !important;
				place-content: center;
				width: 2.35rem;
				height: 2.35rem;
				min-width: 2.35rem !important;
				padding: 0 !important;
			}
			.ikev2-device-policy-scroll { overflow-x: auto; }
			.ikev2-device-policy-table {
				display: grid;
				gap: .45rem;
				min-width: 48rem;
			}
			.ikev2-device-policy-row {
				display: grid;
				grid-template-columns: minmax(12rem, 1.5fr) minmax(7rem, .65fr)
					repeat(3, 4rem) minmax(9rem, .8fr) 2.6rem;
				align-items: center;
				gap: .65rem;
				padding: .68rem .75rem;
				border: 1px solid var(--ikev2-border);
				border-radius: var(--ikev2-radius-sm);
				background: var(--ikev2-surface-2);
			}
			.ikev2-device-policy-row.head {
				padding-block: .3rem;
				border: 0;
				background: transparent;
				color: var(--ikev2-muted);
				font-size: .72rem;
				font-weight: 700;
				letter-spacing: .05em;
				text-transform: uppercase;
			}
			.ikev2-device-policy-name { display: grid; gap: .18rem; min-width: 0; }
			.ikev2-device-policy-name code { overflow-wrap: anywhere; }
			.ikev2-device-policy-traffic {
				color: var(--ikev2-muted);
				font-size: .82rem;
				font-variant-numeric: tabular-nums;
				white-space: nowrap;
			}
			.ikev2-policy-check {
				display: inline-grid;
				place-content: center;
				justify-self: start;
				width: 2rem;
				height: 2rem;
				cursor: pointer;
			}
			.ikev2-policy-check input {
				position: absolute;
				opacity: 0;
				pointer-events: none;
			}
			.ikev2-policy-check span {
				display: grid;
				place-content: center;
				width: 1.2rem;
				height: 1.2rem;
				border: 1px solid var(--ikev2-border-strong);
				border-radius: .32rem;
				background: var(--ikev2-surface);
			}
			.ikev2-policy-check input:checked + span {
				border-color: transparent;
				background-image: var(--ikev2-grad);
			}
			.ikev2-policy-check input:checked + span::after {
				content: "\\2713";
				color: #fff;
				font-size: .78rem;
				font-weight: 800;
			}
			.ikev2-policy-check input:focus-visible + span {
				box-shadow: 0 0 0 3px color-mix(in srgb, var(--ikev2-accent) 24%, transparent);
			}
			.ikev2-policy-check input:disabled + span { opacity: .5; cursor: wait; }
			.ikev2-policy-na { color: var(--ikev2-muted); }
			.ikev2-square-action {
				display: inline-grid !important;
				place-content: center;
				width: 2.35rem;
				height: 2.35rem;
				min-width: 2.35rem !important;
				padding: 0 !important;
			}
			.ikev2-status-widget { display: grid; gap: .75rem; }
			.ikev2-widget-summary {
				display: flex;
				align-items: center;
				justify-content: space-between;
				gap: .75rem;
			}
			.ikev2-widget-summary-label {
				color: var(--ikev2-muted);
				font-size: .78rem;
				font-weight: 650;
				letter-spacing: .05em;
				text-transform: uppercase;
			}
			.ikev2-widget-overview {
				display: grid;
				grid-template-columns: repeat(3, minmax(0, 1fr));
				gap: .65rem;
			}
			.ikev2-widget-component {
				display: flex;
				flex-direction: column;
				min-width: 0;
				padding: .82rem .85rem;
				border: 1px solid var(--ikev2-border);
				border-radius: var(--ikev2-radius-sm);
				background: var(--ikev2-surface-2);
			}
			.ikev2-widget-component-label {
				margin-bottom: .5rem;
				color: var(--ikev2-muted);
				font-size: .7rem;
				font-weight: 650;
				letter-spacing: .06em;
				text-transform: uppercase;
			}
			.ikev2-widget-component-head {
				display: flex;
				align-items: center;
				min-height: 1.65rem;
			}
			.ikev2-widget-component-detail {
				margin-top: .48rem;
				color: var(--ikev2-muted);
				font-size: .82rem;
				line-height: 1.4;
			}
			.ikev2-widget-component-meta {
				display: flex;
				align-items: center;
				flex-wrap: wrap;
				gap: .35rem .7rem;
				margin-top: auto;
				padding-top: .52rem;
				color: var(--ikev2-muted);
				font-size: .78rem;
			}
			.ikev2-widget-component-meta .ikev2-traffic {
				color: var(--ikev2-muted);
			}
			.ikev2-widget-clients {
				display: grid;
				gap: .55rem;
				padding-top: .15rem;
			}
			.ikev2-widget-clients-head {
				display: flex;
				align-items: center;
				justify-content: space-between;
				gap: .75rem;
			}
			.ikev2-widget-client-list { display: grid; gap: .55rem; }
			.ikev2-widget-client {
				display: grid;
				grid-template-columns: minmax(10rem, 1fr) auto auto;
				align-items: center;
				gap: .75rem 1rem;
				padding: .72rem .8rem;
				border: 1px solid var(--ikev2-border);
				border-radius: var(--ikev2-radius-sm);
				background: var(--ikev2-surface-2);
			}
			.ikev2-widget-client-name { min-width: 0; }
			.ikev2-widget-address,
			.ikev2-widget-duration {
				color: var(--ikev2-muted);
				font-size: .82rem;
			}
			.ikev2-widget-address {
				display: block;
				overflow-wrap: anywhere;
			}
			.ikev2-widget-duration { white-space: nowrap; }
			.ikev2-widget-traffic {
				display: inline-flex;
				align-items: center;
				justify-content: flex-end;
				gap: .65rem;
			}
			.ikev2-widget-footer {
				display: flex;
				justify-content: flex-end;
			}

			/* ── Notes ──────────────────────────────────────────────── */
			.ikev2-note {
				padding: .9rem 1rem;
				border: 1px solid color-mix(in srgb, var(--ikev2-info) 30%, var(--ikev2-border));
				border-left: .26rem solid var(--ikev2-info);
				border-radius: var(--ikev2-radius-sm);
				background: color-mix(in srgb, var(--ikev2-info) 7%, transparent);
				line-height: 1.5;
			}
			.ikev2-note.warn {
				border-color: color-mix(in srgb, var(--ikev2-warn) 32%, var(--ikev2-border));
				border-left-color: var(--ikev2-warn);
				background: color-mix(in srgb, var(--ikev2-warn) 8%, transparent);
			}
			.ikev2-note.bad {
				border-color: color-mix(in srgb, var(--ikev2-bad) 32%, var(--ikev2-border));
				border-left-color: var(--ikev2-bad);
				background: color-mix(in srgb, var(--ikev2-bad) 8%, transparent);
			}

			/* ── Forms ──────────────────────────────────────────────── */
			.ikev2-form-grid {
				display: grid;
				grid-template-columns: minmax(11rem, 1fr) minmax(18rem, 2fr);
				gap: .9rem 1.4rem;
				align-items: center;
			}
			.ikev2-field-label { font-weight: 620; }
			.ikev2-field-help {
				display: block;
				margin-top: .22rem;
				font-size: .8rem;
				font-weight: 400;
				color: var(--ikev2-muted);
			}
			.ikev2-page input[type="text"],
			.ikev2-page input[type="password"],
			.ikev2-page input[type="number"],
			.ikev2-page select,
			.ikev2-page textarea {
				border: 1px solid var(--ikev2-border);
				border-radius: var(--ikev2-radius-sm);
				background: color-mix(in srgb, currentColor 3%, transparent);
				padding: .5rem .65rem;
				transition: border-color .14s ease, box-shadow .14s ease;
			}
			/* The bootstrap theme pins input and select to a fixed height: 30px
			   with box-sizing: border-box. Together with the padding above that
			   leaves roughly 12px for a line box that needs about 18px. Blink on
			   macOS lets the glyphs overflow, but Edge on Windows clips the
			   descenders of the selected option. Size these controls by their
			   content and keep a floor that matches the buttons next to them. */
			.ikev2-page input[type="text"],
			.ikev2-page input[type="password"],
			.ikev2-page input[type="number"],
			.ikev2-page select,
			.ikev2-page textarea {
				height: auto;
				min-height: 2.25rem;
				line-height: 1.35;
			}
			.ikev2-page textarea,
			.ikev2-page select[multiple] { min-height: 6rem; }
			.ikev2-form-grid input[type="text"],
			.ikev2-form-grid input[type="password"],
			.ikev2-form-grid input[type="number"] { width: 100%; max-width: 34rem; }
			.ikev2-form-grid textarea,
			.ikev2-form-grid select { width: 100%; max-width: 34rem; }
			.ikev2-form-grid-compact {
				grid-template-columns: minmax(13rem, 19rem) minmax(0, 1fr);
				align-items: start;
			}
			.ikev2-form-grid-compact > .ikev2-field-label { padding-top: .48rem; }
			.ikev2-form-grid-compact input[type="text"],
			.ikev2-form-grid-compact input[type="password"],
			.ikev2-form-grid-compact input[type="number"],
			.ikev2-form-grid-compact select,
			.ikev2-form-grid-compact textarea { max-width: none; }
			.ikev2-choice-custom {
				display: grid;
				gap: .55rem;
				width: 100%;
			}
			.ikev2-choice-custom > select,
			.ikev2-choice-custom > input { max-width: none; }
			.ikev2-choice-list {
				display: grid;
				grid-template-columns: repeat(auto-fit, minmax(10rem, 1fr));
				gap: .45rem;
			}
			.ikev2-choice-list label {
				display: flex;
				align-items: center;
				gap: .5rem;
				min-height: 2.4rem;
				padding: .45rem .65rem;
				border: 1px solid var(--ikev2-border);
				border-radius: var(--ikev2-radius-sm);
				background: var(--ikev2-surface);
				cursor: pointer;
			}
			.ikev2-choice-list input { margin: 0; }
			.ikev2-dns-managed { margin-top: 1rem; }
			.ikev2-dns-preset-picker {
				display: grid;
				grid-template-columns: minmax(0, 1fr) auto;
				gap: .55rem;
				max-width: 34rem;
			}
			.ikev2-dns-preset-picker select { max-width: none; }
			.ikev2-dns-editor {
				display: grid;
				gap: .55rem;
				width: 100%;
				max-width: 34rem;
			}
			.ikev2-dns-endpoints { display: grid; gap: .45rem; }
			.ikev2-dns-endpoint {
				display: grid;
				grid-template-columns: minmax(0, 1fr) 2.35rem;
				gap: .45rem;
				align-items: center;
			}
			.ikev2-dns-endpoint input[type="text"] {
				width: 100%;
				max-width: none;
				font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
				font-size: .85rem;
			}
			.ikev2-dns-endpoint .cbi-button {
				min-width: 2.35rem;
				padding-inline: .55rem;
			}
			.ikev2-dns-empty {
				padding: .58rem .7rem;
				border: 1px dashed var(--ikev2-border);
				border-radius: var(--ikev2-radius-sm);
				color: var(--ikev2-muted);
				font-size: .84rem;
			}
			.ikev2-dns-editor-actions {
				display: flex;
				justify-content: flex-start;
			}
			.ikev2-page input:focus,
			.ikev2-page select:focus,
			.ikev2-page textarea:focus {
				outline: none;
				border-color: var(--ikev2-accent);
				box-shadow: 0 0 0 3px color-mix(in srgb, var(--ikev2-accent) 24%, transparent);
			}
			.ikev2-readonly {
				display: inline-block;
				padding: .4rem .6rem;
				border-radius: var(--ikev2-radius-sm);
				background: var(--ikev2-surface-2);
				font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
				overflow-wrap: anywhere;
			}

			/* ── Buttons (scoped) ───────────────────────────────────── */
			.ikev2-page .cbi-button {
				border-radius: var(--ikev2-radius-sm);
				padding: .5rem 1rem;
				border: 1px solid var(--ikev2-border);
				background: var(--ikev2-surface-2);
				font-weight: 620;
				line-height: 1.2;
				cursor: pointer;
				transition: transform .12s ease, box-shadow .14s ease,
					background .14s ease, border-color .14s ease, filter .14s ease;
			}
			.ikev2-page .cbi-button:hover {
				background: color-mix(in srgb, currentColor 12%, transparent);
				border-color: var(--ikev2-border-strong);
				transform: translateY(-1px);
			}
			.ikev2-page .cbi-button:active { transform: translateY(0); }
			.ikev2-page .cbi-button-apply,
			.ikev2-page .cbi-button-positive,
			.ikev2-page .cbi-button-add,
			.ikev2-page .cbi-button-save {
				background-image: var(--ikev2-grad);
				border-color: transparent;
				color: #fff;
				box-shadow: 0 8px 20px -10px var(--ikev2-accent);
			}
			.ikev2-page .cbi-button-apply:hover,
			.ikev2-page .cbi-button-positive:hover,
			.ikev2-page .cbi-button-add:hover,
			.ikev2-page .cbi-button-save:hover {
				filter: brightness(1.06);
				background-image: var(--ikev2-grad);
			}
			.ikev2-page .cbi-button-action,
			.ikev2-page .cbi-button-edit {
				border-color: color-mix(in srgb, var(--ikev2-accent) 45%, var(--ikev2-border));
				color: var(--ikev2-accent);
			}
			.ikev2-page .cbi-button-remove,
			.ikev2-page .cbi-button-negative {
				color: var(--ikev2-bad);
				border-color: color-mix(in srgb, var(--ikev2-bad) 40%, var(--ikev2-border));
			}
			.ikev2-page .cbi-button-remove:hover,
			.ikev2-page .cbi-button-negative:hover {
				background: color-mix(in srgb, var(--ikev2-bad) 12%, transparent);
			}
			.ikev2-page button[disabled] { opacity: .55; cursor: wait; transform: none; }

			/* ── Toggle switch ──────────────────────────────────────── */
			.ikev2-switch {
				display: inline-flex;
				align-items: center;
				gap: .6rem;
				cursor: pointer;
				user-select: none;
			}
			.ikev2-switch input {
				position: absolute;
				opacity: 0;
				width: 0;
				height: 0;
			}
			.ikev2-switch-track {
				position: relative;
				flex: none;
				width: 3.05rem;
				height: 1.7rem;
				border-radius: 999px;
				border: 1px solid var(--ikev2-border);
				background: var(--ikev2-surface-2);
				transition: background .16s ease, border-color .16s ease;
			}
			.ikev2-switch-track::after {
				content: "";
				position: absolute;
				top: 50%;
				left: .2rem;
				transform: translateY(-50%);
				width: 1.25rem;
				height: 1.25rem;
				border-radius: 50%;
				background: #fff;
				box-shadow: 0 1px 3px rgba(0, 0, 0, .35);
				transition: left .16s ease;
			}
			.ikev2-switch input:checked + .ikev2-switch-track {
				background-image: var(--ikev2-grad);
				border-color: transparent;
			}
			.ikev2-switch input:checked + .ikev2-switch-track::after {
				left: calc(100% - 1.45rem);
			}
			.ikev2-switch input:focus-visible + .ikev2-switch-track {
				box-shadow: 0 0 0 3px color-mix(in srgb, var(--ikev2-accent) 24%, transparent);
			}
			.ikev2-switch input:disabled + .ikev2-switch-track { opacity: .5; cursor: not-allowed; }
			.ikev2-switch-text { font-weight: 620; }

			/* ── Toggle row (label + switch on one line) ─────────────── */
			.ikev2-toggle-row {
				display: flex;
				align-items: center;
				justify-content: space-between;
				gap: 1rem;
				padding: .85rem 1rem;
				border: 1px solid var(--ikev2-border);
				border-radius: .7rem;
				background: var(--ikev2-surface-2);
			}
			.ikev2-toggle-row .ikev2-toggle-text { font-weight: 640; }
			.ikev2-toggle-row .ikev2-toggle-sub {
				display: block;
				font-weight: 400;
				font-size: .86rem;
				color: var(--ikev2-muted);
				margin-top: .15rem;
			}

			/* ── Inline action result (next to buttons) ──────────────── */
			.ikev2-result {
				display: inline-flex;
				align-items: center;
				gap: .35rem;
				max-width: 26rem;
				font-size: .88rem;
				font-weight: 560;
				white-space: nowrap;
				overflow: hidden;
				text-overflow: ellipsis;
			}
			.ikev2-result.busy { color: var(--ikev2-muted); }
			.ikev2-result.ok { color: var(--ikev2-good, #16a34a); }
			.ikev2-result.warn { color: var(--ikev2-warn, #d97706); }
			.ikev2-result.err { color: var(--ikev2-bad, #dc2626); }
			.ikev2-save-bar {
				margin-top: 1.4rem;
				padding-top: 1.1rem;
				border-top: 1px solid var(--ikev2-border);
			}

			/* ── Advanced disclosure ────────────────────────────────── */
			.ikev2-advanced {
				margin-top: 1.1rem;
				border-top: 1px solid var(--ikev2-border);
				padding-top: .9rem;
			}
			.ikev2-advanced summary,
			.ikev2-section > details > summary {
				cursor: pointer;
				font-weight: 660;
				margin-bottom: .9rem;
				list-style: none;
			}
			.ikev2-advanced summary::-webkit-details-marker { display: none; }
			.ikev2-advanced summary::before {
				content: "\\203A";
				display: inline-block;
				margin-right: .5rem;
				transition: transform .15s ease;
			}
			.ikev2-advanced[open] summary::before { transform: rotate(90deg); }

			/* ── Nested settings disclosures ───────────────────────── */
			.ikev2-disclosure-stack {
				display: grid;
				gap: .7rem;
				margin-top: 1.2rem;
			}
			.ikev2-disclosure {
				border: 1px solid var(--ikev2-border);
				border-radius: var(--ikev2-radius-sm);
				background: color-mix(in srgb, var(--ikev2-surface-2) 70%, transparent);
				overflow: hidden;
			}
			.ikev2-disclosure > summary {
				display: flex;
				align-items: center;
				justify-content: space-between;
				gap: 1rem;
				padding: .9rem 1rem;
				cursor: pointer;
				list-style: none;
			}
			.ikev2-disclosure > summary::-webkit-details-marker { display: none; }
			.ikev2-disclosure > summary::before {
				content: "\\203A";
				flex: none;
				font-size: 1.35rem;
				line-height: 1;
				transition: transform .15s ease;
			}
			.ikev2-disclosure[open] > summary::before { transform: rotate(90deg); }
			.ikev2-disclosure-copy {
				display: flex;
				flex: 1;
				flex-direction: column;
				gap: .18rem;
				min-width: 0;
			}
			.ikev2-disclosure-copy strong { font-weight: 680; }
			.ikev2-disclosure-copy > span {
				color: var(--ikev2-muted);
				font-size: .82rem;
				line-height: 1.4;
			}
			.ikev2-disclosure-badges {
				display: flex;
				align-items: center;
				justify-content: flex-end;
				flex-wrap: wrap;
				gap: .4rem;
			}
			.ikev2-disclosure-body {
				padding: 1rem;
				border-top: 1px solid var(--ikev2-border);
				background: color-mix(in srgb, var(--ikev2-surface) 75%, transparent);
			}
			.ikev2-panel-note {
				margin: 0 0 1rem;
				color: var(--ikev2-muted);
				line-height: 1.5;
			}

			/* ── Password row ───────────────────────────────────────── */
			.ikev2-password {
				display: flex;
				align-items: center;
				gap: .45rem;
				min-width: 15rem;
			}
			.ikev2-password code {
				flex: 1;
				padding: .35rem .5rem;
				border-radius: var(--ikev2-radius-sm);
				background: var(--ikev2-surface-2);
				user-select: all;
				overflow-wrap: anywhere;
			}

			/* ── Empty state ────────────────────────────────────────── */
			.ikev2-empty {
				padding: 1.6rem;
				text-align: center;
				color: var(--ikev2-muted);
				border: 1px dashed var(--ikev2-border-strong);
				border-radius: var(--ikev2-radius);
				background: var(--ikev2-surface);
			}

			/* ── Service catalog ────────────────────────────────────── */
			.ikev2-service-grid {
				display: grid;
				grid-template-columns: repeat(auto-fit, minmax(15rem, 1fr));
				gap: .9rem;
			}
			.ikev2-service-group {
				padding: .95rem 1rem;
				border: 1px solid var(--ikev2-border);
				border-radius: var(--ikev2-radius);
				background: var(--ikev2-surface);
				transition: border-color .14s ease, box-shadow .14s ease;
			}
			.ikev2-service-group:hover {
				border-color: var(--ikev2-border-strong);
				box-shadow: var(--ikev2-shadow);
			}
			.ikev2-service-group h4 {
				margin: 0 0 .6rem;
				padding-bottom: .45rem;
				border-bottom: 1px solid var(--ikev2-border);
				font-weight: 700;
			}
			.ikev2-service-option {
				display: flex;
				align-items: flex-start;
				gap: .55rem;
				margin: .15rem -.4rem;
				padding: .35rem .4rem;
				border-radius: var(--ikev2-radius-sm);
				cursor: pointer;
				transition: background .12s ease;
			}
			.ikev2-service-option:hover { background: var(--ikev2-surface-2); }

			/* ── Compact selectable chips (service catalog) ──────────── */
			.ikev2-chip-group { margin-bottom: 1rem; }
			.ikev2-chip-group:last-child { margin-bottom: 0; }
			.ikev2-chip-group h4 {
				margin: 0 0 .55rem;
				font-size: .72rem;
				font-weight: 700;
				letter-spacing: .06em;
				text-transform: uppercase;
				color: var(--ikev2-muted);
			}
			.ikev2-chips { display: flex; flex-wrap: wrap; gap: .45rem; }
			.ikev2-chip {
				display: inline-flex;
				align-items: center;
				gap: .35rem;
				padding: .32rem .7rem;
				border: 1px solid var(--ikev2-border);
				border-radius: 999px;
				background: var(--ikev2-surface-2);
				cursor: pointer;
				user-select: none;
				font-size: .85rem;
				font-weight: 600;
				line-height: 1.3;
				transition: background .12s ease, border-color .12s ease, color .12s ease;
			}
			.ikev2-chip:hover { border-color: var(--ikev2-border-strong); }
			.ikev2-chip.selected {
				border-color: transparent;
				background-image: var(--ikev2-grad);
				color: #fff;
			}
			.ikev2-chip.broad { border-color: color-mix(in srgb, var(--ikev2-warn) 45%, var(--ikev2-border)); }
			.ikev2-chip.broad.selected { background-image: linear-gradient(135deg, #d97706, #b45309); }
			.ikev2-chip input { position: absolute; opacity: 0; width: 0; height: 0; }
			.ikev2-chip-mark { font-size: .7rem; opacity: .65; }

			/* ── Network picker (selectable cards) ──────────────────── */
			.ikev2-netpick-grid {
				display: grid;
				grid-template-columns: repeat(auto-fit, minmax(13rem, 1fr));
				gap: .7rem;
			}
			.ikev2-netpick {
				display: flex;
				align-items: center;
				gap: .7rem;
				padding: .7rem .85rem;
				border: 1px solid var(--ikev2-border);
				border-radius: var(--ikev2-radius-sm);
				background: var(--ikev2-surface-2);
				cursor: pointer;
				transition: border-color .14s ease, background .14s ease, box-shadow .14s ease;
			}
			.ikev2-netpick:hover { border-color: var(--ikev2-border-strong); }
			.ikev2-netpick.selected {
				border-color: var(--ikev2-accent);
				background: var(--ikev2-grad-soft);
				box-shadow: 0 0 0 1px var(--ikev2-accent) inset;
			}
			.ikev2-netpick input { position: absolute; opacity: 0; width: 0; height: 0; }
			.ikev2-netpick-check {
				flex: none;
				width: 1.3rem;
				height: 1.3rem;
				border-radius: .42rem;
				border: 1.5px solid var(--ikev2-border-strong);
				display: grid;
				place-content: center;
				color: #fff;
				font-size: .82rem;
				line-height: 1;
				transition: background .14s ease, border-color .14s ease;
			}
			.ikev2-netpick.selected .ikev2-netpick-check {
				background-image: var(--ikev2-grad);
				border-color: transparent;
			}
			.ikev2-netpick.selected .ikev2-netpick-check::after { content: "\\2713"; }
			.ikev2-netpick-body { min-width: 0; }
			.ikev2-netpick-name { font-weight: 660; }
			.ikev2-netpick-meta {
				display: block;
				font-size: .8rem;
				color: var(--ikev2-muted);
				overflow-wrap: anywhere;
			}
			.ikev2-actions.end { justify-content: flex-end; }
			/* status on the left, action button hard-right (bottom of a block) */
			.ikev2-actions.spread { justify-content: space-between; width: 100%; }
			/* a block's primary actions, separated and right-aligned at the bottom */
			.ikev2-actions.bar {
				justify-content: flex-end;
				margin-top: 1.2rem;
				padding-top: 1rem;
				border-top: 1px solid var(--ikev2-border);
			}
			.ikev2-card.third { grid-column: span 4; }

			/* ── Tags ───────────────────────────────────────────────── */
			.ikev2-tags { display: flex; flex-wrap: wrap; gap: .4rem; }
			.ikev2-tag {
				display: inline-block;
				margin-left: .4rem;
				padding: .12rem .45rem;
				border: 1px solid color-mix(in srgb, currentColor 35%, transparent);
				border-radius: 999px;
				background: color-mix(in srgb, currentColor 10%, transparent);
				font-size: .7rem;
				font-weight: 600;
				vertical-align: middle;
			}
			.ikev2-tags .ikev2-tag { margin-left: 0; }
			.ikev2-tag.warn { color: var(--ikev2-warn); }
			.ikev2-tag.good { color: var(--ikev2-good); }
			.ikev2-tag-x {
				margin-left: .4rem;
				padding: 0;
				border: 0;
				background: none;
				color: inherit;
				cursor: pointer;
				opacity: .55;
				font-size: 1rem;
				line-height: 1;
			}
			.ikev2-tag-x:hover { opacity: 1; color: var(--ikev2-bad); }

			/* ── Layout helpers ─────────────────────────────────────── */
			.ikev2-two-col {
				display: grid;
				grid-template-columns: repeat(2, minmax(0, 1fr));
				gap: 1rem;
			}
			.ikev2-inline-form {
				display: flex;
				align-items: center;
				flex-wrap: wrap;
				gap: .55rem;
			}
			/* Inputs/selects share the row width; the action button is pushed to the
			   right edge so it lines up with the bottom-right convention. */
			.ikev2-inline-form > input { flex: 1 1 12rem; min-width: 10rem; }
			.ikev2-inline-form > select { flex: 1 1 15rem; min-width: 12rem; }
			.ikev2-inline-form > .ikev2-device-picker { flex: 2 1 30rem; min-width: 20rem; }
			.ikev2-inline-form > .ikev2-device-picker select { width: 100%; }
			.ikev2-inline-form > .ikev2-device-picker + select {
				flex: 1 1 18rem;
				max-width: 24rem;
			}
			.ikev2-inline-form > .cbi-button { margin-left: auto; }
			.ikev2-status-box {
				margin: .9rem 0 0;
				padding: .75rem .9rem;
				border: 1px solid var(--ikev2-border);
				border-radius: var(--ikev2-radius-sm);
				background: var(--ikev2-surface-2);
				font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
				font-size: .82rem;
				white-space: pre-wrap;
			}
			.ikev2-domain-editor {
				width: 100%;
				min-height: 14rem;
				resize: vertical;
				font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
				line-height: 1.5;
			}

			/* ── LuCI primitives inside page ────────────────────────── */
			.ikev2-page .cbi-tabmenu {
				display: flex;
				flex-wrap: wrap;
				gap: .35rem;
				margin: 1.1rem 0;
				padding: .3rem;
				border: 1px solid var(--ikev2-border);
				border-radius: 999px;
				background: var(--ikev2-surface);
				list-style: none;
			}
			.ikev2-page .cbi-tabmenu li {
				margin: 0;
				border: 0;
				background: none;
			}
			.ikev2-page .cbi-tabmenu li a {
				display: block;
				padding: .45rem 1.1rem;
				border-radius: 999px;
				text-decoration: none;
				font-weight: 620;
				color: var(--ikev2-muted);
				transition: background .14s ease, color .14s ease;
			}
			.ikev2-page .cbi-tabmenu li.cbi-tab a,
			.ikev2-page .cbi-tabmenu li a:hover {
				color: #fff;
				background-image: var(--ikev2-grad);
			}
			.ikev2-page .cbi-tabmenu li.cbi-tab-disabled a:hover {
				color: var(--ikev2-muted);
				background: var(--ikev2-surface-2);
			}
			.ikev2-page .table { margin: .4rem 0 0; }
			.ikev2-page .table .th,
			.ikev2-page .table .td { vertical-align: middle; padding: .55rem .6rem; }
			.ikev2-page .table .tr.table-titles .th {
				font-size: .72rem;
				letter-spacing: .06em;
				text-transform: uppercase;
				color: var(--ikev2-muted);
			}
			.ikev2-page .cbi-section-descr { color: var(--ikev2-muted); line-height: 1.5; }
			.ikev2-page code {
				font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
			}

			/* ── Motion / a11y ──────────────────────────────────────── */
			@media (prefers-reduced-motion: reduce) {
				.ikev2-page *,
				.ikev2-page *::before,
				.ikev2-page *::after { transition: none !important; }
			}

			/* ── Responsive ─────────────────────────────────────────── */
			@media (max-width: 900px) {
				.ikev2-card { grid-column: span 6; }
				.ikev2-card.wide { grid-column: 1 / -1; }
				.ikev2-hero { grid-template-columns: 1fr; }
				.ikev2-hero-side { flex-direction: row; flex-wrap: wrap; }
				.ikev2-widget-overview { grid-template-columns: 1fr; }
				.ikev2-user-card {
					grid-template-columns: minmax(10rem, .8fr) minmax(16rem, 1.4fr);
				}
				.ikev2-user-actions { grid-column: 1 / -1; }
			}
			@media (max-width: 600px) {
				.ikev2-windows-app { grid-template-columns: auto 1fr; }
				.ikev2-windows-app > .ikev2-result,
				.ikev2-windows-app > button { grid-column: 1 / -1; }
				.ikev2-header, .ikev2-section-head { display: block; }
				.ikev2-header > *, .ikev2-section-head > * { margin-bottom: .8rem; }
				.ikev2-card, .ikev2-card.wide { grid-column: 1 / -1; }
				.ikev2-form-grid { grid-template-columns: 1fr; gap: .4rem; }
				.ikev2-form-grid-compact { grid-template-columns: 1fr; }
				.ikev2-form-grid-compact > .ikev2-field-label { padding-top: 0; }
				.ikev2-form-grid > :nth-child(even) { margin-bottom: .8rem; }
				.ikev2-disclosure > summary { align-items: flex-start; flex-wrap: wrap; }
				.ikev2-disclosure-badges { justify-content: flex-start; }
				.ikev2-two-col { grid-template-columns: 1fr; }
				.ikev2-page .table { display: block; overflow-x: auto; }
				.ikev2-user-card { grid-template-columns: 1fr; }
				.ikev2-user-actions { grid-column: auto; justify-content: flex-start; }
				.ikev2-session { align-items: flex-start; flex-direction: column; }
				.ikev2-widget-client { grid-template-columns: 1fr auto; }
				.ikev2-widget-duration { grid-column: 1; }
				.ikev2-widget-traffic { grid-column: 2; grid-row: 1 / span 2; }
				.ikev2-engine-head { align-items: stretch; flex-direction: column; }
				.ikev2-engine-action { justify-content: flex-start; }
				.ikev2-engine-action .cbi-button { width: 100%; min-width: 0; }
				.ikev2-dns-preset-picker { grid-template-columns: 1fr; }
				.ikev2-dns-preset-picker .cbi-button { width: 100%; }
			}
	`;

// The Status Overview include re-renders on every poll. Returning a fresh
// <style> node each time replaced ~1300 lines of CSS in the live document
// several times a minute, forcing a full style recalculation and a visible
// flash. The sheet is static, so it is installed once per document instead.
// Callers place the result among the children of an E() call. LuCI's E()
// accepts a node or a string it can parse, and falls through to
// document.createElement() for anything else — so returning an empty string
// would raise InvalidCharacterError and break the whole page. An empty
// document fragment satisfies LuCI.dom.elem() and appends nothing.
function styles() {
	if (typeof document === 'undefined')
		return '';
	if (!document.getElementById(STYLE_ID))
		document.head.appendChild(E('style', { 'id': STYLE_ID }, [ CSS ]));
	return document.createDocumentFragment();
}

function pill(text, tone) {
	return E('span', { 'class': 'ikev2-pill ' + (tone || 'neutral') }, [ text ]);
}

function setPill(node, text, tone) {
	if (!node)
		return;
	node.className = 'ikev2-pill ' + (tone || 'neutral');
	node.textContent = text;
}

function icon(name) {
	var paths = {
		key: 'M21 2l-2 2m-7.6 7.6a5 5 0 1 1-7.1-7.1 5 5 0 0 1 7.1 7.1ZM11 11l4 4m0 0 2-2m-2 2-2 2',
		disconnect: 'M9 12h6m-3-3 3 3-3 3M5 5a9 9 0 1 0 14 0',
		trash: 'M3 6h18M8 6V4h8v2m-9 0 1 14h8l1-14M10 10v6m4-6v6',
		addUser: 'M15 19a6 6 0 0 0-12 0m6-8a4 4 0 1 0 0-8 4 4 0 0 0 0 8Zm9-2v6m-3-3h6',
		disconnectAll: 'M4 12h10m-3-3 3 3-3 3m7-8a8 8 0 1 1 0 10',
		settings: 'M12 15.5a3.5 3.5 0 1 0 0-7 3.5 3.5 0 0 0 0 7Zm7.4-3.5a7.8 7.8 0 0 0-.1-1l2-1.6-2-3.4-2.5 1a8 8 0 0 0-1.7-1L14.7 3h-4L10 6a8 8 0 0 0-1.7 1L5.8 6 3.8 9.4l2 1.6a7.8 7.8 0 0 0 0 2L3.8 14.6l2 3.4 2.5-1a8 8 0 0 0 1.7 1l.7 3h4l.7-3a8 8 0 0 0 1.7-1l2.5 1 2-3.4-2-1.6a7.8 7.8 0 0 0 .1-1Z',
		down: 'M12 3v14m-5-5 5 5 5-5M5 21h14',
		up: 'M12 21V7m-5 5 5-5 5 5M5 3h14',
		download: 'M12 3v12m-4-4 4 4 4-4M5 21h14',
		windows: 'M3 5h8v7H3V5Zm10 0h8v7h-8V5ZM3 14h8v7H3v-7Zm10 0h8v7h-8v-7Z',
		phone: 'M8 3h8a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2Zm2 3h4m-3 12h2',
		android: 'M7 9h10v8H7V9Zm2-3-2-2m8 2 2-2M9 12h.01M15 12h.01M5 10v6m14-6v6m-9 1v3m4-3v3'
	};
	return E('<svg class="ikev2-icon" viewBox="0 0 24 24" aria-hidden="true" focusable="false">' +
		'<path d="' + (paths[name] || paths.key) + '"></path></svg>');
}

function languageSwitch() {
	var select = E('select', { 'class': 'cbi-input-select' }, [
		E('option', { 'value': 'en', 'selected': defaultLanguage() === 'en' ? '' : null }, [ _('English') ]),
		E('option', { 'value': 'ru', 'selected': defaultLanguage() === 'ru' ? '' : null }, [ _('Russian') ])
	]);
	select.addEventListener('change', function() {
		if (window.localStorage)
			window.localStorage.setItem(LANG_KEY, select.value);
		window.location.reload();
	});
	return E('label', { 'class': 'ikev2-language' }, [
		E('span', {}, [ _('Language') ]),
		select
	]);
}

// LuCI renders the secondary nav titles from menu.json in its own locale,
// independent of this app's language switch. Relabel the known IKEv2 tabs by
// their English text so the navigation matches the selected language.
function localizeNav() {
	if (typeof document === 'undefined')
		return;
	var titles = {
		'Overview': _('Overview'),
		'Outbound Tunnel': _('Outbound Tunnel'),
		'Inbound Server': _('Inbound Server'),
		'Policy Routing': _('Policy Routing'),
		'VPN Users': _('VPN Users')
	};
	var links = document.querySelectorAll(
		'ul.tabs a, .cbi-tabmenu a, #mainmenu a, .main a[href*="ikev2-manager"]');
	for (var i = 0; i < links.length; i++) {
		var t = (links[i].textContent || '').trim();
		if (titles[t] && titles[t] !== t)
			links[i].textContent = titles[t];
	}
}

function header(title, subtitle, actions) {
	var actionItems = [ languageSwitch() ];
	if (actions) {
		if (Array.isArray(actions))
			actionItems = actionItems.concat(actions);
		else
			actionItems.push(actions);
	}

	if (typeof window !== 'undefined') {
		window.setTimeout(localizeNav, 0);
		window.setTimeout(localizeNav, 300);
	}

	return E('div', { 'class': 'ikev2-header' }, [
		E('div', {}, [
			E('h2', {}, [ title ]),
			subtitle ? E('p', { 'class': 'ikev2-subtitle' }, [ subtitle ]) : ''
		]),
		E('div', { 'class': 'ikev2-header-actions' }, actionItems)
	]);
}

function card(label, value, detail, extraClass) {
	return E('div', { 'class': 'ikev2-card ' + (extraClass || '') }, [
		E('div', { 'class': 'ikev2-card-label' }, [ label ]),
		E('div', { 'class': 'ikev2-card-value' }, [ value ]),
		detail ? E('div', { 'class': 'ikev2-card-detail' }, [ detail ]) : ''
	]);
}

function section(title, description, content, actions) {
	return E('section', { 'class': 'ikev2-section' }, [
		E('div', { 'class': 'ikev2-section-head' }, [
			E('div', {}, [
				E('h3', {}, [ title ]),
				description ? E('p', {}, [ description ]) : ''
			]),
			actions || ''
		]),
		content
	]);
}

function keyValueTable(rows) {
	return E('table', { 'class': 'ikev2-kv' }, rows.map(function(row) {
		return E('tr', {}, [
			E('td', {}, [ row[0] ]),
			E('td', {}, [ row[1] == null || row[1] === '' ? '-' : row[1] ])
		]);
	}));
}

function fieldLabel(title, help) {
	return E('label', { 'class': 'ikev2-field-label' }, [
		title,
		help ? E('span', { 'class': 'ikev2-field-help' }, [ help ]) : ''
	]);
}

function setBusy(button, busy, label) {
	if (!button)
		return;
	if (busy) {
		if (button.dataset.busy !== '1') {
			button.dataset.idleLabel = button.textContent;
			button.dataset.idleHtml = button.innerHTML;
			button.dataset.idleDisabled = button.disabled ? '1' : '0';
		}
		button.dataset.busy = '1';
		button.disabled = true;
		button.setAttribute('aria-busy', 'true');
		button.textContent = label || _('Working...');
	}
	else {
		delete button.dataset.busy;
		button.disabled = button.dataset.idleDisabled === '1';
		delete button.dataset.idleDisabled;
		button.removeAttribute('aria-busy');
		if (button.dataset.idleHtml != null)
			button.innerHTML = button.dataset.idleHtml;
		else
			button.textContent = button.dataset.idleLabel || button.textContent;
	}
}

function errorMessage(error, fallback) {
	if (error && error.message)
		return error.message;
	if (typeof error === 'string' && error)
		return error;
	return fallback || _('Operation failed');
}

function execChecked(path, args, fallback) {
	return fs.exec(path, args || []).then(function(response) {
		if (response && response.code)
			throw new Error(((response.stderr || response.stdout || '').trim()) ||
				fallback || _('Operation failed'));
		return response || {};
	});
}

function delay(ms) {
	return new Promise(function(resolve) { window.setTimeout(resolve, ms); });
}

// Poll a key=value status command for one exact backend action id. A unique id
// prevents a stale status from an earlier click being mistaken for this run.
function pollAction(path, args, actionId, options) {
	options = options || {};
	var deadline = Date.now() + (options.timeout || 90000);
	var interval = options.interval || 1500;

	function once() {
		return L.resolveDefault(fs.exec(path, args || []), { stdout: '' }).then(function(response) {
			var status = parseKeyValues((response && response.stdout) || '');
			if (options.onProgress)
				options.onProgress(status);
			if (status.action_id === actionId &&
			    (status.state === 'ok' || status.state === 'error'))
				return status;
			if (Date.now() >= deadline)
				return null;
			return delay(interval).then(once);
		});
	}

	return once();
}

// Standard action lifecycle for every button:
// idle -> busy -> success/error/timeout -> idle.
// The button is always restored in finally, so navigation/reload is never
// responsible for clearing "Saving...".
function runAction(options) {
	options = options || {};
	var button = options.button;
	var result = options.result;
	setBusy(button, true, options.busy || _('Working...'));
	if (result)
		result.busy(options.busy || _('Working...'));

	return Promise.resolve().then(options.run).then(function(value) {
		if (options.success && result)
			result.ok(options.success);
		if (options.onSuccess)
			return Promise.resolve(options.onSuccess(value)).then(function() { return value; });
		return value;
	}).catch(function(error) {
		var message = errorMessage(error, options.failure);
		if (result)
			result.err(message);
		if (options.onError)
			options.onError(message, error);
		return null;
	}).finally(function() {
		setBusy(button, false);
	});
}

// Start a detached backend action. The starter must return action_id=<id>
// immediately; completion is read from the supplied status command.
function runJob(options) {
	options = options || {};
	return runAction({
		button: options.button,
		result: options.result,
		busy: options.busy,
		failure: options.failure,
		run: function() {
			return execChecked(options.startPath, options.startArgs, options.failure)
				.then(function(response) {
					var started = parseKeyValues(response.stdout || '');
					var actionId = started.action_id;
					if (!actionId && options.allowImmediate) {
						if (options.result)
							options.result.ok(options.success || _('Done'));
						return { state: 'ok', immediate: true };
					}
					if (!actionId)
						throw new Error(options.failure || _('Action did not start'));
					var statusArgs = (options.statusArgs || []).slice();
					if (options.statusIdArg !== false)
						statusArgs.push(actionId);
					return pollAction(options.statusPath, statusArgs, actionId, {
						timeout: options.timeout,
						interval: options.interval,
						onProgress: function(status) {
							if (options.onProgress)
								options.onProgress(status);
							if (options.result && status.action_id === actionId &&
							    status.state === 'running' && status.message)
								options.result.busy(_(status.message));
						}
					}).then(function(status) {
						if (!status) {
							if (options.result)
								options.result.warn(options.timeoutMessage ||
									_('The operation is still running in the background.'));
							if (options.onTimeout)
								options.onTimeout();
							return { state: 'timeout', action_id: actionId };
						}
						if (status.state === 'error')
							throw new Error(status.message ? _(status.message) :
								(options.failure || _('Operation failed')));
						if (options.result)
							options.result.ok(options.success || _('Done'));
						return status;
					});
				});
		},
		onSuccess: options.onSuccess,
		onError: options.onError
	});
}

function copyText(text) {
	if (navigator.clipboard && navigator.clipboard.writeText)
		return navigator.clipboard.writeText(text);
	var input = E('textarea', {
		'style': 'position:fixed;left:-9999px;top:-9999px;'
	}, [ text ]);
	document.body.appendChild(input);
	input.select();
	document.execCommand('copy');
	input.remove();
	return Promise.resolve();
}

function switchLabel(input, text) {
	return E('label', { 'class': 'ikev2-switch' }, [
		input,
		E('span', { 'class': 'ikev2-switch-track' }),
		text ? E('span', { 'class': 'ikev2-switch-text' }, [ text ]) : ''
	]);
}

// A finite set of safe presets with an explicit final Custom… branch. The
// current value is always preserved: an unknown value selects Custom and is
// shown in the input instead of being replaced by a default.
function choiceWithCustom(value, choices, options) {
	options = options || {};
	var customValue = '__ikev2_custom__';
	var field = E('input', Object.assign({
		'type': options.type || 'text',
		'class': 'cbi-input-text',
		'placeholder': options.placeholder || ''
	}, options.attrs || {}));
	var select = E('select', { 'class': 'cbi-input-select' },
		(choices || []).map(function(choice) {
			return E('option', { 'value': String(choice.value) }, [ choice.label ]);
		}).concat([
			E('option', { 'value': customValue }, [ options.customLabel || _('Custom…') ])
		]));
	var node = E('div', { 'class': 'ikev2-choice-custom' }, [ select, field ]);

	function hasChoice(next) {
		return (choices || []).some(function(choice) {
			return String(choice.value) === String(next == null ? '' : next);
		});
	}

	function sync() {
		var custom = select.value === customValue;
		field.style.display = custom ? '' : 'none';
		field.disabled = !custom;
	}

	function setValue(next) {
		next = String(next == null ? '' : next);
		field.value = next;
		select.value = hasChoice(next) ? next : customValue;
		sync();
	}

	select.addEventListener('change', function() {
		if (select.value !== customValue)
			field.value = select.value;
		sync();
	});
	setValue(value);
	return {
		node: node,
		select: select,
		input: field,
		value: function() { return select.value === customValue ? field.value.trim() : select.value; },
		setValue: setValue
	};
}

// Multi-value counterpart used for detected firewall zones. Known values are
// checkboxes; values no longer present on the router stay in the Custom field.
function multiChoiceWithCustom(value, choices, options) {
	options = options || {};
	var picks = [];
	var customField = E('input', {
		'type': 'text',
		'class': 'cbi-input-text',
		'placeholder': options.placeholder || ''
	});
	var knownNodes = (options.prependNodes || []).slice();
	knownNodes = knownNodes.concat((choices || []).map(function(choice) {
			var pick = netPick(String(choice.value), choice.name || choice.label,
				choice.meta || '', false);
			picks.push(pick);
			return pick.node;
		}));
	var list = E('div', { 'class': 'ikev2-netpick-grid' }, knownNodes);
	var customPick = netPick('__custom__', options.customLabel || _('Custom…'),
		options.customMeta || '', false);
	var customList;
	if (options.customBelow)
		customList = E('div', { 'class': 'ikev2-netpick-grid' }, [ customPick.node ]);
	else {
		list.appendChild(customPick.node);
		customList = '';
	}
	var node = E('div', { 'class': 'ikev2-choice-custom' },
		[ list, customList, customField ]);

	function sync() {
		customField.style.display = customPick.input.checked ? '' : 'none';
		customField.disabled = !customPick.input.checked;
	}

	function setValue(next) {
		var selected = String(next || '').trim().split(/\s+/).filter(Boolean);
		var known = {};
		picks.forEach(function(pick) {
			known[pick.input.value] = true;
			pick.setChecked(selected.indexOf(pick.input.value) >= 0);
		});
		var custom = selected.filter(function(item) { return !known[item]; });
		customField.value = custom.join(' ');
		customPick.setChecked(custom.length > 0 || !picks.length);
		sync();
	}

	customPick.input.addEventListener('change', sync);
	setValue(value);
	return {
		node: node,
		value: function() {
			var selected = picks.filter(function(pick) { return pick.input.checked; })
				.map(function(pick) { return pick.input.value; });
			if (customPick.input.checked)
				selected = selected.concat(customField.value.trim().split(/\s+/).filter(Boolean));
			return selected.filter(function(item, index) { return selected.indexOf(item) === index; }).join(' ');
		},
		setValue: setValue
	};
}

// A labelled toggle row: title/description on the left, switch on the right.
function toggleRow(input, title, sub) {
	return E('div', { 'class': 'ikev2-toggle-row' }, [
		E('div', {}, [
			E('span', { 'class': 'ikev2-toggle-text' }, [ title ]),
			sub ? E('span', { 'class': 'ikev2-toggle-sub' }, [ sub ]) : ''
		]),
		switchLabel(input, '')
	]);
}

// Selectable network card (modern replacement for a bare checkbox). Returns
// { node, input }; the card highlights when its hidden checkbox is checked.
function netPick(value, name, meta, checked) {
	var input = E('input', { 'type': 'checkbox', 'value': value, 'checked': checked ? '' : null });
	var card = E('label', { 'class': 'ikev2-netpick' + (checked ? ' selected' : '') }, [
		input,
		E('span', { 'class': 'ikev2-netpick-check' }),
		E('span', { 'class': 'ikev2-netpick-body' }, [
			E('span', { 'class': 'ikev2-netpick-name' }, [ name ]),
			meta ? E('span', { 'class': 'ikev2-netpick-meta' }, [ meta ]) : ''
		])
	]);
	function setChecked(next) {
		input.checked = !!next;
		card.classList.toggle('selected', input.checked);
	}
	input.addEventListener('change', function() { setChecked(input.checked); });
	return { node: card, input: input, setChecked: setChecked };
}

// Inline status chip shown next to an action button instead of a top-of-page
// notification. err() truncates with a hover tooltip carrying the full text.
function inlineResult() {
	var node = E('span', { 'class': 'ikev2-result', 'style': 'display:none' }, []);
	function set(cls, text, full) {
		node.className = 'ikev2-result ' + cls;
		node.style.display = '';
		node.textContent = text;
		node.title = full || text;
	}
	return {
		node: node,
		busy: function(msg) { set('busy', msg || _('Working...'), ''); },
		ok: function(msg) { set('ok', '✓ ' + (msg || _('Done')), msg || ''); },
		warn: function(msg) { set('warn', '… ' + (msg || _('Still running')), msg || ''); },
		err: function(msg) { set('err', '✕ ' + (msg || _('Failed')), msg || ''); },
		clear: function() { node.style.display = 'none'; node.textContent = ''; node.title = ''; }
	};
}

function inputToken() {
	var random = Math.floor(Math.random() * 0x100000000).toString(36);
	return Date.now().toString(36) + '-' + random;
}

function gate(title, subtitle) {
	return E('div', { 'class': 'ikev2-page' }, [
		header(title, subtitle),
		E('div', { 'class': 'ikev2-empty', 'style': 'padding:2.4rem 1.6rem' }, [
			E('div', { 'style': 'font-size:1.1rem;font-weight:680;margin-bottom:.4rem' }, [
				_('Runtime dependencies are not installed') ]),
			E('p', { 'style': 'margin:0 auto 1.2rem;max-width:34rem' }, [
				_('Install PBR and strongSwan on the Overview page, then this page becomes available.') ]),
			E('a', { 'class': 'ikev2-quick-link',
				'href': L.url('admin', 'services', 'ikev2-manager', 'setup') }, [
				_('Go to Overview') ])
		])
	]);
}

return baseclass.extend({
	t: translate,
	parseKeyValues: parseKeyValues,
	parseSwanmon: parseSwanmon,
	formatBytes: formatBytes,
	formatDuration: formatDuration,
	formatDate: formatDate,
	daysUntil: daysUntil,
	styles: styles,
	pill: pill,
	setPill: setPill,
	icon: icon,
	languageSwitch: languageSwitch,
	header: header,
	gate: gate,
	switchLabel: switchLabel,
	toggleRow: toggleRow,
	netPick: netPick,
	choiceWithCustom: choiceWithCustom,
	multiChoiceWithCustom: multiChoiceWithCustom,
	inlineResult: inlineResult,
	inputToken: inputToken,
	localizeNav: localizeNav,
	card: card,
	section: section,
	keyValueTable: keyValueTable,
	fieldLabel: fieldLabel,
	setBusy: setBusy,
	execChecked: execChecked,
	pollAction: pollAction,
	runAction: runAction,
	runJob: runJob,
	copyText: copyText
});
