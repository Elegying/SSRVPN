# SSRVPN 项目记忆

更新时间：2026-07-02

## 当前项目定位

SSRVPN 当前以 `/Users/jared/Desktop/app/SSRVPN` 作为唯一主项目目录维护。GitHub 仓库为：

`https://github.com/Elegying/SSRVPN`

项目采用 monorepo 管理方式：

- `packages/ssrvpn_shared`：三端共享模型、订阅解析、配置生成、通用服务逻辑。
- `SSRVPN_Android`：Android 客户端。
- `SSRVPN_MacOS`：macOS 客户端。
- `SSRVPN_Windows`：Windows 客户端。
- `dist/`：本地最终交付产物目录，不提交到 Git。

## 已完成的发布产物

最终交付目录：

`/Users/jared/Desktop/app/SSRVPN/dist`

保留的主产物：

- `dist/SSRVPN.apk`
- `dist/SSRVPN.dmg`
- `dist/SSRVPN.zip`
- `dist/CHECKSUMS.txt`
- `dist/SSRVPN_项目审查报告.md`

GitHub Release：

`https://github.com/Elegying/SSRVPN/releases/tag/v2.0.0`

说明：

- Android APK 已使用本地 release keystore 签名。
- macOS DMG 是 ad-hoc 签名版本，未做 Apple Developer ID 签名和 notarization。
- Windows ZIP 由 GitHub Actions Windows runner 构建。
- 因为没有 Apple/Microsoft/Google 开发者账号或代码签名证书，用户首次安装可能看到系统安全提示。

## 重要本地文件

不要删除：

- `SSRVPN_Android/android/signing/ssrvpn-release.jks`
- `SSRVPN_Android/android/key.properties`
- `dist/`

注意：

- Android 以后要能覆盖升级，必须继续使用同一个 keystore。
- 不要把 keystore、`key.properties`、证书、`.env`、APK/DMG/ZIP 构建产物提交到 Git。
- `dist/` 是本地交付目录，源码仓库不跟踪它。

## 已完成的清理

项目曾从约 `3.5GB` 清理到约 `469MB`。

已删除的垃圾/可重建内容包括：

- Flutter `.dart_tool`
- 各平台 `build`
- Android `.gradle`、`.cxx`
- macOS `Pods`、Flutter ephemeral
- Windows Flutter ephemeral
- `.DS_Store`
- 临时日志
- 旧的嵌套重复项目副本 `./SSRVPN/`

保留了源码、Git 历史、签名文件和最终构建产物。

## GitHub 与本地管理状态

当前专业管理策略：

- `main` 是稳定主分支。
- 新功能使用 `feature/<name>`。
- bug 修复使用 `fix/<name>`。
- 维护/文档使用 `chore/<name>`。
- 发布使用 `vX.Y.Z` 标签触发 GitHub Release workflow。
- 安装包发布到 GitHub Releases，本地副本放 `dist/`。

已创建的备份分支：

`archive/local-unreviewed-20260702`

用途：

- 保存清理前本地未整理的旧改动。
- 不作为日常开发入口。

## 已新增的项目管理工具

根目录新增 `Makefile` 和 `scripts/` 脚本。

常用命令：

```bash
cd /Users/jared/Desktop/app/SSRVPN
make status
```

作用：查看当前分支、本地是否干净、是否与 GitHub 同步、`dist` 产物是否存在、最新 GitHub Release。

```bash
make sync
```

作用：同步本地 `main` 与 GitHub `origin/main`。如果本地有未保存改动会拒绝执行。

```bash
make feature name=short-feature-name
```

作用：从干净的 `main` 创建并切换到 `feature/short-feature-name` 分支。

```bash
make verify
```

作用：运行共享包和 Android/macOS/Windows 的基础 analyze/test 检查。

## 已新增/更新的管理文档

新增：

- `docs/OWNER_GUIDE.zh-CN.md`：给不懂编程的项目所有者看的中文操作手册。
- `docs/PROJECT_MANAGEMENT.md`：分支模型、产物策略、本地流程、发布策略。
- `Makefile`
- `scripts/project-status.sh`
- `scripts/sync-main.sh`
- `scripts/start-feature.sh`
- `scripts/verify-all.sh`

更新：

- `.gitignore`
- `README.md`
- `CONTRIBUTING.md`
- `docs/MAINTENANCE.md`
- `CHANGELOG.md`

## 已推送的重要提交

- `761c3ea`：准备三端发布产物，触发 `v2.0.0` 发布。
- `c6fb018`：修正 `.gitignore`，避免误忽略 Android 原生源码，并将必要 Android 原生文件纳入 Git。
- `e407fc5`：新增项目所有者友好的管理流程、脚本和文档。

## 当前验证状态

最近一次 `main` 上 GitHub CI 已通过：

- Shared package
- Android
- macOS
- Windows

本地 `make status` 预期状态：

- `main...origin/main`
- Working tree clean
- `dist/SSRVPN.apk` 存在
- `dist/SSRVPN.dmg` 存在
- `dist/SSRVPN.zip` 存在
- 最新 Release 为 `v2.0.0`

## 以后修改功能的推荐流程

用户只需要自然语言提出需求，例如：

- “帮我新增一个功能：……”
- “帮我修复 Windows 打不开的问题。”
- “帮我发布 2.0.1。”
- “帮我同步 GitHub 并检查项目状态。”

执行原则：

1. 先运行 `make status`。
2. 如果要开始新功能，运行 `make sync`，然后创建 `feature/*` 或 `fix/*` 分支。
3. 修改代码和必要文档。
4. 运行相关测试，重大改动运行 `make verify`。
5. 提交并推送 GitHub。
6. 需要发布时创建 `vX.Y.Z` 标签，让 GitHub Actions 构建三端产物。

## 不要做的事

- 不要直接删除签名文件。
- 不要把 `dist/` 里的安装包提交到源码仓库。
- 不要在没有备份分支或提交的情况下重置工作区。
- 不要在 GitHub Release 外随意散发不同来源的安装包。
- 不要把密码、API secret、订阅链接、证书内容写进日志、Issue、PR 或文档。
