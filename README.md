# mwan3 (standalone package)



[English](README.md) | [Русский](README.ru.md) | [Deutsch](README.de.md)



Standalone OpenWrt package extracted from [openwrt/packages `net/mwan3`](https://github.com/openwrt/packages/tree/master/net/mwan3).



Use this repository to track **local patches** (IPv6 multi-WAN) without forking the entire `openwrt/packages` feed.



## nagual2 patches (2.12.1-4)



### `track_host_routes`



Installs host routes (`/32` or `/128`) for each `track_ip` in the mwan3 per-interface routing table so health checks work over the correct WAN (IPv6 multi-tunnel / WireGuard).



- UCI: `mwan3.globals.track_host_routes=1` (default on)

- Per-iface: `option track_host_routes '0'` to disable

- Hotplug `25`/`99` restores routes after `network restart`

- Command: `mwan3 sync-track-routes`



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



Output: `dist/mwan3_2.12.1-4_*.ipk` (and `.apk` if zstd tar available).



Override target: `SDK_URL=... ./scripts/build-ipk-sdk.sh`



Install on router (OpenWrt 25.12+ / **apk**, recommended):

```bash
./scripts/build-apk-mkpkg.sh
./scripts/install-apk.sh 192.168.56.1
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

| Synced commit | `858ec4093deeea8e63ea08cd4f41f7c034ea4b39` |

| Upstream version | 2.12.1-1 |



See [UPSTREAM.md](UPSTREAM.md).



## Integration tests (Windows + OpenWrt lab)

Shipped with the package:

| Artifact | Path on router |
|----------|----------------|
| Lab guide | `/usr/share/doc/mwan3/OPENWRT_DEV_INFRASTRUCTURE.md` |
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



## License



GPL-2.0 — same as upstream. See [NOTICE](NOTICE).

