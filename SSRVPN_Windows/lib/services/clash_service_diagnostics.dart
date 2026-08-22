part of 'clash_service.dart';

List<AppDiagnosticCheck> _buildWindowsPlatformDiagnosticChecks({
  required bool recoveryPending,
  required String? ownershipWarning,
}) {
  final ownershipUnavailable = ownershipWarning?.trim().isNotEmpty ?? false;
  return [
    AppDiagnosticCheck(
      id: 'system_proxy',
      title: '系统代理恢复',
      status: recoveryPending || ownershipUnavailable
          ? AppDiagnosticStatus.warning
          : AppDiagnosticStatus.passed,
      summary: recoveryPending
          ? '检测到 SSRVPN 自有的待恢复代理状态'
          : ownershipUnavailable
              ? '系统代理所有权检查暂时不可用；核心正常，当前连接保持'
              : '没有待恢复的 SSRVPN 系统代理状态',
      errorCode: recoveryPending
          ? AppErrorCode.proxyRecoveryPending
          : ownershipUnavailable
              ? AppErrorCode.systemProxyOwnershipUnavailable
              : null,
      repairAction:
          recoveryPending ? AppRepairAction.retryOwnedProxyRecovery : null,
    ),
  ];
}

String _friendlyStartException(Object error) {
  final message = error.toString();
  final lower = message.toLowerCase();
  if (lower.contains('access is denied') ||
      lower.contains('permission denied') ||
      lower.contains('拒绝访问')) {
    return '无法执行 Mihomo，文件可能被安全软件拦截或当前目录没有执行权限';
  }
  if (lower.contains('not a valid win32') || lower.contains('不是有效的 win32')) {
    return 'Mihomo 与这台电脑的 Windows 架构不兼容，本版本仅支持 64 位 Windows';
  }
  return '启动 Mihomo 时发生异常: $message';
}

String? _describeWindowsExitCode(int exitCode) {
  switch (exitCode) {
    case -1073741819: // 0xC0000005
      return '访问冲突，通常是 CPU 指令集或旧版 Windows 兼容问题，也可能被安全软件注入拦截';
    case -1073741795: // 0xC000001D
      return '非法指令，当前 CPU 不支持此核心使用的指令集';
    case -1073741515: // 0xC0000135
      return '缺少运行库或依赖 DLL';
    case -1073741701: // 0xC000007B
      return '程序或依赖 DLL 的 32/64 位架构不匹配';
    default:
      return null;
  }
}
