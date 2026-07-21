part of 'app.dart';

@visibleForTesting
Widget buildWindowsStartupScaffold({
  required bool startupFailed,
  required double? startupProgress,
  required List<StartupFailure> failures,
  required String? secretRecoveryError,
  required bool secretRecoveryInProgress,
  required void Function(BuildContext context, String secretPath)
      onSecretRecovery,
}) {
  final requiresSecretRecovery =
      failures.any((failure) => failure.requiresWindowsSecretRecovery);
  final secretRecoveryPath = failures
      .where((failure) => failure.requiresWindowsSecretRecovery)
      .map((failure) => failure.windowsSecretRecoveryPath)
      .whereType<String>()
      .firstOrNull;
  return Scaffold(
    backgroundColor: const Color(0xFF050508),
    body: SafeArea(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final minContentHeight =
              constraints.maxHeight > 64 ? constraints.maxHeight - 64 : 0.0;
          return SingleChildScrollView(
            key: const Key('windows-startup-shell-scroll'),
            padding: const EdgeInsets.all(32),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: minContentHeight),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        startupFailed
                            ? Icons.error_outline_rounded
                            : Icons.shield_outlined,
                        color:
                            startupFailed ? AppTheme.error : AppTheme.primary,
                        size: 42,
                      ),
                      const SizedBox(height: 24),
                      Text(
                        startupFailed ? '启动失败' : 'SSRVPN',
                        style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.w800,
                          color: startupFailed
                              ? AppTheme.error
                              : AppTheme.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        startupFailed
                            ? (requiresSecretRecovery
                                ? '本机密钥无法解密，请按下方步骤保留旧密文并恢复启动。'
                                : '初始化服务失败，请稍后查看诊断日志。')
                            : '正在加载必要组件...',
                        style: const TextStyle(
                          fontSize: 14,
                          color: AppTheme.textSecondary,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      if (!startupFailed) ...[
                        const SizedBox(height: 18),
                        SizedBox(
                          width: 260,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(999),
                            child: LinearProgressIndicator(
                              value: startupProgress,
                              minHeight: 6,
                              backgroundColor:
                                  AppTheme.primary.withValues(alpha: 32 / 255),
                              color: AppTheme.primary,
                            ),
                          ),
                        ),
                      ],
                      if (failures.isNotEmpty) ...[
                        const SizedBox(height: 18),
                        _StartupProblemPanel(failures: failures),
                      ],
                      if (secretRecoveryError case final error?) ...[
                        const SizedBox(height: 12),
                        Text(
                          error,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: AppTheme.error,
                            fontSize: 12,
                          ),
                        ),
                      ],
                      if (startupFailed && secretRecoveryPath != null) ...[
                        const SizedBox(height: 16),
                        Builder(
                          builder: (buttonContext) => FilledButton(
                            key: const Key('windows-secret-recovery-button'),
                            onPressed: secretRecoveryInProgress
                                ? null
                                : () => onSecretRecovery(
                                      buttonContext,
                                      secretRecoveryPath,
                                    ),
                            child: Text(
                              secretRecoveryInProgress ? '正在恢复…' : '保留旧密文并重建密钥',
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    ),
  );
}

Widget buildWindowsApiSecretRecoveryDialog(BuildContext context) {
  return AlertDialog(
    scrollable: true,
    title: const Text('保留旧密文并重建密钥？'),
    content: const Text(
      'SSRVPN 会把无法解密的 DPAPI 文件原子隔离，然后生成新的本机通信密钥。'
      '旧密文会原样保留，订阅和普通设置不会删除。',
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(false),
        child: const Text('取消'),
      ),
      FilledButton(
        key: const Key('confirm-windows-secret-recovery'),
        onPressed: () => Navigator.of(context).pop(true),
        child: const Text('确认重建'),
      ),
    ],
  );
}

class _StartupProblemPanel extends StatelessWidget {
  const _StartupProblemPanel({required this.failures});

  final List<StartupFailure> failures;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.error.withValues(alpha: 18 / 255),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: AppTheme.error.withValues(alpha: 50 / 255),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '启动过程中发现问题，但应用仍会继续尝试打开。',
            style: TextStyle(
              color: AppTheme.error,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          for (final failure in failures.take(3))
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: SelectableText(
                failure.userSummary,
                maxLines: failure.requiresWindowsSecretRecovery ? null : 2,
                style: const TextStyle(
                  color: AppTheme.textSecondary,
                  fontSize: 12,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

const _startupStepCount = 4;

double? _startupProgress(StartupStatus status) {
  if (status.completed) return 1;
  final finishedSteps = status.stepStates.values
      .where((state) => state == 'ok' || state == 'failed')
      .length;
  if (finishedSteps == 0 && status.currentStep == null) return null;
  final runningStep = status.currentStep == null ? 0 : 0.35;
  return ((finishedSteps + runningStep) / _startupStepCount).clamp(0.08, 0.95);
}
