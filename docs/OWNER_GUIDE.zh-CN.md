# SSRVPN 项目所有者手册

这份文档是给不写代码的项目所有者看的。你不需要理解 Git 的全部细节，只要记住几个固定动作：同步、开需求、检查、发布。

## 项目怎么管理

专业项目一般这样管理：

- `main` 分支只放稳定代码。
- 新功能放到 `feature/功能名` 分支。
- 修 bug 放到 `fix/问题名` 分支。
- 发布产物不提交进源码仓库，放在本地 `dist/` 和 GitHub Releases。
- 每次改动都要经过检查：共享包测试、三端 analyze/test、必要时构建安装包。
- GitHub Release 是对外下载入口，本地 `dist/` 是你机器上的交付副本。

## 你每天最常用的命令

在项目根目录 `/Users/jared/Desktop/app/SSRVPN` 运行：

```bash
make status
```

作用：查看本地是否干净、是否和 GitHub 同步、交付包是否还在。

```bash
make sync
```

作用：把本地 `main` 同步到 GitHub 最新状态。只有本地没有未保存改动时才会执行。

```bash
make feature name=subscription-import
```

作用：开始一个新功能分支。`subscription-import` 换成简短英文名即可。

```bash
make verify
```

作用：跑完整检查。它会比较久，但能确认共享包、Android、macOS、Windows 的基础测试都没坏。

## 你以后怎么让我改功能

你可以直接用自然语言说：

- “帮我新增一个功能：……”
- “帮我修复 Windows 打不开的问题。”
- “帮我发布下一个版本。”
- “帮我把当前功能改完并同步到 GitHub。”

我会按专业流程处理：

1. 从干净的 `main` 同步最新代码。
2. 新建 feature/fix 分支。
3. 修改代码和文档。
4. 跑测试和必要构建。
5. 提交到 GitHub。
6. 需要发布时打 tag，让 GitHub Actions 生成三端产物。

## 什么文件不要手动动

不要提交或公开这些内容：

- Android release keystore 原文件
- GitHub Actions 里的 Android 签名 secrets
- 本地临时 `SSRVPN_Android/android/key.properties`
- `dist/`
- `.github/workflows/`
- `packages/ssrvpn_shared/`

其中 Android keystore 是以后 APK 覆盖安装的关键。同一个应用要能升级，
GitHub Release workflow 必须继续使用同一套签名 secrets。本地可以没有
`.jks` 和 `key.properties`。

## 本地和 GitHub 的关系

- 本地项目：你电脑上的工作副本。
- GitHub：云端源码仓库和自动构建平台。
- GitHub Release：正式下载页面。
- `dist/`：本地交付文件夹，不提交进 Git。

专业做法是：源码进 GitHub，安装包进 Release，本地 `dist/` 只保留一份方便你使用。

## 当前发布方式

发布版本时使用与当前源码版本一致的标签，例如：

```bash
git tag -a vX.Y.Z -m "SSRVPN vX.Y.Z"
git push origin vX.Y.Z
```

推送 `v*` 标签后，GitHub 会自动构建：

- Android APK
- macOS DMG
- Windows 安装版 EXE 和便携版 ZIP

正式 tag 构建完成后，Release workflow 还会把同一批已校验产物上传到阿里云
OSS，并在最后一步更新 `ssrvpn/latest.json`。客户端优先读取 OSS，GitHub
Releases 是备用检测与下载源。详细操作见
`docs/OSS_RELEASE_OPERATIONS.zh-CN.md`。

没有 Apple/Microsoft 开发者证书时，macOS 和 Windows 安装包仍会遇到系统安全提示。仓库已提供默认关闭的 Developer ID/notarization 与 Authenticode 自动化，实际启用方法见 `docs/RELEASE_SIGNING.md`；不得把“自动化已准备”写成“当前产物已签名”。Android 可以用免费自签名 keystore，只要每次发布都使用同一个 keystore，用户就能覆盖安装升级。

## 历史归档分支

2026-07-02 清理前的本地旧改动曾保存到：

`archive/local-unreviewed-20260702`

该记录不保证远端分支仍存在，也不是当前备份状态。日常开发从 `main` 或
`feature/*` 分支开始；需要依赖归档内容前先重新验证远端分支。
