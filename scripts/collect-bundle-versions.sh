#!/bin/sh
# Collect bundle package versions on OpenWrt (run on router)
apk_ver() {
	apk list --installed 2>/dev/null | grep "^$1-" | head -1 | sed "s/ .*//" | sed "s/^$1-//"
}

mwan6_npt_label() {
	if [ ! -f /usr/share/mwan6-npt/functions.sh ]; then
		echo "MISSING"
		return
	fi
	md5=$(md5sum /usr/share/mwan6-npt/functions.sh | awk '{print $1}')
	case "$md5" in
	2967709f5f221daa75e8a4b0b285264c) echo "1.0.6-2" ;;
	82be0a44578fea7400c7b0ba120502bb) echo "~1.0.3" ;;
	*) echo "unknown" ;;
	esac
}

luci_mwan6_npt_overlay() {
	if [ ! -f /www/luci-static/resources/view/mwan6-npt/network/config.js ]; then
		echo "none"
		return
	fi
	md5=$(md5sum /www/luci-static/resources/view/mwan6-npt/network/config.js | awk '{print $1}')
	case "$md5" in
	c22f4b969bf948d8d318f3119b7aa288) echo "patched" ;;
	dad4c1e9b95dacdb36920c827f8da814) echo "stock-apk" ;;
	*) echo "other" ;;
	esac
}

printf 'mwan3=%s\n' "$(apk_ver mwan3)"
printf 'luci-app-mwan3=%s\n' "$(apk_ver luci-app-mwan3)"
printf 'luci-i18n-mwan3-ru=%s\n' "$(apk_ver luci-i18n-mwan3-ru)"
printf 'luci-app-mwan6-npt=%s\n' "$(apk_ver luci-app-mwan6-npt)"
printf 'luci-i18n-mwan6-npt-ru=%s\n' "$(apk_ver luci-i18n-mwan6-npt-ru)"
printf 'mwan6-npt=%s\n' "$(mwan6_npt_label)"
printf 'luci-mwan6-npt-ui=%s\n' "$(luci_mwan6_npt_overlay)"
