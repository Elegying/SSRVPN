# GitHub 仓库整理审查报告

审查日期：2026-07-02

审查账号：`Elegying`

当前公开仓库：

- `SSRVPN`
- `SSRVPN_Windows`
- `SSRVPN_MacOS`
- `SSRVPN_Android`
- `SSRVPN-Windows`
- `SSR_Panel`
- `ssrvpn_shared`

## 总体结论

当前 GitHub 仓库中真正需要作为活跃项目维护的只有两个：

1. `SSRVPN`
2. `SSR_Panel`

三个下划线平台仓库：

- `SSRVPN_Android`
- `SSRVPN_MacOS`
- `SSRVPN_Windows`

已经正确设置为 archived，并且 README/描述都指向新的 `SSRVPN` monorepo。它们不是活跃项目，但建议继续保留为历史仓库，因为旧客户端更新逻辑和历史 Release 下载仍可能引用它们。

两个最需要清理的仓库：

- `SSRVPN-Windows`
- `ssrvpn_shared`

它们已经被主仓库替代，且不应该再作为活跃开发入口。建议先归档，观察一段时间确认没有外部下载或部署引用后，再决定是否删除。

## 建议分类

| 仓库 | 当前状态 | 建议 | 是否可删除 |
|---|---:|---|---|
| `SSRVPN` | 活跃 monorepo | 必须保留，作为唯一客户端主仓库 | 不可删除 |
| `SSR_Panel` | 活跃服务端/面板仓库 | 必须保留，作为服务端部署与管理仓库 | 不可删除 |
| `SSRVPN_Android` | archived | 保留历史 Release，不再开发 | 暂不删除 |
| `SSRVPN_MacOS` | archived | 保留历史 Release，不再开发 | 暂不删除 |
| `SSRVPN_Windows` | archived | 保留历史 Release，不再开发 | 暂不删除 |
| `SSRVPN-Windows` | 未归档重复 Windows 仓库 | 建议立即归档；确认无外部引用后可删除 | 可删除候选 |
| `ssrvpn_shared` | 未归档旧共享包仓库 | 建议立即归档；确认无外部引用后可删除 | 可删除候选 |

## 必须保留仓库详细说明

### 1. `SSRVPN`

地址：

`https://github.com/Elegying/SSRVPN`

定位：

`SSRVPN` 是当前唯一的客户端主仓库，也是以后所有 Android、macOS、Windows 客户端开发和发布的中心。它是 monorepo，意思是三个平台客户端和共享包都放在同一个仓库里统一维护。

为什么必须保留：

- 它已经包含三端源码：
  - `SSRVPN_Android`
  - `SSRVPN_MacOS`
  - `SSRVPN_Windows`
- 它已经包含共享包：
  - `packages/ssrvpn_shared`
- 它已经有 GitHub Actions：
  - `SSRVPN CI`
  - `Release`
- 它已经可以通过 tag 自动生成三端产物：
  - Android APK
  - macOS DMG
  - Windows ZIP
- 它已经发布了 `v2.0.0`：
  - `https://github.com/Elegying/SSRVPN/releases/tag/v2.0.0`
- 本地项目管理工具和文档也都在这里：
  - `Makefile`
  - `scripts/`
  - `MEMORY.md`
  - `docs/OWNER_GUIDE.zh-CN.md`
  - `docs/PROJECT_MANAGEMENT.md`

以后怎么维护：

- 所有客户端功能修改都从这个仓库开始。
- 本地先运行 `make status` 看状态。
- 新功能使用 `feature/<name>` 分支。
- 修 bug 使用 `fix/<name>` 分支。
- 发布版本使用 `vX.Y.Z` tag。
- 安装包不要提交到源码仓库，应该放 GitHub Releases 和本地 `dist/`。

删除风险：

删除该仓库会导致整个客户端项目源码、自动构建、发布记录、文档和管理流程全部丢失。绝对不能删除。

### 2. `SSR_Panel`

地址：

`https://github.com/Elegying/SSR_Panel`

定位：

