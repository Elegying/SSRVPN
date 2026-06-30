# SSRVPN 全面评估报告

评估日期：2026-06-30 12:10 CST
评估范围：代码仓库 + 线上服务 + 基础设施

---

## 一、项目概览

| 指标 | 数值 |
|------|------|
| 仓库 | `Elegying/SSRVPN` (monorepo) |
| 版本 | 2.0.0+200 |
| Flutter | 3.44.1 (pinned via .fvmrc) |
| 平台 | Android / macOS (Apple Silicon) / Windows |
| Dart 文件 | 110 个 |
| 总代码行 | 38,684 行 |
| 测试文件 | 18 个 |
| 共享包测试 | 53 个（全部通过） |
| License | MIT |

---

## 二、线上服务评估

### 2.1 网站 (ssrvpn.vip)

| 项目 | 状态 | 说明 |
|------|------|------|
| HTTPS | ✅ 正常 | 200 OK，证书有效 |
| SEO meta | ✅ 已配置 | description、og:title、og:description、theme-color、viewport |
| robots.txt | ⚠️ noindex | `<meta name="robots" content="noindex, nofollow">` — 有意为之还是遗留？ |
| 内容完整度 | ✅ 良好 | 套餐介绍、节点状态、下载链接、服务条款、退款政策 |
| 移动适配 | ✅ 已配置 | viewport meta tag |

**套餐信息**：
- 普通线路：美国节点，¥200/年 或 ¥120/半年，250G/月
- 精品专线：香港/新加坡/日本/美国/台湾/英国 IEPL，¥960/年 或 ¥499/半年，250G/月

### 2.2 下载链接 (阿里云 OSS)

| 平台 | 状态 | 大小 |
|------|------|------|
| Android APK | ✅ 200 OK | 29.6 MB |
| macOS DMG | ✅ 200 OK | 28.9 MB |
| Windows ZIP | ✅ 200 OK | 35.2 MB |

### 2.3 DNS 与服务器

| 域名 | 解析 | 状态 |
|------|------|------|
| ssrvpn.vip | 155.103.116.146, 155.103.116.177 | ✅ 正常 |
| ssr.ssrvpn.vip | 155.103.116.150, .146, .177 (轮询) | ✅ 正常 |
| panel.ssrvpn.vip | NXDOMAIN | 🔴 DNS 记录缺失 |

**问题**：`panel.ssrvpn.vip` 无 DNS 记录，面板服务器不可达。根据 MEMORY.md 记录，该域名应指向面板服务器。

### 2.4 节点状态（网站显示）

| 节点 | 状态 |
|------|------|
| 美国 SSR | 🟢 在线 |
| 香港 IEPL | 🟢 在线 |
| 新加坡 IEPL | 🟢 在线 |
| 日本 IEPL | 🟢 在线 |
| 台湾 IEPL | 🟢 在线 |
| 美国 IEPL | 🟢 在线 |
| 英国 IEPL | 🟢 在线 |

---

## 三、代码仓库评估

### 3.1 仓库结构

```
SSRVPN/
├── packages/ssrvpn_shared/     # 共享包 (18 文件, 3,150 行)
│   ├── models/                 # AppSettings, ProxyNode, ProxyGroup, Subscription
│   ├── services/               # ClashConfigGenerator, ClashServiceBase, SubscriptionParser, UnlockTestService
│   ├── utils/                  # LogRedactor, PrivateNodeLatencyPolicy, ForceProxySitePolicy
│   └── constants/              # AppConstants
├── SSRVPN_Android/             # Android (35 文件, 11,026 行)
├── SSRVPN_MacOS/               # macOS (29 文件, 12,388 行)
├── SSRVPN_Windows/             # Windows (28 文件, 12,120 行)
├── .github/                    # CI/CD, templates, dependabot
└── docs/                       # 项目文档
```

### 3.2 CI/CD

| 工作流 | 触发 | 状态 |
|--------|------|------|
| CI (ci.yml) | push/PR to main | ✅ 矩阵构建 (shared → Android/macOS/Windows) |
| Release (release.yml) | tag push (v*) | ✅ 构建 + 校验和 + GitHub Release |
| Dependabot | 每周 | ✅ 5 个生态 (actions + 4 pub) |

### 3.3 文档完整度

