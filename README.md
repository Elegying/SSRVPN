<div align="center">

# SSRVPN

**Android · macOS · Windows**

开源的跨平台代理客户端。导入自己的订阅，用一致的界面管理节点、连接与分流。

[![Latest Release](https://img.shields.io/github/v/release/Elegying/SSRVPN?display_name=tag&sort=semver)](https://github.com/Elegying/SSRVPN/releases/latest)
[![CI](https://github.com/Elegying/SSRVPN/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/Elegying/SSRVPN/actions/workflows/ci.yml?query=branch%3Amain)
[![License: MIT + third-party](https://img.shields.io/badge/License-MIT%20%2B%20third--party-22c55e.svg)](#许可证)

[下载安装](#下载) · [界面预览](#界面预览) · [使用指南](docs/USER_GUIDE.zh-CN.md) · [文档中心](docs/README.md) · [反馈问题](SUPPORT.md)

</div>

SSRVPN 使用 Flutter 构建界面，基于带 SSRVPN 流量统计扩展的 Mihomo 核心提供代理能力。首页查看连接与流量，订阅页管理节点，设置页调整外观和常用选项。

本项目只提供客户端，不提供代理节点或订阅服务。请准备兼容的订阅链接或节点链接；支持的协议和平台差异见[功能列表](docs/FEATURES.zh-CN.md)。

## 下载

| 平台 | 系统要求 | 最新安装包 |
| --- | --- | --- |
| Android | Android 7.0+，arm64-v8a | [下载 APK](https://github.com/Elegying/SSRVPN/releases/latest/download/SSRVPN.apk) |
| macOS | macOS 13+，仅支持 Apple M 系列芯片 | [下载 DMG](https://github.com/Elegying/SSRVPN/releases/latest/download/SSRVPN.dmg) |
| Windows | Windows 10/11，x64 | [下载安装器](https://github.com/Elegying/SSRVPN/releases/latest/download/SSRVPN_Setup.exe) |

以上链接始终指向最新正式版。查看[更新记录](CHANGELOG.md)或打开 [Release 页面](https://github.com/Elegying/SSRVPN/releases/latest)获取 SHA-256 校验文件与构建来源证明。`core-assets-v1` 是构建资源记录，不是客户端安装包。

macOS 安装包采用 ad-hoc 签名、未经公证；Windows 安装器未签名。首次打开时可能出现 Gatekeeper 或 SmartScreen 提示，详情见[安装与使用指南](docs/USER_GUIDE.zh-CN.md)。

## 界面预览

Android 5.0.1 实机截图：已连接主页与节点选择页，公网 IPv4 已遮挡。截图中的节点和延迟仅用于展示。

<p align="center">
  <img src="docs/assets/ssrvpn-product-preview.jpg" alt="SSRVPN 5.0.1 Android 主页：连接状态、当前节点与实时流量" width="320">
  <img src="docs/assets/ssrvpn-node-preview.jpg" alt="SSRVPN 5.0.1 Android 节点选择页：代理模式、网站分流与节点延迟" width="320">
</p>

## 快速开始

1. 下载并安装对应平台的客户端。
2. 打开“订阅”，导入订阅链接或节点链接。
3. 等待节点导入完成，按需手动测速并选择节点。
4. 返回主页，点击连接，并按系统提示完成授权。

Android 使用系统 VPN；macOS 和 Windows 支持系统代理与 TUN。详细步骤见[使用指南](docs/USER_GUIDE.zh-CN.md)。

## 主要功能

| 能力 | 说明 |
| --- | --- |
| 订阅管理 | 支持单独刷新或全部刷新；失败时保留已有节点，当前连接节点配置未变时无需重连。 |
| 节点选择 | 按订阅查看节点，手动选择分组或多个节点测速；重启后复用已保存的延迟。延迟不代表下载速度。 |
| 智能分流 | 根据规则选择直连或代理，也可填写强制直连、强制代理的网站；Android 另有应用分流。 |
| 连接与流量 | 查看真实连接状态、公网 IPv4、上传下载速率和本次代理累计流量；桌面窗口失焦后仍保持刷新。 |
| 外观设置 | 四档液态玻璃特效，内置壁纸、纯色和自定义图片；动态背景默认关闭。 |
| 日常设置 | 自定义代理端口、检查更新、查看运行日志，设置保存在本机。 |
| 问题诊断 | 用简明中文说明失败原因，支持展开技术详情和复制包含版本、平台的脱敏报告。 |

### 怎么选择连接模式？

- **智能模式**：按规则分流，国内目标直连，需要代理及未知目标通过节点访问。
- **全局模式**：通过选中的代理节点访问。
- **桌面端系统代理 / TUN**：系统代理适用于遵循系统代理设置的应用；需要接管更多应用流量时可使用 TUN，并按提示完成系统授权。

外部探测未通过时，结果保留在诊断页和日志中，首页继续显示真实连接状态。核心退出、系统 VPN 停止等明确故障仍会提醒。

### IPv6 能用吗？

支持 IPv4 / IPv6 双栈，两类流量遵循同一套分流规则。代理目标能够恢复域名时优先尝试 IPv4，并在有限时间内尝试备用地址。

直连 IPv6 需要本地网络支持；只有 IPv6 的网站如果需要走代理，则需要节点提供 IPv6 出口。代理失败不会自动改为直连，也不能把只有 IPv6 的网站转换成 IPv4。

更多能力与限制见[完整功能列表](docs/FEATURES.zh-CN.md)。

## 帮助与隐私

连接或订阅遇到问题时，先查看[故障排查](docs/TROUBLESHOOTING.zh-CN.md)，也可以从应用日志入口打开“诊断与运行日志”，按提示定位问题。需要反馈时请阅读[获取帮助](SUPPORT.md)。

SSRVPN 不内置遥测，不自动上传日志；订阅、节点、设置和运行日志默认保存在本机。应用主要会为订阅更新、版本检查、内置基线及受审查通道的路由规则刷新、DNS 解析、连通性检查、公网 IPv4 展示及代理连接发起必要的网络请求。

诊断报告默认脱敏，分享前仍请检查内容，不要公开订阅链接、节点密码或其他个人信息。安全漏洞请按[安全政策](SECURITY.md)私下报告。

## 参与开发

项目使用 Flutter 构建界面，三端共用 `packages/ssrvpn_shared` 中的业务逻辑，系统 VPN、代理与安装流程由各平台实现。

开发环境固定为 Flutter **3.44.1**。配置好对应平台的工具链后，在仓库根目录运行：

```bash
make verify
```

验证入口会检查工具链版本、资源、静态分析、测试和覆盖率。平台构建与安装仍需在对应环境验证。

| 目录 | 职责与构建入口 |
| --- | --- |
| [`packages/ssrvpn_shared`](packages/ssrvpn_shared/README.md) | 共享模型、订阅解析、配置生成与策略 |
| [`SSRVPN_Android`](SSRVPN_Android/README.md) | Flutter / Kotlin、系统 VPN 与 APK |
| [`SSRVPN_MacOS`](SSRVPN_MacOS/README.md) | Flutter / Swift、系统代理、TUN 与 DMG |
| [`SSRVPN_Windows`](SSRVPN_Windows/README.md) | Flutter / C++、系统代理、TUN 与安装器 |

发布通过受保护 PR、合并提交 CI 和正式工作流完成；公开安装包带 SHA-256、provenance 与 GitHub 构建证明。自动化结果和实机验证的边界分别记录在项目健康状态中。

- [贡献指南](CONTRIBUTING.md) · [测试说明](docs/TESTING.md)
- [发布检查清单](docs/RELEASE_CHECKLIST.zh-CN.md) · [免费分发与签名说明](docs/RELEASE_SIGNING.md)
- [项目状态](docs/PROJECT_HEALTH.md) · [路线图](docs/ROADMAP.md) · [全部文档](docs/README.md)

## 许可证

SSRVPN 自有代码采用 [MIT License](LICENSE)。内置 Mihomo、Android Mihomo 分支和 GeoIP 数据库遵循各自许可证，详见[第三方许可清单](third_party/THIRD_PARTY_NOTICES.md)。

使用和参与项目时，请遵守[可接受使用政策](ACCEPTABLE_USE.md)与[社区行为准则](CODE_OF_CONDUCT.md)。重新分发或修改版本请阅读[名称与官方版本说明](TRADEMARKS.md)。

<details>
<summary>免责声明与使用责任</summary>

SSRVPN 是开源网络客户端，供合法授权的网络连接、管理与技术研究使用。本项目不提供代理节点、订阅或国际联网接入服务，也不授权或鼓励任何违法用途。

使用者应遵守所在地及使用行为适用的法律法规。在中国境内使用时，应遵守网络安全、数据安全及计算机信息网络国际联网等相关规定，依法使用获准的网络接入服务，不得利用本软件从事违法跨境联网、未经授权的访问、传播违法信息或侵害他人权益等活动。开源、免费或用于学习研究，不代表具体使用行为当然合法。

软件按[许可证](LICENSE)以“现状”提供。在适用法律允许的范围内，开发者和贡献者不对软件的适用性、持续可用性或使用结果作出保证；使用者应依法对自身的配置、接入服务和使用行为负责。**本声明不排除或限制任何依法不得免除的责任，也不能替代所需的许可、批准或法律义务。**

对具体使用或分发方式的合法性有疑问时，请事先咨询具备相应资质的法律专业人士。另见[可接受使用政策](ACCEPTABLE_USE.md)。

</details>
