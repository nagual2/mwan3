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

	mwan3_track_host_routes_enabled "$interface" || return 0
	[ -n "$device" ] || return 0

	config_get family "$interface" family ipv4
	mwan3_get_iface_id id "$interface"
	[ -n "$id" ] || return 0

	if [ "$family" = "ipv4" ]; then
		IP="$IP4"
		prefix=32
	elif [ "$family" = "ipv6" ] && [ "$NO_IPV6" -eq 0 ]; then
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
