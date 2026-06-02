#!/usr/bin/env bash
# Build mwan3 .ipk without full OpenWrt tree rebuild.
# Compiles libwrap_mwan3_sockopt.so for x86_64 (openwrt-dev) and packs opkg archive.
#
# Usage:
#   ./scripts/build-ipk-mkpkg.sh
#   TARGET_ARCH=x86_64 ./scripts/build-ipk-mkpkg.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT/dist}"
STAGE="$(mktemp -d)"
BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGE" "$BUILD_DIR"' EXIT

PKG_VERSION="${PKG_VERSION:-2.12.1}"
PKG_RELEASE="${PKG_RELEASE:-5}"
PKG_ID="${PKG_VERSION}-${PKG_RELEASE}"
TARGET_ARCH="${TARGET_ARCH:-x86_64}"

log() { printf '[build-ipk-mkpkg] %s\n' "$*"; }

need_cmd() {
	command -v "$1" >/dev/null 2>&1 || {
		echo "Missing command: $1" >&2
		exit 1
	}
}

need_cmd tar
need_cmd gzip
need_cmd ar

# shellcheck source=scripts/lib/compile-libwrap.sh
. "$ROOT/scripts/lib/compile-libwrap.sh"

log "Compiling libwrap_mwan3_sockopt.so for ${TARGET_ARCH} (OpenWrt SDK musl)..."
compile_libwrap "$ROOT" "$BUILD_DIR/libwrap_mwan3_sockopt.so.1.0"

install -d \
	"$STAGE/etc/config" \
	"$STAGE/etc/hotplug.d/iface" \
	"$STAGE/etc/init.d" \
	"$STAGE/etc/uci-defaults" \
	"$STAGE/lib/mwan3" \
	"$STAGE/usr/sbin" \
	"$STAGE/usr/share/rpcd/ucode"

install -m 0644 "$ROOT/files/etc/config/mwan3" "$STAGE/etc/config/"
install -m 0755 "$ROOT/files/etc/init.d/mwan3" "$STAGE/etc/init.d/"
install -m 0755 "$ROOT/files/etc/hotplug.d/iface/15-mwan3" "$STAGE/etc/hotplug.d/iface/"
install -m 0755 "$ROOT/files/etc/hotplug.d/iface/16-mwan3-user" "$STAGE/etc/hotplug.d/iface/"
install -m 0755 "$ROOT/files/etc/hotplug.d/iface/25-mwan3-track-routes" "$STAGE/etc/hotplug.d/iface/"
install -m 0755 "$ROOT/files/etc/hotplug.d/iface/99-mwan3-track-routes" "$STAGE/etc/hotplug.d/iface/"
install -m 0755 "$ROOT/files/etc/uci-defaults/99-mwan3-track-host-routes" "$STAGE/etc/uci-defaults/"
install -m 0755 "$ROOT/files/etc/uci-defaults/100-mwan3-connected-ipv6" "$STAGE/etc/uci-defaults/"
install -m 0755 "$ROOT/files/etc/uci-defaults/mwan3-migrate-flush_conntrack" "$STAGE/etc/uci-defaults/"
install -m 0755 "$ROOT/files/etc/mwan3.user" "$STAGE/etc/"
install -m 0644 "$ROOT/files/lib/mwan3/common.sh" "$STAGE/lib/mwan3/"
install -m 0644 "$ROOT/files/lib/mwan3/mwan3.sh" "$STAGE/lib/mwan3/"
install -m 0644 "$ROOT/files/lib/mwan3/track_host_routes.sh" "$STAGE/lib/mwan3/"
install -m 0644 "$ROOT/files/lib/mwan3/connected_routes.sh" "$STAGE/lib/mwan3/"
install -m 0755 "$ROOT/files/usr/sbin/mwan3" "$STAGE/usr/sbin/"
install -m 0755 "$ROOT/files/usr/sbin/mwan3track" "$STAGE/usr/sbin/"
install -m 0755 "$ROOT/files/usr/sbin/mwan3rtmon" "$STAGE/usr/sbin/"
install -m 0755 "$ROOT/files/usr/share/rpcd/ucode/mwan3" "$STAGE/usr/share/rpcd/ucode/"
install -m 0755 "$BUILD_DIR/libwrap_mwan3_sockopt.so.1.0" "$STAGE/lib/mwan3/"

