part of desktop_home_screen;

class _DesktopConnectionSummary extends StatelessWidget {
  final AppSettings settings;
  final bool isConnected;
  final bool isConnecting;
  final Color textColor;
  final Color subColor;
  final VoidCallback onShowForceProxySites;

  const _DesktopConnectionSummary({
    required this.settings,
    required this.isConnected,
    required this.isConnecting,
    required this.textColor,
    required this.subColor,
    required this.onShowForceProxySites,
  });

  @override
  Widget build(BuildContext context) {
    final status = AnimatedSwitcher(
      duration: const Duration(milliseconds: 300),
      child: Text(
        isConnecting
            ? '正在连接...'
            : isConnected
                ? '已连接'
                : '未连接',
        key: ValueKey(
          isConnecting
              ? 'c'
              : isConnected
                  ? 'y'
                  : 'n',
        ),
        style: TextStyle(
          fontSize: 22,
          fontWeight: FontWeight.w700,
          color: isConnected ? AppTheme.success : textColor,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        softWrap: false,
      ),
    );

    final actions = Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        _DesktopForceProxyButton(
          onTap: onShowForceProxySites,
          enabled: !isConnecting,
        ),
        if (isConnected) ...[
          const SizedBox(height: 8),
          _DesktopModeBadge(
            text:
                '${settings.proxyMode.chineseName} · 端口 ${settings.proxyPort}${settings.enableTun ? " · TUN" : " · 代理"}',
            subColor: subColor,
          ),
        ],
      ],
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 320) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(width: double.infinity, child: status),
              const SizedBox(height: 8),
              Align(alignment: Alignment.centerLeft, child: actions),
            ],
          );
        }

        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: status),
            const SizedBox(width: 10),
            actions,
          ],
        );
      },
    );
  }
}

class _DesktopModeBadge extends StatelessWidget {
  final String text;
  final Color subColor;

  const _DesktopModeBadge({required this.text, required this.subColor});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: AppTheme.success.withValues(alpha: 15 / 255),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          color: subColor,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}

class _DesktopPublicIpRow extends StatelessWidget {
  final PublicIpInfo? info;
  final bool isRefreshing;
  final String? error;
  final Color subColor;
  final VoidCallback onRefresh;

  const _DesktopPublicIpRow({
    required this.info,
    required this.isRefreshing,
    required this.error,
    required this.subColor,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    final display = info?.displayText ??
        (isRefreshing
            ? '正在获取出口 IP...'
            : error != null
                ? '出口 IP $error'
                : '出口 IP 待获取');
    final color = error != null && info == null ? AppTheme.warning : subColor;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppTheme.primary.withValues(alpha: 10 / 255),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: AppTheme.primary.withValues(alpha: 28 / 255),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.public_rounded,
                size: 16,
                color: AppTheme.primary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'IP地址：',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: subColor,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Tooltip(
                message: '刷新出口 IP',
                child: Semantics(
                  button: true,
                  label: '刷新出口 IP',
                  child: InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: isRefreshing ? null : onRefresh,
                    child: SizedBox(
                      width: 28,
                      height: 28,
                      child: Center(
                        child: isRefreshing
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(
                                Icons.refresh_rounded,
                                size: 17,
                                color: AppTheme.primary,
                              ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 3),
          Text(
            display,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13,
              color: color,
              fontWeight: FontWeight.w700,
              letterSpacing: 0,
            ),
          ),
        ],
      ),
    );
  }
}

class _DesktopConnectionError extends StatelessWidget {
  final String message;
  final VoidCallback onShowLogs;

  const _DesktopConnectionError({
    required this.message,
    required this.onShowLogs,
  });

  @override
  Widget build(BuildContext context) {
    final failure = AppFailure.fromMessage(message);
    return Semantics(
      liveRegion: true,
      label: '${failure.title}，${failure.message}，${failure.recommendedAction}',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: AppTheme.error.withValues(alpha: 15 / 255),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: AppTheme.error.withValues(alpha: 40 / 255),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const ExcludeSemantics(
                  child: Icon(
                    Icons.error_outline,
                    size: 14,
                    color: AppTheme.error,
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    failure.title,
                    style: const TextStyle(
                      color: AppTheme.error,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '${failure.message} ${failure.recommendedAction}',
              style: const TextStyle(
                color: AppTheme.textSecondary,
                fontSize: 11,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              failure.code.wireName,
              style: TextStyle(
                color: AppTheme.error.withValues(alpha: 190 / 255),
                fontSize: 10,
                fontFamily: 'monospace',
              ),
            ),
            const SizedBox(height: 4),
            TextButton.icon(
              onPressed: onShowLogs,
              icon: const Icon(Icons.bug_report, size: 13),
              label: const Text('运行诊断'),
              style: TextButton.styleFrom(
                foregroundColor: AppTheme.warning,
                minimumSize: const Size(44, 36),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                textStyle: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
