#!/bin/bash
# Compare multi-WAN bundle package versions: git expected vs dev vs prod.
# Usage: ./scripts/test-bundle-versions.sh
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
COLLECT="$ROOT/scripts/collect-bundle-versions.sh"
MWAN6_PKG="$(CDPATH= cd -- "$ROOT/../../Backup/openwrt-prod/package/mwan6-npt" 2>/dev/null && pwd || true)"
EXPECTED="$ROOT/scripts/bundle-versions.expected"

# shellcheck source=/dev/null
. "$EXPECTED"

DEV_HOST="${DEV_HOST:-root@192.168.56.1}"
PROD_HOST="${PROD_HOST:-root@192.168.35.1}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519_openwrt}"

EXP_MWAN3="$(awk -F= '/^PKG_VERSION:=/{v=$2} /^PKG_RELEASE:=/{print v"-r"$2}' "$ROOT/Makefile" | tail -1)"
if [ -f "${MWAN6_PKG}/VERSION" ]; then
	EXP_MWAN6_NPT="$(tr -d '\r\n' < "${MWAN6_PKG}/VERSION")-${MWAN6_NPT_RELEASE:-2}"
else
	EXP_MWAN6_NPT="1.0.6-${MWAN6_NPT_RELEASE:-2}"
fi
EXP_LUCI_MWAN3="${LUCI_APP_MWAN3}"
EXP_LUCI_MWAN6_NPT="${LUCI_APP_MWAN6_NPT}"
EXP_LUCI_I18N_MWAN3_RU="${LUCI_I18N_MWAN3_RU}"
EXP_LUCI_I18N_MWAN6_NPT_RU="${LUCI_I18N_MWAN6_NPT_RU}"

fetch_host() {
	local target="$1" ssh_args="$2" out="$3"
	scp -O $ssh_args "$COLLECT" "${target}:/tmp/collect-bundle-versions.sh"
	ssh $ssh_args "$target" "sh /tmp/collect-bundle-versions.sh" >"$out"
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fetch_host "$DEV_HOST" "-o ConnectTimeout=5" "$TMP/dev.txt"

PROD_SSH_ARGS="-o ConnectTimeout=5"
if [ -f "$SSH_KEY" ]; then
	PROD_SSH_ARGS="$PROD_SSH_ARGS -i $SSH_KEY"
fi
fetch_host "$PROD_HOST" "$PROD_SSH_ARGS" "$TMP/prod.txt"

parse_kv() {
	grep "^${2}=" "$1" 2>/dev/null | cut -d= -f2- || echo "?"
}

mark() {
	[ "$1" = "$2" ] && echo "OK" || echo "≠"
}

print_row() {
	printf "| %-28s | %-12s | %-14s | %-14s | %-4s | %-4s |\n" "$@"
}

echo "## Пакеты связки: git / dev / prod"
echo
echo "| Пакет | Git (ожид.) | dev | prod | dev | prod |"
echo "|---|---|---|---|:---:|:---:|"

rows=(
	"mwan3|${EXP_MWAN3}|mwan3"
	"luci-app-mwan3|${EXP_LUCI_MWAN3}|luci-app-mwan3"
	"luci-i18n-mwan3-ru|${EXP_LUCI_I18N_MWAN3_RU}|luci-i18n-mwan3-ru"
	"mwan6-npt (IPK)|${EXP_MWAN6_NPT}|mwan6-npt"
	"luci-app-mwan6-npt|${EXP_LUCI_MWAN6_NPT}|luci-app-mwan6-npt"
	"luci-i18n-mwan6-npt-ru|${EXP_LUCI_I18N_MWAN6_NPT_RU}|luci-i18n-mwan6-npt-ru"
)

dev_fail=0
prod_fail=0
for row in "${rows[@]}"; do
	IFS='|' read -r label exp key <<<"$row"
	dev_v=$(parse_kv "$TMP/dev.txt" "$key")
	prod_v=$(parse_kv "$TMP/prod.txt" "$key")
	dm=$(mark "$dev_v" "$exp")
	pm=$(mark "$prod_v" "$exp")
	[ "$dm" = OK ] || dev_fail=$((dev_fail + 1))
	[ "$pm" = OK ] || prod_fail=$((prod_fail + 1))
	print_row "$label" "$exp" "$dev_v" "$prod_v" "$dm" "$pm"
done

dev_ui=$(parse_kv "$TMP/dev.txt" "luci-mwan6-npt-ui")
prod_ui=$(parse_kv "$TMP/prod.txt" "luci-mwan6-npt-ui")
print_row "LuCI mwan6-npt UI overlay" "patched" "$dev_ui" "$prod_ui" "$(mark "$dev_ui" patched)" "$(mark "$prod_ui" patched)"

echo
echo "OK = совпадает с git; ≠ = расхождение"
echo "Источники: mwan3 $ROOT/Makefile; mwan6-npt ${MWAN6_PKG:-Backup/.../VERSION}; apk $EXPECTED"
echo "dev: $dev_fail расхождений с git; prod: $prod_fail расхождений с git"
