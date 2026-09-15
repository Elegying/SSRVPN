# 安卓订阅 Fake-IP 修复与桌面复核（2026-09-15）

## 状态与范围

基于 5.0.5 的本地修复候选。本文区分代码、自动化检查、候选构建、真机验收和公开发布；本次未发布新版。

目标：安卓连接自身 VPN 时能够安全刷新 HTTPS 订阅，并可查看每个失败来源的具体原因。继续保留节点、分组、选中状态、取消与批量事务语义，不主动断开 VPN，不引入新依赖。

## 根因与连接路径

旧安卓流程在 `SubscriptionService._fetchOnce` 中调用系统 `InternetAddress.lookup`，随后立即调用 `SubscriptionFetchPolicy.validateResolvedAddresses`。系统返回 `198.18.0.0/15` Fake-IP 时，被非公网地址检查提前拒绝，尚未建立 HTTPS 连接。这与用户提供的 5.0.5 真机结果一致。

现在复用 `DirectFetcher.resolveSystemAddresses`：

1. 普通公网 DNS 结果照常逐项校验。用户输入 IP 的原有策略不变。
2. 域名答案出现 Fake-IP 时，先检查混合答案中的其他地址，不能用 Fake-IP 掩盖私网答案。
3. 复用原有 DoH：固定 TCP 连接 `223.5.5.5:443`，HTTPS 验证 `dns.alidns.com`，并行查询 A/AAAA。此步骤不需要系统再次解析 DoH 域名。HTTP 状态必须为 200、DNS Status 必须为 0。
4. 备用解析限制 10 秒，一次 A/AAAA 查询，不重新回退到系统 Fake-IP。取消或超时释放 DoH socket；结果为空、失败或含非公网地址时安全失败。
5. 返回的完整地址集合继续执行原有安全检查，再按已有双栈策略选择最多六个地址。安卓 `Socket.connect` 接收经过验证的 `InternetAddress`，不会再次解析订阅域名。
6. TLS 使用 `SecureSocket.secure(..., host: uri.host)`，保留原始域名的证书校验、SNI 和 HTTP Host。没有关闭证书验证。每次重定向仍执行 URL 策略及新目标的完整解析检查。

安卓没有复用桌面的物理接口绑定，也没有新建系统代理配置。DoH 和订阅连接均沿当前系统/VPN 路由发送；连接自身 VPN 时仍受当前分流规则影响。核心 TLS 嗅探配置不覆盖目标地址；核心原有 socket protect 机制负责出口连接，避免核心自身回环。现有节点或网络仍可能阻断 DoH/订阅服务器，遇到这类问题会失败并保留已有节点。

每个订阅全部尝试共享 45 秒预算；批量刷新仍受原有总时限和取消信号约束，单来源超时作为失败收集，未达到批量总时限时继续其他来源。没有新增持久 DNS 缓存。

## 错误反馈

继续使用 `SubscriptionRefreshFailure.detail` → `SubscriptionRefreshResult.failureDetails`。全部失败时保留结构化失败集合，避免压成只有汇总文案的异常。

共享订阅页面增加“查看失败原因”，Android/macOS/Windows 均接入。保留部分成功汇总，详情入口在汇总提示自动消失后仍可使用，下次刷新清除旧结果。复用已有可滚动、脱敏的错误对话框。

安卓错误区分 DNS 解析、DNS 地址安全拒绝、连接/读取超时、TLS 证书或握手、HTTP 状态/响应异常、订阅内容解析；使用简明中文及下一步建议。网络底层异常不原样拼接进用户反馈或日志，解析错误不展示正文片段；名称、URL 和详情继续通过现有脱敏及长度限制。

## 桌面复核

| 平台 | 默认订阅下载路径 | 同类问题结论 |
| --- | --- | --- |
| Android（修复前） | 系统 DNS → 安全校验 → 固定 IP socket | Fake-IP 会被提前拒绝，本次修复目标 |
| macOS | `allowDirectFetch: Platform.isMacOS` → DoH 优先 → 固定 IP，按原策略可绑定物理地址 | 默认已有安全 DoH 路径，不与安卓旧流程相同 |
| Windows | `allowDirectFetch: Platform.isWindows` → DoH 优先 → 固定 IP | 默认已有安全 DoH 路径，不与安卓旧流程相同 |

