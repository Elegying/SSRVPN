---
name: ssrvpn-codebase
description: SSRVPN 项目维护技能——修改、优化、审查、重构本仓库代码前必读。提供「改 X 找哪个文件」的文件地图、架构分层与 part/mixin 边界、全部数字门禁（行数/覆盖率上限与当前余量）与分层验证工作流，使 AI 不必每次重新探索仓库。触发词：改/优化/重构/审查 SSRVPN、SSRVPN 架构、哪个文件、门禁、verify-all、代码库结构。
agent_created: true
---

# SSRVPN 代码库认知与改动导航

省掉「每次重新探索仓库」。**动手前按顺序**：定位文件 → 核对门禁 → 改 → 分层验证。

## 0. 项目一句话

Flutter 单仓（`ssrvpn_workspace`）跨平台 Mihomo(Clash Meta) 客户端，三端 Android/macOS/Windows 共享 `packages/ssrvpn_shared`，各端只留平台壳与原生桥；核心是带 SSRVPN 流量统计扩展的**定制 mihomo**（`native/proxy_traffic/` 补丁），不是官方原版。

## 1. 四条硬约束（违反会被门禁直接打回）

1. **Flutter 钉死 3.44.1**（`.fvmrc`）。`mise exec flutter@3.44.1 -- <命令>`；或用 fvm / 官方 SDK / asdf 切到 3.44.1。版本不对 `check-flutter-version.sh` 直接 exit 1——PATH 上的默认 Flutter 常是别的版本。
2. **测试必须在包目录跑**：`cd <REPO_ROOT>/packages/ssrvpn_shared && flutter test`。仓库根跑会因 CWD 相对 fixture（`test/fixtures/...`、`../../SSRVPN_MacOS/assets/...`、`../../config/...`）假报十几个失败。`<REPO_ROOT>` = 仓库根（含 `pubspec.yaml` 的 `ssrvpn_workspace`）。
3. **数字门禁卡得死**：多处余量个位数行，**加几行就炸**。改 `clash_service*`、`desktop_home_*_part`、`settings_service`、`subscription_*`、`update_*` 前先查 `references/guardrails.md` 的「当前 vs 上限」对照表。守卫 `raise SystemExit` **遇错即停**，验证要一次性算完所有数值。⚠️ 实测值是快照，动手前 `wc -l` 复核。
4. **定制内核不可换官方版**：流量统计、首页与常驻通知的代理用量、私家车流量、设备数全依赖 `GET /ssrvpn/traffic`，换官方内核**静默失效**。`verify-core-assets.sh` SHA-256 fail-closed 校验，**不得跳过或放宽**。

## 2. 改动流程

1. **定位**：查 `references/file-map.md` 的「改 X 找哪里」表，找不到再 Grep。
2. **确认边界**：`references/architecture.md`（哪些属 shared、哪些留平台侧；part/mixin/extension 可见性）。
3. **核对门禁**：`references/guardrails.md`（行数/覆盖率上限 + 当前余量对照，🚨 标零/紧余量）。
4. **改**。契约参数写调用点，别塞进可选参数默认值（Dart 默认值由被调实现解析，覆写/测试替身会静默改掉）。
5. **验证**：按 `references/verification.md` 分层跑。改动涉及跨端复制的逻辑时，顺手核对三端副本有没有漂移（老毛病）。

## 3. 知识索引

| 文件 | 内容 | 什么时候读 |
|---|---|---|
| `references/file-map.md` | 「改 X 找哪里」、三端目录职责、native 分工 | 每次动手前 |
| `references/architecture.md` | 分层、part/mixin 可见性、上游分歧、安全信任链 | 改共享/跨端/原生逻辑 |
| `references/guardrails.md` | 全部数字门禁 + 余量对照 | 改动前预判撞墙 |
| `references/verification.md` | verify-all 步骤全表、分层命令、踩坑 | 验证/排查假失败 |

## 4. 已知技术债（别当新发现）

- YAML 根段落提取现统一委托 `utils/yaml_section.dart`；运行时 `proxies` 继续通过 `buildProxiesText` 执行可运行节点过滤与规范化。引号、嵌套键、CRLF 和多行文本由共享回归覆盖，不再保留四份扫描器。
- Android 补丁相对上游缺 `ssrvpnStartupProviders`/`loadProvider` 同步，根因是三端用三个不同上游（见 architecture.md）。
- Windows `launcher_main.cpp` 的 `MakeSafeDisconnectVisible` 跨进程 `WM_SETTEXT` 依赖窗口标题，脆弱。

## 5. 改完之后

- 用户可见变化写根 `CHANGELOG.md`，未完成项写 `ROADMAP.md`。
- **不要往 `docs/` 新增一次性审查报告**（`docs/README.md` 明确禁止，证据留在提交/Issue/PR）。
- 引用历史结论前必须在当前提交重跑对应测试。
