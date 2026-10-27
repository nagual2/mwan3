#!/bin/sh
# Host routes for mwan3track targets (per-interface routing table).
# Requires: common.sh, mwan3_get_iface_id() from mwan3.sh

mwan3_track_host_routes_enabled()
{
	local iface=$1 enabled

	config_get enabled "$iface" track_host_routes
	case "$enabled" in
		1|true|yes|on) return 0 ;;
		0|false|no|off) return 1 ;;
	esac

	config_get enabled globals track_host_routes 1
	case "$enabled" in
		0|false|no|off) return 1 ;;
	esac
	return 0
}

mwan3_sync_track_host_routes()
{
	local interface=$1 device=$2
	local id family IP track_ip prefix error route_file gw

	config_get family "$interface" family ipv4
	if [ "$family" = "ipv4" ]; then
		# Host /32 dev routes break gateway-based uplinks (ARP for public track_ip).
		# track_host_routes applies to IPv6 tunnels only; drop legacy IPv4 routes.
		mwan3_delete_track_host_routes "$interface"
		return 0
	fi

	mwan3_track_host_routes_enabled "$interface" || return 0
	[ -n "$device" ] || return 0

	mwan3_get_iface_id id "$interface"
	[ -n "$id" ] || return 0

	if [ "$family" = "ipv6" ] && [ "$NO_IPV6" -eq 0 ]; then
		IP="$IP6"
		prefix=128
	else
		return 0
	fi

	route_file="$MWAN3TRACK_STATUS_DIR/$interface/TRACK_ROUTES"
	mkdir -p "$MWAN3TRACK_STATUS_DIR/$interface"

	# Gateway uplinks must reach track_ip through the nexthop: a dev-only route
	# on a broadcast link ARPs for the public target and blackholes the probe.
	# Tunnels (WireGuard, SIT) have no via in their main-table default and keep
	# dev-only routes. Gateway is taken from the device's main-table default.
	# "|| gw=" guards against set -e when grep finds no via (tunnel case).
	gw=$($IP route show default dev "$device" 2>/dev/null |
		grep -m1 ' via ' |
		sed -n 's/.* via \([^ ]*\).*/\1/p') || gw=""

	# The gateway can appear/disappear between syncs (RA up, tunnel reconfig);
	# replace with a different nexthop key leaves the old route in place, so
	# drop previously stored specs first and re-add the current set.
	if [ -f "$route_file" ]; then
		while read -r line; do
			[ -n "$line" ] || continue
			$IP route del table "$id" $line 2>/dev/null ||
				LOG debug "track route del (stale) table $id $line"
		done <"$route_file"
	fi
	: >"$route_file"

	_add_track_route() {
		local tip=$1 spec

		[ -n "$tip" ] || return 0
		if [ -n "$gw" ]; then
			spec="${tip}/${prefix} via ${gw} dev ${device}"
		else
			spec="${tip}/${prefix} dev ${device}"
		fi
		error=$($IP route replace table "$id" $spec metric 1 2>&1) ||
			LOG warn "track route replace table $id $spec metric 1: $error"
		echo "$spec" >>"$route_file"
		LOG debug "track route: table $id $spec"
	}

	config_list_foreach "$interface" track_ip _add_track_route

	# Policy-table default so mwan3track WRAP (per-iface FWMARK) can reach track_ip
	# when main has no ::/1 (route_allowed_ips=0). Not stored in TRACK_ROUTES —
	# ifdown flushes the whole table via mwan3_delete_iface_route.
	mwan3_ensure_policy_default_route "$interface" "$device" "$id" "$IP" "$gw"
}

# Ensure default exists in mwan3 policy table: via-nexthop for gateway uplinks,
# dev-only for tunnels.
mwan3_ensure_policy_default_route()
{
	local interface=$1 device=$2 id=$3 IP=$4 gw=$5
	local error

	[ -n "$device" ] || return 0
	[ -n "$id" ] || return 0
	[ -n "$IP" ] || return 0

	if [ -n "$gw" ]; then
		# A stale dev-only default (added before the gateway appeared) would
		# blackhole everything in this table: remove it explicitly.
		$IP route del table "$id" default dev "$device" metric 1 2>/dev/null
		error=$($IP route replace table "$id" default via "$gw" dev "$device" metric 1 2>&1) ||
			LOG warn "policy default replace table $id default via $gw dev $device metric 1: $error"
		LOG debug "track route: table $id default via $gw dev $device"
	else
		error=$($IP route replace table "$id" default dev "$device" metric 1 2>&1) ||
			LOG warn "policy default replace table $id default dev $device: $error"
		LOG debug "track route: table $id default dev $device"
	fi
}

mwan3_resolve_track_device()
{
	local interface=$1
	local _dev true_iface

	unset "$2"
	mwan3_get_true_iface true_iface "$interface"
	network_get_device _dev "$true_iface" 2>/dev/null
	if [ -z "$_dev" ]; then
		_dev=$(ubus call "network.interface.${true_iface}" status 2>/dev/null |
			jsonfilter -e '@.l3_device' 2>/dev/null)
	fi
	export "$2=$_dev"
}

mwan3_sync_all_track_host_routes()
{
	local iface device

	config_load mwan3
	sync_all_cb() {
		local enabled has_tip=0

		config_get_bool enabled "$1" enabled 0
		[ "$enabled" -eq 1 ] || return 0
		_collect_track_ip() { has_tip=1; }
		config_list_foreach "$1" track_ip _collect_track_ip
		[ "$has_tip" -eq 1 ] || return 0
		mwan3_resolve_track_device "$1" device
		[ -n "$device" ] || return 0
		mwan3_sync_track_host_routes "$1" "$device"
	}
	config_foreach sync_all_cb interface
}

mwan3_delete_track_host_routes()
{
	local interface=$1 id family IP route_file line

	mwan3_get_iface_id id "$interface"
	[ -n "$id" ] || return 0

	config_get family "$interface" family ipv4
	if [ "$family" = "ipv4" ]; then
		IP="$IP4"
	elif [ "$family" = "ipv6" ] && [ "$NO_IPV6" -eq 0 ]; then
		IP="$IP6"
	else
		return 0
	fi

	route_file="$MWAN3TRACK_STATUS_DIR/$interface/TRACK_ROUTES"
	if [ ! -f "$route_file" ]; then
		return 0
	fi

	while read -r line; do
		[ -n "$line" ] || continue
		$IP route del table "$id" $line 2>/dev/null ||
			LOG debug "track route del table $id $line (already gone)"
	done <"$route_file"

	rm -f "$route_file"
}
