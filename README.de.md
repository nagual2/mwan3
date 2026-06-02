# mwan3 (Standalone-Paket)

[English](README.md) | [Русский](README.ru.md) | **Deutsch**

Autonomes OpenWrt-Paket aus [openwrt/packages `net/mwan3`](https://github.com/openwrt/packages/tree/master/net/mwan3).

Repository für **eigene Patches** (IPv6 Multi-WAN) ohne Fork des gesamten `packages`-Feeds.

## nagual2 Patches (2.12.1-4)

### `track_host_routes`

Host-Routen (`/32` oder `/128`) für jedes `track_ip` in der mwan3-Schnittstellentabelle — Health-Checks laufen über das richtige WAN (IPv6 Multi-Tunnel / WireGuard).

- UCI: `mwan3.globals.track_host_routes=1` (Standard an)
- Pro Interface: `option track_host_routes '0'` zum Deaktivieren
- Hotplug `25`/`99` stellt Routen nach `network restart` wieder her
- Befehl: `mwan3 sync-track-routes`

### `connected_ipv6` Filter

Überspringt zu breite IPv6-Routen in `mwan3_connected_ipv6`, damit WG Split-Default (`::/1`, `8000::/1`) und Aggregate (`2000::/3`) mwan3-Policy nicht umgehen.

- UCI: `mwan3.globals.connected_ipv6_min_prefixlen=32` (Standard)
- Befehl: `mwan3 flush-conntrack` nach Policy-Wechsel

## Build

```bash
./scripts/build-all.sh          # Tests + IPK
./scripts/build-ipk-mkpkg.sh    # nur .ipk (schnell, x86/64)
./scripts/build-ipk-sdk.sh      # .ipk via OpenWrt SDK
./scripts/build-apk-sdk.sh      # .apk (OpenWrt 25.12+)
```

Artefakte: `dist/mwan3_2.12.1-4_*.ipk`

## Installation auf dem Router

OpenWrt 25.12+ (**apk**, empfohlen):

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

### apk-Pin

`apk add --allow-untrusted` setzt `mwan3><Q1hash…` in `/etc/apk/world`. Details: [luci-app-mwan3 — Pinning](https://github.com/nagual2/luci-app-mwan3#pinning-the-nagual2-fork-apk).

Overlay ohne IPK (nur Dev): `scripts/deploy-prod.sh prod-openwrt`

## LuCI (Fork-GUI)

Fork-Optionen in der Weboberfläche: **[luci-app-mwan3](https://github.com/nagual2/luci-app-mwan3)** (`track_host_routes`, `connected_ipv6_min_prefixlen`, Diagnostics).

## Verwandte Repositories

| Repository | Rolle |
|------------|-------|
| [nagual2/mwan3](https://github.com/nagual2/mwan3) | Dieses Paket |
| [nagual2/luci-app-mwan3](https://github.com/nagual2/luci-app-mwan3) | LuCI für Fork-Optionen |
| [nagual2/mwan6-npt](https://github.com/nagual2/mwan6-npt) | NPTv6 Multi-WAN |
| [nagual2/mwan6-npt-luci](https://github.com/nagual2/mwan6-npt-luci) | LuCI für mwan6-npt |

## Dokumentation

Dreisprachige README im Paket unter `/usr/share/doc/mwan3/` (`README.en.md`, `README.ru.md`, `README.de.md`).

## Lizenz

GPL-2.0 wie upstream. Siehe [NOTICE](NOTICE).
