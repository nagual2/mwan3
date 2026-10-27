[Русский](GATEWAY_UPLINKS.ru.md) | **[English](GATEWAY_UPLINKS.en.md)** | [Deutsch](GATEWAY_UPLINKS.de.md)

# Gateway-style IPv6 uplinks in mwan3

> **Date:** 2026-10-27  
> **Context:** attaching a native DHCPv6 uplink `wwan2v6` (Wi-Fi STA, broadcast link) on the production router; package mwan3-2.12.1-r9  
> **Related:** [IPV6_POLICY_SWITCHING.ru.md](IPV6_POLICY_SWITCHING.ru.md), package [nagual2/mwan6-npt](https://github.com/nagual2/mwan6-npt)

---

## Why a gateway uplink is not a tunnel

Tunnel channels (WireGuard, 6in4/SIT) are point-to-point: a `dev <iface>` route delivers the
packet to the peer router itself. Gateway uplinks (DHCPv6 over Wi-Fi/Ethernet) are a broadcast
link with a link-local gateway: a packet without `via` is sent as a Neighbor Solicitation straight
to the public target and is lost. This is the source of every difference in configuration and
health-check behaviour.

## Checklist for adding a gateway IPv6 channel

| № | Setting | Where | Value | Why |
|---|---------|-------|-------|-----|
| 1 | `family` | `mwan3.<iface>` | `ipv6` | otherwise mwan3 looks for an IPv4 address on the interface and keeps the channel `unknown` |
| 2 | `enabled` | `mwan3.<iface>` | `1` | without the option, hotplug treats the channel as disabled (`hotplug ... not called because interface disabled`) |
| 3 | `sourcefilter` | `network.<iface>` | `0` | without PD, netifd builds the default with a from-constraint (`default from <PIO>/64`); until it is lifted, bind-to-device traffic (mwan3track WRAP, `ping -I`) gets `Network unreachable` |
| 4 | `metric` | `network.<iface>` | above the primary v6 default | the channel default in main must not capture global traffic from more specific routes |
| 5 | `track_ip` | `mwan3.<iface>` | 2 global targets | with `track_host_routes=1`, a /128 route is created in the channel policy table for each target |
| 6 | NPT | `mwan6-npt.<iface>` | `enabled=1`, `wan_prefix` | to translate the LAN prefix outward; a native uplink prefix is **dynamic SLAAC** — update it on change («Suggest from interface» in LuCI) |

## track_host_routes: via routes (2.12.1-r9)

Before r9, `/128` host routes and the policy-table default were installed as `dev <iface>` —
correct for tunnels, but a black hole for gateway uplinks: health-check probes never egressed,
the channel went offline, and mwan3 switched its fwmark rule to `unreachable` — the channel did
not recover until the next ifup.

Since r9 (`files/lib/mwan3/track_host_routes.sh`):

- the gateway is taken from the device main-table default: `ip -6 route show default dev <device>` → `via`;
- `track_ip` host routes and the policy default are installed as `via <gw> dev <device> metric 1`;
- on re-sync, previously stored specs are removed — the gateway may appear/change together with RA;
- tunnels (no `via` in their main-table default) keep the previous dev-only behaviour.

Tests: `tests/test_track_host_routes.sh` — 9 cases (via and dev-only forms, stale spec removal,
IPv4 skip, global disable).

## DHCPv6 over Wi-Fi STA specifics

| № | Aspect | Details |
|---|--------|---------|
| 1 | Device binding | the UCI interface may have no `option device` — binding goes through the wireless association (`wifi-iface.network='wwan2 wwan2v6'`); mwan3 resolves via `network_get_device`/ubus `l3_device` |
| 2 | Hotplug events | `INTERFACE=<logical>`, but `DEVICE=<l3 device>` (e.g. `phy0-sta0`): scripts that match the section by `DEVICE` (like the mwan6-npt hotplug) do not fire for such channels |
| 3 | LuCI Restart button | inactive while `pending=1` (netifd «setting up → down» loop, e.g. the uplink provides no IPv6) — a netifd state, not an mwan3 failure |
| 4 | Diagnostics | busybox `ping -I <iface>` and mtr bind to the interface link-local address and return `Network unreachable` for global targets; working paths: mwan3 tracking (WRAP fwmark → policy table), a /128 host route via the gateway, `ping -I <GUA>` (with the main-table hijack caveat) |

## Failover to the native uplink (project)

Scenario: both IPv4 uplinks (`wwan`, `wwan2`) are unavailable — all tunnels (WireGuard/6in4 ride
over v4) are physically dead, even if tracking has not yet reached the down threshold. Requirement:
switch `default_rule_v6` to the single native-channel policy (`ipv6_native` → `wwan2v6`); when any
v4 uplink returns, restore `ipv6_primary`.

Implementation — the standard user hook `/etc/mwan3.user` (runs on every netifd hotplug):

- check the `ubus` state of `wwan`, `wwan2` and the liveness of `wwan2v6` itself;
- both v4 down and `wwan2v6` up → `mwan3.default_rule_v6.use_policy='ipv6_native'` + `mwan3 reload`;
- any v4 up → restore `ipv6_primary`;
- switch only on value change (reload-loop guard).

UCI level, no package changes; the `ipv6_native` policy (member `wwan26_m1_w1`) is created in the
panel.
