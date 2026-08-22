# SSRVPN 项目健康与发布状态

最近更新：2026-08-22

当前应用版本：`v4.0.16`（[正式 Release](https://github.com/Elegying/SSRVPN/releases/tag/v4.0.16)）

版本基线提交：`f85135ad5f50908982fa31a94cdb527f1b3d958c`

## 当前结论

`v4.0.16` 已完成正式发布，不再是候选版本。标签、`main`、三端构建、GitHub Release、
SHA-256、发布证明和 OSS 同步均已闭环；终审未发现需要回滚或紧急热修的 P0、P1、P2
代码缺陷。当前项目达到正式发布质量，综合评分为 **92/100（A级）**。

本文件只记录当前状态和仍需跟进的证据边界。版本变更明细以
[CHANGELOG](../CHANGELOG.md) 为准，硬性产品约束以
[项目硬性规则](PRODUCT_REQUIREMENTS.zh-CN.md) 为准，完整能力以
[功能列表](FEATURES.zh-CN.md) 为准。

## 发布证据

| 项目 | 当前结果 |
| --- | --- |
| 源码、远端与标签 | `HEAD = origin/main = v4.0.16 = f85135ad5f50908982fa31a94cdb527f1b3d958c` |
| 版本同步 | `scripts/check-version-sync.sh` 通过，版本为 `4.0.16+4016` |
| 精确 `main` CI | [run 32565194924](https://github.com/Elegying/SSRVPN/actions/runs/32565194924) 成功 |
| 正式 Release workflow | [run 32565752097](https://github.com/Elegying/SSRVPN/actions/runs/32565752097) 成功 |
| GitHub Release | 非草稿、非预发布，公开资产共 7 项 |
| 正式安装包 | `SSRVPN.apk`、`SSRVPN.dmg`、`SSRVPN_Setup.exe` |
| 完整性与来源 | 三个 `.sha256`、`SSRVPN-release-provenance.json` 和 GitHub Attestations 均已验证 |
| OSS 公共通道 | `latest.json`、版本化对象与固定下载地址已核对为 `4.0.16` |
| 仓库安全告警 | 终审时 Code Scanning、Secret Scanning、Dependabot 开放安全告警均为 0 |

以上发布证据绑定 `v4.0.16` 的精确提交和正式资产。后续文档提交不会改变已经发布的
二进制；下一版本仍须重新执行全部门禁，不能继承本表结论。

## 质量评分

| 维度 | 得分 | 主要依据 |
| --- | ---: | --- |
| 功能正确性与失败恢复 | 19/20 | 三端连接、取消、切换、核心退出、代理/TUN 所有权与回滚均有行为验证；外部可达性观察不负责断开连接 |
| 安全、隐私与供应链 | 19/20 | 订阅和更新输入有界，日志与诊断脱敏，进程和系统设置按所有权处理，正式资产可校验来源 |
| 架构与可维护性 | 17/20 | 共享领域逻辑和平台集成边界清楚；少数生命周期与安装事务仍是受规模护栏保护的热点 |
| 测试与 CI | 19/20 | 九项受保护检查、四套 Flutter 测试、三端原生/平台门禁和渐进覆盖率门槛通过 |
| 发布工程 | 11/12 | 自动准备、不可变标签、精确 SHA、Draft/OSS/公开事务、失败恢复和发布后终验形成闭环 |
| 文档与治理 | 7/8 | README、用户指南、安全策略、ADR、UAT 和维护手册齐全；发布后状态需要持续及时回填 |
| **综合** | **92/100** | **正式发布质量；非零风险，不等同于完整三端人工实机矩阵** |

## 自动化验证摘要

- Release tooling：376 项通过。
- Shared：641 项通过，行覆盖率 84.62%。
- Android Flutter：275 项通过，行覆盖率 67.84%；Android 原生测试和 CodeQL 通过。
- macOS Flutter：281 项通过，行覆盖率 67.30%；原生 RunnerTests 通过。
- Windows Flutter：268 项通过，行覆盖率 55.68%；原生恢复、安装器构建、安装和卸载 smoke 通过。
- 分支保护要求严格提交同步、管理员不可绕过、禁止 force-push/删除，并固定九项必需检查。

## 当前证据边界

以下项目是尚未补齐的人工或长期证据，不是已经确认的客户端故障：

1. `v4.0.16` 没有重新执行完整三端人工实机矩阵；自动化和旧版本真机记录不能替代当前版本实机 UAT。
2. Windows 11 仍需人工复验 Explorer 可见性、UAC 取消，以及应用内更新安装包成功安装后的自动清理体验。
3. Android 仍缺原生 16 KiB page-size 硬件，以及长时、Doze、不同 OEM 和同口径电量复测。
4. macOS 持续断网后的取消专项仍未执行；免费 ad-hoc、未公证分发属于既定边界。
5. Windows 未签名安装器属于既定免费分发边界；SmartScreen 提示不能由 SHA-256 完全替代。
6. 崩溃与诊断默认只保存在本机，没有自动遥测、集中聚合或趋势告警。

完整人工流程和历史证据见 [UAT 矩阵](UAT_MATRIX.md)。

## 可维护性重点

- Windows 与 macOS 生命周期、Windows 安装事务、Android VPN Service 继续按
  [ADR-010](decisions/010-risk-controlled-maintainability-boundaries.md) 渐进拆分；不得只为减少行数改变事务顺序或所有权边界。
- 新增连接、提交、停止、取消或恢复分支时，先增加行为测试，并同步提高对应关键文件覆盖率门槛。
- Flutter、Gradle、Kotlin 和插件兼容升级按 [依赖策略](DEPENDENCIES.md) 独立处理，不在正式发版当天临时追新。

## 下一阶段优先级

1. 按 [UAT 矩阵](UAT_MATRIX.md) 补齐 Windows 安装更新、Android 长时/电量和 macOS 故障注入证据。
2. 在原生 16 KiB page-size Android 设备上验证安装、连接、真实流量和断开清理。
3. 在新增行为证据保护下逐步降低生命周期热点复杂度并提高关键文件覆盖率。
4. 每次正式发布后立即回填版本、精确提交、CI、Release、资产和剩余证据边界。

## 更新规则

- 当前状态必须绑定精确版本、提交、工作流和公开资产；历史 Release 或旧 CI 不能替代当前证据。
- 自动化、构建 smoke、人工实机和线上公开资产分别记录，不互相冒充。
- 已完成的用户变化写入 [CHANGELOG](../CHANGELOG.md)，未完成事项写入 [ROADMAP](ROADMAP.md)。
- 规则变化必须同步 [项目硬性规则](PRODUCT_REQUIREMENTS.zh-CN.md)、相关 ADR、测试和三端用户指南。
