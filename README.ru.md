# mwan3 (отдельный пакет)

[English](README.md) | [Русский](README.ru.md)

Автономный пакет OpenWrt, выделенный из [openwrt/packages `net/mwan3`](https://github.com/openwrt/packages/tree/master/net/mwan3).

Репозиторий нужен для **своих патчей** (например маршруты до `track_ip` для IPv6) без форка всего feed `packages`.

## Upstream

| Поле | Значение |
|------|----------|
| Источник | https://github.com/openwrt/packages/tree/master/net/mwan3 |
| Коммит синхронизации | `858ec4093deeea8e63ea08cd4f41f7c034ea4b39` (2025-05-31) |
| Версия upstream | 2.12.1-1 |

Обновление из upstream: [UPSTREAM.md](UPSTREAM.md).

## Сборка (OpenWrt SDK / полное дерево)

```bash
cd package
git clone https://github.com/nagual2/mwan3.git custom/mwan3

make menuconfig   # Network → Routing and Redirection → mwan3
make package/mwan3/compile V=s
```

Собирается `libwrap_mwan3_sockopt.so` из `src/sockopt_wrap.c` под **целевую** архитектуру роутера.

## Установка на роутер

Без патчей удобнее ставить из официального feed:

```bash
opkg update && opkg install mwan3
apk add mwan3   # OpenWrt 25.12+
```

Свой `.ipk` — только если собран под архитектуру вашего устройства.

## Связанные репозитории

| Репозиторий | Назначение |
|-------------|------------|
| [nagual2/mwan3](https://github.com/nagual2/mwan3) | Этот пакет |
| [nagual2/packages](https://github.com/nagual2/packages) | Полный fork feed (тяжёлый) |
| [nagual2/mwan6-npt](https://github.com/nagual2/mwan6-npt) | NPTv6 multi-WAN |

## Лицензия

GPL-2.0, как у upstream. См. [NOTICE](NOTICE).
