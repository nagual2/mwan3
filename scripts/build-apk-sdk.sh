#!/usr/bin/env bash
# Build mwan3 .apk for OpenWrt 25.12+ using the official SDK.
#
# Usage:
#   ./scripts/build-apk-sdk.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SDK_URL="${SDK_URL:-https://downloads.openwrt.org/releases/25.12.0/targets/x86/64/openwrt-sdk-25.12.0-x86-64_gcc-14.3.0_musl.Linux-x86_64.tar.zst}"

case "$ROOT" in
	/mnt/*)
		SDK_DIR="${SDK_DIR:-${HOME}/.cache/openwrt-sdk-mwan3-apk}"
		OUTPUT_DIR="${OUTPUT_DIR:-$ROOT/dist}"
		;;
	*)
		SDK_DIR="${SDK_DIR:-$ROOT/build/sdk-apk}"
		OUTPUT_DIR="${OUTPUT_DIR:-$ROOT/dist}"
		;;
esac

PKG_VERSION="${PKG_VERSION:-2.12.1}"
PKG_RELEASE="${PKG_RELEASE:-5}"

log() { printf '[build-apk-sdk] %s\n' "$*"; }

need_cmd() {
	command -v "$1" >/dev/null 2>&1 || {
		echo "Missing command: $1" >&2
		exit 1
	}
}

need_cmd tar
need_cmd make
need_cmd rsync
need_cmd wget

# shellcheck source=scripts/lib/sdk-cache.sh
. "$ROOT/scripts/lib/sdk-cache.sh"

sdk_cache_ensure_archive "$SDK_URL"
sdk_cache_ensure_extracted "$SDK_CACHE_ARCHIVE" "$SDK_DIR"

log "Syncing mwan3 into SDK..."
rm -rf "$SDK_DIR/package/custom/mwan3"
mkdir -p "$SDK_DIR/package/custom"
rsync -a \
	--exclude .git \
	--exclude build \
	--exclude dist \
	--exclude tests/tmp \
	"$ROOT/" "$SDK_DIR/package/custom/mwan3/"

cd "$SDK_DIR"

sed -i \
	-e 's|git\.openwrt\.org/feed|github.com/openwrt|g' \
	-e 's|git\.openwrt\.org/project|github.com/openwrt|g' \
	-e 's|git\.openwrt\.org/openwrt|github.com/openwrt|g' \
	feeds.conf.default 2>/dev/null || true

./scripts/feeds update base 2>/dev/null || ./scripts/feeds update -a
./scripts/feeds install -p base ip ipset iptables rpcd

cat > .config <<EOF
CONFIG_ALL_NONSHARED=n
CONFIG_ALL_KMODS=n
CONFIG_ALL=n
CONFIG_AUTOREMOVE=n
CONFIG_SIGNED_PACKAGES=n
CONFIG_IPV6=y
CONFIG_PACKAGE_ip6tables=y
CONFIG_PACKAGE_iptables-mod-conntrack-extra=y
CONFIG_PACKAGE_iptables-mod-ipopt=y
CONFIG_PACKAGE_rpcd-mod-ucode=y
CONFIG_PACKAGE_jshn=y
CONFIG_PACKAGE_mwan3=m
EOF

make defconfig

log "Compiling mwan3 ${PKG_VERSION}-${PKG_RELEASE}..."
make "package/custom/mwan3/clean" V=s 2>/dev/null || true
make "package/custom/mwan3/compile" \
	"PKG_VERSION=${PKG_VERSION}" \
	"PKG_RELEASE=${PKG_RELEASE}" \
	-j"$(nproc 2>/dev/null || echo 2)" V=s \
	|| make "package/custom/mwan3/compile" \
		"PKG_VERSION=${PKG_VERSION}" \
		"PKG_RELEASE=${PKG_RELEASE}" \
		-j1 V=s

mkdir -p "$OUTPUT_DIR"
find bin/packages -name 'mwan3*.apk' -exec cp -a {} "$OUTPUT_DIR/" \;

if ! ls "$OUTPUT_DIR"/mwan3*.apk >/dev/null 2>&1; then
	echo "APK build failed: no output in $OUTPUT_DIR" >&2
	exit 1
fi

log "Built packages:"
ls -la "$OUTPUT_DIR"/mwan3*.apk
