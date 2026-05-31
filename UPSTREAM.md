# Sync from openwrt/packages

This tree mirrors `net/mwan3` from https://github.com/openwrt/packages.

## One-time refresh (WSL)

```bash
cd /tmp
rm -rf mwan3-sync && mkdir mwan3-sync && cd mwan3-sync
git init -q
git remote add origin https://github.com/openwrt/packages.git
git config core.sparseCheckout true
echo 'net/mwan3' > .git/info/sparse-checkout
git pull --depth=1 origin master
UPSTREAM_COMMIT=$(git rev-parse HEAD)

# Copy into your clone (adjust path)
rsync -a --delete net/mwan3/ /mnt/c/Git/project/mwan3/
# Restore repo-only files (README, UPSTREAM.md, NOTICE, scripts/)
```

Or run from repo root:

```bash
./scripts/sync-from-upstream.sh
```

After sync, update `UPSTREAM_COMMIT` in `README.md` / `README.ru.md` and commit.

## Version bump

Upstream `Makefile` sets `PKG_VERSION` / `PKG_RELEASE`. For local patches without upstream version change, increment `PKG_RELEASE` in `Makefile` (e.g. `2.12.1-2`).
