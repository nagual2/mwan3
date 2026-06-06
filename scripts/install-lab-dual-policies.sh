#!/bin/sh
# Install lab dual-member IPv6 policies on openwrt-dev (reservation + load balance).
# Idempotent: safe to re-run.
set -eu

echo "=== mwan3 dual policies (lab) ==="

# --- Reservation: tb62 primary (m=2), tb63 backup (m=3) ---
if ! uci -q get mwan3.ipv6_tb62_tb63 >/dev/null 2>&1; then
	uci set mwan3.ipv6_tb62_tb63=policy
fi
uci -q delete mwan3.ipv6_tb62_tb63.use_member 2>/dev/null || true
uci add_list mwan3.ipv6_tb62_tb63.use_member='tb62_m2_w1'
uci add_list mwan3.ipv6_tb62_tb63.use_member='tb63_m3_w1'
uci set mwan3.ipv6_tb62_tb63.last_resort='unreachable'

# --- Balance: tb62 75% / tb63 25% (same metric, different weight) ---
if ! uci -q get mwan3.tb62_bal_w3 >/dev/null 2>&1; then
	uci set mwan3.tb62_bal_w3=member
fi
uci set mwan3.tb62_bal_w3.interface='tb62'
uci set mwan3.tb62_bal_w3.metric='2'
uci set mwan3.tb62_bal_w3.weight='3'

if ! uci -q get mwan3.tb63_bal_w1 >/dev/null 2>&1; then
	uci set mwan3.tb63_bal_w1=member
fi
uci set mwan3.tb63_bal_w1.interface='tb63'
uci set mwan3.tb63_bal_w1.metric='2'
uci set mwan3.tb63_bal_w1.weight='1'

if ! uci -q get mwan3.ipv6_balance_tb62_tb63 >/dev/null 2>&1; then
	uci set mwan3.ipv6_balance_tb62_tb63=policy
fi
uci -q delete mwan3.ipv6_balance_tb62_tb63.use_member 2>/dev/null || true
uci add_list mwan3.ipv6_balance_tb62_tb63.use_member='tb62_bal_w3'
uci add_list mwan3.ipv6_balance_tb62_tb63.use_member='tb63_bal_w1'

uci commit mwan3
/etc/init.d/mwan3 restart

echo "Policies:"
uci show mwan3.ipv6_tb62_tb63
uci show mwan3.ipv6_balance_tb62_tb63
echo "Done."
