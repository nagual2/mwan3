#!/bin/bash
# Tests for mwan3 policy keepalive rule.
#
# Invariant under test: tracking (probe) results must never take the internet
# away from the last member that actually carried traffic. When every member of
# a policy is tracker-offline, the policy chain keeps a rule that marks traffic
# with the fwmark of the last working member -- so ip rule fwmark -> table
# <id> still routes it out through that member's own routing table. The
# terminal unreachable rule stays reachable for the honest case (device gone).
# Note: no `set -e` on purpose. The mwan3 library code under test is plain
# /bin/sh that is not errexit-safe (e.g. mwan3_set_policy probes the hotplug
# state with a bare `[ ... = "online" ]` to capture its exit status), so
# errexit would abort the run on a legitimate "interface is offline" answer.
# The pass/fail accounting is explicit below and drives the exit code.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PKG_DIR="$(dirname "$SCRIPT_DIR")"
MOCK_BIN="$SCRIPT_DIR/mocks/bin"
TMP="$SCRIPT_DIR/tmp/keepalive"
MWAN3_SH="$PKG_DIR/files/lib/mwan3/mwan3.sh"

passed=0
failed=0

log_pass() { echo "PASS: $1"; passed=$((passed + 1)); }
log_fail() { echo "FAIL: $1"; failed=$((failed + 1)); }

IPT_LOG="$TMP/ipt.log"
SYSFS="$TMP/sysclassnet"

# Interface ids: wwan=1 -> 0x100, wan=2 -> 0x200 (mmx_mask 0x3f00).
# dev mapping mirrors the real benches: wwan->phy1-sta0 (prod) / eth2 (dev),
# wan->wan (prod) / eth1 (dev). 6in4 tunnels report a prefixed device name.
IFACE_ID() {
	case "$1" in
	wwan) echo 1 ;;
	wan) echo 2 ;;
	tb62) echo 3 ;;
	*) echo 0 ;;
	esac
}

IFACE_DEV() {
	case "$1" in
	wwan) echo phy1-sta0 ;;
	wan) echo wan ;;
	tb62) echo tb62 ;;
	*) echo "" ;;
	esac
}

