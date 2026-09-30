# 验证工作流与踩坑记录

## 1. 分层验证（按成本从低到高，别一上来就跑全量）

```bash
ROOT="$(git rev-parse --show-toplevel)"    # 仓库根目录，随克隆位置自动适应

# ① 静态检查（单包）
cd $ROOT/packages/ssrvpn_shared && dart analyze

# ② 格式（analyze 不查格式！）
dart format --output=none --set-exit-if-changed .

# ③ 单包测试（必须在包目录里跑，见第 3 节）
cd $ROOT/packages/ssrvpn_shared && flutter test

# ④ 覆盖率门槛（省得跑全量）
cd $ROOT && python3 scripts/check_coverage_thresholds.py

# ⑤ 相关守卫（改了什么就跑哪个）
bash scripts/check-clash-service-boundaries.sh
bash scripts/check-desktop-startup-guards.sh
bash scripts/check-version-sync.sh

# ⑥ 全量
bash scripts/verify-all.sh
```

## 2. `verify-all.sh` 步骤全表（`set -euo pipefail`，**遇错即停**）

顺序即权威，照抄自 `scripts/verify-all.sh`：

| # | 步骤 | 命令 | 条件 |
|---|---|---|---|
| 1 | Flutter toolchain version | `scripts/check-flutter-version.sh` | |
| 2 | Shared barrel imports | `scripts/check-shared-barrel-imports.sh` | |
| 3 | Version sync | `scripts/check-version-sync.sh` | |
| 4 | Bundled smart-routing rules | `python3 scripts/verify-smart-rules.py` | |
| 5 | Rule publication review tests | `python3 -m unittest discover -s rule-channel -p test_publish.py` | |
| 6 | Package guides | `scripts/check-package-guides.sh` | |
| 7 | Documentation consistency | `scripts/check-doc-consistency.sh` | |
| 8 | Workspace pub get | `flutter pub get --enforce-lockfile` | |
| 9 | Source formatting and shell lint | `scripts/check-quality-hygiene.sh` | |
| 10 | Core asset bootstrap model | `scripts/check-core-asset-bootstrap.sh` | |
| 11 | Core asset bootstrap | `scripts/bootstrap-core-assets.sh` | |
| 12 | Core binary assets | `scripts/verify-core-assets.sh` | |
| 13 | Production routing on real core | `python3 scripts/check-routing-core.py` | **Darwin only** |
| 14 | Dual-stack forwarding on real core | `python3 scripts/check-core-dual-stack.py` | **Darwin only** |
| 15 | Dual-stack encrypted protocol paths | `python3 scripts/check-core-dual-stack-protocols.py` | **Darwin only** |
| 16 | Imported SS plugin and HY2 traffic | `python3 scripts/check-imported-protocol-traffic.py --restls` | **Darwin only** |
| 17 | Android native bridge guards | `scripts/check-android-native-bridge-guards.sh` | |
| 18 | Android built-in Kotlin guard | `scripts/check-android-built-in-kotlin.sh` | |
| 19 | Three-page product surface guards | `scripts/check-product-surface-guards.sh` | |
| 20 | Desktop startup guards | `scripts/check-desktop-startup-guards.sh` | |
| 21 | Clash service boundaries | `bash scripts/check-clash-service-boundaries.sh` | |
| 22 | Desktop secure storage guards | `scripts/check-desktop-secure-storage.sh` | |
| 23 | macOS core privilege guards | `scripts/check-macos-core-privileges.sh` | |
| 24 | macOS TUN DNS transaction tests | `scripts/test-macos-tun-dns-transaction.sh` | |
| 25 | Windows launcher security | `scripts/check-windows-launcher-security.sh` | |
| 26 | Imported SS plugin and HY2 traffic | `python3 scripts/check-imported-protocol-traffic.py --core SSRVPN_Windows/assets/mihomo.exe` | **Windows only** |
| 27 | Windows native proxy recovery fault harness | `powershell.exe ... scripts/test_windows_native_proxy_recovery.ps1` | **Windows only** |
| 28 | Secret scan | `scripts/check-secrets.sh` | |
| 29 | Release tooling tests | `scripts/test-release-tooling.sh` | |
| 30 | Critical-path performance smoke | `scripts/check-performance-baseline.sh` | |
| 31 | Workspace analyze | `scripts/workspace.sh analyze` | |
| 32 | Shared tests | `scripts/run-flutter-coverage.sh packages/ssrvpn_shared` | |
| 33 | Shared coverage thresholds | `scripts/check-coverage-thresholds.sh packages/ssrvpn_shared` | |
| 34-36 | 三端各自：tests → （Android/macOS 加原生单测）→ coverage thresholds | `run-flutter-coverage.sh <app>`、`check-coverage-thresholds.sh <app>` | 循环 |

