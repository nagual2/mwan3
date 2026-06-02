#!/bin/bash
# Deploy nagual2 mwan3 2.12.1-4 patches to prod-openwrt / openwrt-dev.
set -euo pipefail

PKG_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOST="${1:-prod-openwrt}"
SSH_KEY="${SSH_KEY:-${HOME}/.ssh/id_ed25519_openwrt}"
SSH_OPTS=(-i "$SSH_KEY" -o StrictHostKeyChecking=accept-new)
SCP_OPTS=(-O "${SSH_OPTS[@]}")

echo "Deploy mwan3 2.12.1-4 to ${HOST}"

scp "${SCP_OPTS[@]}" \
	"$PKG_DIR/files/lib/mwan3/track_host_routes.sh" \
	"$PKG_DIR/files/lib/mwan3/connected_routes.sh" \
	"$PKG_DIR/files/lib/mwan3/mwan3.sh" \
	"root@${HOST}:/lib/mwan3/"

scp "${SCP_OPTS[@]}" \
	"$PKG_DIR/files/usr/sbin/mwan3" \
	"$PKG_DIR/files/usr/sbin/mwan3track" \
	"$PKG_DIR/files/usr/sbin/mwan3rtmon" \
	"root@${HOST}:/usr/sbin/"

scp "${SCP_OPTS[@]}" \
	"$PKG_DIR/files/etc/hotplug.d/iface/15-mwan3" \
	"$PKG_DIR/files/etc/hotplug.d/iface/25-mwan3-track-routes" \
	"$PKG_DIR/files/etc/hotplug.d/iface/99-mwan3-track-routes" \
	"root@${HOST}:/etc/hotplug.d/iface/"

scp "${SCP_OPTS[@]}" \
	"$PKG_DIR/files/etc/init.d/mwan3" \
	"root@${HOST}:/etc/init.d/mwan3"

scp "${SCP_OPTS[@]}" \
	"$PKG_DIR/files/etc/uci-defaults/99-mwan3-track-host-routes" \
	"$PKG_DIR/files/etc/uci-defaults/100-mwan3-connected-ipv6" \
	"root@${HOST}:/etc/uci-defaults/"

ssh "${SSH_OPTS[@]}" "root@${HOST}" '
	chmod 644 /lib/mwan3/*.sh
	chmod 755 /usr/sbin/mwan3 /usr/sbin/mwan3track /usr/sbin/mwan3rtmon
	chmod 755 /etc/init.d/mwan3 /etc/hotplug.d/iface/25-mwan3-track-routes
	chmod 755 /etc/hotplug.d/iface/99-mwan3-track-routes
	chmod 644 /etc/hotplug.d/iface/15-mwan3
	chmod 755 /etc/uci-defaults/99-mwan3-track-host-routes
	chmod 755 /etc/uci-defaults/100-mwan3-connected-ipv6
	/etc/uci-defaults/99-mwan3-track-host-routes
	/etc/uci-defaults/100-mwan3-connected-ipv6
	uci commit mwan3
	/etc/init.d/mwan3 restart
	sleep 3
	mwan3 sync-track-routes
	echo "--- connected ipv6 (should NOT contain ::/1) ---"
	mwan3 connected | sed -n "/ipv6/,/^$/p" | head -12
	mwan3 status 2>/dev/null | sed -n "1,20p"
'

echo "Done."
