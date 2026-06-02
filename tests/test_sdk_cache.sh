#!/bin/bash
# Smoke test for sdk-cache (no full SDK download if cache hit).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
SDK_URL="${SDK_URL:-https://downloads.openwrt.org/releases/24.10.5/targets/x86/64/openwrt-sdk-24.10.5-x86-64_gcc-13.3.0_musl.Linux-x86_64.tar.zst}"

# shellcheck source=scripts/lib/sdk-cache.sh
. "$ROOT/scripts/lib/sdk-cache.sh"

passed=0
failed=0

log_pass() { echo "PASS: $1"; passed=$((passed + 1)); }
log_fail() { echo "FAIL: $1"; failed=$((failed + 1)); }

echo "=== sdk-cache ensure (1st call) ==="
sdk_cache_ensure_archive "$SDK_URL"
echo "archive=${SDK_CACHE_ARCHIVE:-}"
[ -n "${SDK_CACHE_ARCHIVE:-}" ] && [ -f "$SDK_CACHE_ARCHIVE" ] && log_pass "archive path set" || log_fail "archive path set"

echo ""
echo "=== sdk-cache ensure (2nd call — expect cache hit) ==="
out2="$(sdk_cache_ensure_archive "$SDK_URL" 2>&1)"
echo "$out2"
if echo "$out2" | grep -qE 'Using cached archive|sha256 match|ETag unchanged|Last-Modified|size unchanged|timestamping'; then
	log_pass "second call uses cache"
else
	log_fail "second call uses cache"
fi

echo ""
echo "Results: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
