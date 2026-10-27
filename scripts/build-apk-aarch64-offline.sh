#!/usr/bin/env bash
# Build mwan3 .apk for aarch64_cortex-a53 using a pre-extracted filogic SDK (no network).
set -euo pipefail

ROOT="${ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
SDK="${SDK_DIR:-$ROOT/build/sdk-filogic}"
PKG_RELEASE="${PKG_RELEASE:-6}"
PKG_ID="2.12.1-r${PKG_RELEASE}"
TARGET_ARCH="${TARGET_ARCH:-aarch64_cortex-a53}"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT/dist}"

APK_TOOL="$SDK/staging_dir/host/bin/apk"
[ -x "$APK_TOOL" ] || {
	echo "Missing extracted SDK (apk tool): $APK_TOOL" >&2
	echo "Extract: tar --zstd -xf build/openwrt-sdk-25.12.4-mediatek-filogic_*.tar.zst -C build/sdk-filogic --strip-components=1" >&2
	exit 1
}

BUILD_DIR=$(mktemp -d)
STAGE=$(mktemp -d)
POSTINST=$(mktemp)
trap 'rm -rf "$BUILD_DIR" "$STAGE" "$POSTINST"' EXIT

CC=$(find "$SDK/staging_dir" -path '*/bin/*-openwrt-linux-musl-gcc' -type f 2>/dev/null | head -1)
if [ -z "$CC" ]; then
	# sockopt_wrap.c is unchanged since the initial import: when no target
	# toolchain is available, reuse libwrap from the previous aarch64 apk.
	PREV_APK=$(ls -1 "$OUTPUT_DIR"/mwan3-2.12.1-r*_aarch64_cortex-a53.apk 2>/dev/null | sort | tail -1)
	[ -n "$PREV_APK" ] || {
		echo "No aarch64 gcc under $SDK/staging_dir and no previous aarch64 apk to reuse libwrap from" >&2
		exit 1
	}
	echo "[build-apk-aarch64-offline] No target gcc; extracting libwrap from $(basename "$PREV_APK")"
	# apk v3 containers are not plain tar: unpack through the host apk tool.
	"$APK_TOOL" --quiet add --root "$BUILD_DIR/apkroot" --initdb --allow-untrusted --no-scripts "$PREV_APK" >/dev/null 2>&1
	[ -f "$BUILD_DIR/apkroot/lib/mwan3/libwrap_mwan3_sockopt.so.1.0" ] || {
		echo "Failed to extract libwrap from $PREV_APK" >&2
		exit 1
	}
	mv "$BUILD_DIR/apkroot/lib/mwan3/libwrap_mwan3_sockopt.so.1.0" "$BUILD_DIR/libwrap_mwan3_sockopt.so.1.0"
else
	echo "[build-apk-aarch64-offline] Compiling libwrap with $CC ..."
	"$CC" -shared -fPIC -DCONFIG_IPV6 \
		-o "$BUILD_DIR/libwrap_mwan3_sockopt.so.1.0" \
		"$ROOT/src/sockopt_wrap.c" \
		-ldl
fi

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

find "$STAGE" -type f \( -name '*.sh' -o -path '*/etc/init.d/*' -o -path '*/hotplug.d/*' -o -path '*/uci-defaults/*' -o -path '*/usr/sbin/*' \) \
	-exec perl -pi -e 's/\r$//' {} +

mkdir -p "$OUTPUT_DIR"
OUT_APK="$OUTPUT_DIR/mwan3-${PKG_ID}_${TARGET_ARCH}.apk"

echo "[build-apk-aarch64-offline] Creating $OUT_APK"
"$APK_TOOL" mkpkg \
	--compat 3.0.0_pre1 \
	--files "$STAGE" \
	--info "name:mwan3" \
	--info "version:${PKG_ID}" \
	--info "arch:${TARGET_ARCH}" \
	--info "license:GPL-2.0" \
	--info "maintainer:nagual2" \
	--info "depends:ip ipset iptables ip6tables iptables-mod-conntrack-extra iptables-mod-ipopt rpcd-mod-ucode jshn" \
	--info "description:Multiwan hotplug (nagual2 fork): IPv6-only track_host_routes, connected_ipv6." \
	--script "post-install:$POSTINST" \
	--output "$OUT_APK"

ls -la "$OUT_APK"
