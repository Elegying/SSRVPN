# 项目健康状态

最近审查：2026-08-01<br>
当前应用版本：`v4.0.1`；公开发布状态与产物以 [GitHub Release](https://github.com/Elegying/SSRVPN/releases/latest) 为准。<br>
审查基线：PR [#79](https://github.com/Elegying/SSRVPN/pull/79) 完成全仓审查与整改，PR [#74](https://github.com/Elegying/SSRVPN/pull/74) 和 [#80](https://github.com/Elegying/SSRVPN/pull/80) 完成后续依赖与资产维护；最终以受保护 `main` 提交 `c49994f` 的 [CI run 30702261603](https://github.com/Elegying/SSRVPN/actions/runs/30702261603) 为准。

## 综合结论与评分

**综合评分：90/100（优秀，可继续维护；不等同于零风险）。**

| 维度 | 分数 | 当前证据 |
| --- | ---: | --- |
| 功能正确性与失败恢复 | 91 | 三端连接状态、取消、核心退出、代理/TUN 所有权和回滚均有行为测试 |
| 安全与隐私 | 92 | 凭据分平台保护、日志脱敏、最小化 macOS Release 权限、秘密扫描和依赖审查 |
| 架构与可维护性 | 87 | 共享领域逻辑与平台原生边界清晰；仍有少数高复杂度生命周期热点 |
| 测试与 CI | 93 | 四套覆盖率、三端原生门禁、发布故障注入、目标平台构建与安装烟雾 |
| 文档与项目治理 | 92 | 40 份受版本控制 Markdown 自动校验，ADR、贡献、Issue/PR 和发布边界对齐 |
| 性能与可观测性 | 85 | 有界诊断与离线关键路径基线已具备；真机启动/连接阶段数据仍可扩展 |

评分依据是当前源码、测试、构建配置、文档、GitHub 安全设置和本轮实测，不把测试数量或覆盖率单独当作质量。当前没有发现已知 P0-P1；剩余风险主要是目标平台人工证据、上游 Android 工具链迁移以及高复杂度 OS 生命周期代码。

## 本轮完成的优化

- 质量门禁：314 个受版本控制 Dart 文件全部纳入格式检查，全部 Shell 脚本纳入 ShellCheck；共享包和三端启用 `strict-casts`、`strict-inference`、`strict-raw-types`，analyzer 为 0 issue。
- macOS 安全：Release 移除 `get-task-allow`、JIT、未签名可执行内存和禁用库校验权限；真实 `flutter build macos --release` 后的最终 `codesign` 权限已核对，决策记录在 [ADR-009](decisions/009-macos-release-entitlement-minimization.md)。
- Android 日志：VPN 启动超时清理只记录异常类型，不输出可能携带敏感上下文的异常正文；原生测试通过。
- Windows 生命周期：补充未初始化启动、启动禁用和进程身份失败路径，关键生命周期覆盖率由原 4% 级门槛提高到 20%。
- Windows 原生恢复：增加真实 C++ 注册表恢复测试，使用进程级 `RegOverridePredefKey` 沙箱验证有效日志精确恢复、损坏日志失败关闭；GitHub Windows runner 已实际编译运行。
- 重复代码：启动器与窗口宿主的当前用户 SID 查询收敛为同一原生实现，保持既有用户边界。
- 供应链：Pull Request 增加固定提交的 GitHub Dependency Review，中等及以上新增已知漏洞阻止合并；Dependency Graph、漏洞告警、私有漏洞报告和 SPDX SBOM 作为仓库基线。
- 文档治理：文档门禁从手工 29 份扩展为自动枚举全部 40 份受版本控制 Markdown；历史 CHANGELOG 只检查链接，39 份当前文档还检查已知陈旧结论与危险发布命令。
- 仓库入口：README、安全/贡献/维护/测试/路线图/排障、ADR、Issue 与 PR 模板已经对齐当前 4.x 行为和验证入口。

## 当前验证证据

2026-08-01 在 macOS 26.5.2、Flutter 3.44.1 的当前分支执行：

```bash
make verify
```

结果：

- 文档 40/40 本地链接检查、39/39 当前状态检查通过；314 个 Dart 文件格式与全部 ShellCheck 通过。
- 核心资产、版本、包指南、产品表面、结构边界、桌面安全存储、秘密扫描、免费分发和发布资产守卫通过。
- 发布工具 247/247；macOS TUN/DNS 行为 25/25；workspace analyze 0 issue。
- Shared 覆盖率 `82.48%`（`5184/6285`），门槛 65%。
- Android Flutter 218 项通过，覆盖率 `63.89%`（`2091/3273`），门槛 30%；Gradle/JUnit 构建成功。
- macOS Flutter 243 项通过，覆盖率 `65.54%`（`3285/5012`）；生命周期 `76.91%`（`623/810`），系统代理 `88.36%`（`387/438`）；RunnerTests 通过。
- Windows Flutter 209 项通过，8 项仅限 Windows 主机的测试在 macOS 条件跳过；平台覆盖率 `48.47%`（`2716/5604`），生命周期 `20.68%`（`134/648`）。
- 关键路径 smoke：解析、合并与配置生成结构校验通过；耗时只作同环境观察值，不作为跨机器硬阈值。
- PR #79、#74、#80 的依赖审查、全历史秘密扫描、核心资产、Workspace、Android、macOS、Windows 共 7 项均通过；最终 main CI 再次通过全部适用门禁。Windows runner 还实际完成 C++ 代理恢复测试、PowerShell 5.1 检查、安装器构建、安装/卸载及安装后立即升级 smoke。

## 证据边界与残余风险

- macOS 本地不能编译或运行 Windows C++、PowerShell 5.1、DPAPI、注册表和 Inno Setup；这些自动化路径已由 GitHub Windows runner 证明，但仍不替代真实用户交互、重启、全树强杀和 Narrator 验收。
- Android 原生测试不能替代真实 Xiaomi 上的首次授权、快捷磁贴、后台回收、通知断开、休眠/唤醒和耗电验收。
- 自动化不能替代 TalkBack、VoiceOver、Narrator 的完整人工流程，也不能覆盖所有第三方网络、节点和系统升级组合。
- Android 仍有 `android.builtInKotlin=false`、`android.newDsl=false` 与 KGP 兼容告警。当前 Flutter 插件链仍依赖这些边界；应等待上游支持后以 APK 与原生测试迁移，不为消除告警提前破坏构建。
- 高认知复杂度继续集中在 Android VPN Service、macOS 核心/系统代理生命周期和 Windows 代理恢复。后续只按有行为测试的职责小步拆分，不做大爆炸式重构。
- `https://ssrvpn.vip/` 在本轮实时检查返回 Cloudflare 521。GitHub 仓库 Website 字段不应指向失效入口，恢复官网前需先修复源站并重新验证 HTTPS。

## 已固定的产品边界

- HTTP 订阅兼容策略不变。
- Android 继续使用内置 75 个国内应用直连策略，不增加手动应用选择页。
- Android、macOS、Windows 继续使用 IPv4-only Mihomo 运行配置；Android 与 Windows TUN 捕获并拒绝 IPv6 防止绕过。
- 活动产品表面继续只有首页和订阅；节点编辑沿用既有长按/右键手势，不新增可见入口。
- “私家车”节点延迟与既定排序语义不变。
- macOS 继续免费 ad-hoc、未公证分发；Windows 继续只发布未签名 `SSRVPN_Setup.exe`，不提供便携 ZIP 或付费签名路径。
- Windows 固定每用户 LocalAppData 安装并保留已安装数据，不搜索或合并旧独立副本。

## 下一阶段最高优先级

1. 在真实 Android、macOS、Windows 上完成生命周期、无障碍与网络恢复矩阵，记录系统版本和脱敏证据。
2. 修复 `ssrvpn.vip` 源站 521，确认 HTTPS 和下载入口后再恢复 GitHub Website 链接。
3. 在新增行为时继续提高 Windows 生命周期覆盖率，不把当前 20% 门槛当成完成目标。
4. 等待 Flutter/插件链完整支持 AGP 10 内置 Kotlin 与新 DSL 后，分步移除兼容开关。
5. 修改 Android VPN Service、macOS 核心/系统代理或 Windows 恢复热点时，以行为测试保护的小步职责拆分继续降低复杂度。

## 更新规则

每次更新只记录当前提交上已验证的版本、命令、平台、产物和残余风险。历史审查、旧 Release 或单一绿色命令不得覆盖本文件、[安全策略](../SECURITY.md)、[测试策略](TESTING.md) 与 [文档索引](README.md) 的当前结论。
