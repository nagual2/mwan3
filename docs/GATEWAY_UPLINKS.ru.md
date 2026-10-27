**[Русский](GATEWAY_UPLINKS.ru.md)** | [English](GATEWAY_UPLINKS.en.md) | [Deutsch](GATEWAY_UPLINKS.de.md)

# Шлюзовые IPv6-аплинки в mwan3

> **Дата:** 2026-10-27  
> **Контекст:** подключение нативного DHCPv6-аплинка `wwan2v6` (Wi-Fi STA, broadcast-линк) на production-роутере; пакет mwan3-2.12.1-r9  
> **Связанное:** [IPV6_POLICY_SWITCHING.ru.md](IPV6_POLICY_SWITCHING.ru.md), пакет [nagual2/mwan6-npt](https://github.com/nagual2/mwan6-npt)

---

## Почему шлюзовой аплинк — не туннель

Туннельные каналы (WireGuard, 6in4/SIT) — point-to-point: маршрут `dev <iface>` сам доставляет
пакет пир-роутеру. Шлюзовые аплинки (DHCPv6 поверх Wi-Fi/Ethernet) — broadcast-линк с link-local
шлюзом: пакет без `via` уходит Neighbor Solicitation'ом прямо на публичную цель и теряется.
Отсюда все различия в настройке и в поведении трекинга.

## Чек-лист подключения шлюзового IPv6-канала

| № | Настройка | Где | Значение | Зачем |
|---|-----------|-----|----------|-------|
| 1 | `family` | `mwan3.<iface>` | `ipv6` | иначе mwan3 ищет IPv4-адрес на интерфейсе и держит канал в `unknown` |
| 2 | `enabled` | `mwan3.<iface>` | `1` | без опции hotplug считает канал disabled (`hotplug ... not called because interface disabled`) |
| 3 | `sourcefilter` | `network.<iface>` | `0` | при отсутствии PD netifd строит default с from-ограничителем (`default from <PIO>/64`); пока он стоит, bind-to-device трафик (mwan3track WRAP, `ping -I`) получает `Network unreachable` |
| 4 | `metric` | `network.<iface>` | выше основного v6-дефолта | дефолт канала в main не должен перехватывать глобальный трафик у более специфичных маршрутов |
| 5 | `track_ip` | `mwan3.<iface>` | 2 глобальные цели | при `track_host_routes=1` для каждой цели в policy-таблице канала создаётся /128-маршрут |
| 6 | NPT | `mwan6-npt.<iface>` | `enabled=1`, `wan_prefix` | для трансляции LAN-префикса наружу; у нативного аплинка префикс — **динамический SLAAC**: при смене обновлять («Suggest from interface» в LuCI) |

## track_host_routes: via-маршруты (2.12.1-r9)

До r9 `/128` host-маршруты и policy-default ставились как `dev <iface>` — корректно для туннелей,
но чёрная дыра для шлюзовых аплинков: трекинг-пинги не выходили с канала, канал уходил в offline,
а mwan3 переключал его fwmark-правило на `unreachable` — канал не восстанавливался до следующего ifup.

С r9 (`files/lib/mwan3/track_host_routes.sh`):

- шлюз извлекается из main-default устройства: `ip -6 route show default dev <device>` → `via`;
- host-маршруты `track_ip` и policy-default ставятся как `via <gw> dev <device> metric 1`;
- при re-sync удаляются ранее сохранённые спецификации — шлюз может появиться/смениться вместе с RA;
- туннели (в их main-default нет `via`) — прежнее dev-only поведение.

Тесты: `tests/test_track_host_routes.sh` — 9 кейсов (via- и dev-only-формы, удаление устаревших
спецификаций, skip IPv4, глобальное отключение).

## Особенности DHCPv6 поверх Wi-Fi STA

| № | Аспект | Детали |
|---|--------|--------|
| 1 | Привязка устройства | UCI-интерфейс может не иметь `option device` — привязка идёт через wireless-ассоциацию (`wifi-iface.network='wwan2 wwan2v6'`); mwan3 резолвит через `network_get_device`/ubus `l3_device` |
| 2 | Hotplug-события | `INTERFACE=<logical>`, но `DEVICE=<l3 device>` (например `phy0-sta0`): скрипты, матчящие секцию по `DEVICE` (как хотплаг mwan6-npt), для таких каналов не срабатывают — авторегенерация только по логическому имени |
| 3 | LuCI-кнопка Restart | неактивна при `pending=1` (netifd цикл «setting up → down», например аплинк не раздаёт IPv6) — это состояние netifd, а не поломка mwan3 |
| 4 | Диагностика | busybox `ping -I <iface>` и mtr привязываются к link-local адресу интерфейса и на глобальные цели дают `Network unreachable`; рабочие пути: трекинг mwan3 (WRAP fwmark → policy-таблица), host-маршрут /128 через шлюз, `ping -I <GUA>` (с оговоркой перехвата main-маршрутами) |

## Failover на нативный аплинк (проект)

Сценарий: оба IPv4-аплинка (`wwan`, `wwan2`) недоступны — все туннели (WireGuard/6in4 ходят через
v4) физически мертвы, даже если трекинг ещё не доработал порог down. Требуется: `default_rule_v6`
переключить на одиночную политику нативного канала (`ipv6_native` → `wwan2v6`), при возврате любого
v4-аплинка — вернуть `ipv6_primary`.

Реализация — штатный user-hook `/etc/mwan3.user` (исполняется на каждый netifd hotplug):

- проверить `ubus`-состояние `wwan`, `wwan2` и живость самого `wwan2v6`;
- оба v4 down и `wwan2v6` up → `mwan3.default_rule_v6.use_policy='ipv6_native'` + `mwan3 reload`;
- любой v4 up → вернуть `ipv6_primary`;
- переключение только при смене значения (защита от цикла reload).

UCI-уровень, без правок пакета; политика `ipv6_native` (member `wwan26_m1_w1`) создаётся в панели.
