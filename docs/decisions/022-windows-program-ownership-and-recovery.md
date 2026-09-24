# ADR-022：Windows 程序文件归属与安装元数据恢复

日期：2026-09-24。状态：已接受；发布验收状态以 `PROJECT_HEALTH.md` 为准。

## 原因

N03：扫描安装目录只能说明文件存在，不能证明文件属于 SSRVPN。旧事务及 Inno
`[InstallDelete]` 将扫描结果当成清理授权，升级和恢复会删除未知文件；旧 Discard 还会清掉
另一安装目录的共享恢复根。N04：管理员 x64 Inno 写 HKLM64，自有回滚却只记录 HKCU。
安装末段失败后，自有 Recover 可恢复旧文件，却留下新卸载记录。

## 归属来源与旧版迁移

- 新包清单由固定构建入口枚举实际 payload，记录 SHA-256，随 Inno 压缩包内嵌。
  它只授权写入新文件，不能授权删除旧文件。正式包不含任何故障注入开关。
- 旧文件归属优先来自上次成功提交的清单。清单存于 HKLM64 的
  `Software\SSRVPN\InstallerOwnership\<安装绝对路径的小写 SHA-256>`，ACL 仅允许
  Administrators/SYSTEM；每项包含精确相对路径、长度、SHA-256，并绑定安装目录。
- 首次迁移使用 `legacy-program-catalogs.json`：通过固定发布资产 ID、HTTPS URL 和完整包
  SHA-256 下载官方安装器，在一次性 Windows runner 真正安装后采集程序文件。
  来源固定于 `scripts/windows_legacy_installer_sources.json`；生成入口为
  `collect_windows_installer_catalogs.ps1`，不得用当前目录扫描替代。
- 当前目录包含全部可下载的 16 个正式 Windows 版本：5.0.1–5.0.8、5.0.10–5.0.13、
  5.0.15–5.0.18。启动器哈希必须唯一对应一份旧包清单；存在的每个旧程序文件还须逐项验证。
  缺失旧文件允许修复安装；被修改的旧文件、冲突的新目标均在 Clear 前拒绝。
- 旧 `unins*.dat/msg` 随安装路径生成，未纳入历史程序归属，保留在原位置；它们不是 DLL，
  不参与新程序加载。旧包中已知但新包移除的 DLL 必须删除，不能与新 DLL 混用。
- 没有公开原包清单的更早版本、第三方构建和被修改程序不猜测归属。保留原目录和个人数据，
  选择独立空目录安装；旧数据不自动发现、合并或删除。可从已验证的原版包恢复程序文件后
  再覆盖升级，但不能要求用户删除个人文件。

## 事务协议与提交点

schema 4 记录 installDir、registry root/view、快捷方式路径、事务 UUID、恢复根、旧归属、
新 payload、备份文件清单以及四份元数据文档摘要。完整 state 使用该安装目录专属的随机
HMAC 密钥认证；密钥也在受保护注册表键内。状态经独占临时文件、Flush(true) 和原子替换落盘。

1. Begin 验证新旧归属和目标冲突，只备份已确认旧程序，记录 HKLM64 卸载项及快捷方式。
   卸载项存在与否、全部值类型和数据均保留；记录 root/view，恢复时必须与调用方相同。
2. Clear 再验证备份、新目标和所有旧文件，持有备份与目标句柄后仅删除旧清单条目。
3. Inno 将 payload 解到自己的临时目录；生产 helper 以 CreateNew 独占发布、逐文件验哈希。
   原目录中的未知文件、Begin 后新增文件及 `bin\ssrvpn` 始终保留。
4. Inno 写快捷方式、卸载记录并最终写入专属 `installer-state\<随机标识>` 目录；Seal 记录
   已最终生成的卸载器和日志。每次使用新目录，避免旧卸载日志继续拥有新 payload。
5. Commit 再验新文件并持久化新归属，最后写 committed。此后清理失败只记录
   `COMMITTED_CLEANUP_PENDING`，不回滚成功安装。
6. Recover 在任何删除前验证完整材料，仅接受目标文件仍为旧哈希或本事务新哈希。
   被第三方改写、占用或替换成重解析点时停止并保留材料。恢复期间持有已验证备份句柄，
   防止校验后换掉 `.reg` 或其他恢复源。文件、注册表和快捷方式均校验成功且 restored
   已持久化，才能报告恢复完成。单独诊断 status 文件不可写不改变事务成功结果。
7. prepared/cleared 时 Inno 尚未执行图标/注册阶段，Recover 不重放共享元数据，避免把目录 A
   后来的卸载撤销；validated 阶段恢复已记录的注册表/快捷方式。重复恢复可继续未完成工作。

