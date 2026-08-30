## 变更摘要

-

## 影响范围

- [ ] 跨平台共享逻辑
- [ ] Android
- [ ] macOS
- [ ] Windows
- [ ] CI / 发布 / 文档

## 验证

- [ ] `scripts/check-quality-hygiene.sh`
- [ ] `scripts/check-shared-barrel-imports.sh`
- [ ] `scripts/workspace.sh analyze`
- [ ] `scripts/workspace.sh test`
- [ ] `make verify` before merge, or the PR explains why a target-platform gate must run in CI

## 安全与兼容性

- [ ] 未提交或记录密钥、真实订阅、节点凭据、构建产物或未经处理的不可信输入。
- [ ] 除非本 PR 明确替换已有决策，否则订阅兼容、Android 国内应用绕过、IPv4-only 路由和两页产品结构保持不变。
- [ ] 原生生命周期、系统代理、TUN、安装器或发布变更包含目标平台证据。

## 用户可见说明

-

## 风险与回滚

-
