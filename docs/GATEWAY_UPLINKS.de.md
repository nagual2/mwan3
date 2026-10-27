**[Русский](GATEWAY_UPLINKS.ru.md)** | [English](GATEWAY_UPLINKS.en.md) | **[Deutsch](GATEWAY_UPLINKS.de.md)**

# Gateway-artige IPv6-Uplinks in mwan3

> **Datum:** 2026-10-27  
> **Kontext:** Anbindung eines nativen DHCPv6-Uplinks `wwan2v6` (Wi-Fi STA, Broadcast-Link) auf dem Produktionsrouter; Paket mwan3-2.12.1-r9  
> **Verwandt:** [IPV6_POLICY_SWITCHING.ru.md](IPV6_POLICY_SWITCHING.ru.md), Paket [nagual2/mwan6-npt](https://github.com/nagual2/mwan6-npt)

---

## Warum ein Gateway-Uplink kein Tunnel ist

Tunnelkanäle (WireGuard, 6in4/SIT) sind Point-to-Point: eine Route `dev <iface>` liefert das Paket
selbst zum Peer-Router. Gateway-Uplinks (DHCPv6 über Wi-Fi/Ethernet) sind ein Broadcast-Link mit
einem Link-Local-Gateway: ein Paket ohne `via` geht als Neighbor Solicitation direkt auf das
öffentliche Ziel und geht verloren. Daher stammen alle Unterschiede in Konfiguration und
Health-Check-Verhalten.

## Checkliste für einen gateway-artigen IPv6-Kanal

| Nr | Einstellung | Wo | Wert | Warum |
|----|-------------|-----|------|-------|
| 1 | `family` | `mwan3.<iface>` | `ipv6` | sonst sucht mwan3 eine IPv4-Adresse auf dem Interface und hält den Kanal in `unknown` |
| 2 | `enabled` | `mwan3.<iface>` | `1` | ohne die Option behandelt Hotplug den Kanal als deaktiviert (`hotplug ... not called because interface disabled`) |
| 3 | `sourcefilter` | `network.<iface>` | `0` | ohne PD baut netifd das Default mit From-Constraint (`default from <PIO>/64`); solange aktiv, erhält Bind-to-Device-Traffic (mwan3track WRAP, `ping -I`) `Network unreachable` |
| 4 | `metric` | `network.<iface>` | über dem primären v6-Default | das Kanal-Default in main darf keinen globalen Traffic von spezifischeren Routen abfangen |
| 5 | `track_ip` | `mwan3.<iface>` | 2 globale Ziele | mit `track_host_routes=1` wird pro Ziel eine /128-Route in der Policy-Tabelle des Kanals erzeugt |
| 6 | NPT | `mwan6-npt.<iface>` | `enabled=1`, `wan_prefix` | zur Übersetzung des LAN-Präfix nach außen; beim nativen Uplink ist das Präfix **dynamisches SLAAC** — bei Wechsel aktualisieren („Suggest from interface" in LuCI) |

## track_host_routes: via-Routen (2.12.1-r9)

Vor r9 wurden `/128`-Host-Routen und das Policy-Default als `dev <iface>` gesetzt — für Tunnel
korrekt, für Gateway-Uplinks aber ein schwarzes Loch: Tracking-Probes verließen den Kanal nicht,
der Kanal ging offline, und mwan3 schaltete seine Fwmark-Regel auf `unreachable` — ohne Erholung
bis zum nächsten ifup.

Seit r9 (`files/lib/mwan3/track_host_routes.sh`):

- das Gateway wird aus dem Main-Default des Geräts genommen: `ip -6 route show default dev <device>` → `via`;
- `track_ip`-Host-Routen und das Policy-Default werden als `via <gw> dev <device> metric 1` gesetzt;
- beim Re-Sync werden zuvor gespeicherte Spezifikationen entfernt — das Gateway kann mit RA
  erscheinen/wechseln;
- Tunnel (kein `via` in ihrem Main-Default) behalten das bisherige Dev-only-Verhalten.

Tests: `tests/test_track_host_routes.sh` — 9 Fälle (via- und dev-only-Formen, Entfernen veralteter
Spezifikationen, IPv4-Skip, globales Deaktivieren).

## Besonderheiten von DHCPv6 über Wi-Fi STA

| Nr | Aspekt | Details |
|----|--------|---------|
| 1 | Gerätebindung | das UCI-Interface kann ohne `option device` sein — die Bindung läuft über die Wireless-Assoziation (`wifi-iface.network='wwan2 wwan2v6'`); mwan3 löst über `network_get_device`/ubus `l3_device` auf |
| 2 | Hotplug-Ereignisse | `INTERFACE=<logisch>`, aber `DEVICE=<l3 device>` (z. B. `phy0-sta0`): Skripte, die die Sektion über `DEVICE` matchen (wie der mwan6-npt-Hotplug), feuern für solche Kanäle nicht |
| 3 | LuCI-Schaltfläche Restart | inaktiv bei `pending=1` (netifd-Zyklus „setting up → down", z. B. liefert der Uplink kein IPv6) — ein netifd-Zustand, kein mwan3-Fehler |
| 4 | Diagnose | Busybox `ping -I <iface>` und mtr binden an die Link-Local-Adresse des Interfaces und liefern für globale Ziele `Network unreachable`; funktionierende Wege: mwan3-Tracking (WRAP fwmark → Policy-Tabelle), /128-Host-Route über das Gateway, `ping -I <GUA>` (mit der Einschränkung Main-Table-Hijack) |

## Failover zum nativen Uplink (Projekt)

Szenario: beide IPv4-Uplinks (`wwan`, `wwan2`) nicht verfügbar — alle Tunnel (WireGuard/6in4
laufen über v4) sind physisch tot, selbst wenn das Tracking die Down-Schwelle noch nicht erreicht
hat. Anforderung: `default_rule_v6` auf die Single-Native-Policy (`ipv6_native` → `wwan2v6`)
umstellen; bei Rückkehr eines v4-Uplinks `ipv6_primary` wiederherstellen.

Umsetzung — der Standard-User-Hook `/etc/mwan3.user` (läuft bei jedem netifd-Hotplug):

- `ubus`-Zustand von `wwan`, `wwan2` und die Lebendigkeit von `wwan2v6` selbst prüfen;
- beide v4 down und `wwan2v6` up → `mwan3.default_rule_v6.use_policy='ipv6_native'` + `mwan3 reload`;
- ein v4 up → `ipv6_primary` wiederherstellen;
- Umschaltung nur bei Wertwechsel (Schutz vor Reload-Schleife).

UCI-Ebene, ohne Paketänderungen; die Policy `ipv6_native` (Member `wwan26_m1_w1`) wird im Panel
angelegt.
