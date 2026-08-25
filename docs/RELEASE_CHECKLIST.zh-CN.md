# SSRVPN 发布检查清单

这份清单给个人维护者使用，目标是每次发布都按同一套步骤走，减少漏项。

## 发布前

1. 先完成版本号和 changelog 修改并合入 `main`。发版不检查或更新 GeoIP；只有收到明确更新
   指令时，才单独运行 `Maintenance > geoip-refresh`、审查并合并它创建的 PR。
2. 确认版本号一致：

   ```bash
   scripts/check-version-sync.sh
   ```
3. 确认本地或 GitHub CI 通过：
   - `packages/ssrvpn_shared`
   - `SSRVPN_Android`
   - `SSRVPN_MacOS`
   - `SSRVPN_Windows`
   - Windows 日志包含 PowerShell 5.1 全脚本兼容性和新生成安装包真实安装/卸载通过记录；不得只依据 job 绿色，日志中任何脚本或安装器错误都必须对应失败步骤。
4. 确认三端项目地址都指向：
   - `https://github.com/Elegying/SSRVPN`
5. 确认 Release workflow 需要的 Android 自签名 secrets 已配置。桌面端固定走免费分发：
   macOS ad-hoc、未公证，Windows 未签名；仓库和 GitHub 配置中不应出现 Apple/Microsoft
   付费证书 secrets 或启用变量。
6. 引导并确认仓库内固定的核心二进制和 GeoIP 数据库哈希：

   ```bash
   make assets
   scripts/verify-core-assets.sh
   ```
   `Prepare Release` 与正式 `Release` 都不得请求上游 GeoIP、判断新旧或改写来源记录；固定
   快照不是最新版也不得阻断发版。完整性、三端一致性和已记录来源仍必须验证通过。
   只有精确 tag 下的 Release/资产 ID、上传完成状态、摘要、commit 与 provenance 全部一致的
   已有发布恢复重试，才允许复用原 tag 快照；授权阶段固定的 Release ID 与全资产规范身份会在
   发布 job 再次验证。构建期间 Release 消失、变残或被替换时必须失败，禁止删除后新建；缺失、
   重复、网络异常或不完整 draft 均失败关闭。最终公开、轮询和发布后终验继续绑定 numeric
   Release ID；只有预期的 draft → public 状态迁移不计入不可变资产身份。
   OSS 推广后、numeric-ID PATCH 前，以及公开轮询成功后、删除恢复备份前都会再次复核资产身份。
7. 确认没有明显密钥泄露、覆盖率没有低于当前保守门槛：

   ```bash
   scripts/check-secrets.sh
   gitleaks git --config .gitleaks.toml --redact --log-opts=--all
   make verify
   ```
8. 如本地已有安装包产物，做一次结构 smoke：

   ```bash
   scripts/smoke-release-artifacts.sh --allow-missing
   ```
9. 核对 [`third_party/THIRD_PARTY_NOTICES.md`](../third_party/THIRD_PARTY_NOTICES.md)
   中的精确 Mihomo 版本、Android commit、GeoIP 来源、对应源码方向与当前资产记录一致；确认
   三端产物的结构 smoke 分别找到该清单、完整 GPL-3.0 正文和 SSRVPN MIT 正文。上游精确源码不可访问时必须
   修复来源或撤回候选，不得只保留二进制继续发布。
10. 发布前后至少记录一次性能基准，用于对比低配设备体验是否退化：

   ```bash
   scripts/performance-baseline.sh
   ```

### Windows x64 实机冒烟

在干净 Windows 环境准备带有可识别旧订阅与设置的安装版目录，测试
`SSRVPN_Setup.exe` 全新安装与覆盖升级。测试前先记录系统代理原值：

```bat
reg query "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyEnable
reg query "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyServer
```

1. 运行 `SSRVPN_Diag.bat`；必需文件必须齐全，Mihomo 能输出版本，程序 10 秒后仍在运行；完成后从托盘退出诊断启动的实例。
2. 如果诊断报告旧版进程安全例外，以管理员身份运行一次 `remove_legacy_cet_exemption.bat`，然后重新诊断并确认警告消失。
3. 正常启动 `ssrvpn_windows.exe`；确认主页、订阅、节点和已选节点工作正常，`%LOCALAPPDATA%\SSRVPN\logs\startup.log` 没有启动失败。
4. 先从托盘退出正常实例，再运行 `ssrvpn_safe_mode.bat`；确认安全模式提示可见，托盘、旧窗口位置和 Mihomo 自动初始化均被跳过。
5. 使用系统代理模式连接；确认浏览器可联网、代理指向 `127.0.0.1` 的实际监听端口。正常断开后，`ProxyEnable` 和 `ProxyServer` 必须精确恢复为测试前的值。
6. 再次连接后从任务管理器结束 `bin\mihomo.exe`；应用应立即提示核心异常退出，自动清理
   自己设置的系统代理并只恢复一次。首次恢复成功应显示成功提示；再次结束核心后必须停止
   重试、退出连接状态并提示最终失败，不得留下半连接或循环拉起。
