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
	local id family IP track_ip prefix error route_file

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
	: >"$route_file"

	_add_track_route() {
		local tip=$1

		[ -n "$tip" ] || return 0
		error=$($IP route replace table "$id" "${tip}/${prefix}" dev "$device" metric 1 2>&1) ||
			LOG warn "track route replace table $id ${tip}/${prefix} dev $device: $error"
		echo "${tip}/${prefix} dev ${device}" >>"$route_file"
		LOG debug "track route: table $id ${tip}/${prefix} dev $device"
	}

	config_list_foreach "$interface" track_ip _add_track_route
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
