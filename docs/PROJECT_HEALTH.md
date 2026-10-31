# SSRVPN 项目健康与发布状态

> 历史发行说明：6.0.0 之前的公开发行附件按保留策略清理；本文旧版本链接指向保留的源码标签，验收记录与摘要仅用于历史追溯。

最近更新：2026-10-28

当前应用版本：`v6.0.13`

最新正式版本：[GitHub Releases 当前正式版](https://github.com/Elegying/SSRVPN/releases/latest)

## 2026-10-24：6.0.5 发布准备

版本统一为 `6.0.5+6007`，包含已合入 main 的维护及覆盖率门禁加固。本次版本提交
不修改客户端连接、恢复或安装归属逻辑；对外更新说明为“优化稳定性，提升连接体验。”。
维护者决定停止剩余双端生命周期验收并发布，Windows UAC 取消仍不测。已完成与未执行
范围见 [真机验收矩阵](UAT_MATRIX.md)，不能将自动化通过表述为完整真机验收通过。
公开状态以顶部正式版入口及精确发布 workflow 为准；下方保留 6.0.3 的历史证据。

## 2026-10-23：6.0.3 正式发布与验证状态

[稳定版 v6.0.3](https://github.com/Elegying/SSRVPN/releases/tag/v6.0.3) 已公开，版本
`6.0.3+6005`，不可变 tag 固定在 `5ea4c59cba3aa73ec1978f0da4569a60a9df60d8`。
[PR #342](https://github.com/Elegying/SSRVPN/pull/342) 经受保护流程合并；
[最终 PR CI](https://github.com/Elegying/SSRVPN/actions/runs/39919846992) 14 项通过，
[精确 main CI](https://github.com/Elegying/SSRVPN/actions/runs/39923978950) 13 项通过，
仅限 PR 的 Dependency review 在 push 事件按配置跳过。

本机 `verify-all.sh` 在 `5c97a3c81dfa907ed1ae59c7cb73f5c6279e69df` 完整串行重跑通过；
其后只更新维护记录，生产与测试代码未变。首次并发运行的大缓存回滚超时记录保留，
没有放宽断言或时限。客户端可靠性专项在 `e425495828f5b08db5ba6e3ceb4bdfce6acdfebc`
通过 409 项、跳过 7 项；该提交与发布提交的完整 Git tree 一致。目标平台 main CI 的结果如下：

| 包与执行环境 | 通过 / 跳过 | 行覆盖率 |
| --- | ---: | ---: |
| 共享 / Ubuntu 24.04 | 2520 / 14 | 91.86% |
| Android / Ubuntu 24.04 | 447 / 0 | 74.20% |
| macOS / macOS 15 arm64 | 388 / 0 | 77.13% |
| Windows / Windows Server 2025 x64 | 689 / 6 | 75.52% |

Android 与 macOS 原生测试、Windows 原生/PowerShell 5.1 和隔离安装故障矩阵通过，
并核对实际日志。本机 macOS 上的 Windows 跳过项不算 Windows 通过。修复后的最终差异与
调用路径已单独复审，覆盖会话隔离、错误传播、数据保留、失败回滚及安全边界，无新的
未解决发现；这是同一维护代理的独立复审步骤，不声称外部人工审计。

[Prepare Release](https://github.com/Elegying/SSRVPN/actions/runs/39928588386) 与
[Release](https://github.com/Elegying/SSRVPN/actions/runs/39928652505) 全部完成。
公开后的 APK、DMG、EXE 从 GitHub、OSS 版本化路径及固定下载入口独立匿名完整下载，
SHA-256、大小、sidecar、provenance、不可变 Release 身份和更新清单一致；三份 GitHub
构建证明按精确工作流、tag 与提交验证通过。结构 smoke 和
[公开 Windows EXE 隔离安装验收](https://github.com/Elegying/SSRVPN/actions/runs/39932333916)
通过，三端调试符号及发行资产已归档。构建证明不替代 Apple 公证或 Microsoft 发行证书。

本轮范围为三端日常稳定性与可用性，主动断网和读屏专项不执行。候选阶段的覆盖升级、
数据保留、20 轮正常连接/断开、快速取消、节点与订阅操作、窗口/托盘及连接/断开各
30 分钟资源观察按精确候选记录，正式包安装后另做启动和联网复验，详见
[真机矩阵](UAT_MATRIX.md)。历史“不发布”描述仅代表当时阶段，未把旧候选记录改写成
正式包重新执行过的结果。最低系统、其他 OEM、16 KiB Android 硬件、真实 UAC 取消、
睡眠及其他未覆盖交互仍单列；不据此宣称所有系统或完整三端矩阵全部通过。

## 历史记录

更早的验证与候选记录保留在 [Git 历史快照](https://github.com/Elegying/SSRVPN/blob/4e9678472a67518b5a97f1db3e6c60345a586b49/docs/PROJECT_HEALTH.md)。具体公开版本与变更以 [CHANGELOG](../CHANGELOG.md) 和对应 Release 为准；旧测试记录不代表当前提交已重新通过验证。