7. 再次连接后从托盘选择“退出 SSRVPN”；应用和 Mihomo 都应退出，系统代理必须恢复，`%LOCALAPPDATA%\SSRVPN\crashes` 不应新增转储。
8. 再次连接后只从任务管理器结束 `bin\ssrvpn_windows_app.exe`，保留外层 `ssrvpn_windows.exe` 等待子进程退出；外层启动器必须自动恢复系统代理。随后重启 Windows，在未重新打开 SSRVPN 前确认浏览器可直接联网，系统代理不得仍指向 SSRVPN 的本地端口。
9. Windows 分别用普通权限和管理员权限检查 TUN：管理员账户普通启动时必须显示 UAC，确认后安全重启并自动继续连接；取消、标准用户、其他账户凭据和交接失败时旧实例必须保留且不残留代理。管理员权限下应能连接、断开并恢复网络。macOS TUN 必须显示管理员授权框；取消授权、启动超时、正常断开和退出均不得遗留 root Mihomo、utun 默认路由、暂存目录或系统代理。
10. 在系统自带 Windows PowerShell 5.1 中确认 `$PSVersionTable.PSVersion` 后，创建两个带
   `settings.json` 的旧独立副本，并在 `%LOCALAPPDATA%\Programs\SSRVPN\bin\ssrvpn`、
   `%LOCALAPPDATA%\SSRVPN\ssrvpn` 和窗口状态文件中放置可识别旧配置，记录这些文件的
   SHA256，再启动 `SSRVPN_Setup.exe`。安装向导必须全程使用简体中文并在复制前准确说明
   替换和保留范围；它必须忽略两个旧独立副本，从普通桌面会话启动并在 UAC 授权后安装到
   固定的每用户目录。自 3.4.2 起，
   覆盖升级、卸载以及保留数据后的重装都必须保留安装版订阅、设置、DPAPI 密钥、
   LocalAppData 回退数据和窗口状态，前后哈希一致；程序文件、旧恢复状态和两个已知
   WebView 缓存目录必须清理。交互和静默安装完成后都不得自动启动 GUI。
   另保持已安装实例占用文件，确认安装器会在修改程序文件前阻断；退出实例后重试必须成功。
   再让其他目录中的 SSRVPN 副本持有全局实例锁：安装器应先结束当前安装路径中的精确进程，
   但保留外部副本、系统代理和恢复日志，并以 `APP_INSTANCE_ACTIVE` 在文件覆盖前停止。
11. 先确认未连接启动和首页初始化不会发起更新请求；连接节点后，应用内更新必须只从
   `Elegying/SSRVPN` 的正式 GitHub Release 读取并下载固定资产 `SSRVPN_Setup.exe` 及 SHA-256，
   不得请求 OSS `latest.json` 或 OSS 安装包。校验通过后必须使用 Windows Known Folder
   定位当前用户的真实桌面（包括重定向桌面），并保存为
   `SSRVPN_Setup_vX.Y.Z.exe`。完成后必须明确提示手动安装、成功后自动清理且取消或失败时
   保留；SSRVPN 保持运行，不自动打开或安装文件。Windows smoke 必须同时证明只有 v4.0.15
   或更高版本内置更新器下载、SHA-256 校验并写入专属标记的版本化安装包会在安装事务成功后
   删除；旧版客户端下载的首个升级包、手动包、取消或失败包、身份不匹配文件、用户数据和
   无关桌面文件全部保留。取消、摘要不匹配或下载失败不得损坏已有目标文件。日志可提交排查，
   但不要公开发送 `.dmp` 文件。
   另删除一个已标记安装包但保留其隐藏 sidecar，再重下同版本：新文件名必须为
   `SSRVPN_Setup_vX.Y.Z_<32 位小写十六进制>.exe`，新包仍可自动清理，旧 sidecar 内容不变。

## 发布

1. 首次运行前，将仅授权 `Elegying/SSRVPN`、Repository Administration read-only 的
   fine-grained PAT 保存为 repository secret `BRANCH_PROTECTION_READ_TOKEN`。随后运行
   `Prepare Release`。它先验证固定核心资产和精确 `main` 提交；
   若已有 24 小时内同仓库、同 `main` SHA 的成功 `push`/`workflow_dispatch` CI，
   且工作流路径与九项必需 job 的唯一性、结论均通过精确验证，则安全复用；若同一
   workflow 的该精确提交仍为 `queued`、`in_progress`、`requested`、`waiting` 或 `pending`，
   先等待原 run 完成，再重新执行相同的九项严格验收，避免重复调度触发取消重跑。并发取消
   只跟随同 SHA 后继 run，最多等待/替换三轮；等待完成后的列表传播最多复核五次，期间绝不
   再次 dispatch。仅在没有合格记录且没有可等待 run 或记录已过期时按原路径调度；非取消
   失败、超过边界、等待后身份/状态不明或 API/JSON 状态不明均失败关闭，不得当作“没找到”
   后补发新 run。在 tag 前确认 `main` 在验证期间没有前移。
   编排会在开始和创建 tag 前按 `.github/main-branch-protection.json` 校验严格分支保护及九项
   GitHub Actions 检查的精确名称和应用身份；缺项、多项或策略弱化都会失败关闭。
