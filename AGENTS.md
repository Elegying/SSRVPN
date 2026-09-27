# SSRVPN 维护指南（AI Agent 必读）

维护、修改、审查本仓库任何代码前，**必须先完整读取**项目维护技能：

`.workbuddy-ai/skills/ssrvpn-codebase/SKILL.md`（含 `references/` 下 file-map / architecture / guardrails / verification 四份）。

该技能是唯一事实源：含「改 X 找哪个文件」地图、架构分层与 part/mixin 边界、全部数字门禁（行数/覆盖率上限与当前余量）与分层验证工作流。以下是最关键的 4 条硬约束摘要（细节以技能为准）：

1. **Flutter 钉死 3.44.1**（`.fvmrc`）。用 `mise exec flutter@3.44.1 -- <命令>`（或 fvm / 官方 SDK / asdf）；版本不对 `check-flutter-version.sh` 直接 exit 1。
2. **测试必须在包目录跑**：`cd packages/ssrvpn_shared && flutter test`。仓库根跑会因 CWD 相对 fixture 假报十几个失败。
3. **数字门禁卡得死**：多处行数上限余量个位数（如 `desktop_connection_coordinator.dart` 188/188 零余量）。改 `clash_service*` / `desktop_home_*_part` / `settings_service` / `subscription_*` / `update_*` 前先查 `references/guardrails.md` 的「当前 vs 上限」表，并 `wc -l` 复核（快照会随代码变动）。
4. **定制内核不可换官方版**：流量统计、代理用量、私家车流量、设备数全依赖 `GET /ssrvpn/traffic`，换官方内核**静默失效**；`verify-core-assets.sh` 按 SHA-256 fail-closed 校验，**不得跳过或放宽**。

全量门禁：`bash scripts/verify-all.sh`（复刻 CI 全部步骤）。完整验证步骤与踩坑记录见技能的 `references/verification.md`。
