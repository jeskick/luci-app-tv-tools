#!/bin/sh
# TV-Tools：一次输出用户 + 系统应用 TSV（经 stdin 把 inner 喂给 adb，避免 heredoc 在部分环境下无效）
# 用法: tv-tools-adb-pkg-list.sh SERIAL
set -u
SERIAL="${1:?}"
export PATH="/usr/bin:/usr/sbin:/bin:/sbin:${PATH}"

INNER="/usr/bin/tv-tools-adb-pkg-list-inner.sh"
if [ ! -f "$INNER" ]; then
	INNER=$(dirname "$0")/tv-tools-adb-pkg-list-inner.sh
fi
if [ ! -f "$INNER" ]; then
	echo "ERR:missing tv-tools-adb-pkg-list-inner.sh"
	exit 1
fi

timeout 420 adb -s "$SERIAL" shell sh -s < "$INNER" 2>&1
