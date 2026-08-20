# 项目健康状态

最近审查：2026-08-20<br>
当前应用版本：`v4.0.14`；公开发布状态与产物以 [GitHub Release](https://github.com/Elegying/SSRVPN/releases/latest) 为准。<br>
`v4.0.14` 候选包含 Windows v4.0.13 实机验收修复、三端订阅筛选/临时延迟排序、订阅编辑、透明磨砂界面，以及连接成功后才访问 GitHub Releases 的应用内更新策略；本地门禁、精确 `main` CI 与正式 Release 资产分别按下文和后续 GitHub 记录核验。上一正式版 `v4.0.13` 的标签、CI、公开资产和实机报告继续保留为历史证据，不能替代本候选验证。

本候选已在 Windows 宿主通过三端 `flutter analyze --fatal-infos`、新增共享交互/编辑定向测试 49 项、GitHub-only 更新检查定向测试 16 项、Android 测试 236 项、Windows 测试 234 项、版本同步、文档、产品界面、敏感信息与 TLS 门禁，并成功生成 Android Release APK 和 Windows Release 可执行文件。ShellCheck 与 macOS 原生权限/生命周期用例及三端正式打包、摘要、provenance、attestation 仍以对应在线 Runner 和 Release 工作流为准。

## 综合结论与评分

**综合评分：93/100（优秀，可持续维护；不等同于零风险或完整全矩阵实机验收）。**

| 维度 | 分数 | 当前证据 |
| --- | ---: | --- |
| 功能正确性与失败恢复 | 92 | 三端连接、取消、核心退出、代理/TUN 所有权与回滚均有行为测试；Windows 新增未初始化和恢复失败关闭覆盖 |
| 安全与隐私 | 95 | 生产 HTTP 客户端不再允许绕过 TLS，秘密/TLS 策略扫描、日志脱敏、本地崩溃报告与发布产物证明边界已固定 |
| 架构与可维护性 | 91 | 共享更新、平台生命周期与原生桥接形成可检查边界；高风险事务保持渐进修改 |
| 测试与 CI | 95 | 完整本地门禁、四套覆盖率、三端原生测试、CodeQL 配置和发布产物证明结构测试通过 |
| 文档与项目治理 | 94 | 文档自动校验、依赖策略、人工 UAT 矩阵、ADR、Issue/PR 与发布边界对齐 |
| 性能与可观测性 | 88 | 有界诊断、带版本与稳定指纹的脱敏崩溃报告、离线关键路径基线具备；真机长期数据仍待采集 |

当前没有发现已知 P0-P1 代码阻断项。残余风险是 v4.0.14 三端正式产物和线上门禁尚待本候选发布流程完成；原生 16 KiB page-size Android 硬件仍待验收。此外，MIUI 12.5 不渲染通知“断开”动作、macOS 持续断网取消专项按用户要求停止，Flutter/Android 上游工具链仍待迁移；这些边界不冒充已执行验收。

## 本轮完成的优化

- 节点页订阅筛选改为透明磨砂选择框，右侧独立按钮只在当前页面切换延迟升序和订阅默认顺序；Android 长按、桌面右键可编辑订阅名称与链接，主页“关于”同步使用共享磨砂表面。
- 三端不再在应用启动或未连接首页检查更新；节点连接成功后只从 `Elegying/SSRVPN` 的正式 GitHub Release 获取元数据、规范资产和 SHA-256。现有 Release 工作流仍同步同一批正式资产到 OSS，OSS 仅保留为网站和人工分发镜像。
- Windows 诊断复制兼容系统换行规范化并脱敏公网 IPv4；连接态节点切换只在真实状态变化时推进代际，TUN 取消反馈与核心安全停止结果绑定。
- 三端订阅下载先使用真实 SSRVPN 标识，只在服务端拒绝或内容不可解析时执行一次有界兼容标识重试；每次响应继续执行 TLS、状态码、大小、编码、DNS 地址与解析安全检查。
- Windows 修复诊断复制假成功、连接中节点切换无效或无反馈、订阅页连接状态不清晰；主动取消与真实启动失败继续使用不同的日志和状态语义。
- 桌面节点页补齐 Escape 幂等关闭、长节点名称关键后缀、国旗无障碍区分和短时结果自动退场；Android 连接中重载保留连接意图并完成订阅输入本地化。
- 移除 Android 更新与订阅 HTTP 客户端的 `allowBadCertificates` 生产旁路；秘密扫描同时阻止该开关和无条件接受坏证书的回调重新进入三端生产源码。
- 本地崩溃报告增加应用版本和基于脱敏内容的稳定指纹；用户目录路径在 macOS、Linux、Windows 三种格式下都会脱敏，仍不自动上传任何诊断数据。
- Windows 生命周期新增未初始化恢复、代理清理不可用和恢复状态路径不可用的失败关闭测试；生命周期覆盖率门槛由 20% 提高到 25%。
- Pull Request CI 增加固定提交版本的 GitHub CodeQL：Actions、Android Java/Kotlin、Windows C/C++；macOS 原生测试迁入独立无注入 XCTest job。发布工作流对 APK、DMG 和 EXE 分别生成 GitHub artifact attestation。
- Android 内嵌核心已归档固定 Mihomo commit/tree、bridge 源码、Go、x/mobile、NDK 和构建配方；校验同时锁定 build info、六个 JNI 导出、AArch64 与全部 ELF `LOAD` 段的 16 KiB 对齐。
- 新增 [依赖升级策略](DEPENDENCIES.md) 与 [三端人工 UAT 矩阵](UAT_MATRIX.md)；安全更新直接升级，原生主版本升级必须经过目标平台构建和生命周期验收。
- 更新可安全落地的依赖；`flutter_secure_storage 11` 因要求 Android `compileSdk 37`，高于当前 Flutter 3.44.1 默认的 36，暂时保留 10.3.1 并记录迁移条件。

## 当前验证证据

2026-08-20 在 macOS 26.5.2、Flutter 3.44.1 的 `v4.0.13` 候选工作区执行：

```bash
make verify
```

结果：

- 文档 47/47 本地链接、46/46 当前状态检查、333 个 Dart 文件格式、全部 ShellCheck、核心资产、版本、秘密与 TLS 策略、发布资产守卫均通过。
- 发布工具 `296/296`；macOS TUN/DNS 行为 `25/25`；workspace `flutter analyze` 为 0 issue。
- Shared `504` 项测试通过，覆盖率 `83.67%`（`5604/6698`），门槛 65%。
- Android Flutter `237` 项及 Gradle/JUnit 通过，覆盖率 `65.06%`（`2197/3377`），门槛 30%。
- macOS Flutter `259` 项及 RunnerTests 通过，覆盖率 `65.93%`（`3389/5140`）；生命周期 `77.20%`（`633/820`），系统代理 `88.06%`（`391/444`）。
- Windows Flutter `223` 项通过；仅 Windows 主机可运行的 8 项在 macOS 条件跳过。平台覆盖率 `50.28%`（`2892/5752`），生命周期 `26.48%`（`174/657`），门槛 25%。
- 关键路径 smoke 通过；本机观察值为解析中位数 `6881 us`、合并 `31379 us`、配置生成 `43483 us`，只用于同环境回归，不作为跨机器硬阈值。

### 正式发布与线上验收

- `v4.0.13` 标签精确指向 `aa157395f87959696ad21e6a5d894f54c400cb82`；标签前 `main` CI `32304327190` 与正式 Release `32305723229` 全部通过，公开 Release 为非草稿、非预发布且是 `latest`。
- GitHub Release 包含 APK、DMG、EXE、三个 SHA-256 文件和发布来源清单。正式资产 SHA-256：APK `51217ff044fcfdafe53f5d3dbac7dbf5871fb570e30a52e068185b506ee389c7`，DMG `0ddba41cf224a3fe4a0aac39a80a32354f8eec9ba6748ab46ebdbf439b9ef8bf`，Windows 安装器 `50d803295e7f3947893eb1351b743f41f1bb23dac4838b8d77ee95dbebc0b3f2`。
- 三端公开资产均通过随附 SHA-256、provenance 和 `refs/tags/v4.0.13` artifact attestation 验证；匿名 GitHub 下载返回成功，Windows runner 完成安装器构建及安装/卸载 smoke。
- OSS `latest.json` 已指向 `4.0.13`；不可变版本路径与网站固定下载别名重新下载后均与 GitHub Release 摘要一致。官网 macOS 页面继续明确仅支持 Apple M 系列芯片、不支持 Intel Mac。

## 证据边界与残余风险

- Android 17 已完成 v4.0.13 修复项增量实机复验；Windows 11 报告基线完成覆盖安装、数据保留、连接和断开，但报告后修复的三项行为尚未使用最终正式安装器人工复验。未重复的长时、耗电和完整压力矩阵继续保持未执行。
- 候选、版本准备、合并后 `main`、标签前精确 `main`、发布专用 CI 和正式 Release 已分别建立提交证据；发布结论不复用旧版本绿色 run。
- macOS 本机不能执行 Windows C++、PowerShell 5.1、DPAPI、注册表和 Inno Setup；最终源码和安装器已由 Windows CI 覆盖，不能将这些自动化结果表述为修复后的 Windows 人工实机验收。
- macOS 持续断网恢复期间出现过一次可恢复的应用内取消失败报告；因用户明确停止该故障注入，本轮不继续断网实测，也不把该专项标记为通过。正常连接、短时中断恢复、断开、DNS/路由/代理恢复和退出均通过。
- 当前 Android 核心已固定源码提交与树、bridge、Go/x/mobile/NDK、build info、JNI ABI、16 KiB ELF 对齐和内容寻址资产；源码重建会因临时本地 replacement 路径产生不同字节哈希，因此不宣称字节级确定性构建。下次替换仍必须完成目标 Android 真机生命周期回归。
- Android 仍有旧 Kotlin/Gradle 兼容开关；`flutter_secure_storage 11` 和更高 `compileSdk` 应随 Flutter 工具链升级共同迁移，不能只为追新版本破坏可构建性。
- 自动化不能覆盖所有 OEM、系统升级、第三方网络和节点组合；崩溃报告仍依赖用户主动复制，不具备远程聚合、趋势统计或告警能力。

## 已固定的产品边界

- HTTP 订阅固定先发送真实产品标识，兼容重试最多一次；任何重试都不得放宽 TLS、DNS 地址、响应大小、编码或解析安全边界。
- Android 继续使用受测试保护的内置国内应用直连策略，不增加手动应用选择页。
- 三端继续使用 IPv4-only Mihomo 运行配置；Android 与 Windows TUN 捕获并拒绝 IPv6，避免绕过。
- 活动产品表面继续只有首页和订阅；节点编辑沿用长按/右键入口。
- macOS 继续免费 ad-hoc、未公证分发；Windows 继续只发布未签名安装器，不引入付费签名依赖。
- 更新检查只在节点连接成功后通过 GitHub Releases 进行；发现新版只在底部版本号后提示“发现新版本 立即更新”，用户点击后才进入现有更新页。

## 下一阶段最高优先级

1. 后续按 [UAT 矩阵](UAT_MATRIX.md)补充长时、耗电、完整压力和 macOS 持续断网专项；不把本轮未执行项目写成已通过。
2. 在原生 16 KiB page-size Android 设备上补充安装、连接、真实流量和断开验收；当前设备页大小为 4 KiB，只能证明产物结构兼容。
3. 随 Flutter 工具链升级统一迁移 Android Kotlin/Gradle 兼容开关、`compileSdk` 和 `flutter_secure_storage`，保持目标平台构建与生命周期验收。

## 更新规则

每次更新只记录当前工作区或精确提交上已验证的版本、命令、平台、产物和残余风险。历史 Release、旧 CI 或单一绿色命令不得覆盖本文件、[安全策略](../SECURITY.md)、[测试策略](TESTING.md) 与 [文档索引](README.md) 的当前结论。