自有恢复根为 `%LOCALAPPDATA%\SSRVPN\installer-recovery-v4\<目录哈希>`，避免旧卸载器
仍认识的共享根被用于新事务。Discard 先校验目录、hive/view、事务认证，只清理已结束事务。
尚未认证的 staging、未知子项、无效 state 均保留，不用递归删除作为容错策略。
最终空目录清理也只接受本事务创建的 program 目录及文件清单推导的父目录；后到的未知
空目录与未知文件一样阻止清理，保留全部剩余材料，不回滚已经提交的新程序。

## 旧 schema 2/3 与不可恢复状态

旧状态没有可信文件归属；schema 2 还没有 HKLM 原值。新版不得猜测原值、把 HKCU 导入 HKLM，
或用全目录清理尝试恢复。发现与当前目录有关的旧事务时，在修改程序之前停止并保留全部材料。
损坏到无法判断目录的旧状态也不自动删除。处理路径：先完整归档旧安装目录与旧恢复目录，
由维护者核对原版本和实际卸载信息；如果选择先恢复可用性，则把已归档的旧恢复材料独立保存，
在新的空目录安装。这个过程不声称修好了缺失的旧注册表快照，也不自动迁移用户数据。

## 卸载及既定政策

Inno 不再持有 payload 的自动删除记录；helper 验证已提交清单并删除精确程序文件。
Inno 独占已打开的 `unins000.dat`。普通读取失败时，仅在调用本 helper 的直接父进程是已验证
原卸载器的 `_unins.tmp` 副本、SECONDPHASE 指向本目录且进程创建时间一致时，使用 Windows
公开的 PssCaptureSnapshot/DuplicateHandle API 取得该父进程现有 DAT 句柄的只读副本，完成
同样的长度与完整 SHA-256 校验。读取前后恢复共享文件位置，不关闭父进程句柄，不写文件、
放宽共享模式/权限、调试提权或注入进程。扫描有数量上限，身份/权限/API 失败均拒绝卸载。
Inno 最终删除它自己的卸载元数据；其他进程持有 DAT 时不能进入这条读取路径。
当前卸载项指向其他安装目录时拒绝卸载，防止 Inno 自动删除另一目录的记录。
非目标 HKCU/HKLM 项不参与清理。用户数据保留、进程白名单、代理/TUN、内核、GeoIP、
更新包来源校验及免费签名政策保持原边界。

Inno 6.7.1 的 ssPostInstall 异常本身不会触发其完整文件回滚，也可能返回 0。
自有提交失败以专属退出码 10 报告，并在完成页说明未完成；退出时尝试自有 Recover，结果以
日志为准。`/SUPPRESSMSGBOXES` 下错误提示可被抑制，仍返回失败，不能静默挂在确认框。

## 验证入口

- 历史资产采集：[Maintenance 35979092156](https://github.com/Elegying/SSRVPN/actions/runs/35979092156)。
- N03/N04 真实旧行为及 N04 成功恢复：[Maintenance 35982923479](https://github.com/Elegying/SSRVPN/actions/runs/35982923479)。
  此轮后续卸载暴露 DAT 锁冲突，不能把该 run 标成整体通过。
- 修复后完整矩阵：[Maintenance 35987784213](https://github.com/Elegying/SSRVPN/actions/runs/35987784213)，
  HKCU/HKLM 各 36 组生产事务场景及 10 组真实 Inno 场景全部通过，包含中文路径、真实状态
  写失败和当前/历史 A 卸载器对 B 材料的保护。Windows Server 2025 / PS 5.1 / Inno 6.7.1。
- `test_windows_installer_ownership.ps1`：PS 5.1 真实 helper 故障/冲突/跨目录/提交边界矩阵。
- `test_windows_installer_ownership_package.ps1`：固定官方 v5.0.18 和临时故障包的真实 Inno 矩阵；
  候选包复用已验证 v5.0.18 应用字节，验证安装器行为，不能冒充正式候选应用构建。
- `test_windows_installer_package.ps1`：实际当前应用构建、原生进程、覆盖升级与卸载 smoke。
- 以上注册表及安装执行仅允许一次性 GitHub Windows runner；PR/main 的 Windows 汇总门禁
  必须同时通过这些测试。最终公开 EXE 另做匿名下载校验和隔离验收。

本 ADR 取代 ADR-002 中由 Inno 广泛替换程序的实现描述，不变更其个人数据保留原则；安装
目录可选择及进程处理以当前产品硬规则和 ADR-021 为准。
