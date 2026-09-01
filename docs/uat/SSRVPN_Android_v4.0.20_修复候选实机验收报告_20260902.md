# SSRVPN Android v4.0.20 修复候选实机验收报告

- 验收日期：2026-09-02（Asia/Shanghai）
- 修复候选提交：`ae83e529a60830e51054b710db764293dcf53732`
- 候选来源：非标签 Release workflow
  [33545476322](https://github.com/Elegying/SSRVPN/actions/runs/33545476322)
- 候选 APK 身份：`com.ssrvpn.android`，`4.0.19+4019`；版本提升提交前构建
- 候选 APK SHA-256：
  `432e385f6ff734a41dabc697d7a6a20605965ac9bebcc799cd45d3be526ddeae`
- 设备：Xiaomi Redmi Note 8，Android 11 / API 30，MIUI 12.5.5，arm64-v8a
- 内核页大小：4 KiB
- 网络：设备自身 Wi-Fi；Mac 只通过 USB 反向转发提供隔离 UAT 节点，不修改 Mac 系统代理、DNS、路由或 Wi-Fi
- 脱敏：不提交设备序列号、订阅地址、节点凭据、用户名路径、完整公网地址或原始日志

## 结论

本候选关闭了 v4.0.19 在同一 Redmi Note 8 上复现的 Android TUN 释放阻断。
App 入口连续 20/20 轮连接与断开、10/10 轮连接中快速取消均保持同一应用 PID；每轮停止后
系统 VPN、`tun0`、7890/7891 数据端口全部释放，等待 12 秒、超过旧版约 10 秒进程终止窗口后
没有资源重新出现，也没有新的 fail-closed 日志。后台 60 秒和强制 deep Doze 60 秒期间，
系统 VPN 保持 `CONNECTED/VALIDATED`，`tun0` 和同一 PID 保持，真实 HTTPS 探针返回 204；
退出 Doze 后正常断开并完成相同清理。

快捷磁贴已取得真实单轮连接与断开证据：`VpnTileService` 启动 VPN，Mihomo API 和 TUN
就绪，真实代理请求成功，随后磁贴断开并释放资源。MIUI 的 `cmd statusbar click-tile`
在面板展开时会连续注入两次 `onClick`，面板收起时则不投递，因此无法用该接口获得可信的
20 轮单击循环；本报告不把系统双击包装成 20/20 人工磁贴验收。

候选 APK 的版本仍是 4.0.19，因为它来自版本提升之前的精确修复提交；provenance 已把 APK
绑定到上述 `main` 提交。v4.0.20 的版本提交只修改版本号、变更日志和发布证据，不改变该实测
Android 运行路径；正式包仍必须由受保护 `main` 重新构建并完成摘要、签名谱系和 provenance
终验。

## 候选包与供应链证据

| 项目 | 结果 |
| --- | --- |
| Release candidate workflow | PASS；三端构建、共享测试、Windows 安装器和产物门禁全部成功，正式发布步骤按非标签运行设计跳过 |
| APK sidecar | PASS；下载后的 `SSRVPN.apk` 与 `.sha256` 一致 |
| GitHub artifact attestation | PASS；仓库、工作流、run attempt 和源码提交精确匹配 |
| APK 签名 | PASS；APK Signature Scheme v2、1 个 signer，证书 SHA-256 为 `caf5bb670e4513c4e3d7815a7314f489281c37f02827db07d0a59e1242f2cc0c` |
| Android 身份 | PASS；`versionName=4.0.19`、`versionCode=4019`、`minSdk=24`、`targetSdk=36`、包名正确 |
| 核心来源 | PASS；固定 Android bridge 源码和核心资产来源摘要与仓库元数据一致 |
| 16 KiB 包兼容 | PASS（结构证据）；AArch64/JNI 和所有 ELF `LOAD` 段 16,384 字节对齐，不冒充原生 16 KiB 设备 UAT |

## 实机步骤与结果

| 场景 | 结果 | 关键证据 |
| --- | --- | --- |
| 同版本覆盖安装 | PASS | `adb install -r` 安装候选后，既有 UAT 订阅、节点和设置仍存在；应用 PID 重新建立，包身份与候选一致 |
| VPN 授权 | PASS（沿用已授权状态） | 系统授权在同一应用数据上保持；本轮未清数据重新弹窗，避免破坏用户测试资料 |
| App 连接/断开 20 轮 | PASS 20/20 | 每轮 `startCoreWithVpn`、TUN listener、`VALIDATED` VPN 和语义化已连接状态成立；断开后 VPN/TUN/端口为 0，12 秒后同一 PID |
| 快速取消 10 轮 | PASS 10/10 | 每轮确实收到一次原生启动和一次停止；最终未连接，资源为 0，同一 PID，无 fail-closed |
| 后台 60 秒 | PASS | 回到系统桌面后同一 PID、VPN、TUN 保持；真实 HTTPS 为 204 |
| 强制 deep Doze 60 秒 | PASS | 系统报告 `mState=IDLE`；同一 PID、`VALIDATED` VPN、TUN 保持，真实 HTTPS 为 204 |
| Doze 恢复与断开 | PASS | 主动 `unforce`、唤醒、回到应用正常断开；12 秒后 VPN/TUN 为 0，无 fail-closed |
| 快捷磁贴单轮 | PASS | `onClick: current=false` 后核心、API、TUN 就绪并真实代理访问；`current=true` 后正常停止和清理 |
| 快捷磁贴 20 轮 | BLOCKED（MIUI 自动化） | 展开面板后组件命令连续发送两次点击；收起面板时命令不投递，不能证明 20 次独立用户单击 |
| 原生 16 KiB 设备 | BLOCKED | 真机页大小为 4096；仅保留 ELF/APK 结构兼容证据 |
| 蜂窝切换、第二 VPN、其他 OEM | BLOCKED | 设备无 SIM、未安装第二 VPN，且只有 MIUI 真机；不外推到 ColorOS/One UI 等设备 |

## 修复边界

修复保持 fail-closed：未知 TUN 基线、不可读描述符证据，以及描述符仍指向活动自有 TUN 时，
停止验证仍会拒绝提前报告成功。只有 `/proc/self/fdinfo` 明确证明自有描述符已经关闭，或编号
已被非 TUN 资源复用时，才会清除本代所有权声明；MIUI 延迟移除一个已不再由应用持有的接口
不再形成循环等待。重连仍要求创建新的 TUN listener，不能复用上一代关闭状态。

## 自动化与线上构建

- 修复分支 Android 原生定向测试：171 项通过。
- Flutter `3.44.1` 下完整 `make verify`：Release tooling 396、Shared 652、Android Flutter
  276、Android 原生 171、macOS Flutter 284、Windows Flutter 273；格式、分析、覆盖率、安全、
  资产和发布门禁全部通过。
- 修复 PR [#175](https://github.com/Elegying/SSRVPN/pull/175) 的必需检查全部成功并经受保护
  `main` 合并；精确提交 CI
  [33543771035](https://github.com/Elegying/SSRVPN/actions/runs/33543771035) 成功。
- 非标签 Release candidate
  [33545476322](https://github.com/Elegying/SSRVPN/actions/runs/33545476322) 从同一提交完成三端
  正式形态构建和产物验证；发布步骤按设计未执行。

## 最终现场恢复

- Android：已退出强制 Doze 并唤醒；SSRVPN 保持安装且进程存活，VPN 为 0、`tun0` 为 0，
  Wi-Fi 为 `CONNECTED/VALIDATED`。
- USB：已删除测试用 `adb reverse`；本地 UAT 代理和订阅 fixture 已停止。
- macOS：本轮没有修改系统代理、DNS、路由、Wi-Fi 或 TUN；没有通过断开 Wi-Fi 制造故障。

## 未解决风险

1. MIUI 命令行快捷磁贴入口无法提供可信 20 轮单击证据；当前只有人工单轮和组件双击下的
   真实连接/断开证据。
2. 4 KiB 真机不能替代原生 16 KiB page-size 硬件验收。
3. 无 SIM、第二 VPN 和其他 OEM 设备，蜂窝切换、VPN 竞争及跨 OEM 后台策略仍未执行。
4. 本轮短时 Doze 是修复候选回归；v4.0.19 同设备已有 30 分钟 Doze 证据，但不把旧包的
   时长直接写成候选包 30 分钟。
