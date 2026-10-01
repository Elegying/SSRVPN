# 待验证的可靠性问题

- [ ] **Windows 夹具可执行路径偶发不匹配**：在带有当前 PID、调用行、预期路径和实际路径诊断的 Windows 运行中复现，确认启动竞态、路径规范化或进程归属问题后，再修改对应边界。保留严格身份断言；同提交重跑通过不能单独证明是环境问题。[失败运行](https://github.com/Elegying/SSRVPN/actions/runs/36683539187/attempts/1)
- [ ] **Windows 升级预安装身份拒绝**：围绕 `IDENTITY_UNVERIFIED` 采集无法证明归属的具体原因，区分宿主进程信息不可读与生产身份处理缺陷。已有失败在程序文件修改前返回；保留此安全边界，按确认根因补回归后再调整模块。[失败运行](https://github.com/Elegying/SSRVPN/actions/runs/36701722872/attempts/1)
