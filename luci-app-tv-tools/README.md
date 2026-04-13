# luci-app-tv-tools

TV-Tools for LuCI/OpenWrt.

## 卸载脚本（彻底清理）

项目内提供一键清理脚本：

- 路径：`/usr/bin/tv-tools-uninstall.sh`
- 运行：

```sh
sh /usr/bin/tv-tools-uninstall.sh
```

### 清理范围

- `luci-app-tv-tools` 包（若通过 `opkg` 安装）
- TV-Tools 的 UCI 配置（`/etc/config/tv_tools`）
- 插件控制器、视图、静态资源、ADB 辅助脚本
- TV-Tools 运行缓存（截图、临时文件、LuCI 缓存）
- TV-Tools 产生的 OpenClash 文件：
  - `vgeo-universal-overlay.yaml` 及其备份
  - `openclash-default-overwrite.local.sh`（可选，覆盖包内默认覆写示例）
  - `openclash_custom_overwrite.sh.bak.tvtools`
- 保留你已注入到 `openclash_custom_overwrite.sh` 的覆写内容，不会主动删除注入块

> 注意：该脚本按“程序卸载”目标执行清理，执行前建议自行备份重要配置。
