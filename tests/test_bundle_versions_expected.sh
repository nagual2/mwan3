#!/bin/bash
# Unit test: bundle-versions.expected matches Makefile / mwan6-npt VERSION.
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
EXPECTED="$ROOT/scripts/bundle-versions.expected"
MWAN6_PKG="$(CDPATH= cd -- "$ROOT/../../Backup/openwrt-prod/package/mwan6-npt" 2>/dev/null && pwd || true)"

# shellcheck source=/dev/null
. "$EXPECTED"

fail=0
assert_eq() {
	if [ "$1" = "$2" ]; then
		echo "OK: $3"
	else
		echo "FAIL: $3 (got='$1' want='$2')" >&2
		fail=$((fail + 1))
	fi
}

mwan3_ver="$(awk -F= '/^PKG_VERSION:=/{v=$2} /^PKG_RELEASE:=/{print v"-r"$2}' "$ROOT/Makefile" | tail -1)"
assert_eq "$LUCI_APP_MWAN3" "1.0.1-r1" "LUCI_APP_MWAN3 pinned"
assert_eq "$LUCI_APP_MWAN6_NPT" "1.2.2-r1" "LUCI_APP_MWAN6_NPT pinned"
assert_eq "$LUCI_I18N_MWAN3_RU" "1.0.0-r1" "LUCI_I18N_MWAN3_RU pinned"
assert_eq "$LUCI_I18N_MWAN6_NPT_RU" "1.0.2-r1" "LUCI_I18N_MWAN6_NPT_RU pinned (docs/license apk; lmo same as 1.0.x)"

if [ -f "${MWAN6_PKG}/VERSION" ]; then
	want_mwan6="$(tr -d '\r\n' < "${MWAN6_PKG}/VERSION")-${MWAN6_NPT_RELEASE}"
	echo "OK: mwan6-npt VERSION file -> ${want_mwan6} (release ${MWAN6_NPT_RELEASE})"
else
	echo "WARN: mwan6-npt VERSION not found" >&2
fi

echo "Makefile mwan3 -> ${mwan3_ver}"
[ "$fail" -eq 0 ] || exit 1
echo "bundle-versions.expected: all checks passed"
