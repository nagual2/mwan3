#!/bin/bash
# Tests for mwan3 connected_ipv6 route filter (nagual2 patch).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PKG_DIR="$(dirname "$SCRIPT_DIR")"
CONNECTED_SH="$PKG_DIR/files/lib/mwan3/connected_routes.sh"
COMMON_SH="$PKG_DIR/files/lib/mwan3/common.sh"

passed=0
failed=0

log_pass() { echo "PASS: $1"; passed=$((passed + 1)); }
log_fail() { echo "FAIL: $1"; failed=$((failed + 1)); }

setup() {
	export IPKG_INSTROOT=""
	export MWAN3_CONNTRACK_FILE="/dev/null"
	# shellcheck disable=SC1091
	. "$COMMON_SH"
	# shellcheck disable=SC1091
	. "$CONNECTED_SH"

	config_get() {
		local _export=$1 _opt=$3 _sec=$2 _default=${4:-}
		case "$_sec" in
			globals)
				case "$_opt" in
					connected_ipv6_min_prefixlen) _export="${MIN_PREFIXLEN:-32}" ;;
					*) _export="$_default" ;;
				esac
				;;
		esac
		export "$1=$_export"
	}
}

assert_skip() {
	local prefix=$1
	setup
	MIN_PREFIXLEN="${3:-32}"
	if mwan3_connected_ipv6_skip "$prefix"; then
		log_pass "skip $prefix ($2)"
	else
		log_fail "skip $prefix ($2)"
	fi
}

assert_add() {
	local prefix=$1
	setup
	MIN_PREFIXLEN="${3:-32}"
	if mwan3_connected_ipv6_skip "$prefix"; then
		log_fail "add $prefix ($2)"
	else
		log_pass "add $prefix ($2)"
	fi
}

assert_skip "::/1" "WG split lower"
assert_skip "8000::/1" "WG split upper"
assert_skip "2000::/3" "global aggregate"
assert_skip "::/0" "default"
assert_skip "default" "default keyword"

assert_add "2606:4700:4700::1111/128" "track host /128"
assert_add "fd00:1::/64" "ULA /64"
assert_add "fe80::1" "link-local host"

setup
MIN_PREFIXLEN=32
assert_skip "2000::/16" "prefix shorter than /32"

echo ""
echo "Results: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