setup() {
	rm -rf "$TMP"
	mkdir -p "$MOCK_BIN" "$SYSFS"
	export PATH="$MOCK_BIN:$PATH"
	# mwan3.sh sources libubox/jshn.sh at the top; the policy code never uses
	# it, so provide an empty stub rather than depending on a real libubox.
	export IPKG_INSTROOT="$TMP/instroot"
	mkdir -p "$IPKG_INSTROOT/usr/share/libubox" "$IPKG_INSTROOT/lib/mwan3"
	: >"$IPKG_INSTROOT/usr/share/libubox/jshn.sh"
	cp "$PKG_DIR/files/lib/mwan3/"*.sh "$IPKG_INSTROOT/lib/mwan3/"

	# Mock sysfs: carrier=1 -> link up; carrier=0 -> link down; no carrier file
	# at all (what down wireguard/6in4 devices actually look like on both
	# benches) -> fall back to operstate.
	# set_link <dev> <carrier|none> <operstate>
	set_link() {
		local dev=$1 mode=$2 state=$3
		mkdir -p "$SYSFS/$dev"
		echo "$state" >"$SYSFS/$dev/operstate"
		if [ "$mode" = "none" ]; then
			rm -f "$SYSFS/$dev/carrier"
		else
			echo "$mode" >"$SYSFS/$dev/carrier"
		fi
	}

	set_online() { echo "online" >"$MWAN3_STATUS_DIR/iface_state/$1"; }
	set_offline() { echo "offline" >"$MWAN3_STATUS_DIR/iface_state/$1"; }
	# Same format mwan3_keepalive_record writes: member name, then the uptime
	# value at which it was recorded.
	set_working() { set_working_at "$1" "$2" "$(get_uptime)"; }
	set_working_at() {
		printf '%s\n%s\n' "$1" "$3" >"$MWAN3_STATUS_KEEPALIVE_DIR/$2"
	}
	# get_uptime() with an argument exports, without one it echoes; the fake
	# has to honour that or the ttl comparison would read an empty value.
	fake_uptime() {
		if [ $# -gt 1 ]; then export -n "$1=$2"; else echo "$2"; fi
	}
	# First line of a record: the member name (line 2 is the uptime stamp).
	recorded_member() { head -n 1 "$MWAN3_STATUS_KEEPALIVE_DIR/$1" 2>/dev/null; }

	cat >"$MOCK_BIN/iptables" <<'MOCK'
#!/bin/bash
echo "iptables $*" >>"${IPT_LOG}"
exit 0
MOCK
	cp "$MOCK_BIN/iptables" "$MOCK_BIN/ip6tables"
	chmod +x "$MOCK_BIN/iptables" "$MOCK_BIN/ip6tables"
	export IPT_LOG

	cat >"$MOCK_BIN/iptables-restore" <<'MOCK'
#!/bin/bash
echo "restore $*" >>"${IPT_LOG}"
while IFS= read -r line; do
	[ -n "$line" ] && echo "$line" >>"${IPT_LOG}"
done
exit 0
MOCK
	cp "$MOCK_BIN/iptables-restore" "$MOCK_BIN/ip6tables-restore"
	chmod +x "$MOCK_BIN/iptables-restore" "$MOCK_BIN/ip6tables-restore"

	# shellcheck disable=SC1090
	. "$MWAN3_SH"

	# common.sh resets the status paths every time it is sourced, so they must
	# be re-pinned after the final source (top of setup).
	export MWAN3_STATUS_DIR="$TMP/status/mwan3"
	export MWAN3_STATUS_IPTABLES_LOG_DIR="$MWAN3_STATUS_DIR/iptables_log"
	export MWAN3_STATUS_KEEPALIVE_DIR="$MWAN3_STATUS_DIR/keepalive"
	export MWAN3_SYSFS_NET="$SYSFS"
	mkdir -p "$MWAN3_STATUS_DIR/iface_state" "$MWAN3_STATUS_IPTABLES_LOG_DIR" \
		"$MWAN3_STATUS_KEEPALIVE_DIR"
	echo "0x3F00" >"$MWAN3_STATUS_DIR/mmx_mask"

	# Force IPv4-only so the table is built once; ip6tables mock stays unused.
	NO_IPV6=1
	MMX_MASK=0x3f00
	MM_BLACKHOLE=61
	MM_UNREACHABLE=62
	MMX_DEFAULT=0x3f00
	MMX_BLACKHOLE=0x3d00
	MMX_UNREACHABLE=0x3e00
	export MWAN3_IP_LOG="$TMP/ip.log"
	: >"$MWAN3_IP_LOG"
}

# Members of the policy under test: wwan (metric 1), wan (metric 2).
configure_policy() {
	config_get() {
		local _export=${4:-} _opt=$3 _sec=$2 _default=${4:-}
		case "$_sec" in
		ipv4_primary)
			case "$_opt" in
			last_resort) _export=unreachable ;;
			use_member) _export="" ;;
			*) _export="$_default" ;;
			esac
			;;
		wwan_m1_w1 | wan_m2_w1)
			case "$_opt" in
			interface)
				case "$_sec" in
				wwan_m1_w1) _export=wwan ;;
				wan_m2_w1) _export=wan ;;
				esac
				;;
			metric)
				case "$_sec" in
				wwan_m1_w1) _export=1 ;;
				wan_m2_w1) _export=2 ;;
				esac
				;;
			weight) _export=1 ;;
			*) _export="$_default" ;;
			esac
			;;
		wwan | wan)
			case "$_opt" in
			family) _export=ipv4 ;;
			*) _export="$_default" ;;
			esac
			;;
		esac
		export "$1=$_export"
	}
	config_list_foreach() {
		local _sec=$1 _opt=$2 _fn=$3
		[ "$_sec" = ipv4_primary ] && [ "$_opt" = use_member ] || return 0
		$_fn wwan_m1_w1
		$_fn wan_m2_w1
	}
	config_foreach() { :; }
	network_get_device() {
		local _export=$1 _iface=$2
		export "$_export=$(IFACE_DEV "$_iface")"
	}
	mwan3_get_iface_id() {
		local _export=$1 _iface=$2
		export "$_export=$(IFACE_ID "$_iface")"
	}
	LOG() { :; }
	uci_get_state() { echo ""; }
	uci_toggle_state() { :; }
	mwan3_flush_conntrack() { :; }
	ipset() { :; }
}

build() {
	: >"$IPT_LOG"
	mwan3_create_policies_iptables ipv4_primary
}

