# mwan3 (standalone package)

[English](README.md) | [Русский](README.ru.md)

Standalone OpenWrt package extracted from [openwrt/packages `net/mwan3`](https://github.com/openwrt/packages/tree/master/net/mwan3).

Use this repository to track **local patches** (for example IPv6 `track_ip` routing) without forking the entire `openwrt/packages` feed.

## Upstream

| Field | Value |
|--------|--------|
| Source | https://github.com/openwrt/packages/tree/master/net/mwan3 |
| Synced commit | `858ec4093deeea8e63ea08cd4f41f7c034ea4b39` (2025-05-31) |
| Upstream version | 2.12.1-1 |

See [UPSTREAM.md](UPSTREAM.md) for refresh instructions.

## Build (OpenWrt SDK / full tree)

```bash
# In your OpenWrt build tree
cd package
git clone https://github.com/nagual2/mwan3.git custom/mwan3
# or: ln -s /path/to/mwan3 custom/mwan3

make menuconfig   # Network → Routing and Redirection → mwan3
make package/mwan3/compile V=s
```

The package builds a small shared library `libwrap_mwan3_sockopt.so` from `src/sockopt_wrap.c` for the **target** architecture (not `all` at runtime despite `PKGARCH:=all` in control).

## Install on router

Prefer the official feed when unmodified:

```bash
opkg update && opkg install mwan3
# OpenWrt 25.12+ (apk)
apk add mwan3
```

Install a custom `.ipk` only if you built it for your router's **target arch** from SDK.

## Relation to other repos

| Repo | Role |
|------|------|
| [nagual2/mwan3](https://github.com/nagual2/mwan3) | This package (scripts + `sockopt_wrap`) |
| [nagual2/packages](https://github.com/nagual2/packages) | Full feed fork (optional; heavy) |
| [nagual2/mwan6-npt](https://github.com/nagual2/mwan6-npt) | IPv6 NPT multi-WAN (complementary) |

## License

GPL-2.0 — same as upstream OpenWrt `mwan3`. See [NOTICE](NOTICE).
