#!/bin/sh
# 应用缓存/重启：pm clear + force-stop + monkey 启动
# 用法: tv-tools-adb-app-refresh.sh SERIAL PACKAGE
set -u

SERIAL="${1:?}"
PKG="${2:?}"

export HOME="${HOME:-/root}"
export PATH="/usr/bin:/usr/sbin:/bin:/sbin:${PATH}"

echo "== pm clear $PKG =="
adb -s "$SERIAL" shell "pm clear '$PKG'" 2>&1
RC_CLEAR=$?

echo "== am force-stop $PKG =="
adb -s "$SERIAL" shell "am force-stop '$PKG'" 2>&1
RC_STOP=$?

echo "== monkey launch $PKG =="
adb -s "$SERIAL" shell "monkey -p '$PKG' -c android.intent.category.LAUNCHER 1" 2>&1
RC_LAUNCH=$?

if [ "$RC_CLEAR" -eq 0 ] && [ "$RC_STOP" -eq 0 ] && [ "$RC_LAUNCH" -eq 0 ]; then
	echo "TVTOOLS_APP_REFRESH_OK"
	exit 0
fi

echo "TVTOOLS_APP_REFRESH_FAIL clear=$RC_CLEAR stop=$RC_STOP launch=$RC_LAUNCH"
exit 7
