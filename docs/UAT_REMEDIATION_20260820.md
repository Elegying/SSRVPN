# 2026-08-20 综合审查建议闭环记录

本记录对应测试分支 `codex/complete-audit-recommendations`，不是新版本发布证明。Windows、macOS、Android 的物理设备证据分开记录；自动化、产物结构和 CI 不替代缺少的真机结果。

## GitHub 合并门禁

2026-08-20 回读 `main` 分支保护，`strict=true`、`enforce_admins=true` 保持不变。必需状态检查由 6 项增加到 9 项，新增项均绑定 GitHub Actions `app_id=15368`：

- `Dependency review`
- `CodeQL (Actions)`
- `macOS native unit tests`

原有 `Full-history secret scan`、`Prepare verified core assets`、`Workspace checks`、`Android`、`macOS`、`Windows` 保持不变。没有修改审核人数、管理员约束或其他保护项。

## Windows 交接状态

- 已提供 [Windows Codex 最终验收提示词](WINDOWS_V4_0_13_FINAL_UAT_CODEX_PROMPT.md)。
- 提示词固定核验 v4.0.13 正式安装器 SHA-256 `50d803295e7f3947893eb1351b743f41f1bb23dac4838b8d77ee95dbebc0b3f2`，覆盖诊断复制、连接态节点切换、未连接订阅状态、20 轮生命周期、性能/内存/能耗、大字体和键盘。
- Windows Codex 只允许推送测试分支，不创建 PR、不合并、不打标签、不发布。
- Windows 实机报告返回前，本记录不把 Windows 项标记为通过。

## Android USB 真机

| 项目 | 结果 | 证据与边界 |
| --- | --- | --- |
| 环境 | 通过 | Xiaomi `2509FPN0BC`，Android 17 / SDK 37，arm64-v8a；已安装 SSRVPN 4.0.13（4013） |
| 正式 APK | 通过 | 从已安装应用回读的 `base.apk` SHA-256 为 `51217ff044fcfdafe53f5d3dbac7dbf5871fb570e30a52e068185b506ee389c7`，与 v4.0.13 Release 一致 |
| APK 内核心 | 通过 | `go1.25.11 android/arm64 c-shared with_gvisor,cmfa`；AArch64、JNI ABI 存在，4 个 ELF `LOAD` 段对齐均为 16384 |
| 原生 16 KiB 页设备 | 阻塞 | 当前设备运行时页大小为 4096 字节。只能证明 APK 结构兼容，不能冒充 16 KiB 硬件安装/连接/流量/断开验收 |
| 10 次 Activity 冷启动 | 通过 | `am start -W -S` 10/10 返回 `Status: ok`；TotalTime 中位数 0.1465 秒、P95/最大值 0.687 秒。该指标是 Activity 启动总时长，不代表首帧或可交互时长 |
| 连接与真实流量 | 通过 | 使用“香港 \| IEPL ①”连接后，系统报告 `VPN CONNECTED`，7890/7891 监听；设备经 TUN 请求 `connectivitycheck.gstatic.com/generate_204` 返回 HTTP 204，断开后两个数据端口约 200 ms 释放。9090 是回环鉴权控制面，按实现设计可在断开时保留，不作为数据面残留 |
| 20 轮生命周期 | 通过 | 设备空闲后从零重跑 20/20 轮；每轮 7890/7891 建立和释放均约 200 ms，真实 HTTP 204 全部成功，无崩溃、卡死或数据端口残留。第 7 轮需 2 次数据探测、第 20 轮需 5 次，其余首次成功；测试窗口实体触控事件为 0 |
| 数据面时序 | 通过 | 20 个 HTTP 204 样本中位数 0.237917 秒、P95 0.545249 秒、最大值 0.621750 秒；连接后补采系统证据显示 SSRVPN VPN 为 `IS_VPN`、`IS_VALIDATED`，接口为 `tun0` |
| 现场恢复 | 通过 | 已恢复测试前节点“美国住宅IP”和智能模式；最终 UI 为“连接状态：未连接”，7890/7891 无监听 |
| 约 7 小时耗电复测 | 阻塞 | 预检发现 `AC powered=true`、电池 `status=2`（充电），工具返回退出码 2；USB 供电状态下不能生成有效放电证据 |

脱敏原始证据保存在本机临时目录，未提交设备序列号。关键文件 SHA-256：Android 运行快照 `e47c57e271da5316cce8fb673e06edc180f8d5eead354311f8fd3cf2b60be1e0`，耗电预检 `f451426427725d51655796aafe7045553cfb4d94718bfaaa506371fa9a582d81`，启动汇总 `f5c532bf60957d627166b5dbce2eb70e420ef103f8aef296555c9abb6d0f80d8`，20 轮记录 `58cc21108e90dd5842867a0daf4443b355343e7885e24cdf7899b230a28293e5`，HTTP 时序汇总 `f7b0c6c1ba771c2cc83bb04a81bc301e78b504ca9bf5536ab9e78f94224e75dd`，连接后系统网络快照 `6d8323c61e45742afd9e233972608dc8ff0641a131385030e56541d18a23be34`。

## macOS 本机

