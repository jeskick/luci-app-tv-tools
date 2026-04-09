#!/bin/sh
# TV-Tools：推送 APK 到设备并 pm install
# 用法: tv-tools-adb-install.sh SERIAL /path/to/local.apk
set -u
SERIAL="${1:?}"
APK="${2:?}"
export PATH="/usr/bin:/usr/sbin:/bin:/sbin:${PATH}"
export HOME="${HOME:-/root}"

[ -f "$APK" ] || {
	echo "ERR: apk missing"
	exit 2
}

REMOTE="/data/local/tmp/tv_tools_install.apk"
if ! timeout 300 adb -s "$SERIAL" push "$APK" "$REMOTE" 2>&1; then
	echo "ERR: adb push failed"
	exit 3
fi

OUT=$(timeout 300 adb -s "$SERIAL" shell pm install -r -t "$REMOTE" 2>&1) || true
RC=$?
adb -s "$SERIAL" shell rm -f "$REMOTE" >/dev/null 2>&1 || true
printf "%s\n" "$OUT"
exit "$RC"