| 文档 | 状态 |
|------|------|
| README.md | ✅ 完整（结构、验证、构建、发布） |
| CHANGELOG.md | ✅ 遵循 Keep a Changelog |
| CONTRIBUTING.md | ✅ 开发规则、验证流程 |
| SECURITY.md | ✅ 漏洞报告、密钥处理、TUN 权限模型 |
| MIGRATION.md | ✅ 旧仓库迁移指南 |
| LICENSE (MIT) | ✅ |
| docs/PROJECT_HEALTH.md | ✅ 评分卡 |
| docs/MAINTENANCE.md | ✅ 周维护、PR、发布清单 |
| docs/ROADMAP.md | ✅ 近/中/长期规划 |
| docs/RELEASE_SIGNING.md | ✅ 签名清单 |
| .github/ISSUE_TEMPLATE/ | ✅ bug/feature/maintenance |
| .github/PULL_REQUEST_TEMPLATE.md | ✅ 验证清单 |
| .github/CODEOWNERS | ✅ |

### 3.4 静态分析 & 测试

| 平台 | dart analyze | flutter analyze | 测试 |
|------|-------------|-----------------|------|
| ssrvpn_shared | ✅ 无问题 | — | 53 通过 |
| Android | ✅ 无问题 | — | 7 文件 |
| macOS | ✅ 无问题 | — | 3 文件 |
| Windows | — | ✅ 无问题 | 3 文件 |

### 3.5 代码质量

| 检查项 | 结果 |
|--------|------|
| print() 调试残留 | ✅ 无（仅 debugPrint） |
| TODO/FIXME 标记 | ✅ 无 |
| 日志脱敏 | ✅ LogRedactor 覆盖 Bearer/password/apiSecret |
| 原子文件写入 | ✅ writeStringAtomically |
| 端口冲突处理 | ✅ 自动重试 |
| Isolate 使用 | ✅ gzip 解压/延迟测试不阻塞 UI |

---

## 四、技术债务分析

### 4.1 代码重复（核心问题）

| 文件 | 三端总行数 | 重复率 | 说明 |
|------|-----------|--------|------|
| HomeScreen | 6,270 | ~70% | UI 逻辑与业务逻辑混合 |
| ClashService | 3,745 | ~60% | API/延迟/健康检查/配置生成重复 |
| SubscriptionService | 2,475 | ~50% | 订阅解析/刷新逻辑重复 |
| AppSettings | ~800 | ~80% | 4 份独立实现（含共享包） |
| **合计** | **~13,290** | — | 估计可消除 ~6,000 行重复 |

### 4.2 ProxyMode 枚举 — 4 处重复定义

```
packages/ssrvpn_shared/lib/models/app_settings.dart:240
SSRVPN_MacOS/lib/models/app_settings.dart:229
SSRVPN_Android/lib/models/app_settings.dart:236
SSRVPN_Windows/lib/models/app_settings.dart:220
```

### 4.3 AppSettings 字段差异

| 字段 | shared | macOS | Android | Windows |
|------|--------|-------|---------|---------|
| startWithWindows | — | ✅ | — | ✅ |
| autoConnectOnStartup | — | — | ✅ | — |
| autoCheckUpdate | — | — | ✅ | — |
| enableSystemProxy (getter) | — | ✅ | ✅ | — |
| tunMode (getter) | — | ✅ | ✅ | — |
| lastSelectedNode (alias) | — | ✅ | ✅ | — |

### 4.4 依赖版本

**Windows 独有的过时依赖**：
| 包 | 当前 | 最新 | 风险 |
|----|------|------|------|
| uuid | 3.0.7 | 4.5.3 | ⚠️ 大版本跳跃 |

**三端共有的过时传递依赖**：
| 包 | 当前 | 最新 |
|----|------|------|
| meta | 1.18.0 | 1.18.3 |
| async | 2.12.0 | 2.13.1 |

### 4.5 macOS CocoaPods

macOS 项目仍使用 CocoaPods，Flutter 建议迁移到 Swift Package Manager。不影响功能，但增加构建复杂度。

---

## 五、安全评估

### 5.1 已实施的安全措施

| 措施 | 状态 |
|------|------|
| API 密钥 Bearer 认证 | ✅ |
| 日志脱敏 (LogRedactor) | ✅ |
| YAML 安全转义 (apiSecret) | ✅ 本次修复 |
| Android 安全存储 (flutter_secure_storage) | ✅ |
| 原子文件写入 | ✅ |
| setuid root 验证 (macOS TUN) | ✅ |
| SECURITY.md 漏洞报告流程 | ✅ |

