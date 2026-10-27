#!/usr/bin/env bash
# Install LICENSE, NOTICE, and trilingual README into a package staging tree.
# Usage: stage-docs.sh <staging-root> <doc-package-name>
set -euo pipefail

STAGE="${1:?staging root required}"
PKG="${2:?package name required}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOC="$STAGE/usr/share/doc/$PKG"

install -d "$DOC"
[ -f "$ROOT/NOTICE" ] && install -m 0644 "$ROOT/NOTICE" "$DOC/"
[ -f "$ROOT/LICENSE" ] && install -m 0644 "$ROOT/LICENSE" "$DOC/"
install -m 0644 "$ROOT/README.md" "$DOC/README.en.md"
install -m 0644 "$ROOT/README.ru.md" "$DOC/"
install -m 0644 "$ROOT/README.de.md" "$DOC/"

# Thematic trilingual docs: <base>.{en,ru,de}.md — add new base names here.
for _basedoc in OPENWRT_DEV_INFRASTRUCTURE GATEWAY_UPLINKS; do
	for _lang in en ru de; do
		[ -f "$ROOT/docs/${_basedoc}.${_lang}.md" ] && install -m 0644 "$ROOT/docs/${_basedoc}.${_lang}.md" "$DOC/"
	done
done

if [ -d "$ROOT/scripts" ]; then
	install -d "$DOC/integration"
	for _ps1 in Test-Mwan3PolicySwitch.ps1 Test-Mwan3ChannelSwitch.ps1; do
		[ -f "$ROOT/scripts/$_ps1" ] && install -m 0644 "$ROOT/scripts/$_ps1" "$DOC/integration/"
	done
fi
