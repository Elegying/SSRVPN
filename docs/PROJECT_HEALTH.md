# 项目健康状态

最近审查：2026-08-17<br>
当前应用版本：`v4.0.11`；公开发布状态与产物以 [GitHub Release](https://github.com/Elegying/SSRVPN/releases/latest) 为准。<br>
公开基线：提交 `3f791d9`、[main CI run 31980010536](https://github.com/Elegying/SSRVPN/actions/runs/31980010536) 与 [Release run 31980486396](https://github.com/Elegying/SSRVPN/actions/runs/31980486396) 均成功。本文新增优化仍在本地工作区，尚未提交、推送或发布；其线上结论必须由后续 Pull Request、目标平台 CI 与合并后 `main` CI 重新建立。

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

当前没有发现已知 P0-P1 阻断项。主要未决风险是三端人工 UAT、Windows 目标 runner 对本地修改的复核、Android 内嵌核心缺少可定位源码提交，以及 Flutter/Android 上游工具链迁移。

## 本轮完成的优化（本地、未提交）

- 移除 Android 更新与订阅 HTTP 客户端的 `allowBadCertificates` 生产旁路；秘密扫描同时阻止该开关和无条件接受坏证书的回调重新进入三端生产源码。
- 本地崩溃报告增加应用版本和基于脱敏内容的稳定指纹；用户目录路径在 macOS、Linux、Windows 三种格式下都会脱敏，仍不自动上传任何诊断数据。
- Windows 生命周期新增未初始化恢复、代理清理不可用和恢复状态路径不可用的失败关闭测试；生命周期覆盖率门槛由 20% 提高到 25%。
- Pull Request CI 增加固定提交版本的 GitHub CodeQL：Actions、Android Java/Kotlin、macOS Swift、Windows C/C++；发布工作流对 APK、DMG 和 EXE 分别生成 GitHub artifact attestation。
- Android 内嵌核心新增 Go build info 自动验证，锁定模块、Go 版本、构建模式、标签、平台和架构；同时明确现有二进制只能做到字节级复现，不能冒充源码级可重建。
- 新增 [依赖升级策略](DEPENDENCIES.md) 与 [三端人工 UAT 矩阵](UAT_MATRIX.md)；安全更新直接升级，原生主版本升级必须经过目标平台构建和生命周期验收。
- 更新可安全落地的依赖；`flutter_secure_storage 11` 因要求 Android `compileSdk 37`，高于当前 Flutter 3.44.1 默认的 36，暂时保留 10.3.1 并记录迁移条件。

## 当前验证证据

2026-08-17 在 macOS 26.5.2、Flutter 3.44.1 的当前本地工作区执行：

```bash
make verify
```

结果：

- 文档 47/47 本地链接、46/46 当前状态检查、321 个 Dart 文件格式、全部 ShellCheck、核心资产、版本、秘密与 TLS 策略、发布资产守卫均通过。
- 发布工具 `286/286`；macOS TUN/DNS 行为 `25/25`；workspace `flutter analyze` 为 0 issue。
- Shared 全套测试通过，覆盖率 `82.84%`（`5281/6375`），门槛 65%。
- Android Flutter `231` 项及 Gradle/JUnit 通过，覆盖率 `65.07%`（`2152/3307`），门槛 30%。
- macOS Flutter `250` 项及 RunnerTests 通过，覆盖率 `65.52%`（`3314/5058`）；生命周期 `77.20%`（`633/820`），系统代理 `88.32%`（`378/428`）。
- Windows Flutter `214` 项通过；仅 Windows 主机可运行的 8 项在 macOS 条件跳过。平台覆盖率 `49.29%`（`2776/5632`），生命周期 `26.56%`（`174/655`），新门槛 25%。
- 关键路径 smoke 通过；本机观察值为解析中位数 `7555 us`、合并 `32670 us`、配置生成 `42559 us`，只用于同环境回归，不作为跨机器硬阈值。
- Android Release APK 构建成功，大小约 31.0 MB，SHA-256 为 `64ad128f3f5bec51221fa2c1f6cc061c6837505b68b9f9a72df64f5cca668f4e`。
- macOS 正式打包脚本完成最终 ad-hoc 重签、`codesign --verify --deep --strict` 与 DMG CRC 校验；版本化 DMG SHA-256 为 `af4d943b3d55367fef2ae5b08ebb6980a4cf6e665ef07ee157ab5ebf332150fc`。

以上 APK 与 DMG 是本地验证中间产物，不是公开发布资产。

## 证据边界与残余风险

- 按本轮范围没有执行 Android、macOS、Windows 物理设备人工 UAT；[UAT 矩阵](UAT_MATRIX.md)保持未执行状态，自动化和构建成功不替代真实连接、重启、休眠、网络切换、无障碍及长时间稳定性验收。
- 当前修改尚未推送，因此新增 CodeQL 和 artifact attestation 只完成配置、语法与结构测试，尚无 GitHub 运行结果；不得引用 v4.0.11 的旧绿色 run 为新修改背书。
- macOS 本机不能执行 Windows C++、PowerShell 5.1、DPAPI、注册表和 Inno Setup；后续必须由 Windows runner 重新完成原生测试、安装、升级和卸载 smoke。
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

1. 获得提交/推送授权后，通过 Pull Request 运行新增 CodeQL、三端 CI 与 Windows 安装器 smoke；合并后再次验证精确 `main` 提交。
2. 按 [UAT 矩阵](UAT_MATRIX.md)在真实 Android、macOS、Windows 上完成连接循环、网络恢复、更新、无障碍、内存与耗电验收。
3. 为 Android 内嵌核心建立源码仓库、固定提交和可复现构建流水线，再替换当前只能字节级验证的二进制。
4. 随 Flutter 稳定工具链升级 Android `compileSdk`、Kotlin/Gradle 配置和 `flutter_secure_storage`，每一步保留 APK 与原生回归证据。
5. 继续扩展 Windows 生命周期和真实 OS 故障注入覆盖；不把当前 25% 门槛当作完成目标。

## 更新规则

每次更新只记录当前工作区或精确提交上已验证的版本、命令、平台、产物和残余风险。历史 Release、旧 CI 或单一绿色命令不得覆盖本文件、[安全策略](../SECURITY.md)、[测试策略](TESTING.md) 与 [文档索引](README.md) 的当前结论。
