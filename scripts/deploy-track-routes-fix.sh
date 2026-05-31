#!/bin/bash
# Deploy track_host_routes persistence fix (2.12.1-3) to prod-openwrt.
set -euo pipefail

PKG_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOST="${1:-prod-openwrt}"
SSH_KEY="${SSH_KEY:-${HOME}/.ssh/id_ed25519_openwrt}"
SCP_OPTS=(-O -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new)
SSH_OPTS=(-i "$SSH_KEY" -o StrictHostKeyChecking=accept-new)

echo "Deploy mwan3 2.12.1-3 track routes persistence to ${HOST}"

scp "${SCP_OPTS[@]}" \
	"$PKG_DIR/files/lib/mwan3/track_host_routes.sh" \
	"$PKG_DIR/files/lib/mwan3/mwan3.sh" \
	"root@${HOST}:/lib/mwan3/"

scp "${SCP_OPTS[@]}" \
	"$PKG_DIR/files/etc/hotplug.d/iface/15-mwan3" \
	"$PKG_DIR/files/etc/hotplug.d/iface/25-mwan3-track-routes" \
	"$PKG_DIR/files/etc/hotplug.d/iface/99-mwan3-track-routes" \
	"root@${HOST}:/etc/hotplug.d/iface/"

scp "${SCP_OPTS[@]}" \
	"$PKG_DIR/files/usr/sbin/mwan3" \
	"root@${HOST}:/usr/sbin/mwan3"

scp "${SCP_OPTS[@]}" \
	"$PKG_DIR/files/etc/init.d/mwan3" \
	"root@${HOST}:/etc/init.d/mwan3"

ssh "${SSH_OPTS[@]}" "root@${HOST}" '
	chmod 644 /lib/mwan3/track_host_routes.sh
	chmod 755 /etc/hotplug.d/iface/25-mwan3-track-routes
	chmod 755 /etc/hotplug.d/iface/99-mwan3-track-routes
	chmod 755 /etc/init.d/mwan3
	/etc/init.d/mwan3 restart
	sleep 5
	echo "=== track routes after mwan3 restart ==="
	for t in 3 4 5 6 7 8 9; do
		r=$(ip -6 route show table $t 2>/dev/null | grep -E "8888|1111" || true)
		[ -n "$r" ] && echo "table $t:" && echo "$r"
	done
'

echo "Done. Run: ssh root@${HOST} /etc/init.d/network restart  then verify tables again."
