part of 'home_screen.dart';

class _AndroidHomeDashboard extends StatelessWidget {
  final bool isDark;
  final Color textColor;
  final Color subColor;
  final AppSettings settings;
  final Widget nodeList;
  final bool isConnected;
  final bool isConnecting;
  final String? errorMessage;
  final Animation<double> glowAnimation;
  final VoidCallback onToggleConnection;
  final VoidCallback onShowTutorial;
  final VoidCallback onShowForceProxySites;
  final VoidCallback onShowLogs;
  final ValueChanged<String> onProxyModeChanged;

  const _AndroidHomeDashboard({
    required this.isDark,
    required this.textColor,
    required this.subColor,
    required this.settings,
    required this.nodeList,
    required this.isConnected,
    required this.isConnecting,
    required this.errorMessage,
    required this.glowAnimation,
    required this.onToggleConnection,
    required this.onShowTutorial,
    required this.onShowForceProxySites,
    required this.onShowLogs,
    required this.onProxyModeChanged,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Builder(
        builder: (context) {
          Responsive.init(context);
          final topBar = _AndroidHomeTopBar(
            isDark: isDark,
            textColor: textColor,
            isConnected: isConnected,
            onShowTutorial: onShowTutorial,
          );
          final statusBar = _AndroidHomeStatusBar(
            isDark: isDark,
            textColor: textColor,
            subColor: subColor,
            settings: settings,
            isConnected: isConnected,
            isConnecting: isConnecting,
            errorMessage: errorMessage,
            glowAnimation: glowAnimation,
            onToggleConnection: onToggleConnection,
            onShowForceProxySites: onShowForceProxySites,
            onShowLogs: onShowLogs,
            onProxyModeChanged: onProxyModeChanged,
          );

          if (Responsive.isLandscape) {
            return Row(
              children: [
                Expanded(
                  flex: 5,
                  child: Column(
                    children: [
                      topBar,
                      statusBar,
                      const Expanded(child: SizedBox()),
                    ],
                  ),
                ),
                VerticalDivider(
                  width: 1,
                  color: isDark ? AppTheme.darkBorder : AppTheme.lightBorder,
                ),
                Expanded(flex: 7, child: nodeList),
              ],
            );
          }

          return Column(
            children: [
              topBar,
              statusBar,
              Expanded(child: nodeList),
            ],
          );
        },
      ),
    );
  }
}

class _AndroidHomeTopBar extends StatelessWidget {
  final bool isDark;
  final Color textColor;
  final bool isConnected;
  final VoidCallback onShowTutorial;

