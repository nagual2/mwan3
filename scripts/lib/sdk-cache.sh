#!/usr/bin/env bash
# Shared OpenWrt SDK archive cache: download only when remote file changed.
#
# Cache layout:
#   ${SDK_CACHE_DIR}/archives/<basename>       — tarball
#   ${SDK_CACHE_DIR}/archives/<basename>.meta  — etag, last-modified, sha256, size

sdk_cache_log() {
	printf '[sdk-cache] %s\n' "$*"
}

sdk_cache_dir() {
	printf '%s\n' "${SDK_CACHE_DIR:-${HOME}/.cache/openwrt-sdk}"
}

sdk_cache_archive_path() {
	local url=$1
	local cache
	cache="$(sdk_cache_dir)/archives"
	printf '%s/%s\n' "$cache" "$(basename "$url")"
}

sdk_cache_meta_path() {
	printf '%s.meta\n' "$1"
}

sdk_cache_read_meta() {
	local key=$1 file=$2
	[ -f "$file" ] || return 1
	grep -m1 "^${key}=" "$file" 2>/dev/null | cut -d= -f2- || return 1
}

sdk_cache_write_meta() {
	local file=$1 etag=$2 last_modified=$3 size=$4 sha256=${5:-}
	cat >"$file" <<EOF
etag=${etag}
last-modified=${last_modified}
size=${size}
sha256=${sha256}
url=${SDK_CACHE_URL:-}
fetched=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
}

sdk_cache_remote_headers() {
	local url=$1
	# stdout: etag<TAB>last-modified<TAB>content-length
	curl -fsSIL --max-time 30 "$url" 2>/dev/null | awk '
BEGIN { etag=""; lm=""; cl="" }
tolower($1)=="etag:" { etag=$2; gsub(/\r$/, "", etag) }
tolower($1)=="last-modified:" { lm=$2" "$3" "$4" "$5" "$6; gsub(/\r$/, "", lm) }
tolower($1)=="content-length:" { cl=$2; gsub(/\r$/, "", cl) }
END { print etag "\t" lm "\t" cl }
'
}

sdk_cache_local_sha256() {
	local file=$1
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$file" | awk '{print $1}'
	elif command -v shasum >/dev/null 2>&1; then
		shasum -a 256 "$file" | awk '{print $1}'
	else
		printf '\n'
	fi
}

sdk_cache_archive_valid() {
	local archive=$1
	[ -f "$archive" ] || return 1
	[ -s "$archive" ] || return 1
	# Minimal sanity: tar/zst magic or non-trivial size (>10MB)
	local size
	size=$(wc -c <"$archive" | tr -d ' ')
	[ "${size:-0}" -gt 10485760 ] || return 1
	return 0
}

