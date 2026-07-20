part of desktop_app;

class _DesktopAppShell extends StatelessWidget {
  const _DesktopAppShell({
    required this.safeMode,
    required this.startupFailureMessages,
    required this.runtimeNotice,
    required this.currentIndex,
    required this.onIndexChanged,
  });

  final bool safeMode;
  final List<String> startupFailureMessages;
  final String? runtimeNotice;
  final int currentIndex;
  final ValueChanged<int> onIndexChanged;

  @override
  Widget build(BuildContext context) {
    final runtimeNoticeSuccessful = isSuccessfulRuntimeNotice(runtimeNotice);
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: DefaultTextStyle.merge(
        style: const TextStyle(decoration: TextDecoration.none),
        child: SsrvpnAppBackdrop(
          child: Column(
            children: [
              if (safeMode)
                const _StartupBanner(
                  icon: Icons.health_and_safety_outlined,
                  color: AppTheme.warning,
                  title: '安全模式已启用',
                  message: '托盘、旧窗口位置和 Mihomo 自动初始化已跳过。',
                ),
              if (startupFailureMessages.isNotEmpty)
                _StartupBanner(
                  icon: Icons.error_outline,
                  color: AppTheme.error,
                  title: '部分启动步骤失败',
                  message: startupFailureMessages.join('\n'),
                ),
              if (runtimeNotice != null)
                _StartupBanner(
                  icon: runtimeNoticeSuccessful
                      ? Icons.check_circle_outline
                      : Icons.error_outline,
                  color: runtimeNoticeSuccessful
                      ? AppTheme.success
                      : AppTheme.error,
                  title: runtimeNoticeSuccessful ? '连接已恢复' : '连接未完成',
                  message: runtimeNotice!,
                ),
              Expanded(child: _PageStack(currentIndex: currentIndex)),
              SsrvpnBottomNavigation(
                currentIndex: currentIndex,
                version: AppConstants.appVersion,
                onTap: onIndexChanged,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PageStack extends StatelessWidget {
  const _PageStack({required this.currentIndex});

  final int currentIndex;

  @override
  Widget build(BuildContext context) {
    return IndexedStack(
      index: currentIndex,
      children: const [
        HomeScreen(),
        SubscriptionScreen(),
      ],
    );
  }
}

class _StartupBanner extends StatelessWidget {
  const _StartupBanner({
    required this.icon,
    required this.color,
    required this.title,
    required this.message,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return SafeArea(
      bottom: false,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(18, 10, 18, 10),
        decoration: BoxDecoration(
          color: color.withValues(alpha: (isDark ? 20 : 14) / 255),
          border: Border(
            bottom: BorderSide(color: color.withValues(alpha: 55 / 255)),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: color, size: 18),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: color,
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    message,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: isDark
                          ? AppTheme.textSecondary
                          : AppTheme.lightTextSecondary,
                      fontSize: 12,
                      height: 1.3,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