# --- cases -----------------------------------------------------------------

# 1. Upstream baseline: no keepalive recorded, all members offline -> the
#    terminal unreachable rule is still emitted, and no keepalive rule.
test_upstream_unreachable_preserved() {
	setup
	configure_policy
	set_offline wwan
	set_offline wan
	set_link phy1-sta0 1 up
	set_link wan 1 up
	build
	if grep -q 'comment unreachable' "$IPT_LOG" && ! grep -q 'comment "keepalive' "$IPT_LOG"; then
		log_pass "no keepalive state -> terminal unreachable preserved"
	else
		log_fail "no keepalive state -> terminal unreachable preserved"
		cat "$IPT_LOG"
	fi
}

# 2. A member is online and lowest-metric: the chain carries that member's own
#    fwmark rule, and that member is recorded as the last working one.
test_online_member_recorded_as_working() {
	setup
	configure_policy
	set_online wwan
	set_offline wan
	set_link phy1-sta0 1 up
	set_link wan 0 lowerlayerdown
	build
	local recorded=""
	[ -f "$MWAN3_STATUS_KEEPALIVE_DIR/ipv4_primary" ] &&
		recorded="$(recorded_member ipv4_primary)"
	if grep -q 'set-xmark 0x100/0x3f00' "$IPT_LOG" && [ "$recorded" = "wwan" ]; then
		log_pass "online lowest member carries traffic and is recorded"
	else
		log_fail "online lowest member carries traffic and is recorded (recorded='$recorded')"
		cat "$IPT_LOG"
	fi
}

# 3. The invariant: every member is tracker-offline, but the last working one is
#    still physically present -> keepalive rule marks that member's fwmark and
#    the terminal unreachable rule is NOT emitted.
test_all_offline_keeps_last_working_member() {
	setup
	configure_policy
	set_working wwan ipv4_primary
	set_offline wwan
	set_offline wan
	set_link phy1-sta0 1 up
	set_link wan 0 lowerlayerdown
	build
	if grep -q 'comment "keepalive wwan"' "$IPT_LOG" &&
		grep -q 'set-xmark 0x100/0x3f00' "$IPT_LOG" &&
		! grep -q 'comment unreachable' "$IPT_LOG"; then
		log_pass "all offline but device alive -> keepalive marks last working member"
	else
		log_fail "all offline but device alive -> keepalive marks last working member"
		cat "$IPT_LOG"
	fi
}

# 4. Honest failure preserved: last working member's device is really gone ->
#    no keepalive rule, unreachable stands.
test_device_gone_falls_back_to_unreachable() {
	setup
	configure_policy
	set_working wwan ipv4_primary
	set_offline wwan
	set_offline wan
	set_link phy1-sta0 0 lowerlayerdown
	set_link wan 0 lowerlayerdown
	build
	if ! grep -q 'comment "keepalive' "$IPT_LOG" && grep -q 'comment unreachable' "$IPT_LOG"; then
		log_pass "device really gone -> keepalive dropped, unreachable returns"
	else
		log_fail "device really gone -> keepalive dropped, unreachable returns"
		cat "$IPT_LOG"
	fi
}

# 5. Real-world quirk seen on both benches: a wireguard/6in4 device has no
#    carrier file at all, so operstate is the only signal available.
#    operstate=up  -> treated as alive, keepalive survives.
test_missing_carrier_file_operstate_up() {
	setup
	configure_policy
	set_working wwan ipv4_primary
	set_offline wwan
	set_offline wan
	set_link phy1-sta0 none up
	set_link wan none down
	build
	if grep -q 'comment "keepalive wwan"' "$IPT_LOG" &&
		grep -q 'set-xmark 0x100/0x3f00' "$IPT_LOG"; then
		log_pass "missing carrier file + operstate up -> treated as alive"
	else
		log_fail "missing carrier file + operstate up -> treated as alive"
		cat "$IPT_LOG"
	fi
}

# 6. Same quirk, opposite reading: operstate=down must be read as dead and the
#    keepalive must be dropped (case 3 covers carrier=0, this covers "no file").
test_missing_carrier_file_operstate_down() {
	setup
	configure_policy
	set_working wwan ipv4_primary
	set_offline wwan
	set_offline wan
	set_link phy1-sta0 none down
	set_link wan none down
	build
	if ! grep -q 'comment "keepalive' "$IPT_LOG" && grep -q 'comment unreachable' "$IPT_LOG"; then
		log_pass "missing carrier file + operstate down -> treated as dead"
	else
		log_fail "missing carrier file + operstate down -> treated as dead"
		cat "$IPT_LOG"
	fi
}

