part of 'clash_service.dart';

@visibleForTesting
List<AppDiagnosticCheck> buildWindowsPlatformDiagnosticChecks({
  required bool activeTunSession,
  required bool recoveryPending,
  required String? ownershipWarning,
  required WindowsTunTeardownGate tunRecovery,
}) {
  final ownershipUnavailable = ownershipWarning?.trim().isNotEmpty ?? false;
  final protectedSession = activeTunSession && tunRecovery.ownershipKnown;
  final restorationPending = tunRecovery.pending && !protectedSession;
  return [
    AppDiagnosticCheck(
      id: 'tun_recovery',
      title: 'TUN 网络恢复',
      status: restorationPending
          ? AppDiagnosticStatus.warning
          : AppDiagnosticStatus.passed,
      summary: tunRecovery.pending && protectedSession
          ? '当前 TUN 连接已启用恢复保护，断开后会自动检查网络清理情况'
          : tunRecovery.diagnosticSummary,
      errorCode: restorationPending ? AppErrorCode.tunRecoveryPending : null,
    ),
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
  // CreateProcess can surface invalid or truncated executables through
  // localized messages (and, on some Windows runner images, through Dart's
  // generic process_win.cc fallback). Never expose that raw exception or the
  // command line: this boundary only needs to tell the user how to recover.
  return '无法启动 Mihomo，核心文件可能损坏或与 Windows 架构不兼容；请重新安装官方版本后重试';
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

Future<AppDiagnosticCheck> _buildWindowsCoreSessionDiagnostic({
  required Process? process,
  required bool starting,
  required bool stopping,
  required bool tun,
}) async {
  final exited = process == null
      ? null
      : await process.exitCode
          .then((_) => true)
          .timeout(const Duration(milliseconds: 100), onTimeout: () => false);
  return AppDiagnosticCheck(
    id: 'core_session',
    title: '核心进程与会话',
    status: exited == null
        ? AppDiagnosticStatus.skipped
        : exited
            ? AppDiagnosticStatus.warning
            : AppDiagnosticStatus.passed,
    summary: 'PID：${process?.pid ?? '未获取'}；'
        '进程：${exited == null ? '未独立确认' : exited ? '已退出' : '存活'}；'
        '启动：${starting ? '进行中' : '无'}；'
        '停止：${stopping ? '进行中' : '无'}；'
        'TUN：${tun ? '已启用' : '未启用'}。',
  );
}

extension _WindowsPlatformDiagnostics on _WindowsCoreLifecycle {
  Future<List<AppDiagnosticCheck>> _windowsPlatformDiagnosticChecks({
    required String? ownershipWarning,
  }) async {
    final process = _coreProcess;
    final session = await _buildWindowsCoreSessionDiagnostic(
      process: process,
      starting: _startOperation != null,
      stopping: _stopOperation != null,
      tun: _coreUsesTun,
    );
    return [
      session,
      ...buildWindowsPlatformDiagnosticChecks(
        activeTunSession: session.status == AppDiagnosticStatus.passed &&
            identical(process, _coreProcess) &&
            isRunning &&
            _coreUsesTun &&
            _startOperation == null &&
            _stopOperation == null,
        recoveryPending: _proxyService.recoveryPending,
        ownershipWarning: ownershipWarning,
        tunRecovery: _tunTeardownGate,
      ),
    ];
  }
}
