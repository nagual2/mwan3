#!/usr/bin/env bash
# Compile libwrap_mwan3_sockopt.so with the OpenWrt SDK musl toolchain.
#
# Usage:
#   compile_libwrap <repo_root> <output.so>
#
# Requires SDK extracted (see ensure_openwrt_sdk below).

ensure_openwrt_sdk() {
	local root=$1
	local sdk_dir=${SDK_DIR:-$root/build/sdk}
	local url=${SDK_URL:-https://downloads.openwrt.org/releases/25.12.0/targets/x86/64/openwrt-sdk-25.12.0-x86-64_gcc-14.3.0_musl.Linux-x86_64.tar.zst}

	# shellcheck source=scripts/lib/sdk-cache.sh
	. "$root/scripts/lib/sdk-cache.sh"
	sdk_cache_ensure_archive "$url"
	sdk_cache_ensure_extracted "$SDK_CACHE_ARCHIVE" "$sdk_dir"
	OPENWRT_SDK_DIR="$sdk_dir"
}

find_sdk_gcc() {
	local sdk_dir=$1
	local cc
	cc=$(find "$sdk_dir/staging_dir" -path '*/bin/*-openwrt-linux-musl-gcc' -type f 2>/dev/null | head -1)
	[ -n "$cc" ] && [ -x "$cc" ] || {
		echo "compile-libwrap: OpenWrt musl gcc not found under $sdk_dir/staging_dir" >&2
		return 1
	}
	printf '%s\n' "$cc"
}

compile_libwrap() {
	local root=$1
	local output=$2

	ensure_openwrt_sdk "$root"
	local cc
	cc=$(find_sdk_gcc "$OPENWRT_SDK_DIR")

	"$cc" -shared -fPIC -DCONFIG_IPV6 \
		-o "$output" \
		"$root/src/sockopt_wrap.c" \
		-ldl
}