桌面常规 HTTP 备用路径仍使用系统 DNS 安全检查；若 DoH 不可用且系统仍返回 Fake-IP，会安全失败，不承诺所有网络可达。本次不改桌面网络优先级、绑定或代理策略。三端均存在详情未接入共享页面的问题，已统一补齐。

## 验证记录

验证使用仓库 `make verify`（实际入口 `scripts/verify-all.sh`）。首次在静态分析发现两条测试参数标注告警后停止；修正后通过仓库 `scripts/workspace.sh analyze` 复查四个工作区，继续执行验证入口剩余的全量测试、覆盖率和原生脚本。格式、导入规范、秘密扫描和文档检查也在最终修改后重跑通过。

已通过的前置检查包括固定 Flutter 3.44.1、版本同步、内置规则/核心资产、真实核心分流、Android 原生桥、macOS TUN DNS 事务 25 项、发布工具 433 项和关键路径性能冒烟。

已完成结果：共享全量 1270 通过/1 跳过，覆盖率 88.51%；Windows Flutter 307 通过/7 平台相关跳过，覆盖率 59.95%，Windows 生命周期覆盖率 51.94% 达标。Android 全量 316 通过，覆盖率 70.86%，安卓原生单元测试 BUILD SUCCESSFUL；macOS Flutter 全量 334 通过，覆盖率 72.88%，生命周期及系统代理覆盖率专项门槛通过。

macOS 原生脚本实际运行被 Xcode 未接受许可阻断：`You have not agreed to the Xcode license agreements`。没有接受许可或修改系统配置；本轮没有原生代码变更。Windows 原生实机/系统 API 检查不能由 macOS 上的 Flutter 测试替代。

候选 APK 已构建并通过 APK 签名校验：`com.ssrvpn.android.preview`、`5.0.5-fakeip.1-preview`、versionCode `5005`、最低 Android API 24、ARM64。签名证书 SHA-256：`c0acf8b64b266e4542fa866a4ce0de13cfd99a78988028eae58b91336d683ec9`。这是本地独立预览身份，不是正式签名覆盖安装包。

日志归档到 `artifacts/subscription-fake-ip-20260915/`。

新增/强化行为覆盖：

- 公网 DNS 不触发 DoH；Fake-IP/混合公网结果仅触发一次备用解析。
- 私网、Fake-IP、IPv4-mapped 回环及混合私网备用结果拒绝；失败/空结果不回退到系统 DNS。
- 取消和总时限中断备用解析。
- 本地真实 TLS 服务验证固定 TCP 目标、HTTP Host、正确域名成功、可信证书但错误域名失败。
- 重定向新目标私网拒绝，第二个 socket 不建立。
- Fake-IP → 公网 → Fake-IP 连续请求不复用旧地址。
- 取消保留节点、多来源部分失败和全部失败保留节点、成功来源更新、错误详情脱敏。
- 共享 UI 详情入口、提示消失后仍可用、脱敏与关闭行为。
- 复用既有 HTTP 分帧、大小限制、身份兼容、双栈回退与桌面下载回归。

另在本机使用公开示例域名执行真实 DoH 冒烟测试：系统解析注入 Fake-IP、备用解析使用真实网络，结果通过公网校验。此项不是安卓自身 VPN 实测。

## 真机与发布边界

首次 USB 检查识别到型号 `2509FPN0BC`，已安装 `com.ssrvpn.android`，versionName `5.0.5`、versionCode `5005`，Wi-Fi 开关开启。随后设备断开，后续 `adb devices -l` 为空。已向用户请求重新连接。

本机无正式版签名配置，候选采用独立 `com.ssrvpn.android.preview` 身份，保护正式应用数据。不卸载、不清空、不覆盖正式订阅配置。

在设备恢复且完成验收前，不将 Wi-Fi + 自身 VPN、VPN 断开、切换后再次刷新、多订阅真机结果记为通过。本次未改变手机原有网络/代理状态，因此也未执行网络恢复操作。

Edge 曾出现的证书域名错误、其他 iOS 客户端在 Wi-Fi 下的超时均未定位，不属于本次已确认根因，不能据此宣称已解决。