  const _AndroidHomeTopBar({
    required this.isDark,
    required this.textColor,
    required this.isConnected,
    required this.onShowTutorial,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        Responsive.gap(16),
        Responsive.gap(8),
        Responsive.gap(16),
        Responsive.gap(4),
      ),
      child: Row(
        children: [
          Container(
            width: Responsive.wp(32),
            height: Responsive.wp(32),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [AppTheme.primaryColor, AppTheme.accentColor],
              ),
              borderRadius: BorderRadius.circular(Responsive.radius(8)),
            ),
            child: Icon(
              Icons.shield_rounded,
              color: Colors.white,
              size: Responsive.icon(18),
            ),
          ),
          SizedBox(width: Responsive.gap(10)),
          Text(
            'SSRVPN',
            style: TextStyle(
              fontSize: Responsive.sp(18),
              fontWeight: FontWeight.w700,
              color: textColor,
              letterSpacing: 0.5,
            ),
          ),
          const Spacer(),
          if (isConnected)
            Container(
              padding: EdgeInsets.symmetric(
                horizontal: Responsive.gap(8),
                vertical: Responsive.gap(4),
              ),
              decoration: BoxDecoration(
                color: AppTheme.successColor.withValues(alpha: 20 / 255),
                borderRadius: BorderRadius.circular(Responsive.radius(8)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.check_circle,
                    size: Responsive.icon(14),
                    color: AppTheme.successColor,
                  ),
                  SizedBox(width: Responsive.gap(4)),
                  Text(
                    '已连接',
                    style: TextStyle(
                      fontSize: Responsive.sp(12),
                      color: AppTheme.successColor,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          SizedBox(width: Responsive.gap(8)),
          GestureDetector(
            onTap: onShowTutorial,
            child: Container(
              padding: EdgeInsets.symmetric(
                horizontal: Responsive.gap(10),
                vertical: Responsive.gap(6),
              ),
              decoration: BoxDecoration(
                color: isDark ? AppTheme.darkCard : AppTheme.lightBg,
                borderRadius: BorderRadius.circular(Responsive.radius(8)),
                border: Border.all(
                  color: isDark ? AppTheme.darkBorder : AppTheme.lightBorder,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.menu_book_rounded,
                    size: Responsive.icon(14),
                    color: isDark
                        ? AppTheme.darkTextSecondary
                        : AppTheme.lightTextSecondary,
                  ),
                  SizedBox(width: Responsive.gap(4)),
                  Text(
                    '使用教程',
                    style: TextStyle(
                      fontSize: Responsive.sp(12),
                      fontWeight: FontWeight.w500,
                      color: isDark
                          ? AppTheme.darkTextSecondary
                          : AppTheme.lightTextSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AndroidHomeStatusBar extends StatelessWidget {
  final bool isDark;
  final Color textColor;
  final Color subColor;
  final AppSettings settings;
  final bool isConnected;
  final bool isConnecting;
  final String? errorMessage;
  final Animation<double> glowAnimation;
  final VoidCallback onToggleConnection;
  final VoidCallback onShowForceProxySites;
  final VoidCallback onShowLogs;
  final ValueChanged<String> onProxyModeChanged;

  const _AndroidHomeStatusBar({
    required this.isDark,
    required this.textColor,
    required this.subColor,
    required this.settings,
    required this.isConnected,
    required this.isConnecting,
    required this.errorMessage,
    required this.glowAnimation,
    required this.onToggleConnection,
    required this.onShowForceProxySites,
    required this.onShowLogs,
    required this.onProxyModeChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        Responsive.gap(16),
        Responsive.gap(8),
        Responsive.gap(16),
        Responsive.gap(8),
      ),
      child: AnimatedBuilder(
        animation: glowAnimation,
        builder: (context, child) {
          final glowIntensity = isConnected
              ? 0.25 + 0.15 * math.sin(glowAnimation.value * 2 * math.pi)
              : 0.0;
          final glowColor =
              AppTheme.successColor.withValues(alpha: glowIntensity);
          return Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(Responsive.radius(16)),
              boxShadow: isConnected
                  ? [
                      BoxShadow(
                        color: glowColor,
                        blurRadius: 24,
                        spreadRadius: -2,
                      ),
                      BoxShadow(
                        color: AppTheme.accentColor.withValues(
                          alpha: glowIntensity * 80 / 255,
                        ),
                        blurRadius: 40,
                        spreadRadius: -8,
                      ),
                    ]
                  : null,
            ),
            child: child,
          );
        },
        child: GlassContainer(
          borderRadius: Responsive.radius(16),
          padding: EdgeInsets.symmetric(
            vertical: Responsive.gap(20),
            horizontal: Responsive.gap(16),
          ),
          child: Column(
            children: [
              Row(
                children: [
                  ConnectionButton(
                    isConnected: isConnected,
                    isConnecting: isConnecting,
                    onTap: onToggleConnection,
                  ),
                  SizedBox(width: Responsive.gap(12)),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _AndroidForceProxyButton(
                          onTap: onShowForceProxySites,
                          enabled: !isConnecting,
                        ),
                        SizedBox(height: Responsive.gap(10)),
                        AnimatedSwitcher(
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
                              fontSize: Responsive.sp(18),
                              fontWeight: FontWeight.w700,
                              color: isConnected
                                  ? AppTheme.successColor
                                  : textColor,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        SizedBox(height: Responsive.gap(4)),
                        if (isConnected)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: AppTheme.successColor.withValues(
                                alpha: 15 / 255,
                              ),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(
                              '${settings.proxyMode.chineseName} · 端口 ${settings.proxyPort}',
                              style: TextStyle(
                                fontSize: Responsive.sp(11),
                                color: subColor,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        if (errorMessage != null) ...[
                          const SizedBox(height: 8),
                          _AndroidConnectionError(
                            message: errorMessage!,
                            onShowLogs: onShowLogs,
                            onRetry: onToggleConnection,
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              ProxyModeSelector(
                isDark: isDark,
                settings: settings,
                enabled: !isConnecting,
                onChanged: onProxyModeChanged,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AndroidConnectionError extends StatelessWidget {
  final String message;
  final VoidCallback onShowLogs;
  final VoidCallback onRetry;

  const _AndroidConnectionError({
    required this.message,
    required this.onShowLogs,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AppTheme.errorColor.withValues(alpha: 15 / 255),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: AppTheme.errorColor.withValues(alpha: 40 / 255),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.error_outline,
                size: 12,
                color: AppTheme.errorColor,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  message,
                  style: TextStyle(
                    color: AppTheme.errorColor,
                    fontSize: Responsive.sp(11),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              GestureDetector(
                onTap: onShowLogs,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.bug_report,
                      size: 12,
                      color: AppTheme.warningColor,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '查看日志',
                      style: TextStyle(
                        fontSize: Responsive.sp(10),
                        color: AppTheme.warningColor.withValues(
                          alpha: 200 / 255,
                        ),
                        decoration: TextDecoration.underline,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              GestureDetector(
                onTap: onRetry,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.refresh, size: 12, color: AppTheme.primaryColor),
                    const SizedBox(width: 4),
                    Text(
                      '重试',
                      style: TextStyle(
                        fontSize: Responsive.sp(10),
                        color: AppTheme.primaryColor.withValues(
                          alpha: 200 / 255,
                        ),
                        decoration: TextDecoration.underline,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _AndroidForceProxyButton extends StatelessWidget {
  final VoidCallback onTap;
  final bool enabled;

  const _AndroidForceProxyButton({
    required this.onTap,
    required this.enabled,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: Responsive.wp(170)),
      child: Opacity(
        opacity: enabled ? 1 : 0.55,
        child: GestureDetector(
          onTap: enabled ? onTap : null,
          child: Container(
            padding: EdgeInsets.symmetric(
              horizontal: Responsive.gap(8),
              vertical: Responsive.gap(6),
            ),
            decoration: BoxDecoration(
              color: AppTheme.primaryColor.withValues(
                alpha: (isDark ? 24 : 16) / 255,
              ),
              borderRadius: BorderRadius.circular(Responsive.radius(10)),
              border: Border.all(
                color: AppTheme.primaryColor.withValues(
                  alpha: (isDark ? 70 : 55) / 255,
                ),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.add_link_rounded,
                  size: Responsive.icon(14),
                  color: AppTheme.primaryColor,
                ),
                SizedBox(width: Responsive.gap(4)),
                Flexible(
                  child: Text(
                    '添加强制代理网站',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: Responsive.sp(10),
                      height: 1.2,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.primaryColor,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
