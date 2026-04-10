#!/bin/sh
# TV-Tools 一键彻底卸载脚本
# 用法:
#   sh /usr/bin/tv-tools-uninstall.sh
# 说明:
# - 清理 luci-app-tv-tools 的配置/缓存/静态文件/控制器/脚本
# - 清理 TV-Tools 生成的 OpenClash 相关模板与注入块
# - 若检测到 opkg，则尝试卸载 luci-app-tv-tools 包（可失败，不中断清理）

set -u
export PATH="/usr/sbin:/usr/bin:/sbin:/bin:${PATH}"

log() { printf '[tv-tools-uninstall] %s\n' "$*"; }

remove_path() {
	local p="$1"
	if [ -e "$p" ] || [ -L "$p" ]; then
		rm -rf "$p" 2>/dev/null || true
		log "removed: $p"
	fi
}

remove_glob() {
	local pat="$1"
	# shellcheck disable=SC2086
	for p in $pat; do
		[ -e "$p" ] || [ -L "$p" ] || continue
		rm -rf "$p" 2>/dev/null || true
		log "removed: $p"
	done
}

log "start cleanup..."

# 1) 尝试包卸载（若不是 opkg 安装可忽略）
if command -v opkg >/dev/null 2>&1; then
	if opkg list-installed 2>/dev/null | grep -q '^luci-app-tv-tools '; then
		log "opkg remove luci-app-tv-tools"
		opkg remove luci-app-tv-tools >/dev/null 2>&1 || log "opkg remove failed, continue cleanup"
	fi
fi

# 2) 清理 UCI 配置
if command -v uci >/dev/null 2>&1; then
	uci -q delete tv_tools.main >/dev/null 2>&1 || true
	uci -q commit tv_tools >/dev/null 2>&1 || true
fi
remove_path "/etc/config/tv_tools"

# 3) 清理插件文件（按 tv-tools 现有安装路径）
remove_path "/usr/lib/lua/luci/controller/tv_tools.lua"
remove_path "/usr/lib/lua/luci/view/tv_tools"
remove_path "/www/luci-static/tv-tools"
remove_path "/usr/bin/tv-tools-adb-key.sh"
remove_path "/usr/bin/tv-tools-adb-text.sh"
remove_path "/usr/bin/tv-tools-adb-text-inner.sh"
remove_path "/usr/bin/tv-tools-adb-screencap.sh"
remove_path "/usr/bin/tv-tools-adb-pkg-list.sh"
remove_path "/usr/bin/tv-tools-adb-pkg-list-inner.sh"
remove_path "/usr/bin/tv-tools-adb-install.sh"
remove_path "/usr/bin/tv-tools-adb-uninstall.sh"
remove_path "/usr/bin/tv-tools-adb-app-refresh.sh"
remove_path "/usr/bin/tv-tools-uninstall.sh"
remove_path "/usr/share/tv-tools"

# 4) 清理 TV-Tools 运行数据/缓存
remove_path "/www/luci-static/tv-tools/caps"
remove_glob "/tmp/tvt_syshell_*"
remove_glob "/tmp/tvt_apk_*.apk"

# 5) 清理 OpenClash 相关（仅 TV-Tools 产物）
remove_path "/etc/openclash/custom/tvtools-template3.txt"
remove_path "/etc/openclash/custom/vgeo-universal-overlay.yaml"
remove_path "/etc/openclash/custom/vgeo-universal-overlay.yaml.bak.tvtools"
remove_path "/etc/openclash/custom/openclash_custom_overwrite.sh.bak.tvtools"

OC_OVERWRITE="/etc/openclash/custom/openclash_custom_overwrite.sh"
if [ -f "$OC_OVERWRITE" ]; then
	if grep -q ">>> TVTOOLS_VGEO_BEGIN >>>" "$OC_OVERWRITE" 2>/dev/null; then
		# 删除注入块（从 begin 到 end）
		sed '/>>> TVTOOLS_VGEO_BEGIN >>>/,/<<< TVTOOLS_VGEO_END <<</d' "$OC_OVERWRITE" > "${OC_OVERWRITE}.tmp.tvtools" 2>/dev/null || true
		if [ -s "${OC_OVERWRITE}.tmp.tvtools" ]; then
			mv -f "${OC_OVERWRITE}.tmp.tvtools" "$OC_OVERWRITE"
			log "removed TVTOOLS_VGEO block from: $OC_OVERWRITE"
		else
			rm -f "${OC_OVERWRITE}.tmp.tvtools" 2>/dev/null || true
		fi
	fi
fi

# 6) 清理 LuCI 缓存并重载服务（不强依赖）
remove_path "/tmp/luci-indexcache"
remove_path "/tmp/luci-modulecache"
remove_path "/tmp/luci-*cache*"
/etc/init.d/rpcd reload >/dev/null 2>&1 || true
/etc/init.d/uhttpd reload >/dev/null 2>&1 || true

log "done."
exit 0