`SSR_Panel` 是服务端/面板工具仓库，不属于客户端仓库。它管理 SSR、AnyTLS、服务器优化和部署脚本，是服务端基础设施的一部分。

它包含三个主要子项目：

- `ssr-admin-panel`：SSR 用户、流量、账号管理面板。
- `anytls-panel`：AnyTLS 节点管理和部署工具。
- `ssr-server-optimizer`：旧版 Python SSR 服务器优化工具。

为什么必须保留：

- 本地代码和部署脚本中大量引用该仓库地址：
  - `https://github.com/Elegying/SSR_Panel.git`
  - `https://raw.githubusercontent.com/Elegying/SSR_Panel/main/...`
- 它是线上服务端部署入口，而不是旧客户端仓库。
- 它已有独立 CI workflow。
- 它已有 `v1.0.0` Release。
- 客户端 `SSRVPN` 与服务端 `SSR_Panel` 是不同职责：
  - `SSRVPN`：用户电脑/手机上的客户端。
  - `SSR_Panel`：服务器侧部署、管理和运维工具。

以后怎么维护：

- 服务端部署脚本、面板脚本、AnyTLS 部署逻辑继续放这里。
- 不要把它合并进客户端仓库，除非未来要做一个大 monorepo。
- 修改部署脚本后必须小心测试，因为 raw.githubusercontent.com 链接可能会被服务器直接执行。
- 建议以后给这个仓库补一份更详细的生产运维说明和回滚方案。

删除风险：

删除该仓库会导致现有服务器部署命令、更新脚本和 raw GitHub 下载链接失效。它不能删除。

## 保留但不再活跃开发的历史仓库

### 1. `SSRVPN_Android`

地址：

`https://github.com/Elegying/SSRVPN_Android`

当前状态：

- 已 archived。
- README 已说明迁移到 `SSRVPN` monorepo。
- 仍保留历史 Release：
  - `v1.0.0`
  - `v1.1.0`
  - `v2.0.0`

为什么暂不删除：

- 历史 Android APK 下载链接仍在 Release 中。
- 当前客户端更新服务代码仍指向 `Elegying/SSRVPN_Android` 的 latest release。
- 删除后旧客户端检查更新可能失败，旧用户也无法访问历史下载。

建议：

- 继续 archived 保留。
- 后续把 Android 更新服务迁移到 `Elegying/SSRVPN` 主仓库 Release。
- 等确认旧版本不再需要更新入口，再考虑是否删除。

### 2. `SSRVPN_MacOS`

地址：

`https://github.com/Elegying/SSRVPN_MacOS`

当前状态：

- 已 archived。
- README 已说明迁移到 `SSRVPN` monorepo。
- 仍保留历史 DMG Release。

为什么暂不删除：

- 历史 DMG 下载链接仍有价值。
- 当前 macOS 更新服务代码仍指向 `Elegying/SSRVPN_MacOS` 的 latest release。
- 删除后旧客户端检查更新可能失败。

建议：

- 继续 archived 保留。
- 后续把 macOS 更新服务迁移到主仓库 `SSRVPN` Release。
- 不再在该仓库开发新功能。

### 3. `SSRVPN_Windows`

地址：

`https://github.com/Elegying/SSRVPN_Windows`

当前状态：

- 已 archived。
- README 已说明迁移到 `SSRVPN` monorepo。
- 仍保留历史 Windows ZIP Release。

为什么暂不删除：

- 历史 Windows ZIP 下载链接仍有价值。
- 当前 Windows 更新服务代码仍指向 `Elegying/SSRVPN_Windows` 的 latest release。
- 删除后旧客户端检查更新可能失败。

建议：

- 继续 archived 保留。
- 后续把 Windows 更新服务迁移到主仓库 `SSRVPN` Release。
- 不再在该仓库开发新功能。

## 建议清理仓库

### 1. `SSRVPN-Windows`

地址：

`https://github.com/Elegying/SSRVPN-Windows`

当前状态：