chmod +x "$ROOT/scripts/stage-docs.sh"
"$ROOT/scripts/stage-docs.sh" "$STAGE" mwan3

CONTROL="$BUILD_DIR/control"
cat >"$CONTROL" <<EOF
Package: mwan3
Version: ${PKG_ID}
Depends: ip, ipset, iptables, ip6tables, iptables-mod-conntrack-extra, iptables-mod-ipopt, rpcd-mod-ucode, jshn
Source: nagual2/mwan3
SourceName: mwan3
License: GPL-2.0
Section: net
SourceDateEpoch: 1746057600
Architecture: ${TARGET_ARCH}
Installed-Size: $(du -sk "$STAGE" | awk '{print $1}')
Description: Multiwan hotplug script (nagual2 fork 2.12.1-4)
 IPv6 track_host_routes, connected_ipv6 filter, flush-conntrack.
EOF

CONFFILES="$BUILD_DIR/conffiles"
cat >"$CONFFILES" <<EOF
/etc/config/mwan3
/etc/mwan3.user
EOF

POSTINST="$BUILD_DIR/postinst"
cat >"$POSTINST" <<'EOF'
#!/bin/sh
[ -n "${IPKG_INSTROOT}" ] && exit 0
[ -x /etc/uci-defaults/99-mwan3-track-host-routes ] && /etc/uci-defaults/99-mwan3-track-host-routes
[ -x /etc/uci-defaults/100-mwan3-connected-ipv6 ] && /etc/uci-defaults/100-mwan3-connected-ipv6
/etc/init.d/rpcd restart
exit 0
EOF
chmod 0755 "$POSTINST"

POSTRM="$BUILD_DIR/postrm"
cat >"$POSTRM" <<'EOF'
#!/bin/sh
[ -n "${IPKG_INSTROOT}" ] && exit 0
/etc/init.d/rpcd restart
exit 0
EOF
chmod 0755 "$POSTRM"

mkdir -p "$OUTPUT_DIR"
OUT_BASE="$OUTPUT_DIR/mwan3_${PKG_ID}_${TARGET_ARCH}"
OUT_IPK="${OUT_BASE}.ipk"

pack_manual() {
	log "Creating .ipk manually (debian-binary + tar + ar)"
	local ipk_dir="$BUILD_DIR/ipk"
	mkdir -p "$ipk_dir/data" "$ipk_dir/control"
	cp -a "$STAGE/." "$ipk_dir/data/"
	install -m 0644 "$CONTROL" "$ipk_dir/control/control"
	install -m 0644 "$CONFFILES" "$ipk_dir/control/conffiles"
	install -m 0755 "$POSTINST" "$ipk_dir/control/postinst"
	install -m 0755 "$POSTRM" "$ipk_dir/control/postrm"
	(
		cd "$ipk_dir/data" && tar --numeric-owner --owner=0 --group=0 -czf ../data.tar.gz .
		cd "$ipk_dir/control" && tar --numeric-owner --owner=0 --group=0 -czf ../control.tar.gz .
		cd "$ipk_dir" && printf '2.0\n' >debian-binary
		rm -f "$OUT_IPK"
		ar cr "$OUT_IPK" debian-binary control.tar.gz data.tar.gz
	)
}

IPKG_BUILD="${IPKG_BUILD:-}"
if [ -z "$IPKG_BUILD" ]; then
	for candidate in \
		"${HOME}/.cache/openwrt-sdk-mwan3-ipk/scripts/ipkg-build" \
		"$ROOT/build/sdk-ipk/scripts/ipkg-build"; do
		if [ -x "$candidate" ] && [[ "$candidate" != /mnt/* ]]; then
			IPKG_BUILD="$candidate"
			break
		fi
	done
fi

if [ -n "$IPKG_BUILD" ]; then
	log "Packing with ipkg-build..."
	if "$IPKG_BUILD" "$STAGE" "$OUTPUT_DIR"; then
		latest="$(ls -t "$OUTPUT_DIR"/mwan3_*.ipk 2>/dev/null | head -1 || true)"
		[ -n "$latest" ] && mv -f "$latest" "$OUT_IPK"
	fi
fi

if [ ! -f "$OUT_IPK" ]; then
	pack_manual
fi

if [ ! -f "$OUT_IPK" ]; then
	echo "IPK build failed" >&2
	exit 1
fi

log "Built: $OUT_IPK ($(wc -c <"$OUT_IPK") bytes)"
ls -la "$OUT_IPK"
