# Sync from openwrt/packages

This tree mirrors `net/mwan3` from https://github.com/openwrt/packages.

## Remotes

| Remote | URL |
|--------|-----|
| `origin` | https://github.com/nagual2/mwan3.git |
| `upstream` | https://github.com/openwrt/packages.git |

```bash
git fetch upstream
git log -1 --oneline upstream/master
```

## Refresh package files (WSL)

```bash
./scripts/sync-from-upstream.sh
```

The script sparse-clones `net/mwan3` from `upstream/master` and rsyncs into the repo root.
**Excluded from rsync** (never deleted): `.git/`, `build/`, `dist/`, `docs/`, `tests/`, `scripts/`, README*, NOTICE, UPSTREAM.md.

After sync:

1. Restore nagual2 fork overlays if upstream removed them under `files/` (track_host_routes, connected_ipv6, hotplug 25/99, uci-defaults).
2. Update synced commit in `README.md`, `README.ru.md`, and `NOTICE`.
3. Commit on a `sync/upstream-YYYY-MM-DD` branch; merge to `main`.

## Current sync

| Field | Value |
|-------|-------|
| Upstream commit | `aa32dd256eb04eff40748b8b1a8623461441ffbe` |
| Upstream version | 2.12.1-1 (`PKG_RELEASE:=1`) |
| Fork release | 2.12.1-r6 (nagual2 patches on top) |
| Last sync | 2026-06-09 |

## Version bump

Upstream `Makefile` sets `PKG_VERSION` / `PKG_RELEASE`. For local patches without upstream version change, increment `PKG_RELEASE` in `Makefile` (e.g. `2.12.1-r7`).
