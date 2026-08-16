# 项目健康状态

最近审查：2026-08-16<br>
当前应用版本：`v4.0.11`；公开发布状态与产物以 [GitHub Release](https://github.com/Elegying/SSRVPN/releases/latest) 为准。<br>
审查基线：公开版本 `v4.0.3`、提交 `bcca48a` 与 [CI run 30887916321](https://github.com/Elegying/SSRVPN/actions/runs/30887916321) 的三端构建及发布产物已核对；本文所在提交继续以完整本地门禁、对应 Pull Request 检查和合并后 `main` CI 共同作为当前结论。

## 综合结论与评分

**综合评分：91/100（优秀，可继续维护；不等同于零风险）。**

| 维度 | 分数 | 当前证据 |
| --- | ---: | --- |
| 功能正确性与失败恢复 | 91 | 三端连接状态、取消、核心退出、代理/TUN 所有权和回滚均有行为测试 |
| 安全与隐私 | 92 | 凭据分平台保护、日志脱敏、最小化 macOS Release 权限、秘密扫描和依赖审查 |
| 架构与可维护性 | 90 | 更新、macOS 原生支持和 Windows 代理模型形成可检查边界；高风险事务保留原顺序并受增长护栏保护 |
| 测试与 CI | 93 | 四套覆盖率、三端原生门禁、发布故障注入、目标平台构建与安装烟雾 |
| 文档与项目治理 | 92 | 全部受版本控制 Markdown 自动校验，ADR、贡献、Issue/PR 和发布边界对齐 |
| 性能与可观测性 | 85 | 有界诊断与离线关键路径基线已具备；真机启动/连接阶段数据仍可扩展 |

评分依据是当前源码、测试、构建配置、文档、GitHub 安全设置和本轮实测，不把测试数量、覆盖率或文件变短单独当作质量。当前没有发现已知 P0-P1；剩余风险主要是目标平台人工证据、上游 Android 工具链迁移以及仍需真实 OS 故障注入才能继续拆分的生命周期事务。

## 本轮完成的优化

- Google Play 安装恢复：会话 API 与分包配送域名在国内域名和 GeoIP 直连规则之前固定使用同一代理 DNS 与代理出口，避免智能模式的出口分裂导致下载连接被关闭；共享生成器保证三端规则一致。
- Android 状态收敛：原生运行状态连续读取失败时只执行三轮有界复核；仍无法确认则清除会话并标记断开，避免无限轮询和界面长期停留在错误的已连接状态。
- 版本治理：`check-version-sync.sh` 同时校验本健康文档的当前应用版本，版本升级后若忘记更新审查基线会直接阻止门禁通过。
- 可维护性边界：共享更新服务的稳定 façade 从 1534 行收敛为 513 行，下载/取消和校验后发布/恢复分别进入独立 part；公开调用入口、持久化格式、错误语义和发布顺序不变。
- macOS 原生边界：`AppDelegate.swift` 从 2273 行降至 1999 行；核心身份/PID/有界输出与原生 owned-process 值对象进入 `CoreProcessSupport.swift`，安全单实例租约和窗口恢复进入 `ApplicationLifecycleSupport.swift`；代理状态快照和退出租约状态恢复为委托私有实现，Xcode RunnerTests 连续真实编译运行通过。
- Windows 代理边界：系统代理事务入口从 1530 行降至 1432 行；私有快照、取消、恢复动作和原生日志模型迁入同一 Dart library 的 101 行 part，锁、PowerShell 调用、恢复判定和写入顺序未移动，47 项代理专项测试通过。
- 风险控制：新增职责回流和规模门禁，并以 [ADR-010](decisions/010-risk-controlled-maintainability-boundaries.md) 固定渐进拆分规则。Android VPN Service 与 Windows 安装恢复没有为降低行数进行高风险重排，只锁定现有边界并保留目标平台验证要求。
- 质量门禁：317 个受版本控制 Dart 文件全部纳入格式检查，全部 Shell 脚本纳入 ShellCheck；共享包和三端启用 `strict-casts`、`strict-inference`、`strict-raw-types`，analyzer 为 0 issue。
- macOS 安全：Release 移除 `get-task-allow`、JIT、未签名可执行内存和禁用库校验权限；真实 `flutter build macos --release` 后的最终 `codesign` 权限已核对，决策记录在 [ADR-009](decisions/009-macos-release-entitlement-minimization.md)。
- Android 日志：VPN 启动超时清理只记录异常类型，不输出可能携带敏感上下文的异常正文；原生测试通过。
- Windows 生命周期：补充未初始化启动、启动禁用和进程身份失败路径，关键生命周期覆盖率由原 4% 级门槛提高到 20%。
- Windows 原生恢复：增加真实 C++ 注册表恢复测试，使用进程级 `RegOverridePredefKey` 沙箱验证有效日志精确恢复、损坏日志失败关闭；GitHub Windows runner 已实际编译运行。
- 重复代码：启动器与窗口宿主的当前用户 SID 查询收敛为同一原生实现，保持既有用户边界。
- 供应链：Pull Request 增加固定提交的 GitHub Dependency Review，中等及以上新增已知漏洞阻止合并；Dependency Graph、漏洞告警、私有漏洞报告和 SPDX SBOM 作为仓库基线。
- 文档治理：文档门禁已从手工清单扩展为自动枚举全部受版本控制 Markdown；历史 CHANGELOG 只检查链接，其余当前文档还检查已知陈旧结论与危险发布命令。
- 仓库入口：README、安全/贡献/维护/测试/路线图/排障、ADR、Issue 与 PR 模板已经对齐当前 4.x 行为和验证入口。

## 当前验证证据

2026-08-08 在 macOS 26.5.2、Flutter 3.44.1 的当前提交执行：

```bash
make verify
```

结果：

- 文档 43/43 本地链接检查、42/42 当前状态检查通过；317 个 Dart 文件格式与全部 ShellCheck 通过。
- 核心资产、版本、包指南、产品表面、结构边界、桌面安全存储、秘密扫描、免费分发和发布资产守卫通过。
- 发布工具 276/276；macOS TUN/DNS 行为 25/25；workspace analyze 0 issue。
- Shared 全套测试通过，覆盖率 `82.44%`（`5183/6287`），门槛 65%。
- Android Flutter 219 项通过，覆盖率 `64.13%`（`2115/3298`），门槛 30%；Gradle/JUnit 构建成功。
- macOS Flutter 247 项通过，覆盖率 `65.64%`（`3297/5023`）；生命周期 `76.91%`（`623/810`），系统代理 `88.32%`（`378/428`）；RunnerTests 通过。
- Windows Flutter 210 项通过，8 项仅限 Windows 主机的测试在 macOS 条件跳过；平台覆盖率 `48.62%`（`2729/5613`），生命周期 `20.68%`（`134/648`）。
- 关键路径 smoke：解析、合并与配置生成结构校验通过；耗时只作同环境观察值，不作为跨机器硬阈值。
- 上一轮 PR #79、#74、#80、#81 的依赖审查、全历史秘密扫描、核心资产、Workspace、Android、macOS、Windows 共 7 项均通过；`main` CI 再次通过全部适用门禁。Windows runner 还实际完成 C++ 代理恢复测试、PowerShell 5.1 检查、安装器构建、安装/卸载及安装后立即升级 smoke；本轮 Windows 专属结论仍须由对应 PR 与合并后 CI 重新确认。

## 证据边界与残余风险

- macOS 本地不能编译或运行 Windows C++、PowerShell 5.1、DPAPI、注册表和 Inno Setup；这些自动化路径已由 GitHub Windows runner 证明，但仍不替代真实用户交互、重启、全树强杀和 Narrator 验收。
- Android 原生测试不能替代真实 Xiaomi 上的首次授权、快捷磁贴、后台回收、通知断开、休眠/唤醒和耗电验收。
- 自动化不能替代 TalkBack、VoiceOver、Narrator 的完整人工流程，也不能覆盖所有第三方网络、节点和系统升级组合。
- Android 仍有 `android.builtInKotlin=false`、`android.newDsl=false` 与 KGP 兼容告警。当前 Flutter 插件链仍依赖这些边界；应等待上游支持后以 APK 与原生测试迁移，不为消除告警提前破坏构建。
- 高认知复杂度继续集中在 Android VPN Service、macOS 核心/系统代理编排、Windows 生命周期和安装恢复。结构护栏只防止继续膨胀；后续必须先增加目标平台行为证据，再按 ADR-010 小步拆分。
- 官网可用性和下载链路需要独立实时核验；历史网络快照不作为当前状态结论，也不由本次客户端代码修复代替。

## 已固定的产品边界

- HTTP 订阅兼容策略不变。
- Android 继续使用受测试保护的内置国内应用直连策略，不增加手动应用选择页。
- Android、macOS、Windows 继续使用 IPv4-only Mihomo 运行配置；Android 与 Windows TUN 捕获并拒绝 IPv6 防止绕过。
- 活动产品表面继续只有首页和订阅；节点编辑沿用既有长按/右键手势，不新增可见入口。
- “私家车”节点延迟与既定排序语义不变。
- macOS 继续免费 ad-hoc、未公证分发；Windows 继续只发布未签名 `SSRVPN_Setup.exe`，不提供便携 ZIP 或付费签名路径。
- Windows 固定每用户 LocalAppData 安装并保留已安装数据，不搜索或合并旧独立副本。

## 下一阶段最高优先级

1. 在真实 Android、macOS、Windows 上完成生命周期、无障碍与网络恢复矩阵，记录系统版本和脱敏证据。
2. 定期从公开网络和真实浏览器复核官网 HTTPS、下载入口与固定别名到版本化产物的一致性。
3. 在新增行为时继续提高 Windows 生命周期覆盖率，不把当前 20% 门槛当成完成目标。
4. 等待 Flutter/插件链完整支持 AGP 10 内置 Kotlin 与新 DSL 后，分步移除兼容开关。
5. 修改 Android VPN Service、macOS 核心/系统代理或 Windows 恢复热点时，先补故障注入证据，再按 ADR-010 做单职责切片；不以行数下降作为完成标准。

## 更新规则

每次更新只记录当前提交上已验证的版本、命令、平台、产物和残余风险。历史审查、旧 Release 或单一绿色命令不得覆盖本文件、[安全策略](../SECURITY.md)、[测试策略](TESTING.md) 与 [文档索引](README.md) 的当前结论。
