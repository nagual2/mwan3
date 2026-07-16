#!/bin/sh
# Sync kernel IPv6 route metrics with active mwan3 IPv6 policy members.
# WG: uci network.<iface>.metric 30/40 or delete + ifup.
# HE 6in4: explicit ip -6 route replace/del (split-default does not apply).

MWAN3_TUNNEL_METRICS_STATE="${MWAN3_STATUS_DIR}/tunnel_metrics.state"
MWAN3_TUNNEL_METRICS_LOCK="${MWAN3_STATUS_DIR}/tunnel_metrics.lock"
MWAN3_WG_IFACE_LIST=
MWAN3_CHANGED_IFACES=
MWAN3_SYNC_POLICY=
MWAN3_SYNC_ONLINE_IFACES=

mwan3_tunnel_metrics_enabled()
{
	local enabled

	config_get enabled globals sync_tunnel_metrics 1
	case "$enabled" in
		1|true|yes|on) return 0 ;;
		0|false|no|off) return 1 ;;
	esac
	return 0
}

mwan3_tunnel_metrics_load_active_policy()
{
	local enabled

	config_get enabled default_rule_v6 enabled 1
	[ "$enabled" = "1" ] || return 1
	config_get MWAN3_SYNC_POLICY default_rule_v6 use_policy
	[ -n "$MWAN3_SYNC_POLICY" ] || return 1
	return 0
}

mwan3_iface_is_online()
{
	[ "$(mwan3_get_iface_hotplug_state "$1")" = "online" ]
}

mwan3_collect_policy_online_ifaces()
{
	local policy="$1"
	local members member iface

	MWAN3_SYNC_ONLINE_IFACES=
	config_get members "$policy" use_member
	[ -n "$members" ] || return 0

	for member in $members; do
		config_get iface "$member" interface
		[ -n "$iface" ] || continue
		mwan3_iface_is_online "$iface" || continue
		MWAN3_SYNC_ONLINE_IFACES="${MWAN3_SYNC_ONLINE_IFACES}${MWAN3_SYNC_ONLINE_IFACES:+ }${iface}"
	done
}

_mwan3_append_wg_iface()
{
	local proto

	config_get proto "$1" proto
	[ "$proto" = "wireguard" ] || return 0
	MWAN3_WG_IFACE_LIST="${MWAN3_WG_IFACE_LIST}${MWAN3_WG_IFACE_LIST:+ }$1"
}

mwan3_list_network_wireguard_ifaces()
{
	MWAN3_WG_IFACE_LIST=
	config_foreach _mwan3_append_wg_iface interface
}

mwan3_network_iface_exists()
{
	uci -q get "network.$1" >/dev/null 2>&1
}

mwan3_henet_load_prefixes()
{
	local ip6addr plen base

	MWAN3_HENET_FROM_PREFIX=
	MWAN3_HENET_ROUTED48=
	config_get ip6addr henet ip6addr
	[ -n "$ip6addr" ] || return 1
	plen="${ip6addr##*/}"
	base="${ip6addr%/*}"
	case "$base" in
		*::*) MWAN3_HENET_FROM_PREFIX="${base%::*}::/${plen}" ;;
		*) MWAN3_HENET_FROM_PREFIX="${base%:*}:/${plen}" ;;
	esac
	config_get MWAN3_HENET_ROUTED48 henet_routed48 target
	return 0
}

mwan3_henet_clear_managed_routes()
{
	local device="$1" metric

	[ -n "$device" ] || return 0
	[ -f "$MWAN3_TUNNEL_METRICS_STATE" ] && . "$MWAN3_TUNNEL_METRICS_STATE"
	mwan3_henet_load_prefixes 2>/dev/null

	for metric in 30 40; do
		[ -n "$MWAN3_HENET_FROM_PREFIX" ] &&
			$IP6 route del default from "$MWAN3_HENET_FROM_PREFIX" dev "$device" metric "$metric" 2>/dev/null
		[ -n "$MWAN3_HENET_ROUTED48" ] &&
			$IP6 route del "$MWAN3_HENET_ROUTED48" dev "$device" metric "$metric" 2>/dev/null
	done
}