# 7. The full two-channel sequence: wwan carries traffic, its probes die so wan
#    takes over, then wan's probes die too. The policy must stay on wan, because
#    wan is the last member that was actually working.
test_two_channel_failover_then_keepalive() {
	setup
	configure_policy
	set_link phy1-sta0 1 up
	set_link wan 1 up

	# step 1: only wwan is healthy
	set_online wwan
	set_offline wan
	build
	local recorded=""
	[ -f "$MWAN3_STATUS_KEEPALIVE_DIR/ipv4_primary" ] &&
		recorded="$(recorded_member ipv4_primary)"
	if [ "$recorded" != "wwan" ]; then
		log_fail "two-channel sequence: step1 records wwan (recorded='$recorded')"
		cat "$IPT_LOG"
		return
	fi

	# step 2: wwan probes fail, wan is healthy -> wan becomes the working member
	set_offline wwan
	set_online wan
	build
	recorded="$(recorded_member ipv4_primary)"
	if [ "$recorded" != "wan" ] || ! grep -q 'set-xmark 0x200/0x3f00' "$IPT_LOG"; then
		log_fail "two-channel sequence: step2 records wan (recorded='$recorded')"
		cat "$IPT_LOG"
		return
	fi

	# step 3: wan's probes fail too, but the link is alive -> stay on wan
	set_offline wan
	build
	if grep -q 'comment "keepalive wan"' "$IPT_LOG" &&
		grep -q 'set-xmark 0x200/0x3f00' "$IPT_LOG" &&
		! grep -q 'comment unreachable' "$IPT_LOG"; then
		log_pass "two-channel sequence: last working channel is never dropped"
	else
		log_fail "two-channel sequence: last working channel is never dropped"
		cat "$IPT_LOG"
	fi
}

# 7. TTL safety valve. A 6in4 device keeps carrier=1 for as long as the outer
#    link is up, so "link alive" cannot tell a dead tunnel from a lying probe.
#    After keepalive_ttl the record must expire and last_resort take over.
test_keepalive_expires_after_ttl() {
	setup
	configure_policy
	set_working_at wwan ipv4_primary 1000
	set_offline wwan
	set_offline wan
	set_link phy1-sta0 1 up
	set_link wan 0 lowerlayerdown
	get_uptime() { if [ $# -gt 0 ]; then eval "$1=1250"; else echo 1250; fi; }
	build
	if ! grep -q 'comment "keepalive' "$IPT_LOG" && grep -q 'comment unreachable' "$IPT_LOG" &&
		[ ! -f "$MWAN3_STATUS_KEEPALIVE_DIR/ipv4_primary" ]; then
		log_pass "keepalive record expires past ttl -> last_resort returns"
	else
		log_fail "keepalive record expires past ttl -> last_resort returns"
		cat "$IPT_LOG"
	fi
}

# 8. Same record, still inside the ttl window -> keepalive holds.
test_keepalive_survives_inside_ttl() {
	setup
	configure_policy
	set_working_at wwan ipv4_primary 1000
	set_offline wwan
	set_offline wan
	set_link phy1-sta0 1 up
	set_link wan 0 lowerlayerdown
	get_uptime() { if [ $# -gt 0 ]; then eval "$1=1100"; else echo 1100; fi; }
	build
	if grep -q 'comment "keepalive wwan"' "$IPT_LOG" &&
		! grep -q 'comment unreachable' "$IPT_LOG"; then
		log_pass "keepalive record inside ttl -> keepalive holds"
	else
		log_fail "keepalive record inside ttl -> keepalive holds"
		cat "$IPT_LOG"
	fi
}

test_online_member_recorded_as_working
test_all_offline_keeps_last_working_member
test_device_gone_falls_back_to_unreachable
test_missing_carrier_file_operstate_up
test_missing_carrier_file_operstate_down
test_upstream_unreachable_preserved
test_two_channel_failover_then_keepalive
test_keepalive_expires_after_ttl
test_keepalive_survives_inside_ttl

echo ""
echo "Results: $passed passed, $failed failed"
[ "$failed" -eq 0 ]