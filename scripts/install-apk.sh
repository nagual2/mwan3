#!/bin/sh
# Install or upgrade mwan3 (nagual2 fork) via apk on OpenWrt 25.12+.
# Preserves /etc/config/mwan3 (conffile).
# Usage: ./scripts/install-apk.sh <router_host>
set -eu

PKG_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOST="${1:?Usage: $0 <router_host>}"
SSH_KEY="${SSH_KEY:-${HOME}/.ssh/id_ed25519}"
APK_FILE="$(ls -1 "$PKG_DIR"/dist/mwan3-*_x86_64.apk 2>/dev/null | tail -1)"

[ -n "$APK_FILE" ] || {
	echo "Build APK first: ./scripts/build-apk-mkpkg.sh" >&2
	exit 1
}

BASENAME="$(basename "$APK_FILE")"
REMOTE="/tmp/$BASENAME"

echo "Backing up mwan3 UCI on $HOST..."
ssh -i "$SSH_KEY" "root@${HOST}" '
	set -e
	B="/root/backup/apk-install-$(date +%Y%m%d-%H%M%S)"
	mkdir -p "$B"
	[ -f /etc/config/mwan3 ] && cp -a /etc/config/mwan3 "$B/"
	uci export mwan3 >"$B/mwan3.uci-export" 2>/dev/null || true
	echo "Backup: $B"
'

echo "Stopping mwan3 and removing stock/manual package..."
ssh -i "$SSH_KEY" "root@${HOST}" '
	set -e
	/etc/init.d/mwan3 stop 2>/dev/null || true
	if apk info -e mwan3 >/dev/null 2>&1; then
		apk del mwan3
	fi
'

echo "Installing $BASENAME via apk..."
scp -O -i "$SSH_KEY" "$APK_FILE" "root@${HOST}:${REMOTE}"
ssh -i "$SSH_KEY" "root@${HOST}" "
	set -e
	apk add --allow-untrusted '${REMOTE}'
	rm -f '${REMOTE}'
	[ -x /etc/uci-defaults/99-mwan3-track-host-routes ] && sh /etc/uci-defaults/99-mwan3-track-host-routes || true
	[ -x /etc/uci-defaults/100-mwan3-connected-ipv6 ] && sh /etc/uci-defaults/100-mwan3-connected-ipv6 || true
	/etc/init.d/mwan3 enable
	/etc/init.d/mwan3 restart
	apk info -e mwan3
	uci get mwan3.globals.track_host_routes 2>/dev/null || true
	/etc/init.d/mwan3 status
	find /lib/mwan3 -user 1000 2>/dev/null | head -3 || echo 'OK: no uid 1000 under lib/mwan3'
"

echo "Installed mwan3 on $HOST"
echo "Pin check:"
ssh -i "$SSH_KEY" "root@${HOST}" "grep '^mwan3><' /etc/apk/world || echo 'WARN: mwan3 not pinned'"