mwan3_henet_apply_metric()
{
	local device="$1" metric="$2" error

	[ -n "$device" ] || return 1
	[ -n "$metric" ] || return 1
	mwan3_henet_load_prefixes || return 1

	error=$($IP6 route replace default from "$MWAN3_HENET_FROM_PREFIX" dev "$device" metric "$metric" 2>&1) ||
		LOG warn "henet default route metric $metric: $error"
	if [ -n "$MWAN3_HENET_ROUTED48" ]; then
		error=$($IP6 route replace "$MWAN3_HENET_ROUTED48" dev "$device" metric "$metric" 2>&1) ||
			LOG warn "henet routed48 metric $metric: $error"
	fi

	mkdir -p "$MWAN3_STATUS_DIR"
	{
		echo "MWAN3_HENET_FROM_PREFIX='$MWAN3_HENET_FROM_PREFIX'"
		echo "MWAN3_HENET_ROUTED48='$MWAN3_HENET_ROUTED48'"
		echo "MWAN3_HENET_DEVICE='$device'"
		echo "MWAN3_HENET_METRIC='$metric'"
	} >"$MWAN3_TUNNEL_METRICS_STATE"
	return 0
}

mwan3_wg_set_metric_uci()
{
	local iface="$1" metric="$2" true_iface current

	mwan3_get_true_iface true_iface "$iface"
	[ -n "$true_iface" ] || return 1

	current=$(uci -q get "network.${true_iface}.metric")
	if [ "$current" = "$metric" ]; then
		return 0
	fi

	uci set "network.${true_iface}.metric=$metric"
	LOG info "tunnel metric: set network.${true_iface}.metric=$metric"
	MWAN3_CHANGED_IFACES="${MWAN3_CHANGED_IFACES}${MWAN3_CHANGED_IFACES:+ }${true_iface}"
}

mwan3_wg_clear_metric_uci()
{
	local iface="$1" true_iface

	mwan3_get_true_iface true_iface "$iface"
	[ -n "$true_iface" ] || return 1
	uci -q get "network.${true_iface}.metric" >/dev/null 2>&1 || return 0

	uci delete "network.${true_iface}.metric"
	LOG info "tunnel metric: delete network.${true_iface}.metric"
	MWAN3_CHANGED_IFACES="${MWAN3_CHANGED_IFACES}${MWAN3_CHANGED_IFACES:+ }${true_iface}"
}

mwan3_sync_tunnel_metrics()
{
	local first second first_iface second_iface iface henet_device

	mwan3_tunnel_metrics_enabled || return 0
	[ $NO_IPV6 -eq 0 ] || return 0

	config_load mwan3
	mwan3_tunnel_metrics_load_active_policy || {
		LOG debug "tunnel metrics: no active IPv6 policy"
		return 0
	}

	config_get first globals tunnel_metric_first 30
	config_get second globals tunnel_metric_second 40

	mwan3_collect_policy_online_ifaces "$MWAN3_SYNC_POLICY"
	set -- $MWAN3_SYNC_ONLINE_IFACES
	first_iface=$1
	second_iface=$2

	config_load network

	if mwan3_network_iface_exists henet; then
		network_get_device henet_device henet
		mwan3_henet_clear_managed_routes "$henet_device"
	fi

	if [ "$first_iface" = "henet" ]; then
		network_get_device henet_device henet
		mwan3_henet_apply_metric "$henet_device" "$first"
	elif [ "$second_iface" = "henet" ]; then
		network_get_device henet_device henet
		mwan3_henet_apply_metric "$henet_device" "$second"
	fi

	MWAN3_CHANGED_IFACES=
	mwan3_list_network_wireguard_ifaces
	for iface in $MWAN3_WG_IFACE_LIST; do
		case "$iface" in
			"$first_iface")
				mwan3_wg_set_metric_uci "$iface" "$first"
				;;
			"$second_iface")
				mwan3_wg_set_metric_uci "$iface" "$second"
				;;
			*)
				mwan3_wg_clear_metric_uci "$iface"
				;;
		esac
	done

	[ -n "$MWAN3_CHANGED_IFACES" ] && uci commit network

	for iface in $MWAN3_CHANGED_IFACES; do
		ifup "$iface"
	done

	mwan3_sync_all_track_host_routes

	if [ -x /usr/sbin/mwan6-npt ]; then
		/usr/sbin/mwan6-npt update 2>/dev/null ||
			LOG warn "tunnel metrics: mwan6-npt update failed"
	fi

	LOG info "tunnel metrics synced for policy $MWAN3_SYNC_POLICY (online: $MWAN3_SYNC_ONLINE_IFACES)"
}

mwan3_schedule_tunnel_metrics_sync()
{
	(
		sleep 3
		if mkdir "$MWAN3_TUNNEL_METRICS_LOCK" 2>/dev/null; then
			trap 'rmdir "$MWAN3_TUNNEL_METRICS_LOCK" 2>/dev/null' EXIT INT TERM
			. /lib/functions.sh
			. /lib/functions/network.sh
			. /lib/mwan3/mwan3.sh
			mwan3_init
			mwan3_sync_tunnel_metrics
		fi
	) &
}
