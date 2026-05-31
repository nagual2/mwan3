#!/bin/bash
# Tests for mwan3 track host routes (nagual2 patch).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PKG_DIR="$(dirname "$SCRIPT_DIR")"
MOCK_BIN="$SCRIPT_DIR/mocks/bin"
TRACK_SH="$PKG_DIR/files/lib/mwan3/track_host_routes.sh"
COMMON_SH="$PKG_DIR/files/lib/mwan3/common.sh"

passed=0
failed=0

log_pass() { echo "PASS: $1"; passed=$((passed + 1)); }
log_fail() { echo "FAIL: $1"; failed=$((failed + 1)); }

setup() {
	mkdir -p "$MOCK_BIN" "$SCRIPT_DIR/tmp/status/mwan3track/tb62"
	export PATH="$MOCK_BIN:$PATH"
	export IPKG_INSTROOT=""
	export MWAN3_STATUS_DIR="$SCRIPT_DIR/tmp/status/mwan3"
	export MWAN3_STATUS_IPTABLES_LOG_DIR="$MWAN3_STATUS_DIR/iptables_log"
	export MWAN3_INTERFACE_MAX=61
	export NO_IPV6=0
	export MWAN3_IP_LOG="$SCRIPT_DIR/tmp/ip.log"
	mkdir -p "$MWAN3_STATUS_DIR/iface_state" "$MWAN3_STATUS_IPTABLES_LOG_DIR"
	echo "0x3F00" >"$MWAN3_STATUS_DIR/mmx_mask"
	: >"$MWAN3_IP_LOG"

	cat >"$MOCK_BIN/ip" <<'MOCK'
#!/bin/bash
echo "ip $*" >> "${MWAN3_IP_LOG}"
exit 0
MOCK
	chmod +x "$MOCK_BIN/ip"

	export UCI_CONFIG_DIR="$SCRIPT_DIR/tmp/uci"
	mkdir -p "$UCI_CONFIG_DIR"
	cat >"$UCI_CONFIG_DIR/mwan3" <<'EOF'
config globals 'globals'
	option track_host_routes '1'

config interface 'tb62'
	option enabled '1'
	option family 'ipv6'
	list track_ip '2606:4700:4700::1001'
	list track_ip '2606:4700:4700::1111'
EOF

	# shellcheck disable=SC1091
	. "$COMMON_SH"
	export MWAN3TRACK_STATUS_DIR="$SCRIPT_DIR/tmp/status/mwan3track"
	mkdir -p "$MWAN3TRACK_STATUS_DIR"
	mwan3_get_iface_id() { export "$1=2"; }

	config_load() { :; }
	config_get() {
		local _export=$1 _opt=$3 _sec=$2 _default=${4:-}
		case "$_sec" in
			globals)
				case "$_opt" in
					track_host_routes) _export=1 ;;
					*) _export="$_default" ;;
				esac
				;;
			tb62)
				case "$_opt" in
					family) _export=ipv6 ;;
					track_host_routes) _export="" ;;
					*) _export="$_default" ;;
				esac
				;;
		esac
		if [ "$_sec" = globals ] && [ "$_opt" = track_host_routes ] &&
			[ -f "$SCRIPT_DIR/tmp/disabled.flag" ]; then
			_export=0
		fi
		export "$1=$_export"
	}
	config_list_foreach() {
		local _sec=$1 _opt=$2 _fn=$3
		[ "$_sec" = tb62 ] && [ "$_opt" = track_ip ] && {
			$_fn 2606:4700:4700::1001
			$_fn 2606:4700:4700::1111
		}
	}

	# shellcheck disable=SC1091
	. "$TRACK_SH"
	config_load mwan3
}

test_sync_adds_host_routes() {
	setup
	mwan3_sync_track_host_routes tb62 tb62
	if grep -q 'route replace table 2 2606:4700:4700::1001/128 dev tb62' "$MWAN3_IP_LOG" &&
		grep -q 'route replace table 2 2606:4700:4700::1111/128 dev tb62' "$MWAN3_IP_LOG"; then
		log_pass "sync adds /128 routes to interface table"
	else
		log_fail "sync adds /128 routes to interface table"
		cat "$MWAN3_IP_LOG"
	fi
}

test_disabled_globally() {
	setup
	echo "track_host_routes_disabled=1" >"$SCRIPT_DIR/tmp/disabled.flag"
	sed -i "s/track_host_routes '1'/track_host_routes '0'/" "$UCI_CONFIG_DIR/mwan3"
	config_load mwan3
	: >"$MWAN3_IP_LOG"
	mwan3_sync_track_host_routes tb62 tb62
	if [ ! -s "$MWAN3_IP_LOG" ]; then
		log_pass "sync skipped when track_host_routes=0"
	else
		log_fail "sync skipped when track_host_routes=0"
		cat "$MWAN3_IP_LOG"
	fi
}

test_delete_removes_routes() {
	setup
	mwan3_sync_track_host_routes tb62 tb62
	: >"$MWAN3_IP_LOG"
	mwan3_delete_track_host_routes tb62
	if grep -q 'route del table 2 2606:4700:4700::1001/128 dev tb62' "$MWAN3_IP_LOG"; then
		log_pass "delete removes stored track routes"
	else
		log_fail "delete removes stored track routes"
		cat "$MWAN3_IP_LOG"
	fi
}

test_sync_adds_host_routes
test_disabled_globally
test_delete_removes_routes

echo ""
echo "Results: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
