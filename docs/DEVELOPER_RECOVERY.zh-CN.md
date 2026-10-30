# 重装系统后恢复开发与发布

这份手册面向原仓库维护者。源码、测试、固定依赖记录和发布工作流在
`Elegying/SSRVPN`；Android 正式签名及私有构建配置通过独立的私有备份仓库恢复。
主要本地步骤以 Apple Silicon macOS 为例。正式三端安装包仍由 GitHub Actions 的
Linux、macOS、Windows 运行器构建，不依赖旧电脑、旧安装包或本机构建缓存。

## 1. 重装前确认恢复入口

- 保持原 GitHub 账号可登录，并能完成双因素认证；恢复码保存在系统盘以外。
- 提交并推送需要保留的源码。`git status --short` 为空只表示源码工作区干净，
  不表示忽略的签名文件、私有配置、订阅或客户端数据已经备份。
- 确认能访问私有仓库 [SSRVPN-Recovery](https://github.com/Elegying/SSRVPN-Recovery)。
  它保存 age 加密的 keystore、密码、别名和私有构建查询配置；`manifest.json`
  记录密文摘要、正式证书摘要及备份来源，解密身份保存在该仓库的
  Actions Secret `RECOVERY_IDENTITY`，不写进 Git 历史。
- 私有备份仓库的 `Restore developer configuration` 工作流只允许原仓库所有者
  从 `main` 手动运行。恢复时它会将备份重新加密给新电脑临时生成的公钥，
  Artifact 中只有密文，保留 1 天；永久备份位于私有仓库的 `archive/`。
- 备份完成后先实际运行一次第 3 节的恢复命令，再重装。保留私有仓库和
  `RECOVERY_IDENTITY`；只有密文、没有对应解密身份无法恢复。

这套备份覆盖本机重装，不覆盖整个 GitHub 账号同时丢失。需要应对账号丢失时，
另外把密文和解密身份分别放入独立加密备份介质。应用里的订阅、节点、设置和
运行数据也不属于源码或签名备份，需要按自己的数据保留要求另外保存。

## 2. 安装新系统的开发工具

先安装 Xcode 和 Command Line Tools，打开 Xcode 完成首次组件安装与许可确认。
安装 Homebrew 后准备基础工具：

```bash
brew install git gh mise python age shellcheck cocoapods
mise install flutter@3.44.1
mise install java@temurin-17
mise install go@1.20.14 go@1.25.11 go@1.26.5
gh auth login
```

Flutter 必须使用 `.fvmrc` 固定的 **3.44.1**。JDK 使用 **17**。
三个 Go 版本分别用于重建仓库固定的不同平台核心，不用默认最新版替代。
Python 使用 3.12 或更高版本。

安装 Android Studio，通过 SDK Manager 安装 Android SDK Command-line Tools。
macOS 的默认 SDK 路径如下；如果安装时选了其他路径，请相应调整：

```bash
export JAVA_HOME="$(mise where java@temurin-17)"
export ANDROID_HOME="$HOME/Library/Android/sdk"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
"$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" --licenses
"$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" \
  "platform-tools" "platforms;android-36" "build-tools;36.0.0" \
  "ndk;28.2.13676358"
```

把所需环境变量加入自己的 shell 配置，重新打开终端后确认仍然有效。
运行 `mise exec flutter@3.44.1 -- flutter doctor -v`，解决准备开发的平台所报的
工具链问题。Windows 本地开发另需 Visual Studio 的 C++ 桌面开发组件和
Inno Setup，按 [Windows 构建说明](../SSRVPN_Windows/README.md) 准备；
macOS 上的检查不能替代 Windows 原生与安装器验收。

## 3. 拉取源码与恢复正式签名

以下操作使用同一个原维护者 GitHub 账号。两个仓库都必须是已有仓库，不重新创建或分叉：

```bash
mkdir -p "$HOME/Projects"
gh repo clone Elegying/SSRVPN "$HOME/Projects/SSRVPN"
gh repo clone Elegying/SSRVPN-Recovery "$HOME/Projects/SSRVPN-Recovery"
git -C "$HOME/Projects/SSRVPN" switch main
git -C "$HOME/Projects/SSRVPN" pull --ff-only origin main

mise exec java@temurin-17 -- python3 \
  "$HOME/Projects/SSRVPN-Recovery/recovery.py" restore \
  --project "$HOME/Projects/SSRVPN"
```

恢复脚本读取 GitHub 上的正式证书摘要，用临时公钥申请加密恢复包，并验证
keystore 的证书、存储密码、私钥密码及一次实际签名。验证通过后才写入：

| 文件 | 用途 |
| --- | --- |
| `SSRVPN_Android/android/ssrvpn-release.jks` | 与现有正式 APK 相同的 Android 私钥 |
| `SSRVPN_Android/android/key.properties` | Gradle 使用的本机绝对路径、别名和签名密码 |
| `config/ssrvpn-private-defines.json` | 本地构建使用的账号查询配置 |

三个文件均被 Git 忽略，macOS 上权限为 `0600`。密码不打印到终端。
如果目标已有不同内容、出现符号链接、证书不匹配或解密失败，脚本会停止并保留原文件。
不要用 `git add -f` 提交这些文件，也不要通过修改证书摘要来绕过身份不一致。
恢复失败时先查看工作流链接并核对私有仓库权限和工具是否齐全；不要重新生成正式签名。

`config/ssrvpn-usage-defines.json` 中公开的查询服务列表为空。
本地要包含与正式版一致的账号用量和设备数功能，应显式传入恢复后的
`ssrvpn-private-defines.json`。正式 Release 工作流会从原仓库的 Secret
`SSRVPN_USAGE_PROVIDERS` 生成同一类私有配置。

## 4. 恢复依赖、核心资产并验证

在新拉取的项目根目录执行：

```bash
cd "$HOME/Projects/SSRVPN"
mise exec flutter@3.44.1 -- flutter pub get --enforce-lockfile
make assets
bash scripts/verify-core-assets.sh
mise exec flutter@3.44.1 -- make verify
git status --short
```

`make assets` 可能从固定源码重建三端定制核心，因此前面的 Android SDK、NDK、
JDK 和 Go 准备也适用于主要开发 macOS 的机器。缺少旧缓存只会增加首次下载和
构建时间，不需要从旧电脑复制缓存。核心和 GeoIP 必须通过仓库记录的 SHA-256
校验，不能用上游官方核心替代。固定资源详见 [核心资产来源](CORE_ASSETS.md)。

共享测试应在 `packages/ssrvpn_shared` 运行；三端测试在各自包目录运行。
`make verify` 提供统一入口。环境恢复验收以命令实际通过为准，不能把“拉取成功”
或“恢复了签名”记为完整编译、真机连接或跨平台验收通过。

macOS 本地启动示例：

```bash
cd "$HOME/Projects/SSRVPN/SSRVPN_MacOS"
mise exec flutter@3.44.1 -- flutter run -d macos \
  --dart-define-from-file=../config/ssrvpn-private-defines.json
```

Android 开发先用 `flutter devices` 确认设备，再在 `SSRVPN_Android` 目录执行
同样携带私有配置的 `flutter run`。Debug 包使用独立应用标识；需要验证正式签名
APK 时，构建命令为：

```bash
cd "$HOME/Projects/SSRVPN/SSRVPN_Android"
mise exec flutter@3.44.1 -- flutter build apk --release \
  --target-platform android-arm64 \
  --dart-define-from-file=../config/ssrvpn-private-defines.json
```

此处只生成本地验证包。对外正式安装包继续使用下一节的现有发布流程。

## 5. 继续维护与发布更新

1. 从最新 `main` 建立功能或修复分支，完成修改、相关测试和 PR。
2. 发版时同步三端版本号、递增构建号，并按现有规范更新变更日志；运行
   `bash scripts/check-version-sync.sh`。版本修改也先经 PR 合入 `main`。
3. 核对原仓库的 GitHub Actions 设置：四项 `ANDROID_KEY*` 签名 Secret、
   `SSRVPN_USAGE_PROVIDERS`、`BRANCH_PROTECTION_READ_TOKEN`、两项
   `ALIYUN_OSS_ACCESS_KEY_*` Secret，以及正式证书摘要和三项 OSS Variable。
   重装本机不会删除它们；令牌过期或云端凭据被撤销仍需维护。
4. 按 [发布检查清单](RELEASE_CHECKLIST.zh-CN.md) 在 GitHub Actions 运行
   **Prepare Release**，输入与源码版本一致的新 tag，等待精确 `main` CI 校验
   和其调度的 **Release**。不要自行绕过准备流程创建或移动正式 tag。
5. 在 `release` 环境需要审批时完成审批。确认三端构建、Android 固定签名校验、
   GitHub Release 与 OSS 发布事务全部成功。
6. 运行 `bash scripts/check-release-assets.sh vX.Y.Z`，并按发布清单检查安装包、
   SHA-256、构建证明与目标平台启动、覆盖升级行为。

Android 后续版本必须保持同一正式签名；新电脑自动生成的 debug keystore 不能
替代它。macOS 继续使用 ad-hoc 签名、未公证，Windows 继续未签名分发。
备份与系统重装不会改变这些产品决策。

## 6. 恢复材料的维护

私有备份保存的是某次已校验快照，后续修改私有查询配置时应另做新快照并实测恢复。
原项目的 Secrets 是现行发布配置，私有备份不是自动同步服务。
OSS 凭据和分支保护读取令牌继续保存在原仓库；它们不包含在本地签名恢复包中。
不要删除 `core-assets-v1` / `core-assets-v2` 构建资源发行记录、正式版本 tag、私有备份仓库或其解密 Secret。
需要离开 GitHub 独立恢复时，还应另外保存固定资源及离线解密材料。
