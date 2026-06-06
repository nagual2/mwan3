# mwan3 (отдельный пакет)



[English](README.md) | **Русский** | [Deutsch](README.de.md)



Автономный пакет OpenWrt, выделенный из [openwrt/packages `net/mwan3`](https://github.com/openwrt/packages/tree/master/net/mwan3).



Репозиторий для **своих патчей** IPv6 multi-WAN без форка всего feed `packages`.



## Патчи nagual2 (2.12.1-4)



### `track_host_routes`



Host-маршруты `/128` до каждого `track_ip` в таблице mwan3 **только для IPv6** — без них `mwan3track` ping6 по IPv6 WG не проходит. Для IPv4 (шлюз/NAT) host-маршруты не создаются.



- UCI: `mwan3.globals.track_host_routes=1`

- Hotplug `25` + `99` после `network restart`

- `mwan3 sync-track-routes`



### Фильтр `connected_ipv6`



Не добавляет в `mwan3_connected_ipv6` широкие префиксы (`::/1`, `8000::/1`, `2000::/3`, короче `/32`) — иначе policy mwan3 обходится.



- UCI: `mwan3.globals.connected_ipv6_min_prefixlen=32`

- `mwan3 flush-conntrack` — после смены policy (CONNMARK)



## Сборка



```bash

./scripts/build-all.sh          # тесты + IPK (mkpkg)
./scripts/build-ipk-mkpkg.sh    # только .ipk (быстро, x86/64)
./scripts/build-ipk-sdk.sh      # .ipk через OpenWrt SDK (медленно)
./scripts/build-apk-sdk.sh      # .apk (OpenWrt 25.12+)

```



Артефакты: `dist/mwan3_2.12.1-4_*.ipk`



Другая архитектура: `SDK_URL=<url SDK вашего target> ./scripts/build-ipk-sdk.sh`

Кэш SDK: `~/.cache/openwrt-sdk/archives/` — повторная загрузка только если на сервере изменился файл (ETag / Last-Modified / size). Модуль: `scripts/lib/sdk-cache.sh`.



## Установка на роутер

OpenWrt 25.12+ (**apk**, рекомендуется):

```bash
./scripts/build-apk-mkpkg.sh
./scripts/install-apk.sh 192.168.56.1
```

OpenWrt 23.x (opkg):

```bash
scp dist/mwan3_*.ipk root@openwrt-dev:/tmp/
ssh root@openwrt-dev 'opkg install /tmp/mwan3_*.ipk'
/etc/init.d/mwan3 restart
mwan3 sync-track-routes
```

### Pin (apk)

`apk add --allow-untrusted` создаёт pin `mwan3><Q1hash…` в `/etc/apk/world`. Проверка: `grep '^mwan3><' /etc/apk/world`, `apk policy mwan3`. Подробно: [luci-app-mwan3 — Pinning](https://github.com/nagual2/luci-app-mwan3#pinning-the-nagual2-fork-apk).

Overlay без ipk (только dev): `scripts/deploy-prod.sh prod-openwrt`



## Интеграционные тесты (Windows + OpenWrt lab)

В пакете:

| Артефакт | Путь на роутере |
|----------|-----------------|
| Описание lab | `/usr/share/doc/mwan3/OPENWRT_DEV_INFRASTRUCTURE.md` |
| PowerShell-скрипт | `/usr/share/doc/mwan3/integration/Test-Mwan3PolicySwitch.ps1` |

Скопируйте скрипт на Windows-хост. Переключает IPv6 policy на роутере, проверяет ping с роутера и с Windows (на `-LanInterface` — ровно один GUA).

```powershell
scp root@<router-lan-ip>:/usr/share/doc/mwan3/integration/Test-Mwan3PolicySwitch.ps1 .
.\Test-Mwan3PolicySwitch.ps1 -DevHost <router-lan-ip> -LanInterface 'vEthernet (OpenWrt-LAN-Host)'
```



## Связанные пакеты



| Репозиторий | Назначение |

|-------------|------------|

| [nagual2/mwan3](https://github.com/nagual2/mwan3) | Этот пакет |

| [nagual2/luci-app-mwan3](https://github.com/nagual2/luci-app-mwan3) | LuCI для fork-опций |

| [nagual2/mwan6-npt](https://github.com/nagual2/mwan6-npt) | NPTv6 multi-WAN |

| [nagual2/mwan6-npt-luci](https://github.com/nagual2/mwan6-npt-luci) | LuCI для mwan6-npt |



## LuCI



Fork-опции в GUI: **[luci-app-mwan3](https://github.com/nagual2/luci-app-mwan3)**.



## Документация



Триязычные README в пакете: `/usr/share/doc/mwan3/` (`README.en.md`, `README.ru.md`, `README.de.md`).



## Лицензия



GPL-2.0, как у upstream. См. [NOTICE](NOTICE).