### 5.2 潜在风险

| 风险 | 严重度 | 说明 |
|------|--------|------|
| apiSecret 明文存储 (macOS/Windows) | ⚠️ 中 | settings.json 中明文保存，建议用 Keychain/Credential Manager |
| 订阅 URL 明文存储 | ⚠️ 中 | 包含认证信息的 URL 明文保存 |
| setuid root 继承 | ⚠️ 中 | 任何本地用户可以 root 身份执行核心二进制 |
| noindex meta tag | ℹ️ 低 | 网站不被搜索引擎收录（可能是有意为之） |

---

## 六、发布就绪度

### 6.1 当前状态

| 项目 | 状态 |
|------|------|
| Monorepo 首个 tag | 🔴 未创建 |
| GitHub Release | 🔴 未发布 |
| 签名自动化 | 🔴 未配置 |
| 公证自动化 (macOS) | 🔴 未配置 |
| 代码签名 (Windows) | 🔴 未配置 |
| CI 构建 | ✅ 正常 |
| Release 工作流 | ✅ 已就绪（缺签名 secrets） |

### 6.2 线上/线下一致性

| 项目 | 线上 | 线下 | 一致？ |
|------|------|------|--------|
| 网站套餐信息 | 普通¥200/年, 专线¥960/年 | — | ✅ |
| 下载链接 | OSS 存在 (29.6/28.9/35.2 MB) | 本地构建产出 | ⚠️ 未验证是否为最新构建 |
| 节点列表 | 7 个节点在线 | — | ✅ |
| panel.ssrvpn.vip | NXDOMAIN | MEMORY.md 记录应存在 | 🔴 不一致 |
| ssr.ssrvpn.vip | DNS 轮询 3 IP | — | ✅ |
| 客户端版本 | 网站未显示版本号 | 2.0.0+200 | ⚠️ 网站缺少版本信息 |

---

## 七、评分卡

| 维度 | 评分 | 方向 | 说明 |
|------|------|------|------|
| **线上服务** | 7/10 | → | 网站正常，下载正常，panel DNS 缺失 |
| **代码质量** | 8/10 | ↑ | 静态分析全绿，测试覆盖关键路径，无调试残留 |
| **架构设计** | 6/10 | ↑ | 共享包在改善，但三端重复严重 |
| **文档完整度** | 9/10 | → | 从 README 到签名清单一应俱全 |
| **CI/CD** | 8/10 | → | 矩阵构建 + Dependabot + Release 工作流 |
| **安全性** | 7/10 | ↑ | 日志脱敏好，但存储加密不足 |
| **发布就绪** | 5/10 | ↑ | 无 tag、无签名、无公证 |
| **整体** | **7.1/10** | ↑ | 基础扎实，主要瓶颈在代码去重和发布流程 |

---

## 八、优先级建议

### P0 — 立即处理

1. **修复 panel.ssrvpn.vip DNS** — 面板服务器不可达
2. **创建首个 monorepo tag** — 验证 Release 工作流端到端

### P1 — 本周

3. **各平台 ClashService 继承 ClashServiceBase** — 消除 ~2,000 行重复
4. **统一 ProxyMode 枚举** — 消除 4 处重复定义
5. **Windows uuid 升级到 4.x** — 大版本跳跃，需测试兼容性

### P2 — 本月

6. **AppSettings 基类提取** — 消除 ~500 行重复
7. **HomeScreen 组件拆分** — 提升可维护性
8. **macOS CocoaPods → Swift Package Manager 迁移**
9. **配置签名 secrets** — Android keystore + macOS Developer ID + Windows code signing

### P3 — 后续

10. **apiSecret 安全存储** — macOS Keychain / Windows Credential Manager
11. **网站添加版本号显示**
12. **网站 SEO** — 确认 noindex 是否有意为之
13. **集成测试** — Clash 配置生成 + API 组切换

---

## 九、本次审查修改清单

| 修改 | 类型 | 文件 |
|------|------|------|
| 修复 apiSecret YAML 注入 | 🔴 BUG | macOS/Android ClashService |
| 补全 Windows AppSettings 缺失字段 | 🔴 BUG | Windows AppSettings |
| 新增 ClashServiceBase 共享基类 | 🟡 架构 | ssrvpn_shared |
| 新增审计报告 | 📄 文档 | docs/AUDIT_REPORT.md |

分支：`refactor/extract-shared-clash-service`（2 commits）