原生单测：`scripts/test-android-native.sh`（Android 之后）、`scripts/test-macos-native.sh`（macOS 之后）。
Windows **没有**对应的原生单测步骤。

⚠️ **注意两个名字很像但不同的脚本**：
- `scripts/check-coverage-thresholds.sh`（**连字符**，verify-all 用的入口）
- `scripts/check_coverage_thresholds.py`（**下划线**，Python 实现，含阈值常量，可单独跑）

⚠️ `make assets` **不在** verify-all 里——那是发版清单第 6 步的命令。verify-all 用的是 `bootstrap-core-assets.sh` + `verify-core-assets.sh`。

## 3. 踩过的坑（照抄能省半小时）

### 测试必须在包目录里跑
`proxy_option_validation_test.dart:72` 读 `test/fixtures/proxy_option_cases.json`、
`node_country_lookup_test.dart:161` 读 `../../SSRVPN_MacOS/assets/geoip.metadb.gz`、
`account_usage_identity_test.dart:34` 读 `../../config/ssrvpn-usage-defines.json` —— **都是 CWD 相对路径**。
在仓库根跑会假报 **9 个失败**。CI 也用 `working-directory: packages/ssrvpn_shared`。

### 后台 Bash 的 CWD 不继承
后台任务总是从工作区根目录起，之前命令里的 `cd` **不生效**。必须把 `cd` 写进命令本身：
```bash
cd "$(git rev-parse --show-toplevel)/packages/ssrvpn_shared" && flutter test
```

### macOS 没有 `timeout` 命令
`timeout 900 ...` → `zsh: command not found: timeout`。直接去掉，不要装 coreutils。

### `dart test` 跑不动这里的测试
测试 import `package:flutter`，必须用 Flutter test runner：
`flutter test`（Flutter 3.44.1），不是 `dart test`。

### `bash script.sh | tail -N` 会吞掉退出码
`$?` 变成 tail 的退出码，门禁失败会被漏掉。**重定向到文件再取 `$?`**。

### 守卫遇错即停
`check-clash-service-boundaries.sh` / `check-desktop-startup-guards.sh` 用 `raise SystemExit`，
修好一处才暴露下一处。**一次性算完所有数值**，别反复打地鼠。

### 别信子 Agent 的结论
2026-09-27 代码审查中，一个 general-purpose Agent 交出详细报告，引用
`packages/ssrvpn_shared/lib/desktop_ui/app_tray.dart:591`、`NetworkInterfaceStatus`、
`onNetworkInterfaceStatusChanged` —— **这些文件和符号在仓库里根本不存在**（`find`/`grep` 复核）。
另一个 Agent 的 5 条结论里 2 条是假阳性、1 条存疑。
**规则：Agent 报的每个结论都要独立复核，尤其是引用具体文件行号的。**

### 已被证伪的「疑似 BUG」（别再报）

| 疑点 | 结论 | 证据 |
|---|---|---|
| `direct_fallback.go:95` 的 `if r == nil \|\| !r.Invalid()` 语义反了 | **正确** | mihomo 的 `Invalid()==true` 表示 resolver **可用**。上游 `component/resolver/resolver.go` 5 处调用全用 `if r != nil && r.Invalid() { return r.XXX() }`；项目自带测试夹具 `direct_fallback_test.go:83` 返回 `true` 并断言走直连分支 |
| `ipv6LastFailure` 可能是 0 导致误报 | **不成立** | `clash_service_traffic.dart:12-55` 有 `count is int && count > 0 && age is int && age >= 0 && age <= 60000` 前置守卫 |
| Go 里 `[0]` 索引会 panic / 越界 | **不可达** | 全 `native/proxy_traffic/` **无显式 `panic(` 调用**；隐式 panic 风险只有下标越界，两处都有前置守卫：`target_address.go:91` 的 `conn.Chains()[0]` 由 `len(conn.Chains()) == 0` 拦、`proxy_traffic.go:40` 的 `sessions[0]` 由 `len(sessions) != 0` 拦。另有 `ssrvpnProxyTargetCandidates(...)[0]`（`target_address.go:117`）只在**测试**里被下标访问，其「所有 return 分支非空」性质护住它——生产代码只遍历不取下标 |

