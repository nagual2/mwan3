# mwan3 (standalone package)



[English](README.md) | [Русский](README.ru.md) | [Deutsch](README.de.md)



Standalone OpenWrt package extracted from [openwrt/packages `net/mwan3`](https://github.com/openwrt/packages/tree/master/net/mwan3).



Use this repository to track **local patches** (IPv6 multi-WAN) without forking the entire `openwrt/packages` feed.



## nagual2 patches (2.12.1-r9)



### `track_host_routes`



Installs host routes (`/32` or `/128`) for each `track_ip` in the mwan3 per-interface routing table so health checks work over the correct WAN (IPv6 multi-tunnel / WireGuard).



- UCI: `mwan3.globals.track_host_routes=1` (default on)

- Per-iface: `option track_host_routes '0'` to disable

- Hotplug `25`/`99` restores routes after `network restart`

- Command: `mwan3 sync-track-routes`



Since **r9**, host routes and the policy-table default for **gateway uplinks** (DHCPv6 over
Wi-Fi/Ethernet) are installed via `via <gateway>`: a dev-only route on a broadcast link sends a
Neighbor Solicitation straight to the public target and blackholes tracking (the channel went
offline and did not recover). The gateway is taken from the device main-table default; tunnels
keep the dev-only form. Details: [docs/GATEWAY_UPLINKS.en.md](docs/GATEWAY_UPLINKS.en.md).



### `connected_ipv6` filter



Skips overly broad IPv6 routes in `mwan3_connected_ipv6` ipset so WG split-default (`::/1`, `8000::/1`) and aggregates (`2000::/3`) do not bypass mwan3 policy rules.



- UCI: `mwan3.globals.connected_ipv6_min_prefixlen=32` (default)

- Command: `mwan3 flush-conntrack` after policy switch



## Build



```bash

# Tests + IPK for x86/64 (openwrt-dev)

./scripts/build-all.sh



# IPK only (opkg)

./scripts/build-ipk-sdk.sh



# APK only (OpenWrt 25.12+)

./scripts/build-apk-sdk.sh

```



Output: `dist/mwan3-2.12.1-r9_aarch64_cortex-a53.apk` (prod), `dist/mwan3-2.12.1-r8_x86_64.apk` (dev VM).



Override target: `SDK_URL=... ./scripts/build-ipk-sdk.sh`



Install on router (OpenWrt 25.12+ / **apk**, recommended):

```bash
./scripts/build-apk-mkpkg.sh
./scripts/install-apk.sh <router-lan-ip>
```

OpenWrt 23.x (opkg):

```bash
scp dist/mwan3_*.ipk root@openwrt-dev:/tmp/
ssh root@openwrt-dev 'opkg install /tmp/mwan3_*.ipk'
```

## apk pin (OpenWrt 25.12+)

`apk add --allow-untrusted` records a **world pin** (`mwan3><Q1hash…` in `/etc/apk/world`) so feeds cannot replace the nagual2 fork during `apk upgrade`.

```bash
grep '^mwan3><' /etc/apk/world
apk policy mwan3
```

Verify all nagual2 packages: [luci-app-mwan3/scripts/verify-apk-pins.sh](https://github.com/nagual2/luci-app-mwan3/blob/main/scripts/verify-apk-pins.sh). Full guide: [Pinning the nagual2 fork](https://github.com/nagual2/luci-app-mwan3#pinning-the-nagual2-fork-apk).

## Deploy to router (file overlay, dev only)



| Field | Value |

|--------|--------|

| Source | https://github.com/openwrt/packages/tree/master/net/mwan3 |

| Synced commit | `aa32dd256eb04eff40748b8b1a8623461441ffbe` |

| Upstream version | 2.12.1-1 |



See [UPSTREAM.md](UPSTREAM.md).



## Integration tests (Windows + OpenWrt lab)

Shipped with the package:

| Artifact | Path on router |
|----------|----------------|
| Lab guide (en / ru / de) | `/usr/share/doc/mwan3/OPENWRT_DEV_INFRASTRUCTURE.{en,ru,de}.md` |
| PowerShell script | `/usr/share/doc/mwan3/integration/Test-Mwan3PolicySwitch.ps1` |

Copy the script to a Windows host. It switches `mwan3` IPv6 policies on the router and verifies connectivity from the router and from Windows (`-LanInterface` must have exactly one GUA).

```powershell
scp root@<router-lan-ip>:/usr/share/doc/mwan3/integration/Test-Mwan3PolicySwitch.ps1 .
.\Test-Mwan3PolicySwitch.ps1 -DevHost <router-lan-ip> -LanInterface '<hyper-v-lan-adapter>'
```



## Related repos



| Repo | Role |

|------|------|

| [nagual2/mwan3](https://github.com/nagual2/mwan3) | This package |

| [nagual2/luci-app-mwan3](https://github.com/nagual2/luci-app-mwan3) | LuCI for fork options |

| [nagual2/mwan6-npt](https://github.com/nagual2/mwan6-npt) | IPv6 NPT multi-WAN |

| [nagual2/mwan6-npt-luci](https://github.com/nagual2/mwan6-npt-luci) | LuCI for mwan6-npt |



## LuCI



Fork options in the web UI: **[luci-app-mwan3](https://github.com/nagual2/luci-app-mwan3)** (`track_host_routes`, `connected_ipv6_min_prefixlen`, diagnostics).



## Documentation



Trilingual README files ship in `/usr/share/doc/mwan3/` (`README.en.md`, `README.ru.md`, `README.de.md`).



Thematic docs of this repository (also shipped in the package):

- [docs/IPV6_POLICY_SWITCHING.ru.md](docs/IPV6_POLICY_SWITCHING.ru.md) — per-iface WRAP fwmark and the policy-table default for IPv6 channels.
- [docs/GATEWAY_UPLINKS.ru.md](docs/GATEWAY_UPLINKS.ru.md) — gateway IPv6 uplinks: channel checklist (family/enabled/sourcefilter), via-tracking since r9, DHCPv6-over-WLAN specifics, native-uplink failover plan. Tri-lingual: [en](docs/GATEWAY_UPLINKS.en.md) | [ru](docs/GATEWAY_UPLINKS.ru.md) | [de](docs/GATEWAY_UPLINKS.de.md).



## License



GPL-2.0 — same as upstream. See [NOTICE](NOTICE).