2. 只有上述步骤全部通过且远端不存在同名 tag/Release 时，编排才创建 annotated tag，并通过
   `workflow_dispatch` 显式启动该 tag 上的 `Release`。CI、合并、分支树一致性或 GitHub API
   状态任一不明确都会失败关闭。
   从编排最后一次复核 `main` 到 Release 的 `Validate release source` 通过前暂停合并 `main`；
   tag push 与 `main` 没有跨引用原子事务。若该窗口内 `main` 前移，Release 会拒绝旧 tip，且
   受保护的不可变 tag 不能删除或移动：此时必须升新版本创建新 tag，不能重跑这个搁浅 tag。
3. 等待 `Prepare Release` 所跟踪的 `Release` workflow 完成。
   工作流会先创建 Draft Release、上传并验证 OSS 不可变目录，然后备份并推广
   OSS 固定下载通道，最后公开 GitHub Release。GitHub 未能明确转为正式 Release
   时不得人工推进；按失败日志确认自动恢复结果或使用保留的恢复 Artifact。

### 手动恢复入口

GeoIP 更新不是发布回退步骤。只有收到明确更新指令时才手动运行
`Maintenance > geoip-refresh`，合并其 PR 并等待 `main` CI；正常和手工发版都只使用并校验
仓库内已经固定的快照。

若 `Prepare Release` 已成功推送 tag，但 `Release` 调度失败或等待超时，不得删除、移动 tag，
也不得用同名 tag 重跑准备流程。先确认失败不是“tag 后 `main` 前移”：若是该竞态，必须升新
版本创建新 tag；若 `main` 未前移，则确认没有重复的 Release run，再在 GitHub Actions 选择
该精确 tag 手动运行 `Release`，或执行 `gh workflow run release.yml --ref vX.Y.Z`。已有正式或
可验证 Draft Release 的重试仍必须通过精确 tag、commit、资产和 provenance 身份校验。

## 发布后

1. 打开 GitHub Release，确认有这些文件：
   - `SSRVPN.apk`
   - `SSRVPN.apk.sha256`
   - `SSRVPN.dmg`
   - `SSRVPN.dmg.sha256`
   - `SSRVPN_Setup.exe`
   - `SSRVPN_Setup.exe.sha256`
   - `SSRVPN-release-provenance.json`（绑定 tag、commit 与三个安装包 SHA256）
   或直接运行：

   ```bash
   scripts/check-release-assets.sh vX.Y.Z
   ```
2. 下载每个平台产物，至少做一次启动检查。
3. 检查未连接时不会检查更新，连接节点后应用内更新能从 GitHub Release 读到最新版本；
   Windows 应将经校验的当前版本安装包保存到真实桌面，显示手动安装与安全清理提示并保持
   客户端运行，不打开外部下载链接；只有 v4.0.15 或更高版本客户端写入专属标记的后续更新包
   才在成功安装后删除，旧版客户端下载的首个升级包、取消、失败和手动下载的安装包必须保留。
4. 按 `docs/PRODUCT_REQUIREMENTS.zh-CN.md` 检查安装包、首次导入、节点排序和记忆节点行为。
5. 按校验机器的系统检查 SHA-256 文件；不要把不同系统的命令混在同一个终端中执行：

   macOS：

   ```bash
   shasum -a 256 -c SSRVPN.dmg.sha256
   ```

   Linux：

   ```bash
   sha256sum -c SSRVPN.apk.sha256
   ```

   Windows PowerShell（计算结果必须与随包校验文件中的摘要一致）：

   ```powershell
   Get-FileHash .\SSRVPN_Setup.exe -Algorithm SHA256
   Get-Content .\SSRVPN_Setup.exe.sha256
   ```
6. 校验三个安装包均由本仓库 `release.yml` 对应 tag 的 GitHub Actions 构建并签发证明：

   ```bash
   gh attestation verify SSRVPN.apk --repo Elegying/SSRVPN --signer-workflow Elegying/SSRVPN/.github/workflows/release.yml --source-ref refs/tags/vX.Y.Z
   gh attestation verify SSRVPN.dmg --repo Elegying/SSRVPN --signer-workflow Elegying/SSRVPN/.github/workflows/release.yml --source-ref refs/tags/vX.Y.Z
   gh attestation verify SSRVPN_Setup.exe --repo Elegying/SSRVPN --signer-workflow Elegying/SSRVPN/.github/workflows/release.yml --source-ref refs/tags/vX.Y.Z
   ```

   attestation 不替代安装包旁的 SHA256，也不代表 Apple/Microsoft 受信任发布者签名。
7. 检查用户会看到的系统提示是否符合预期：
   - Android APK 使用同一个自签名 keystore，可覆盖安装升级。
   - macOS 未公证时可能需要右键打开。
   - Windows 未代码签名时可能出现 SmartScreen 未知发布者提示。
