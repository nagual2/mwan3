#!/bin/sh
# IPv6 connected-route filtering and conntrack helpers (nagual2 fork).
# Requires: common.sh (LOG), config_get from functions.sh when UCI is loaded.

MWAN3_CONNTRACK_FILE="${MWAN3_CONNTRACK_FILE:-/proc/net/nf_conntrack}"

# Return 0 if prefix must NOT be added to mwan3_connected_ipv6.
mwan3_connected_ipv6_skip()
{
	local prefix=$1 min_len plen

	[ -n "$prefix" ] || return 0
	case "$prefix" in
		default|::/0) return 0 ;;
	esac

	config_get min_len globals connected_ipv6_min_prefixlen 32

	# WG split-default and common aggregates that bypass mwan3 policy.
	case "$prefix" in
		::/1|8000::/1|2000::/3) return 0 ;;
	esac

	if [ -z "${prefix##*/*}" ]; then
		plen="${prefix#*/}"
		case "$plen" in
			''|*[!0-9]*) return 1 ;;
		esac
		[ "$plen" -lt "$min_len" ] && return 0
	fi

	return 1
}

mwan3_flush_all_conntrack()
{
	[ -e "$MWAN3_CONNTRACK_FILE" ] || return 0
	echo f >"$MWAN3_CONNTRACK_FILE"
	LOG info "Connection tracking flushed (all)"
}
