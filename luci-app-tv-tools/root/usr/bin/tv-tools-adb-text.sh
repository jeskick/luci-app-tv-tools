#!/bin/sh
# TV-Tools：UTF-8 文本发到电视当前焦点输入框
# 与 luci-app-tvcontrol 一致：设备端用「单条 adb shell 命令」执行脚本，不经 stdin 喂多行，
# 避免部分 Android 把脚本内容回显进 stdout，导致 LuCI 误判。
# 1) adb push 文本到 /data/local/tmp/tv_tools_in.txt
# 2) adb push 设备端脚本并 sh 执行（剪贴板 + 粘贴，或 ASCII 时 input text）
# 用法: tv-tools-adb-text.sh SERIAL /tmp/local_utf8_file
set -u
SERIAL="${1:?}"
LOCAL="${2:?}"
INNER="/usr/bin/tv-tools-adb-text-inner.sh"
[ -f "$LOCAL" ] || { echo "ERR: no file"; exit 2; }
[ -f "$INNER" ] || { echo "ERR: no inner script $INNER"; exit 2; }

export HOME="${HOME:-/root}"
export PATH="/usr/bin:/usr/sbin:/bin:/sbin:${PATH}"

REMOTE_TXT="/data/local/tmp/tv_tools_in.txt"
REMOTE_SH="/data/local/tmp/tv_tools_text_inner.sh"

adb -s "$SERIAL" push "$LOCAL" "$REMOTE_TXT" >/dev/null 2>&1 || {
	echo "ERR: adb push failed"
	exit 3
}
adb -s "$SERIAL" push "$INNER" "$REMOTE_SH" >/dev/null 2>&1 || {
	echo "ERR: adb push inner failed"
	exit 3
}

adb -s "$SERIAL" shell chmod 755 "$REMOTE_SH" >/dev/null 2>&1 || true

# 单条远程命令，无 stdin 脚本（对齐 tvcontrol 的 adb shell 用法）
adb -s "$SERIAL" shell "sh $REMOTE_SH"
