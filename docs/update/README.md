# update/ — 插件自更新

路径：[`book.koplugin/update/`](../../book.koplugin/update/)。

查 GitHub Release、下载校验、完整替换插件目录。  
**自动检查只提示**，不会自动下载安装。

## 设计

- `init.lua`：查版本、弹窗、进度条、与设置开关
- `install.lua`：解压/替换（Job）
- API：`https://api.github.com/repos/gyh1621/moon/releases/latest`；仅接受本 fork 的 Release 附件链接，继续校验 SHA256。
- 检查间隔默认 24h；当前版本来自 `bookversion`
- 自动检查入口：`Desktop:onResume` → `Update.autoCheck`（仅提示，不自动装）
- `_checking` / `_installing` 防重入；在飞 job 可 cancel

版本文件必须叫 `bookversion.lua`（不能叫 `version.lua`，与 KOReader 冲突）。CI 在 `v*` tag 注入版本。

## 用法

```lua
local Update = require("update")

Update.manualCheck(plugin_root)  -- 设置页「检查更新」
-- 静默检查：Desktop:onResume → Update.autoCheck（仅有新版本才提示）

-- 用户确认后内部走 download + Install
```

安装失败不得留下半替换的 `book.koplugin/`；先落到临时目录再切换。

## 发布 fork 版本

从已验证的 `main` 创建稳定版本标签并推送到 `gyh1621/moon`：

```sh
git push origin main
git tag -a v0.1.0 -m "Moon fork v0.1.0"
git push origin v0.1.0
```

后续版本递增为 `v0.1.1`、`v0.1.2` 等，不移动已有发布标签。`.github/workflows/release.yml` 在 `v*` 标签推送时运行测试、注入版本号，发布 `book.koplugin-v0.1.0.zip`、对应 `.sha256` 和输入法词库。源码的 `bookversion.lua` 保持开发版本。

更新器使用最新稳定 Release；带 `-` 的预发布标签不会成为稳定更新。首次手动安装本 fork 的发布 ZIP 后，设置中的「检查更新」会检查本 fork；自动检查仍只提示，不自动安装。替换插件目录时保留 `.moon` 用户数据。
