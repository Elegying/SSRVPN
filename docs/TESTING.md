# 测试策略

测试目标不是制造数量，而是证明用户可见状态、失败回滚和安全边界在三个平台上仍然成立。新增或修复行为应先写一个会失败的最小回归测试，再实现到转绿。

## 合并门禁

根目录唯一完整入口：

```bash
make verify
```

当前门禁依次验证：

- 共享包导入、版本同步、安装包内指南和当前文档一致性。
- Mihomo/GeoIP 资源的可复现引导与 SHA256。
- Android native bridge、解锁取消、桌面启动、Clash 职责、macOS 特权和 Windows launcher 的静态边界。
- 全部受版本控制 PowerShell 脚本的 Windows PowerShell 5.1 解析与已知参数集兼容性，以及 CI/Release 子进程退出码的逐次传播。
- 明显密钥模式扫描和发布工具单元测试。
- Flutter workspace 依赖解析与零 analyzer finding。
- `ssrvpn_shared`、Android、macOS、Windows 的覆盖率测试。
- Android Kotlin/JUnit 原生测试。

行为、原生集成或打包有变化时，`make verify` 只是最低要求，还必须运行下面的目标平台检查。

## 覆盖率门槛

门槛是回归保险，不是质量分数。本轮根据已稳定通过的实际基线，将过低的 `50/40/10/12` 收紧为：

| 目标 | 最低行覆盖率 |
| --- | ---: |
| `packages/ssrvpn_shared` | 65% |
| Android | 50% |
| macOS | 30% |
| Windows | 30% |

不得通过排除生产源码、删除分支或添加无有效断言的测试来满足门槛。若行为新增导致覆盖率下降，应优先覆盖用户结果与错误路径；确需调整门槛时，在 PR 中写明可执行行变化和风险。

定向查看：

```bash
scripts/check-coverage-thresholds.sh
scripts/check-coverage-thresholds.sh SSRVPN_MacOS
```

## 分层策略

### 共享逻辑

订阅解析与合并、输入边界、YAML 生成、更新下载、脱敏、解锁证据、控制器状态和跨平台 UI 行为优先放在 `ssrvpn_shared` 测试。失败测试应断言最后可用数据未被破坏。

### Flutter 平台层

各平台覆盖设置迁移、配置差异、连接控制器、进程/代理协调和关键 UI 状态。凭据存储测试使用注入的读写函数证明“写入并回读成功后才删除旧明文”，并覆盖轮换失败回滚、重置串行化与损坏设置清理；macOS 还验证专用文件权限及启动/重置清除崩溃临时文件，Windows 还验证替换失败保留旧密文、解密失败保留恢复证据，并必须在目标 OS 构建/运行以验证 DPAPI FFI 链路。

### 原生层

- Android Kotlin/JUnit 覆盖 VPN Service 代际、更新安装身份和 Mihomo API 健康检查；涉及 Service、磁贴、通知或 MethodChannel 时还需真机回归。
- macOS Swift/XCTest 覆盖窗口/Dock 生命周期等原生行为；TUN、管理员授权、系统代理和打包必须在 macOS 实际运行。
- Windows launcher、安装器、代理恢复和进程路径需要 Windows CI。CI 必须用 `powershell.exe` 5.1 执行全部脚本兼容性测试，并在每个子进程后检查退出码，不能只看最后一条打包命令；首次安装、覆盖升级、异常退出、重启与卸载仍需干净 Windows 设备。

### 发布与文档

发布工具使用 Python 单元测试和资产冒烟；文档门禁只扫描当前有效文档，不因历史 CHANGELOG 或审查报告中的旧事实失败。发布后资产检查通过已认证的 GitHub CLI 下载元数据、SHA-256 文件与 provenance，并对瞬时失败有限重试；随后还要重新下载公开产物并校验随包 SHA256。

## 常用命令

```bash
# 全量
make verify

# 工作区
scripts/workspace.sh pub-get
scripts/workspace.sh analyze
scripts/workspace.sh test

# 单平台示例
cd SSRVPN_Android && flutter test --coverage
cd SSRVPN_MacOS && flutter test --coverage
cd SSRVPN_Windows && flutter test --coverage

# Android 原生
scripts/test-android-native.sh

# 产物与性能
scripts/smoke-release-artifacts.sh --allow-missing
scripts/performance-baseline.sh
```

从平台目录执行后续根脚本时注意恢复仓库根目录；CI 与交接记录必须写出实际执行命令、平台、退出码和跳过项。

## 改动对应的最低证据

| 改动 | 最低额外验证 |
| --- | --- |
| 订阅/节点/YAML | 边界输入、回滚、目标平台生成配置 |
| 连接/取消/核心进程 | 重复操作、取消延迟、过期代际、异常退出清理 |
| 系统代理/TUN | 所有权判断、失败回滚、真实 OS 冒烟 |
| 凭据存储 | 旧数据迁移、写失败回滚、并发重置、普通保存不回写、目标 OS 权限/构建 |
| 更新/发布 | 来源、版本、资产名、大小、SHA256、重定向和失败清理 |
| UI/无障碍 | Widget 测试加目标平台键盘/读屏器检查 |
| 安装/升级 | 干净环境首次安装、全新覆盖、PowerShell 5.1、普通用户权限、异常退出/重启后的系统代理、卸载 |

网络相关测试不得依赖开放公网稳定性；需要真实下载或发布验证时，应单独标注为集成/发布冒烟并记录时间与来源。