# Ensure SDK tarball exists and is up to date. Sets SDK_CACHE_ARCHIVE.
# Optional: SDK_SHA256=... to verify after download.
sdk_cache_ensure_archive() {
	local url=$1
	local archive meta etag lm size remote_etag remote_lm remote_size
	local local_etag local_lm local_size local_sha need_download=0

	SDK_CACHE_URL="$url"
	archive="$(sdk_cache_archive_path "$url")"
	meta="$(sdk_cache_meta_path "$archive")"
	mkdir -p "$(dirname "$archive")"

	if sdk_cache_archive_valid "$archive"; then
		local_etag="$(sdk_cache_read_meta etag "$meta" || true)"
		local_lm="$(sdk_cache_read_meta last-modified "$meta" || true)"
		local_size="$(sdk_cache_read_meta size "$meta" || true)"
		local_sha="$(sdk_cache_read_meta sha256 "$meta" || true)"

		if [ -n "${SDK_SHA256:-}" ] && [ -n "$local_sha" ] && [ "$local_sha" = "$SDK_SHA256" ]; then
			sdk_cache_log "Using cached archive (sha256 match): $archive"
			SDK_CACHE_ARCHIVE="$archive"
			return 0
		fi

		if command -v curl >/dev/null 2>&1; then
			IFS=$'\t' read -r remote_etag remote_lm remote_size < <(sdk_cache_remote_headers "$url")
			if [ -n "$remote_etag" ] && [ "$remote_etag" = "$local_etag" ]; then
				sdk_cache_log "Using cached archive (ETag unchanged): $archive"
				SDK_CACHE_ARCHIVE="$archive"
				return 0
			fi
			if [ -z "$remote_etag" ] && [ -n "$remote_lm" ] && [ "$remote_lm" = "$local_lm" ] &&
				[ -n "$remote_size" ] && [ "$remote_size" = "$local_size" ]; then
				sdk_cache_log "Using cached archive (Last-Modified + size unchanged): $archive"
				SDK_CACHE_ARCHIVE="$archive"
				return 0
			fi
			if [ -n "$remote_size" ] && [ "$remote_size" = "$local_size" ] && [ -n "$local_sha" ]; then
				sdk_cache_log "Using cached archive (size unchanged, have sha256): $archive"
				SDK_CACHE_ARCHIVE="$archive"
				return 0
			fi
			need_download=1
		else
			# Fallback: wget timestamping only re-downloads if remote is newer
			if wget -N --spider "$url" 2>&1 | grep -q 'File .* already there; not retrieving'; then
				sdk_cache_log "Using cached archive (wget timestamping): $archive"
				SDK_CACHE_ARCHIVE="$archive"
				return 0
			fi
			need_download=1
		fi
	else
		need_download=1
	fi

	if [ "$need_download" -eq 1 ] && sdk_cache_archive_valid "$archive"; then
		sdk_cache_log "Remote SDK changed — updating: $archive"
	elif [ "$need_download" -eq 1 ]; then
		sdk_cache_log "Downloading OpenWrt SDK: $url"
	fi

	if command -v wget >/dev/null 2>&1; then
		# -N: conditional GET (If-Modified-Since); -c: resume partial download
		wget -N -c -O "$archive" "$url"
	elif command -v curl >/dev/null 2>&1; then
		curl -fL --retry 3 -o "$archive.part" "$url"
		mv -f "$archive.part" "$archive"
	else
		echo "sdk_cache_ensure_archive: need wget or curl" >&2
		return 1
	fi

	sdk_cache_archive_valid "$archive" || {
		echo "sdk_cache_ensure_archive: invalid archive after download: $archive" >&2
		return 1
	}

	local_sha="$(sdk_cache_local_sha256 "$archive")"
	if [ -n "${SDK_SHA256:-}" ] && [ "$local_sha" != "$SDK_SHA256" ]; then
		echo "sdk_cache_ensure_archive: sha256 mismatch (expected ${SDK_SHA256}, got ${local_sha})" >&2
		return 1
	fi

	IFS=$'\t' read -r remote_etag remote_lm remote_size < <(sdk_cache_remote_headers "$url" || printf '\t\t%s\n' "$(wc -c <"$archive" | tr -d ' ')")
	sdk_cache_write_meta "$meta" "${remote_etag:-}" "${remote_lm:-}" "${remote_size:-$(wc -c <"$archive" | tr -d ' ')}" "$local_sha"
	sdk_cache_log "Cached: $archive (${local_sha:0:12}…)"
	SDK_CACHE_ARCHIVE="$archive"
}

# Extract archive into sdk_dir if missing or archive is newer than stamp.
sdk_cache_ensure_extracted() {
	local archive=$1 sdk_dir=$2
	local stamp archive_mtime

	archive_mtime=$(stat -c %Y "$archive" 2>/dev/null || stat -f %m "$archive")
	stamp="$sdk_dir/.sdk-archive-stamp"

	if [ -d "$sdk_dir/staging_dir/host" ] && [ -f "$stamp" ] &&
		[ "$(cat "$stamp" 2>/dev/null)" = "$archive_mtime" ]; then
		sdk_cache_log "Using extracted SDK: $sdk_dir"
		return 0
	fi

	sdk_cache_log "Extracting SDK to $sdk_dir ..."
	rm -rf "$sdk_dir"
	mkdir -p "$sdk_dir"

	if [[ "$archive" == *.tar.zst ]]; then
		tar --zstd -xf "$archive" -C "$sdk_dir" --strip-components=1
	elif [[ "$archive" == *.tar.xz ]]; then
		tar -xJf "$archive" -C "$sdk_dir" --strip-components=1
	else
		echo "sdk_cache_ensure_extracted: unsupported archive: $archive" >&2
		return 1
	fi

	printf '%s' "$archive_mtime" >"$stamp"
}
