part of 'app.dart';

@visibleForTesting
Widget buildAndroidInitializationFailureScaffold({
  required String message,
  required bool recoveryRequired,
  required bool recoveryInProgress,
  required VoidCallback onRetry,
  required VoidCallback onRecover,
}) {
  return Scaffold(
    backgroundColor: const Color(0xFF0B0D14),
    body: SafeArea(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final minContentHeight =
              constraints.maxHeight > 64 ? constraints.maxHeight - 64 : 0.0;
          return SingleChildScrollView(
            key: const Key('android-initialization-failure-scroll'),
            padding: const EdgeInsets.all(32),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: minContentHeight),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 64,
                        height: 64,
                        decoration: BoxDecoration(
                          color:
                              AppTheme.errorColor.withValues(alpha: 20 / 255),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.error_outline,
                          size: 32,
                          color: AppTheme.errorColor,
                        ),
                      ),
                      const SizedBox(height: 20),
                      const Text(
                        '初始化失败',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.darkTextPrimary,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        message,
                        style: const TextStyle(
                          fontSize: 13,
                          color: AppTheme.darkTextSecondary,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 24),
                      Wrap(
                        alignment: WrapAlignment.center,
                        spacing: 12,
                        runSpacing: 10,
                        children: [
                          SizedBox(
                            height: 44,
                            child: ElevatedButton(
                              onPressed: recoveryInProgress ? null : onRetry,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: AppTheme.primaryColor,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                              child: const Text(
                                '重试',
                                style: TextStyle(color: Colors.white),
                              ),
                            ),
                          ),
                          if (recoveryRequired)
                            SizedBox(
                              height: 44,
                              child: OutlinedButton(
                                onPressed:
                                    recoveryInProgress ? null : onRecover,
                                child: const Text('重建本机密钥'),
                              ),
                            ),
                        ],
                      ),
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

Widget buildAndroidApiSecretRecoveryDialog(BuildContext context) {
  return AlertDialog(
    scrollable: true,
    title: const Text('重建本机 API 密钥？'),
    content: const Text(
      '这会先断开当前 VPN，停用旧的快速连接快照，并重建仅用于本机核心通信的密钥。'
      '订阅和普通设置会保留；如果无法安全断开，恢复不会继续。',
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(false),
        child: const Text('取消'),
      ),
      FilledButton(
        key: const Key('confirm-api-secret-recovery'),
        onPressed: () => Navigator.of(context).pop(true),
        child: const Text('确认重建'),
      ),
    ],
  );
}
