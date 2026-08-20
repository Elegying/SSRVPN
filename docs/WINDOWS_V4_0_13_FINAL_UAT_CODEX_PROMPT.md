# Windows Codex 执行提示词：SSRVPN v4.0.13 最终实机验收

把下面整段提示词原样交给 Windows 电脑上的 Codex。该任务只允许推送测试分支，不创建 PR、不合并、不打标签、不发布。

```text
你正在 Windows 11 x64 实机上为 Elegying/SSRVPN 做 v4.0.13 最终验收与 Windows 专属测试补强。不要只给方案，请持续执行到所有可执行项完成，并把无法完成的项明确标记为 BLOCKED；禁止把自动化、源码检查或 CI 冒充 Windows 实机结果。

仓库：https://github.com/Elegying/SSRVPN.git
正式版本：https://github.com/Elegying/SSRVPN/releases/tag/v4.0.13
正式安装器：https://github.com/Elegying/SSRVPN/releases/download/v4.0.13/SSRVPN_Setup.exe
安装器预期 SHA-256：50d803295e7f3947893eb1351b743f41f1bb23dac4838b8d77ee95dbebc0b3f2
标签目标提交：aa157395f87959696ad21e6a5d894f54c400cb82
仓库当前 main 基线（开始前必须重新 fetch 核实，不要盲信）：47c995227e863916555dfc5eaf433acaa0c10fc2

最终目标：
1. 用 v4.0.13 GitHub Release 的正式安装器复验三项最终修复：诊断复制、连接态节点切换、未连接时订阅页状态。
2. 完成 Windows 安装/升级/卸载、系统代理、TUN、托盘、异常退出与 RunOnce 恢复的实机验收。
3. 完成 20 轮连接/断开，记录启动/连接/断开耗时的中位数和 P95、内存稳定性。
4. 建立断开与连接各 30 分钟的同机空闲能耗基线，并完成 200% 文本和全键盘验收。
5. 审查 Windows 生命周期自动化覆盖。只有发现无法由现有测试证明的具体行为时，才先写失败测试，再做最小提取/修复；不要为了覆盖率重写 launcher。
6. 生成脱敏报告，运行全部 Windows 门禁，提交并推送测试分支。不要创建 PR、不要合并、不要发布。

权限和安全边界：
- 默认自主执行只读检查、仓库内编辑、测试、构建、安装器校验、应用内验收和测试分支推送。
- 遇到 UAC、管理员授权、TUN 授权、显示比例切换等需要真人确认的界面时，清楚告诉我当前动作、影响和恢复方式，然后让我接管确认；不得绕过 UAC、关闭 Defender/防火墙或降低系统安全策略。
- 按用户边界，不测试 Narrator、其他屏幕阅读器或盲文；这些项目直接标记为“按用户要求不在本轮范围”，不得记为 FAIL 或 BLOCKED。
- 不修改路由器、DNS、其他 VPN、无关系统代理、注册表策略或用户文件；不得做 Wi-Fi 断网故障注入。
- 测试前保存系统代理、WinHTTP 代理、相关路由/网卡、SSRVPN 进程、7890/7891/9090 端口、应用配置目录和安装版本基线；测试后恢复到原状态。
- 不删除用户订阅、节点、密钥或配置。确需全新安装时先做可恢复备份，并验证覆盖安装/卸载不会丢数据。
- 报告、提交和终端输出不得包含订阅 URL、Token、节点密码、Cookie、完整公网 IP、Windows 用户名或绝对用户目录；原始证据保存在本机临时目录，只提交脱敏摘要。
- 仓库若有未提交改动，不得 reset/checkout 覆盖；使用新 worktree 或停止说明冲突。
- 安装器哈希不匹配、来源不是上述正式 Release、代理/路由无法恢复、出现数据丢失或系统安全异常时立即停止相关动作并报告。

执行顺序：

A. 仓库和正式资产基线
1. 读取仓库 AGENTS.md 和相关项目文档，优先使用项目知识图工具；图工具不可用时才降级到 rg/文件读取并记录原因。
2. 找到或克隆仓库，执行：
   - git fetch --all --tags --prune
   - 确认工作树状态、origin/main、v4.0.13 标签目标和远端地址。
   - 从最新 origin/main 新建 codex/windows-v4.0.13-final-uat；若同名远端分支已存在且不是本机续跑分支，使用带日期时间的新分支名。
3. 下载正式 SSRVPN_Setup.exe 到独立临时目录；用 Get-FileHash -Algorithm SHA256 核对必须精确等于上面的哈希。记录文件大小、哈希、下载时间和 Release URL。可记录 Get-AuthenticodeSignature 的客观状态，但不得把未签名误报成已签名。
4. 创建本机临时证据目录，例如 $env:TEMP\SSRVPN-Windows-UAT-v4.0.13；不要把未脱敏原始证据加入 Git。
5. 保存测试前状态：
   - Windows 版本、CPU、内存、当前电源模式；
   - SSRVPN 安装版本和安装路径；
   - Get-Process 的 SSRVPN/mihomo 相关 PID、工作集和启动时间；
   - netsh winhttp show proxy；
   - 当前用户 Internet Settings 的 ProxyEnable/ProxyServer/AutoConfigURL（只记录脱敏值）；
   - Get-NetAdapter、Get-NetRoute 的相关项；
   - Get-NetTCPConnection 对 7890/7891/9090 的监听；
   - 应用配置目录存在性与备份位置。

B. 安装和升级实测
1. 若机器已有旧版，先备份配置并记录版本；使用正式安装器完成覆盖升级，验证只有一个快捷方式、订阅/节点/模式保留、版本显示 4.0.13。
2. 在不删除用户数据的前提下验证普通用户安装、启动和卸载行为；如需要完整卸载/重装，先说明恢复方案并让我确认。完成后恢复正式 v4.0.13。
3. 验证首次/重复启动、托盘打开/隐藏/退出、资源管理器重启后的托盘恢复、重复启动单实例行为。

C. 三项必须复验的正式版修复
1. 诊断复制：
   - 打开“运行日志/诊断”，等待诊断完成，点击“复制脱敏诊断报告”。
   - 将剪贴板粘贴到本机临时文本文件或记事本，确认内容非空、与界面报告一致、提示为“诊断报告已复制（敏感内容已脱敏）”。
   - 检查报告不含订阅 Token、节点密码、Windows 用户名或未脱敏绝对路径。
   - 如果剪贴板没有实际写入，界面必须显示“复制失败，请重试”，不得出现假成功。
2. 连接态节点切换：
   - 使用同一订阅内两个已知可用且名称脱敏的节点 A/B。
   - 连接 A，确认 UI 已连接、核心存活、系统代理或 TUN 的真实数据路径成立。
   - 保持连接时选择 B；必须看到“已切换: <B>”，诊断/API 中当前有效节点变为 B，数据流量继续可用，不能只改卡片文字。
   - 再切回 A，验证同样成立；记录耗时和错误日志。
3. 未连接时订阅页状态：
   - 完全断开并确认核心/代理/TUN 已清理。
   - 打开订阅页，必须明确显示“连接状态：未连接”，不能展示陈旧的已连接节点。
   - 再连接一个节点，订阅页必须显示“连接状态：已连接”和当前运行节点；断开后回到“未连接”。

D. 连接与恢复矩阵
1. 系统代理模式：连接、真实网页/204 请求、断开；确认只修改和恢复本应用拥有的代理事务。
2. TUN 模式：管理员同意、主动取消、失败清理各至少 1 次；取消必须显示“连接已取消”，不能显示启动异常或假连接，不能遗留核心、TUN 网卡或路由。
3. 连接中取消和快速重复点击至少 3 组，最终状态必须与最后一次操作一致。
4. 强制结束应用/核心后重开，验证 guardian 只恢复本应用拥有的代理；验证 RunOnce 恢复日志损坏时 fail-closed，不触碰无关代理设置。
5. 不做 Wi-Fi 断网注入；可以验证应用内正常失败路径，但不得改变现场网络基础设施。

E. 20 轮稳定性、性能和内存
1. 先预热 1 轮，再连续执行 20 轮“连接成功 -> 实际数据请求成功 -> 正常断开 -> 代理/TUN/端口清理”。每轮记录：连接耗时、断开耗时、结果、PID、WorkingSet64、端口/代理/TUN 状态。
2. 另采样至少 10 次冷/温启动耗时；对启动、连接、断开分别计算样本数、中位数、P95、最大值。不要删掉失败样本。
3. 第 5 轮作为预热内存基线；第 20 轮结束、断开并空闲 2 分钟后再次记录。若高于第 5 轮 20% 或持续单调增长，使用 Windows Performance Recorder/任务管理器进一步定位并标记失败或待调查。
4. 任何崩溃、卡死、残留代理、残留 TUN/路由、残留 7890/7891/9090 或状态漂移都算失败。

F. 能耗、大字体和键盘
1. 在同一网络、电源模式和后台负载下，建立断开空闲 30 分钟和连接空闲 30 分钟两组基线。使用 powercfg /energy（需要管理员时让我确认），同时记录 SSRVPN/mihomo CPU time、Working Set 和唤醒/错误摘要。不要直接比较不同电源条件的电池百分比。
2. 报告每组起止时间、电源条件、powercfg 报告路径和脱敏摘要；发现持续高 CPU、异常唤醒或连续偏离时附 WPR/系统证据。
3. 将 Windows 文本缩放到 200%（切换前记录原值，完成后恢复），验证主页、节点页、订阅页、诊断页没有关键控件不可达或弹窗无法关闭。
4. 全程只用键盘完成一次启动、打开节点页、选择节点、打开订阅/诊断和关闭弹窗；焦点顺序可预测，焦点可见。
5. 不启用 Narrator、其他屏幕阅读器或盲文。完成后恢复原文本缩放状态。

G. Windows 生命周期自动化补强
1. 先运行并阅读现有 Windows Flutter、PowerShell、Python 和原生 harness；重点检查：
   - SSRVPN_Windows/windows/runner/launcher_main.cpp
   - SSRVPN_Windows/lib/services/clash_service_lifecycle.dart
   - SSRVPN_Windows/lib/services/windows_start_transaction.dart
   - scripts/test_windows_native_proxy_recovery.ps1
   - scripts/test_windows_installer_runtime.ps1
   - scripts/test_windows_proxy_shutdown_recovery.py
   - scripts/test_windows_runonce_proxy_recovery.py
2. 列出 launcher 生命周期中已经有确定性测试证据和仍无证据的分支。不要以整文件覆盖率低为理由大改。
3. 若存在与本次实机路径直接相关、当前无法确定性验证的分支：先写一个会失败的最小测试并保存 RED 结果，再从 launcher 提取最小纯函数/小状态机或补充现有 harness，使测试转绿。优先覆盖单实例/窗口激活、托盘重建、退出清理、guardian/RunOnce、TUN UAC 取消与提交边界。
4. 不改变公开行为、不新增依赖、不重写 Win32 架构。若现有测试已经充分证明该分支，只补证据说明，不做无收益重构。

H. 测试门禁
至少执行并记录：
- flutter pub get
- dart format --output=none --set-exit-if-changed（仓库内 Dart）
- flutter analyze（SSRVPN_Windows）
- flutter test --coverage（SSRVPN_Windows）
- PowerShell 5.1 兼容性测试和仓库现有全部 Windows installer/native/proxy/RunOnce 测试
- scripts/check-windows-launcher-security.sh（在 Git Bash/WSL 可用环境）
- make verify；若 Windows 缺少 make/bash，运行 scripts/verify-all.sh 的可用等价门禁，并用 GitHub Actions 补齐，不能静默跳过。
- git diff --check

I. 报告、提交和交付
1. 新建并提交 `docs/uat/SSRVPN_Windows_v4.0.13_实机验收报告_20260820.md`，至少包含：
   - 脱敏证据头；
   - C-01~C-10、W-01~W-06 逐项 PASS/FAIL/BLOCKED；
   - 三项修复的单独结论；
   - 20 轮明细和启动/连接/断开中位数、P95、最大值；
   - 第 5/20 轮内存、2 分钟空闲结果；
   - 两组 30 分钟能耗结果；
   - 200% 文本、键盘结果，并注明屏幕阅读器/盲文按用户要求不在本轮范围；
   - 自动化补强的 RED/GREEN 证据；
   - 测试前后代理、TUN、进程、端口和配置恢复证据；
   - 未完成项、复现步骤和残余风险。
2. 原始日志和 powercfg HTML 留在本机临时证据目录，不提交；报告里只给脱敏摘要和文件哈希。
3. 最终检查 `git status`、`git diff`、测试结果；只提交与 Windows 验收/测试补强有关的文件。
4. 提交信息使用 Conventional Commits，例如 `test(windows): record v4.0.13 physical UAT`。
5. 推送当前测试分支到 origin。禁止创建 PR、禁止合并 main、禁止打标签、禁止创建 Release、禁止触发发布工作流。
6. 最后回复我：
   - 总结 PASS/FAIL/BLOCKED 数；
   - 明确三项正式版修复是否通过；
   - 给出分支名、提交 SHA、报告路径和远端分支链接；
   - 列出所有实际执行的命令及退出码摘要；
   - 明确确认“未创建 PR、未合并、未发布”；
   - 如果需要我在 Windows 上做任何人工动作，只给最少且精确的步骤。

完成标准：正式安装器哈希正确；三项修复均有 Windows 实机证据；20 轮和性能/内存/能耗/大字体/键盘有真实结果；系统现场恢复；Windows 门禁通过；脱敏报告和必要测试已推送测试分支；没有 PR、合并或发布。
```
