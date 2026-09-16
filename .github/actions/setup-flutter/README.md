# 固定版本的 Flutter 设置 Action

此目录保留 [subosito/flutter-action](https://github.com/subosito/flutter-action/tree/1a449444c387b1966244ae4d4f8c696479add0b2)
提交 `1a449444c387b1966244ae4d4f8c696479add0b2` 的实现，遵循同目录的 MIT `LICENSE`。

仓库要求所有远程 Action 使用完整提交 SHA。上游 composite Action 内部的两个
`actions/cache@v5` 引用不满足此要求，即使外层已固定 SHA，也会在 GitHub Actions 准备阶段失败。

本地副本仅将 `action.yaml` 中上述两个引用固定为
`actions/cache@caa296126883cff596d87d8935842f9db880ef25`。
该提交已通过 GitHub API 核对为 `actions/cache` 的 `v5` 对应提交。
`setup.sh`、`LICENSE` 和其余 Action 配置均与原提交逐字节一致；Flutter 下载、版本选择、
三平台路径、SDK 缓存和 pub 缓存行为保持不变。

## 更新方法

1. 选择并记录明确的上游完整提交 SHA，审查与当前来源的差异。
2. 从该提交获取 `action.yaml`、`setup.sh`、`LICENSE`，保留原脚本和许可证。
3. 核对所有远程子 Action 的真实提交，将引用固定为完整 SHA；同时检查子 Action 的依赖。
4. 更新本文件的来源记录和 `scripts/test_dependency_security.py` 中的原始 Git blob 摘要。
5. 运行 `python3 -m unittest scripts.test_dependency_security`、ShellCheck 和 actionlint，
   并确认 Android、macOS、Windows CI 的设置、缓存、分析、测试与构建成功后再发布。

各工作流须先检出 SSRVPN 仓库，再通过 `uses: ./.github/actions/setup-flutter` 调用本地 Action。
