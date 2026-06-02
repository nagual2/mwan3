#!/usr/bin/env bash
# Run tests and build mwan3 packages for openwrt-dev (x86/64).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKG_RELEASE="${PKG_RELEASE:-5}"

log() { printf '[build-all] %s\n' "$*"; }

log "Running tests..."
bash "$ROOT/tests/run_tests.sh"

log "Building IPK (mkpkg, x86_64)..."
PKG_RELEASE="$PKG_RELEASE" bash "$ROOT/scripts/build-ipk-mkpkg.sh"

if [ "${BUILD_SDK:-0}" = 1 ]; then
	log "Building IPK via OpenWrt SDK (optional, slow)..."
	PKG_RELEASE="$PKG_RELEASE" bash "$ROOT/scripts/build-ipk-sdk.sh"
fi

if command -v tar >/dev/null 2>&1 && tar --help 2>&1 | grep -q zstd && [ "${BUILD_APK:-0}" = 1 ]; then
	log "Building APK (OpenWrt 25.12+)..."
	PKG_RELEASE="$PKG_RELEASE" bash "$ROOT/scripts/build-apk-sdk.sh"
else
	log "Skipping APK build (tar without zstd support)"
fi

log "Done. Output: $ROOT/dist/"
ls -la "$ROOT/dist/" 2>/dev/null || true
