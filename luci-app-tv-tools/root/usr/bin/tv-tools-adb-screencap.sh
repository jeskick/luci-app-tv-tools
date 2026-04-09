#!/bin/sh
# TV-Tools：ADB 截屏写入 PNG（二进制走重定向，避免经 LuCI sys.exec 截断）
# 用法: tv-tools-adb-screencap.sh SERIAL /path/to/out.png
set -u
SERIAL="${1:?}"
OUT="${2:?}"
export HOME="${HOME:-/root}"
export PATH="/usr/bin:/usr/sbin:/bin:/sbin:${PATH}"

DIR=$(dirname "$OUT")
mkdir -p "$DIR" 2>/dev/null
TMP="${OUT}.part"
rm -f "$TMP"

if timeout 40 adb -s "$SERIAL" exec-out screencap -p >"$TMP" 2>/dev/null; then
	SZ=$(wc -c <"$TMP" 2>/dev/null || echo 0)
	if [ "$SZ" -gt 200 ] 2>/dev/null; then
		mv -f "$TMP" "$OUT"
		exit 0
	fi
fi
rm -f "$TMP"

if timeout 40 adb -s "$SERIAL" shell screencap -p >"$TMP" 2>/dev/null; then
	SZ=$(wc -c <"$TMP" 2>/dev/null || echo 0)
	if [ "$SZ" -gt 200 ] 2>/dev/null; then
		mv -f "$TMP" "$OUT"
		exit 0
	fi
fi
rm -f "$TMP"
exit 1
