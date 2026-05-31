#!/bin/sh
# Refresh package files from openwrt/packages net/mwan3 (sparse clone).
set -eu

REPO_ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

cd "$WORKDIR"
git init -q
git remote add origin https://github.com/openwrt/packages.git
git config core.sparseCheckout true
mkdir -p .git/info
echo 'net/mwan3' > .git/info/sparse-checkout
git pull --depth=1 -q origin master
UPSTREAM_COMMIT=$(git rev-parse HEAD)

rsync -a --delete \
  --exclude='README.md' \
  --exclude='README.ru.md' \
  --exclude='UPSTREAM.md' \
  --exclude='NOTICE' \
  --exclude='.gitignore' \
  --exclude='scripts/' \
  net/mwan3/ "$REPO_ROOT/"

echo "Synced net/mwan3 from openwrt/packages @ $UPSTREAM_COMMIT"
echo "Update UPSTREAM_COMMIT in README.md, README.ru.md, and NOTICE."
