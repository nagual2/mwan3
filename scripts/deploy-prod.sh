#!/bin/bash
# Deploy nagual2 mwan3 patch (track_host_routes) to prod-openwrt.
set -euo pipefail

PKG_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOST="${1:-prod-openwrt}"
SSH_KEY="${SSH_KEY:-${HOME}/.ssh/id_ed25519_openwrt}"
SSH_OPTS=(-i "$SSH_KEY" -o StrictHostKeyChecking=accept-new)
SCP_OPTS=(-O "${SSH_OPTS[@]}")

echo "Deploy mwan3 track_host_routes patch to ${HOST}"

scp "${SCP_OPTS[@]}" \
	"$PKG_DIR/files/lib/mwan3/track_host_routes.sh" \
	"$PKG_DIR/files/lib/mwan3/mwan3.sh" \
	"root@${HOST}:/lib/mwan3/"

scp "${SCP_OPTS[@]}" \
	"$PKG_DIR/files/usr/sbin/mwan3track" \
	"root@${HOST}:/usr/sbin/mwan3track"

scp "${SCP_OPTS[@]}" \
	"$PKG_DIR/files/etc/hotplug.d/iface/15-mwan3" \
	"root@${HOST}:/etc/hotplug.d/iface/15-mwan3"

scp "${SCP_OPTS[@]}" \
	"$PKG_DIR/files/etc/uci-defaults/99-mwan3-track-host-routes" \
	"root@${HOST}:/etc/uci-defaults/99-mwan3-track-host-routes"

ssh "${SSH_OPTS[@]}" "root@${HOST}" '
	chmod 644 /lib/mwan3/track_host_routes.sh /lib/mwan3/mwan3.sh
	chmod 755 /usr/sbin/mwan3track /etc/hotplug.d/iface/15-mwan3
	chmod 755 /etc/uci-defaults/99-mwan3-track-host-routes
	/etc/uci-defaults/99-mwan3-track-host-routes
	uci set mwan3.globals.track_host_routes=1
	uci commit mwan3
	/etc/init.d/mwan3 restart
	sleep 3
	echo "--- track routes sample (first enabled ipv6 iface) ---"
	for s in $(uci show mwan3 | sed -n "s/^mwan3\\.\\([^=]*\\)=interface.*/\\1/p"); do
		en=$(uci -q get mwan3.${s}.enabled); fam=$(uci -q get mwan3.${s}.family)
		[ "$en" = 1 ] && [ "$fam" = ipv6 ] && id=$(ubus call mwan3 status 2>/dev/null | jsonfilter -e "@.interfaces[\"${s}\"].route_table" 2>/dev/null) && {
			dev=$(ip -6 route show table "$id" 2>/dev/null | awk "/default/{print \$5; exit}")
			echo "iface=$s table=$id dev=$dev"
			ip -6 route show table "$id" | grep -E "/128|default" | head -12
			break
		}
	done
	logread -e mwan3track | tail -5
'

echo "Done."