- 未 archived。
- 默认分支是 `master`，不是当前主项目统一使用的 `main`。
- 仓库描述为空。
- README badge 指向 `SSRVPN_Windows`，说明它与另一个 Windows 仓库关系混乱。
- 有一个 `v2.0.0` Release，资产为 `SSRVPN.zip`。
- 本地和账号内代码搜索没有发现它被主项目引用。

判断：

这是一个重复 Windows 仓库。它与 `SSRVPN_Windows` 和主仓库 `SSRVPN/SSRVPN_Windows` 功能重叠，而且不是当前 monorepo 维护入口。

建议操作：

1. 立即归档。
2. README 顶部加迁移说明，指向 `https://github.com/Elegying/SSRVPN`。
3. 检查官网、下载页、聊天记录、外部文档是否还有 `SSRVPN-Windows` 下载链接。
4. 如果 30 天内确认无人使用，可删除。

删除风险：

- 如果有人拿着旧 release 下载链接，删除后链接会失效。
- 如果官网或第三方页面指向该仓库，用户会打不开。

推荐结论：

先归档，暂不立刻删除。确认无外部引用后可删除。

### 2. `ssrvpn_shared`

地址：

`https://github.com/Elegying/ssrvpn_shared`

当前状态：

- 未 archived。
- 没有 Release。
- 体积很小。
- 主仓库 `SSRVPN` 已经内置 `packages/ssrvpn_shared`。
- 当前三端使用的是本地 path 依赖：
  - `path: ../packages/ssrvpn_shared`

判断：

这个独立仓库已经被 monorepo 内的 `packages/ssrvpn_shared` 替代。继续保留为活跃仓库会造成维护混乱：别人可能以为共享包要在这里改，但真实代码已经在 `SSRVPN` 主仓库里。

建议操作：

1. 立即归档。
2. README 顶部加迁移说明，指向 `https://github.com/Elegying/SSRVPN/tree/main/packages/ssrvpn_shared`。
3. 如果确认没有 pub.dev、Git submodule、外部项目依赖，可删除。

删除风险：

- 如果未来有人把它当 Git dependency 使用，删除会导致依赖拉取失败。
- 目前未发现主项目依赖它。

推荐结论：

优先归档；确认无外部依赖后可删除。

## 推荐执行顺序

第一阶段：立即做，安全可逆。

1. 保持 `SSRVPN` 活跃。
2. 保持 `SSR_Panel` 活跃。
3. 保持 `SSRVPN_Android` / `SSRVPN_MacOS` / `SSRVPN_Windows` archived。
4. 将 `SSRVPN-Windows` 归档并加迁移说明。
5. 将 `ssrvpn_shared` 归档并加迁移说明。

第二阶段：下一次客户端版本处理。

1. 把三端 `UpdateService` 的 release 检查源从旧平台仓库迁移到 `SSRVPN` 主仓库。
2. 发布新版本，例如 `v2.0.1`。
3. 确认新客户端能从主仓库 release 检查更新。

第三阶段：观察后删除。

1. 检查官网、下载页、用户文档、服务器脚本是否还引用 `SSRVPN-Windows` 或 `ssrvpn_shared`。
2. 观察 30 天。
3. 如果无引用、无下载需求、无依赖，再删除：
   - `SSRVPN-Windows`
   - `ssrvpn_shared`

## 不建议删除的仓库

不要删除：

- `SSRVPN`
- `SSR_Panel`
- `SSRVPN_Android`
- `SSRVPN_MacOS`
- `SSRVPN_Windows`

其中后三个虽然是旧平台仓库，但仍应作为历史 release 和旧客户端更新入口保留。

## 最终建议

当前最专业、风险最低的整理结果应该是：

- 活跃仓库只保留两个：`SSRVPN`、`SSR_Panel`。
- 历史客户端仓库保留 archived 状态：`SSRVPN_Android`、`SSRVPN_MacOS`、`SSRVPN_Windows`。
- 重复/过期仓库先归档，确认无引用后删除：`SSRVPN-Windows`、`ssrvpn_shared`。

删除仓库前必须再次确认，因为 GitHub 仓库删除会让所有 release、issues、stars、下载链接和历史记录消失。
