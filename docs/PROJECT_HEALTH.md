# 项目健康状态

最近审查：2026-08-18<br>
当前应用版本：`v4.0.12`；公开发布状态与产物以 [GitHub Release](https://github.com/Elegying/SSRVPN/releases/latest) 为准。<br>
本轮客户端候选提交 `47bfbea` 已由 [PR #119](https://github.com/Elegying/SSRVPN/pull/119) 的 [CI run 32047401097](https://github.com/Elegying/SSRVPN/actions/runs/32047401097) 完成 10 项检查，并通过 Android 11、Android 17、Apple M 系列 macOS 与 Windows 11 增量实机复验。版本与文档准备提交仍须通过新的 PR 检查、合并后精确 `main` CI 和正式 Release workflow，才能构成 v4.0.12 发布证据。

## 综合结论与评分

**综合评分：93/100（优秀，可持续维护；不等同于零风险或已完成实机验收）。**

| 维度 | 分数 | 当前证据 |
| --- | ---: | --- |
| 功能正确性与失败恢复 | 92 | 三端连接、取消、核心退出、代理/TUN 所有权与回滚均有行为测试；Windows 新增未初始化和恢复失败关闭覆盖 |
| 安全与隐私 | 95 | 生产 HTTP 客户端不再允许绕过 TLS，秘密/TLS 策略扫描、日志脱敏、本地崩溃报告与发布产物证明边界已固定 |
| 架构与可维护性 | 91 | 共享更新、平台生命周期与原生桥接形成可检查边界；高风险事务保持渐进修改 |
| 测试与 CI | 95 | 完整本地门禁、四套覆盖率、三端原生测试、CodeQL 配置和发布产物证明结构测试通过 |
| 文档与项目治理 | 94 | 文档自动校验、依赖策略、人工 UAT 矩阵、ADR、Issue/PR 与发布边界对齐 |
| 性能与可观测性 | 88 | 有界诊断、带版本与稳定指纹的脱敏崩溃报告、离线关键路径基线具备；真机长期数据仍待采集 |

当前没有发现已知 P0-P1 发布阻断项。残余风险是 MIUI 12.5 不渲染通知“断开”动作、macOS 持续断网取消专项按用户要求停止、Android 内嵌核心仍缺少可定位源码提交，以及 Flutter/Android 上游工具链迁移；这些都没有改变本轮正常连接、断开和资源恢复结论。

## 本轮完成的优化

- 移除 Android 更新与订阅 HTTP 客户端的 `allowBadCertificates` 生产旁路；秘密扫描同时阻止该开关和无条件接受坏证书的回调重新进入三端生产源码。
- 本地崩溃报告增加应用版本和基于脱敏内容的稳定指纹；用户目录路径在 macOS、Linux、Windows 三种格式下都会脱敏，仍不自动上传任何诊断数据。
- Windows 生命周期新增未初始化恢复、代理清理不可用和恢复状态路径不可用的失败关闭测试；生命周期覆盖率门槛由 20% 提高到 25%。
- Pull Request CI 增加固定提交版本的 GitHub CodeQL：Actions、Android Java/Kotlin、Windows C/C++；macOS 原生测试迁入独立无注入 XCTest job。发布工作流对 APK、DMG 和 EXE 分别生成 GitHub artifact attestation。
- Android 内嵌核心新增 Go build info 自动验证，锁定模块、Go 版本、构建模式、标签、平台和架构；同时明确现有二进制只能做到字节级复现，不能冒充源码级可重建。
- 新增 [依赖升级策略](DEPENDENCIES.md) 与 [三端人工 UAT 矩阵](UAT_MATRIX.md)；安全更新直接升级，原生主版本升级必须经过目标平台构建和生命周期验收。
- 更新可安全落地的依赖；`flutter_secure_storage 11` 因要求 Android `compileSdk 37`，高于当前 Flutter 3.44.1 默认的 36，暂时保留 10.3.1 并记录迁移条件。

## 当前验证证据

2026-08-18 在 macOS 26.5.2、Flutter 3.44.1 的候选工作区执行：

```bash
make verify
```

结果：

- 文档 47/47 本地链接、46/46 当前状态检查、327 个 Dart 文件格式、全部 ShellCheck、核心资产、版本、秘密与 TLS 策略、发布资产守卫均通过。
- 发布工具 `291/291`；macOS TUN/DNS 行为 `25/25`；workspace `flutter analyze` 为 0 issue。
- Shared `489` 项测试通过，覆盖率 `83.00%`（`5347/6442`），门槛 65%。
- Android Flutter `233` 项及 Gradle/JUnit 通过，覆盖率 `64.96%`（`2175/3348`），门槛 30%。
- macOS Flutter `257` 项及 RunnerTests 通过，覆盖率 `65.77%`（`3356/5103`）；生命周期 `77.20%`（`633/820`），系统代理 `88.06%`（`391/444`）。
- Windows Flutter `219` 项通过；仅 Windows 主机可运行的 8 项在 macOS 条件跳过。平台覆盖率 `49.99%`（`2853/5707`），生命周期 `26.56%`（`174/655`），门槛 25%。
- 关键路径 smoke 通过；本机观察值为解析中位数 `5833 us`、合并 `29497 us`、配置生成 `40219 us`，只用于同环境回归，不作为跨机器硬阈值。
- Android Release APK 构建成功，大小约 31.0 MB，SHA-256 为 `8109c0fbf8d6ff0d09fbe0c184e69d486fd04ff04938727c5c77b64a71cb10ca`。
- macOS 正式打包脚本确认应用与内嵌核心均为 arm64，并完成最终 ad-hoc 重签、`codesign --verify --deep --strict` 与 DMG CRC 校验；版本化 DMG SHA-256 为 `76e1341175a2c95880a5ebcccc5cfca1ab7ba81598a2f5c8d893e9220f78c4e7`。

以上 APK 与 DMG 是本地验证中间产物，不是公开发布资产。

## 证据边界与残余风险

- 本轮 Android 11、Android 17、Apple M 系列 macOS 与 Windows 11 已完成针对修复项的增量实机复验；未重复已确认的长时、耗电和完整 20/50 轮压力矩阵，自动化和快速实机证据不冒充未执行项目。
- PR #119 的精确候选 CI 已通过；版本与文档准备提交、合并后 `main` 和正式发布资产必须重新建立各自证据，不复用旧绿色 run。
- macOS 本机不能执行 Windows C++、PowerShell 5.1、DPAPI、注册表和 Inno Setup；这些已由 Windows CI 和候选安装器实机覆盖安装、数据保留、连接与断开复验补充。
- macOS 持续断网恢复期间出现过一次可恢复的应用内取消失败报告；因用户明确停止该故障注入，本轮不继续断网实测，也不把该专项标记为通过。正常连接、短时中断恢复、断开、DNS/路由/代理恢复和退出均通过。
- 当前 Android 核心可验证固定二进制、补丁与 build info，但 build info 仅显示本地替换路径，没有上游源码提交。下次替换核心必须同时归档受审源码提交、构建命令、Go/NDK 环境、ABI 与生命周期回归证据。
- Android 仍有旧 Kotlin/Gradle 兼容开关；`flutter_secure_storage 11` 和更高 `compileSdk` 应随 Flutter 工具链升级共同迁移，不能只为追新版本破坏可构建性。
- 自动化不能覆盖所有 OEM、系统升级、第三方网络和节点组合；崩溃报告仍依赖用户主动复制，不具备远程聚合、趋势统计或告警能力。

## 已固定的产品边界

- HTTP 订阅兼容策略不变。
- Android 继续使用受测试保护的内置国内应用直连策略，不增加手动应用选择页。
- 三端继续使用 IPv4-only Mihomo 运行配置；Android 与 Windows TUN 捕获并拒绝 IPv6，避免绕过。
- 活动产品表面继续只有首页和订阅；节点编辑沿用长按/右键入口。
- macOS 继续免费 ad-hoc、未公证分发；Windows 继续只发布未签名安装器，不引入付费签名依赖。
- 更新检查只在底部版本号后提示“发现新版本 立即更新”，用户点击后才进入现有更新页。

## 下一阶段最高优先级

1. 版本与文档准备提交通过 PR 检查后合并，复验精确 `main`，再由 `Prepare Release` 创建不可变标签并启动正式线上构建。
2. 发布后重新下载 APK、DMG、EXE，核对 SHA256、GitHub attestation、OSS `latest.json` 与官网固定下载入口。
3. 后续按 [UAT 矩阵](UAT_MATRIX.md)补充长时、耗电、完整压力和 macOS 持续断网专项；不把本轮未执行项目写成已通过。
4. 为 Android 内嵌核心建立源码仓库、固定提交和可复现构建流水线，再替换当前只能字节级验证的二进制。

## 更新规则

每次更新只记录当前工作区或精确提交上已验证的版本、命令、平台、产物和残余风险。历史 Release、旧 CI 或单一绿色命令不得覆盖本文件、[安全策略](../SECURITY.md)、[测试策略](TESTING.md) 与 [文档索引](README.md) 的当前结论。