## 4. 测试规模基线

**2026-09-27 实测**（`flutter test --reporter compact` 从包目录跑）：

| 包 | 测试文件 | 用例 |
|---|---|---|
| `packages/ssrvpn_shared` | 114 | **1703 通过 + 1 跳过**（约 80 秒） |
| `SSRVPN_Android` | 29 | — |
| `SSRVPN_MacOS` | 27 | — |
| `SSRVPN_Windows` | 45 | — |

跑到这个量级再谈「全绿」。数字会随代码变动，**别把这张表当永久事实**——真要报数就自己跑一遍。
三端用例数只数了 `_test.dart` 文件数，未逐个跑；shared 的 1703 是真跑出来的。

## 5. 发版要点（`docs/RELEASE_CHECKLIST.zh-CN.md` 是唯一逐步入口）

1. **版本号 + changelog 先合入 `main`**。发版**不检查、不更新 GeoIP**；只有收到明确指令才跑 `Maintenance > geoip-refresh`。
2. `scripts/check-version-sync.sh`
3. CI 全绿（四个包）。Windows 日志必须含 PowerShell 5.1 全脚本兼容性 + 新生成安装包真实安装/卸载通过记录；**不得只看 job 绿色**，日志里任何脚本或安装器错误都必须对应失败步骤。
4. 三端项目地址都指向 `https://github.com/Elegying/SSRVPN`
5. 分发策略：桌面端固定**免费分发**——macOS ad-hoc 未公证、Windows 未签名。仓库/GitHub 配置中**不应出现** Apple/Microsoft 付费证书 secrets 或启用变量。Actions 固定完整提交 SHA；`GITHUB_TOKEN` 不允许审批 PR；Release immutability 已启用。Release 必须先 Draft → 上传齐全并校验 → 一次性公开；公开后不得替换/删除同版本资产。
6. `make assets` + `scripts/verify-core-assets.sh`（**不可跳过**，见 `guardrails.md` 第 5 节）
7. `scripts/check-secrets.sh` + `gitleaks git --config .gitleaks.toml --redact --log-opts=--all` + `make verify`
8. `scripts/smoke-release-artifacts.sh --allow-missing`

发版 tag 驱动：`release.yml` 由 push tag `v*` 触发，另有 `prepare-release.yml` 手动输入 tag。
CI/Release 的 macOS runner 是 `macos-15`（自带 Xcode 16，支持 `MACOSX_DEPLOYMENT_TARGET = 11.0`）；本机 Xcode 27 不支持 11.0，属本机摩擦，不影响发布。

## 6. 文档政策（`docs/README.md`）

- 过期审查报告和一次性执行计划**不保留在文档树中**；需要追溯用 Git 历史。
- 一次性审查证据保留在**对应提交 / Issue / Pull Request**，不新增快照型 Markdown。
- 用户可见变化写根 `CHANGELOG.md`，未完成项写 `ROADMAP.md`。
- **引用历史结论前，必须在当前提交上重新执行对应测试或检查。**
- 文档门禁自动枚举全部受版本控制 Markdown；`CHANGELOG.md` 只做链接检查，其余当前文档还检查已知陈旧结论和危险发布命令。
- 既有先例目录 `docs/diagnostics/`、`docs/audit/` 用**英文 kebab-case** 命名。

## 7. 三端内核差异持续回归

`python3 scripts/test-core-contracts.py all --report-dir /tmp/ssrvpn-core-contracts`
独立检出三端固定 commit/tree，应用同一扩展复制清单并运行全部共享 Go 契约。Go 版本各自钉死，
测试结果不走缓存；缺失、跳过或失败即失败。CI 的必需 core-assets job 在二进制缓存前运行，
始终上传 core-contracts 结果。该步骤不修改随包内核，不替代真实 JNI、TUN 或系统恢复验收。

## 8. 客户端可靠性专项

`mise exec flutter@3.44.1 -- bash scripts/test-client-reliability.sh`
按包目录执行共享健康/故障/URI/出口策略及三端旧配置往返测试，最后验证 Windows 有界退出、
外部观察与恢复所有权、配置校验的进程退出/取消和阶段计时所有权。Android 原生等待计时
另随 `scripts/test-android-native.sh` 执行；健康连接复用随三端服务全量测试执行。
测试由现有全量 CI 自动发现；本入口不替代 make verify 或目标平台验收。
