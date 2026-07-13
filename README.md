# SSRVPN

[![CI](https://github.com/Elegying/SSRVPN/actions/workflows/ci.yml/badge.svg)](https://github.com/Elegying/SSRVPN/actions/workflows/ci.yml)

SSRVPN 是一个面向 Android、macOS 和 Windows 的 Flutter VPN 客户端。三端共享订阅解析、节点模型、路由策略、配置生成和更新校验，原生 VPN、系统代理、托盘与安装流程各自留在平台目录。

本 Monorepo 是唯一开发入口；历史平台仓库和旧审查报告只用于追溯，不代表当前能力。

## 用户先看

| 平台 | 发布产物 | 连接方式 | 当前分发限制 |
| --- | --- | --- | --- |
| Android | `SSRVPN.apk` | 系统 VPN | 当前正式包仅含 arm64 核心 |
| macOS | `SSRVPN.dmg` | 系统代理；TUN 每次连接需管理员授权 | 未配置 Developer ID / notarization |
| Windows | `SSRVPN_Setup.exe`、便携版 `SSRVPN.zip` | 系统代理、TUN | 未配置 Authenticode 签名 |

首次使用：

1. 只从本仓库 Release 或官网固定下载地址获取安装包，并校验随包 SHA256。
2. 安装并打开 SSRVPN，导入订阅链接或节点链接。
3. 等待刷新与测速完成，选择可用节点后连接。
4. 以首页连接状态和系统 VPN/代理状态为准；遇到问题先断开再重试，不要公开粘贴原始订阅或日志中的凭据。

完整操作说明见 [公共用户指南](docs/USER_GUIDE.zh-CN.md)，平台安装与权限差异见：

- [Android 指南](SSRVPN_Android/USER_GUIDE.md)
- [macOS 指南](SSRVPN_MacOS/USER_GUIDE.md)
- [Windows 指南](SSRVPN_Windows/USER_GUIDE.md)
- [故障排查](docs/TROUBLESHOOTING.zh-CN.md)

三端均生成 IPv4/IPv6 双栈配置；公网 IPv6 是否可用取决于本地网络与节点。首页公网 IP 固定显示 IPv4，它不是 IPv6 连通性检测结果。

macOS TUN 的管理员授权只代表本机用户同意本次提权。当前 ad-hoc 包不能让 macOS 验证发布者身份；正式商用分发仍应采用 Developer ID、公证以及受审计的最小权限 helper 或 Network Extension。

## 仓库结构

```text
SSRVPN/
├── packages/ssrvpn_shared/    # 三端共享模型、服务、策略与测试
├── SSRVPN_Android/            # Flutter UI、Android VPN Service 与快捷磁贴
├── SSRVPN_MacOS/              # Flutter UI、系统代理、授权 TUN 与 DMG 打包
├── SSRVPN_Windows/            # Flutter UI、系统代理、TUN、安装版与便携版
├── docs/                      # 当前文档、决策记录与历史审查材料
└── scripts/                   # 验证、资源、发布与维护脚本
```

## 开发与验证

推荐使用 Flutter `3.44.1` 或兼容 stable 版本。Android 构建还需要 Android SDK、NDK 与 JDK；macOS 需要 Xcode；Windows 需要 Visual Studio 2022 的“使用 C++ 的桌面开发”工作负载，安装器还需要 Inno Setup 6。

根目录统一入口：

```bash
make verify
```

它会检查版本与资源、边界守卫、密钥扫描、发布工具、依赖解析、静态分析、四套 Flutter 测试、Android 原生测试和覆盖率门槛。日常可按需执行：

```bash
scripts/workspace.sh pub-get
scripts/workspace.sh analyze
scripts/workspace.sh test
scripts/check-secrets.sh
scripts/performance-baseline.sh
```

行为、持久化、进程、系统代理、TUN 或打包发生变化时，还要在目标平台运行对应构建或安装冒烟；macOS 不能替代真实 Windows 的安装、升级和卸载验证。

## 发布

匹配 `v*` 的 tag 会触发 GitHub Actions 构建并上传三端产物及 SHA256。发布前必须保持 `main`、版本号、CHANGELOG 与资产清单一致，并在发布后重新下载校验。

详细流程见 [发布检查清单](docs/RELEASE_CHECKLIST.zh-CN.md)、[签名说明](docs/RELEASE_SIGNING.md) 与 [OSS 运维手册](docs/OSS_RELEASE_OPERATIONS.zh-CN.md)。

## 文档与安全

[文档索引](docs/README.md) 区分当前规范、维护手册、架构决策与历史审查。项目状态以当前代码、自动验证和该索引中的有效文档为准。

不要在日志、Issue、PR、截图或崩溃报告中泄露订阅 URL、API secret、Bearer token、节点密码、服务端凭据或签名材料。安全问题请按 [SECURITY.md](SECURITY.md) 私下报告。

## 许可证

MIT License
