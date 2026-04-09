#
# 放入 OpenWrt SDK 时使用: feeds/luci/applications/luci-app-tv-tools
# 本地仅 scp 部署时可忽略完整编译，直接按目录复制到路由器对应路径
#
include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-tv-tools
PKG_VERSION:=0.1
PKG_RELEASE:=1

LUCI_TITLE:=TV-Tools
LUCI_DEPENDS:=+luci-base
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
$(eval $(call BuildPackage,luci-app-tv-tools))