| 项目 | 结果 | 证据与边界 |
| --- | --- | --- |
| 环境 | 通过 | macOS 26.5.2 arm64，正式 `/Applications/SSRVPN.app` 为 4.0.13（4013），系统页大小 16384 |
| 基线清理 | 通过 | 发现一个此前遗留的 TUN 管理员授权等待；取消后 staging 目录消失，系统 HTTP/HTTPS/SOCKS/PAC 均关闭，7890/7891/9090 无监听 |
| 订阅页运行状态 | 通过 | 正式版在断开时 AX 树明确显示“连接状态：未连接”，订阅 URL 仅显示脱敏形式 |
| 启动采样 | 部分通过 | 紧接终止后首次 `open` 返回 LaunchServices `-600`；之后取得 10 个成功的进程就绪样本，中位数 0.105 秒、P95/最大值 0.228 秒。保留首次失败，不将进程就绪时间冒充 UI 可交互时间 |
| 2 分钟内存观察 | 通过 | RSS 样本为 79,568、27,392、70,032、75,344、22,256 KiB，未持续单调增长；这是短时观察，不替代 30 分钟/20 轮连接压力 |
| 删除按钮语义 | 已修复并真机验证 | 正式版两个删除图标在 AX 树中无名称；测试分支先增加失败测试，再为共享组件加入“删除订阅 <名称>”。本机 Debug 候选 AX 树已显示“删除订阅 私家车-2026”和“删除订阅 SSRVPN.VIP” |
| 大字体与键盘 | 自动化通过、实机待补 | 已有 2.0/3.2 文本缩放和键盘语义测试；本轮尚未改变系统显示比例，不把自动化冒充系统实机 |
| TUN 连接/断开 | 通过 | 取得用户当次明确授权后，正式 v4.0.13 使用原节点“私家车-2026”和智能模式完成真实 TUN 连接；`1.1.1.1`、`8.8.8.8` 均经 `utun4`/`198.18.0.1`，Google、Cloudflare 返回 HTTP 204，YouTube 返回 HTTP 200。短时稳定性复测仍为 204；正常断开后路由/DNS 恢复 `en0` 与原路由器，系统代理关闭，7890/7891/9090、AtlasCore 和 TUN runner 均无残留，断开后直连 204 通过 |

按用户最新边界，本轮不测试 VoiceOver、Narrator、其他屏幕阅读器或盲文；跳过不记为失败或阻塞。

脱敏本机快照 SHA-256 为 `b8c4764a1ddf35319cde1f341c065c335b1d450384fa5c3d7299b01b28657011`，启动汇总为 `562b0c5f6b7b3641fb248b9cf8d40a6c50c53e6672fb005dd1fe3f90ab52d4f5`。本轮 TUN 基线、连接态和断开后快照 SHA-256 分别为 `0b514140e19be136fc9c26d8fd153a0d9cb9ebee54691a85fccb9ba51ecc4c2b`、`54ebd5dc3913d8c6fb2fca0269a2212e439e8cfe82729a159abf939d12d9a2c6`、`e0c591f9b1a66fad54c85060f366e469f3d1accaa943566a7105a7c9c1e046c2`；原始文件仅保存在本机临时目录，未提交公网 IP 或用户路径。

## 新增证据工具

`scripts/collect_uat_evidence.py` 只读采集 Android/macOS 版本、页大小、供电、进程内存、代理和监听端口，并可对时序样本计算中位数和最近秩 P95：

```bash
python3 scripts/collect_uat_evidence.py android \
  --serial <adb-serial> --output /tmp/android-uat.json
python3 scripts/collect_uat_evidence.py android \
  --serial <adb-serial> --output /tmp/android-16k.json --require-16k
python3 scripts/collect_uat_evidence.py android \
  --serial <adb-serial> --output /tmp/android-battery.json \
  --require-battery-ready
python3 scripts/collect_uat_evidence.py macos \
  --app-path /Applications/SSRVPN.app --output /tmp/macos-uat.json
python3 scripts/collect_uat_evidence.py timings 0.10 0.12 0.14 \
  --output /tmp/timings.json
```

`--require-16k` 和 `--require-battery-ready` 在前置条件不满足时仍写入真实快照，并返回退出码 2，防止错误标记通过。输出必须保存在本机临时目录并脱敏后再引用。

## 最终自动化门禁

测试分支执行完整 `make verify` 返回 0：发布工具 302 项、Shared 505 项、Android 237 项、macOS 259 项和 Windows 223 项全部通过；Android Gradle/JUnit、macOS RunnerTests、静态分析、格式、文档、秘密/TLS、核心与发布资产守卫及四套覆盖率门槛均通过。Windows 中仅目标系统可执行的 8 项按设计在 macOS 跳过，不能替代 Windows 实机报告。

## 尚未闭环

1. 等待 Windows Codex 返回正式安装器实机报告和测试分支。
2. 需要一台运行时 `getconf PAGESIZE=16384` 的 Android 设备完成安装、连接、真实流量和断开。
3. Android 约 7 小时耗电复测需要设备真实放电且仍能采集 ADB；当前 USB 充电现场不满足前置条件。

以上项目在取得新证据前保持“待执行/阻塞”，不得通过修改文案将其关闭。
