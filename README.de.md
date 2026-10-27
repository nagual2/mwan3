# mwan3 (Standalone-Paket)

[English](README.md) | [Русский](README.ru.md) | **Deutsch**

Autonomes OpenWrt-Paket aus [openwrt/packages `net/mwan3`](https://github.com/openwrt/packages/tree/master/net/mwan3).

Repository für **eigene Patches** (IPv6 Multi-WAN) ohne Fork des gesamten `packages`-Feeds.

## nagual2 Patches (2.12.1-r9)

### `track_host_routes`

Host-Routen (`/32` oder `/128`) für jedes `track_ip` in der mwan3-Schnittstellentabelle — Health-Checks laufen über das richtige WAN (IPv6 Multi-Tunnel / WireGuard).

- UCI: `mwan3.globals.track_host_routes=1` (Standard an)
- Pro Interface: `option track_host_routes '0'` zum Deaktivieren
- Hotplug `25`/`99` stellt Routen nach `network restart` wieder her
- Befehl: `mwan3 sync-track-routes`

Seit **r9** werden Host-Routen und das Policy-Default für **Gateway-Uplinks** (DHCPv6 über
Wi-Fi/Ethernet) über `via <Gateway>` gesetzt: eine Dev-only-Route auf einem Broadcast-Link schickt
eine Neighbor Solicitation direkt auf das öffentliche Ziel und erstickt das Tracking (der Kanal
ging offline und erholte sich nicht). Das Gateway stammt aus dem Main-Default des Geräts; Tunnel
behalten die Dev-only-Form. Details: [docs/GATEWAY_UPLINKS.de.md](docs/GATEWAY_UPLINKS.de.md).

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

Artefakte: `dist/mwan3-2.12.1-r9_aarch64_cortex-a53.apk` (Prod), `dist/mwan3-2.12.1-r8_x86_64.apk` (Dev-VM)

## Installation auf dem Router

OpenWrt 25.12+ (**apk**, empfohlen):

```bash
./scripts/build-apk-mkpkg.sh
./scripts/install-apk.sh <router-lan-ip>
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

Thematische Dokumente des Repos (ebenfalls im Paket):

- [docs/IPV6_POLICY_SWITCHING.ru.md](docs/IPV6_POLICY_SWITCHING.ru.md) — Per-Iface-WRAP-Fwmark und Policy-Default für IPv6-Kanäle.
- [docs/GATEWAY_UPLINKS.ru.md](docs/GATEWAY_UPLINKS.ru.md) — Gateway-artige IPv6-Uplinks: Kanal-Checkliste (family/enabled/sourcefilter), via-Tracking seit r9, DHCPv6-over-WLAN-Besonderheiten, Failover-Plan für den nativen Uplink. Dreisprachig: [en](docs/GATEWAY_UPLINKS.en.md) | [ru](docs/GATEWAY_UPLINKS.ru.md) | [de](docs/GATEWAY_UPLINKS.de.md).

## Lizenz

GPL-2.0 wie upstream. Siehe [NOTICE](NOTICE).
