part of 'app_diagnostics.dart';

/// Presentation only: never infer a root cause from raw log text or change a
/// check's severity. The original observation stays in the technical details.
class AppDiagnosticGuidance {
  const AppDiagnosticGuidance(this.problem, this.impact, this.nextStep);

  final String problem;
  final String impact;
  final String nextStep;
}

extension AppDiagnosticCheckGuidance on AppDiagnosticCheck {
  bool get needsAttention =>
      status == AppDiagnosticStatus.failed ||
      status == AppDiagnosticStatus.warning;

  AppDiagnosticGuidance? get guidance {
    if (!needsAttention) return null;
    if (id == 'last_start') {
      return const AppDiagnosticGuidance(
        '上一次连接没有完成',
        '这是历史记录，不代表当前连接仍然失败。',
        '以本次运行状态为准；若仍无法连接，查看下方错误编号并复制报告。',
      );
    }
    if (id == 'ports') {
      return const AppDiagnosticGuidance(
        '已自动避开被占用的本地端口',
        '客户端已改用可用端口，这条记录本身不代表连接故障。',
        '若当前访问正常，无需处理。',
      );
    }
    if (id == 'data_plane') {
      return const AppDiagnosticGuidance(
        '还不能确认外部网络是否可用',
        '探测未通过或结果暂不可用，不能据此认定节点损坏或所有网站都打不开。',
        '先试着打开需要访问的网站；若确实打不开，再换节点重试。',
      );
    }
    if (errorCode == AppErrorCode.proxyRecoveryPending) {
      return AppDiagnosticGuidance(
        '系统代理还有待恢复的设置',
        '可能影响其他应用联网，尚未确认实际访问是否受影响。',
        repairAction == AppRepairAction.retryOwnedProxyRecovery
            ? '点击“修复系统代理”，完成后重新检查。'
            : '重新检查；若仍提示待恢复，复制报告以便排查。',
      );
    }
    if (errorCode == AppErrorCode.systemProxyOwnershipUnavailable) {
      return const AppDiagnosticGuidance(
        '暂时无法核实系统代理状态',
        '检查没有完成，不能据此认定代理设置错误；当前连接保持。',
        '若访问正常可继续使用，稍后重新检查。',
      );
    }
    if (errorCode == AppErrorCode.tunRecoveryPending) {
      return const AppDiagnosticGuidance(
        '上次连接的网络清理尚未完成',
        '新的连接可能需要等待清理完成。',
        '稍后重新检查；持续未恢复时复制报告，不要手动删除系统网卡。',
      );
    }
    if (id == 'platform' || id == 'android_native') {
      return const AppDiagnosticGuidance(
        '部分系统状态未能检查',
        '当前信息不足，尚不能判断这部分连接状态。',
        '稍后重新检查；若仍未完成，复制报告。',
      );
    }
    if (id == 'controller_endpoint') {
      return AppDiagnosticGuidance(
        '本地连接服务的通信需要检查',
        status == AppDiagnosticStatus.failed
            ? '客户端使用的控制端口与运行端口不一致。'
            : '这次未连上本地控制端口，原因尚未确定。',
        '连接或断开完成后重新检查；持续异常时复制报告。',
      );
    }
    if (id == 'core_session') {
      return const AppDiagnosticGuidance(
        '连接进程已停止',
        '如果刚刚主动断开，这是预期状态；否则连接可能已中断。',
        '需要联网时重新连接；若反复停止，复制报告。',
      );
    }
    // A code can identify an observed failure, but does not prove why it arose.
    return switch (errorCode) {
      AppErrorCode.coreMissing => const AppDiagnosticGuidance(
          '连接服务文件未确认可用',
          '文件检查未通过，连接可能无法启动；尚不能确定是缺失、损坏还是检查失败。',
          '先重新检查；持续失败时从官方来源重新安装客户端。',
        ),
      AppErrorCode.permissionRequired => const AppDiagnosticGuidance(
          '连接所需的系统授权未完成',
          '需要该授权的连接方式暂时无法启动。',
          '重新连接时完成系统授权；若系统不允许授权，复制报告。',
        ),
      AppErrorCode.coreUnavailable ||
      AppErrorCode.localProxyUnavailable =>
        const AppDiagnosticGuidance(
          '本地连接服务状态异常',
          '连接可能无法正常转发，具体原因尚未确定。',
          '等待当前连接操作结束后重新连接；若仍失败，复制报告。',
        ),
      AppErrorCode.configInvalid => const AppDiagnosticGuidance(
          '本次运行配置未确认可用',
          '连接可能无法启动或继续运行，不代表保存的订阅已丢失。',
          '重新连接以生成运行配置；仍失败时复制报告。',
        ),
      _ => null,
    };
  }
}
