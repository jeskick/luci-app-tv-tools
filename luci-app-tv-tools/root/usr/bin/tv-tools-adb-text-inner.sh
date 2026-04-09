#!/bin/sh
# 在 Android TV 上由 tv-tools-adb-text.sh push 后执行；与 luci-app-tvcontrol 一致用「单条 adb shell」调用，不经 stdin 喂多行脚本。
# 依赖：/data/local/tmp/tv_tools_in.txt 已由 adb push
set -u
T=$(cat /data/local/tmp/tv_tools_in.txt)
# 尝试多种“粘贴触发”方式：部分 TV/ROM 对 KEYCODE_PASTE(279) 不生效
try_paste() {
	if input keyevent 279 >/dev/null 2>&1; then
		echo TVTOOLS_PASTE_KEYEVENT_279
		return 0
	fi
	if input keycombination 113 50 >/dev/null 2>&1; then
		echo TVTOOLS_PASTE_CTRL_V
		return 0
	fi
	if input keyevent 50 >/dev/null 2>&1; then
		echo TVTOOLS_PASTE_KEYEVENT_50
		return 0
	fi
	return 1
}

# 剪贴板 + 粘贴（中文走此路径，不经 input text）
if cmd clipboard set "$T" >/dev/null 2>&1; then
	try_paste >/dev/null 2>&1 || true
	echo TVTOOLS_OK_CLIPBOARD_SET
	exit 0
fi
if cmd clipboard set-text "$T" >/dev/null 2>&1; then
	try_paste >/dev/null 2>&1 || true
	echo TVTOOLS_OK_CLIPBOARD_SETTEXT
	exit 0
fi
if cmd clipboard set-primary-clip "$T" >/dev/null 2>&1; then
	try_paste >/dev/null 2>&1 || true
	echo TVTOOLS_OK_PRIMARY
	exit 0
fi
if cmd clipboard --user 0 set "$T" >/dev/null 2>&1; then
	try_paste >/dev/null 2>&1 || true
	echo TVTOOLS_OK_USER0
	exit 0
fi

# 仅 ASCII：回退 input text
HAS_HI=0
for x in $(od -An -tu1 /data/local/tmp/tv_tools_in.txt 2>/dev/null); do
	[ "$x" -gt 127 ] 2>/dev/null && HAS_HI=1 && break
done
if [ "$HAS_HI" -eq 0 ]; then
	ESC=$(printf '%s' "$T" | sed 's/%/%%/g; s/ /%s/g')
	if input text "$ESC" 2>&1; then
		echo TVTOOLS_OK_ASCII
		exit 0
	fi
	echo TVTOOLS_ERR_ASCII_INPUT
	exit 5
fi

echo "TVTOOLS_ERR_UNICODE_CLIPBOARD"
exit 4
