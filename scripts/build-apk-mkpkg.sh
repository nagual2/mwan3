#!/usr/bin/env bash
# Build mwan3 .apk for OpenWrt 25.12+ (x86_64) using apk mkpkg.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT/dist}"
SDK_DIR="${SDK_DIR:-$ROOT/build/sdk}"
APK_TOOL="${APK_TOOL:-$SDK_DIR/staging_dir/host/bin/apk}"

PKG_VERSION="${PKG_VERSION:-2.12.1}"
PKG_RELEASE="${PKG_RELEASE:-5}"
PKG_ID="${PKG_VERSION}-r${PKG_RELEASE}"
TARGET_ARCH="${TARGET_ARCH:-x86_64}"

log() { printf '[build-apk-mkpkg] %s\n' "$*"; }

ensure_apk_tool() {
	if [ -x "$APK_TOOL" ]; then
		return 0
	fi
	local archive url
	url="${SDK_URL:-https://downloads.openwrt.org/releases/25.12.0/targets/x86/64/openwrt-sdk-25.12.0-x86-64_gcc-14.3.0_musl.Linux-x86_64.tar.zst}"
	archive="$ROOT/build/$(basename "$url")"
	log "Extracting apk host tool from OpenWrt SDK..."
	mkdir -p "$ROOT/build"
	[ -f "$archive" ] || wget -O "$archive" "$url"
	rm -rf "$SDK_DIR"
	mkdir -p "$SDK_DIR"
	tar --zstd -xf "$archive" -C "$SDK_DIR" --strip-components=1
	APK_TOOL="$SDK_DIR/staging_dir/host/bin/apk"
	[ -x "$APK_TOOL" ] || {
		echo "apk tool not found: $APK_TOOL" >&2
		exit 1
	}
}

ensure_apk_tool

STAGE="$(mktemp -d)"
BUILD_DIR="$(mktemp -d)"
POSTINST="$(mktemp)"
trap 'rm -rf "$STAGE" "$BUILD_DIR" "$POSTINST"' EXIT

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

cat >"$POSTINST" <<'EOF'
#!/bin/sh
[ -n "${IPKG_INSTROOT}" ] && exit 0
[ -x /etc/uci-defaults/99-mwan3-track-host-routes ] && /etc/uci-defaults/99-mwan3-track-host-routes
[ -x /etc/uci-defaults/100-mwan3-connected-ipv6 ] && /etc/uci-defaults/100-mwan3-connected-ipv6
/etc/init.d/rpcd restart 2>/dev/null
exit 0
EOF
chmod 0755 "$POSTINST"

mkdir -p "$OUTPUT_DIR"
OUT_APK="$OUTPUT_DIR/mwan3-${PKG_ID}_${TARGET_ARCH}.apk"

log "Creating $OUT_APK"
"$APK_TOOL" mkpkg \
	--compat 3.0.0_pre1 \
	--files "$STAGE" \
	--info "name:mwan3" \
	--info "version:${PKG_ID}" \
	--info "arch:${TARGET_ARCH}" \
	--info "license:GPL-2.0" \
	--info "maintainer:nagual2" \
	--info "depends:ip ipset iptables ip6tables iptables-mod-conntrack-extra iptables-mod-ipopt rpcd-mod-ucode jshn" \
	--info "description:Multiwan hotplug (nagual2 fork): IPv6 track_host_routes, connected_ipv6." \
	--script "post-install:$POSTINST" \
	--output "$OUT_APK"

log "Built: $OUT_APK ($(wc -c <"$OUT_APK") bytes)"
