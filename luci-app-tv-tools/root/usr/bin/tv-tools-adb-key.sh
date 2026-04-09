#!/bin/sh
# TV-Tools：按键名 -> adb shell input keyevent（自用，仅被 LuCI 白名单调用）
KEY="$1"
[ -n "$KEY" ] || { echo "ERR: no key"; exit 2; }

HOST=""
PORT="5555"
command -v uci >/dev/null 2>&1 && HOST="$(uci -q get tv_tools.main.host)"
command -v uci >/dev/null 2>&1 && PORT="$(uci -q get tv_tools.main.port)"
[ -n "$PORT" ] || PORT="5555"

if [ -z "$HOST" ] || [ "$HOST" = "0.0.0.0" ]; then
	echo "ERR: 未配置 host。执行: uci set tv_tools.main.host=电视IP; uci set tv_tools.main.port=5555; uci commit tv_tools"
	exit 3
fi

# LuCI 多为 www-data/http 用户：若无权读 /root/.android，请把 root 首次 adb 授权后的 ~/.android 拷到该用户 HOME（常见 /var/www）
if [ -r /root/.android/adbkey ] 2>/dev/null || [ -r /root/.android/adbkey.pub ] 2>/dev/null; then
	export HOME=/root
elif [ -d /var/www ]; then
	export HOME=/var/www
else
	export HOME="${HOME:-/root}"
fi
export PATH="/usr/bin:/usr/sbin:/bin:/sbin:${PATH}"

SERIAL="${HOST}:${PORT}"
CODE=""
case "$KEY" in
	power) CODE=26 ;;
	home) CODE=3 ;;
	back) CODE=4 ;;
	ok) CODE=66 ;;
	up) CODE=19 ;;
	down) CODE=20 ;;
	left) CODE=21 ;;
	right) CODE=22 ;;
	vol_plus) CODE=24 ;;
	vol_minus) CODE=25 ;;
	mute) CODE=164 ;;
	menu) CODE=82 ;;
	*) echo "ERR: unknown key $KEY"; exit 4 ;;
esac

command -v adb >/dev/null 2>&1 || { echo "ERR: adb 不在 PATH"; exit 5; }

adb start-server >/dev/null 2>&1 || true
if ! adb devices 2>/dev/null | grep -F "${SERIAL}" | grep -qE '[[:space:]]device$'; then
	adb connect "$SERIAL" >/dev/null 2>&1 || true
fi

# 无线 ADB 偶发 shell 卡死；timeout 避免脚本/LuCI 长时间阻塞（无 timeout 时直接 adb）
if command -v timeout >/dev/null 2>&1; then
	OUT="$(timeout 10 adb -s "$SERIAL" shell input keyevent "$CODE" 2>&1)" || true
else
	OUT="$(adb -s "$SERIAL" shell input keyevent "$CODE" 2>&1)" || true
fi
# 部分固件 shell 返回非 0 仍已生效，只要无典型错误即认为成功
if echo "$OUT" | grep -qi "error\\|closed\\|unauthor\\|cannot connect"; then
	echo "ERR: $OUT"
	exit 6
fi
echo OK
exit 0
