#!/bin/sh
# 在路由器上执行：用于 LuCI / TV-Tools / OpenClash / ADB 开发前的环境摸底
# 用法: ssh root@路由IP 'sh -s' < check-router-env.sh
# 或:   scp check-router-env.sh root@IP:/tmp/ && ssh root@IP sh /tmp/check-router-env.sh

echo "========== 系统标识 =========="
uname -a 2>/dev/null || uname -m
echo "主机名: $(uci get system.@system[0].hostname 2>/dev/null || hostname)"
echo "OpenWrt: $(cat /etc/openwrt_release 2>/dev/null || true)"
echo "固件版本: $(cat /etc/banner 2>/dev/null | head -3 || true)"

echo ""
echo "========== 内存与存储 =========="
free -m 2>/dev/null || cat /proc/meminfo | head -5
df -h 2>/dev/null | sed -n '1,8p'

echo ""
echo "========== CPU =========="
grep -E 'model name|Hardware|processor|BogoMIPS|CPU implementer' /proc/cpuinfo 2>/dev/null | head -10 || cat /proc/cpuinfo | head -8

echo ""
echo "========== 内核与模块 =========="
uname -r
lsmod 2>/dev/null | head -20 || echo "(无 lsmod 或为空)"

echo ""
echo "========== 网络接口 =========="
ip -br link 2>/dev/null || ifconfig -a 2>/dev/null | head -30
echo "--- 默认路由 ---"
ip route 2>/dev/null || route -n 2>/dev/null

echo ""
echo "========== LuCI / uHTTPd =========="
opkg list-installed 2>/dev/null | grep -E '^luci-|^uhttpd' || true
ls -la /www/cgi-bin/luci 2>/dev/null || true
ls -d /usr/lib/lua/luci/controller/*.lua 2>/dev/null | wc -l | xargs echo "controller 文件数:"

echo ""
echo "========== OpenClash（若已装） =========="
opkg list-installed 2>/dev/null | grep -i clash || true
ls -la /etc/openclash 2>/dev/null | head -15 || echo "无 /etc/openclash"
command -v clash 2>/dev/null && clash -v 2>/dev/null || true

echo ""
echo "========== ADB =========="
command -v adb && adb version || echo "未找到 adb（需自行安装 adb 或静态二进制）"
ls -la /usr/bin/adb /opt/bin/adb 2>/dev/null || true

echo ""
echo "========== 解释器 / 工具链（后端扩展用） =========="
for c in lua luac5.1 lua5.1 sh ash; do command -v $c 2>/dev/null && echo "  OK: $c" || true; done
echo "--- 磁盘空间（/tmp） ---"
df -h /tmp 2>/dev/null

echo ""
echo "========== ubus / rpcd =========="
command -v ubus && ubus list 2>/dev/null | head -25 || true
ls /usr/libexec/rpcd 2>/dev/null | head -15 || true

echo ""
echo "========== 完成 =========="
