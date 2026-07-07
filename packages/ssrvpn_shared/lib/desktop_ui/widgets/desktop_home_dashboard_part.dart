part of desktop_home_screen;

class _DesktopHomeDashboard extends StatelessWidget {
  final bool isDark;
  final Color textColor;
  final Color subColor;
  final AppSettings settings;
  final Widget nodeList;
  final bool isConnected;
  final bool isConnecting;
  final String? errorMessage;
  final PublicIpInfo? publicIpInfo;
  final bool isRefreshingPublicIp;
  final String? publicIpError;
  final Animation<double> glowAnimation;
  final VoidCallback onToggleConnection;
  final VoidCallback onShowTutorial;
  final VoidCallback onShowForceProxySites;
  final VoidCallback onShowLogs;
  final VoidCallback onRefreshPublicIp;
  final ValueChanged<ProxyMode> onProxyModeChanged;
  final ValueChanged<bool> onEnableTunChanged;

  const _DesktopHomeDashboard({
    required this.isDark,
    required this.textColor,
    required this.subColor,
    required this.settings,
    required this.nodeList,
    required this.isConnected,
    required this.isConnecting,
    required this.errorMessage,
    required this.publicIpInfo,
    required this.isRefreshingPublicIp,
    required this.publicIpError,
    required this.glowAnimation,
    required this.onToggleConnection,
    required this.onShowTutorial,
    required this.onShowForceProxySites,
    required this.onShowLogs,
    required this.onRefreshPublicIp,
    required this.onProxyModeChanged,
    required this.onEnableTunChanged,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 880;
          final padding = wide
              ? const EdgeInsets.fromLTRB(24, 18, 24, 24)
              : EdgeInsets.zero;

          final topBar = _DesktopHomeTopBar(
            isDark: isDark,
            textColor: textColor,
            isConnected: isConnected,
            onShowTutorial: onShowTutorial,
          );
          final statusPanel = _DesktopHomeStatusPanel(
            isDark: isDark,
            textColor: textColor,
            subColor: subColor,
            settings: settings,
            isConnected: isConnected,
            isConnecting: isConnecting,
            errorMessage: errorMessage,
            publicIpInfo: publicIpInfo,
            isRefreshingPublicIp: isRefreshingPublicIp,
            publicIpError: publicIpError,
            denseLayout: !wide || constraints.maxHeight < 640,
            glowAnimation: glowAnimation,
            onToggleConnection: onToggleConnection,
            onShowForceProxySites: onShowForceProxySites,
            onShowLogs: onShowLogs,
            onRefreshPublicIp: onRefreshPublicIp,
            onProxyModeChanged: onProxyModeChanged,
            onEnableTunChanged: onEnableTunChanged,
          );

          if (!wide) {
            return Column(
              children: [
                topBar,
                statusPanel,
                Expanded(child: nodeList),
              ],
            );
          }

          return Padding(
            padding: padding,
            child: Column(
              children: [
                topBar,
                const SizedBox(height: 10),
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(
                        width: 420,
                        child: SingleChildScrollView(
                          physics: const BouncingScrollPhysics(),
                          child: statusPanel,
                        ),
                      ),
                      const SizedBox(width: 18),
                      Expanded(
                        child: LiquidGlassContainer(
                          blur: 30,
                          opacity: isDark ? 0.045 : 0.5,
                          borderRadius: const BorderRadius.all(
                            Radius.circular(26),
                          ),
                          padding: EdgeInsets.zero,
                          borderOpacity: isDark ? 0.16 : 0.72,
                          child: nodeList,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _DesktopHomeTopBar extends StatelessWidget {
  final bool isDark;
  final Color textColor;
  final bool isConnected;
  final VoidCallback onShowTutorial;

  const _DesktopHomeTopBar({
    required this.isDark,
    required this.textColor,
    required this.isConnected,
    required this.onShowTutorial,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 430;
        return Padding(
          padding: EdgeInsets.fromLTRB(
            compact ? 20 : 28,
            14,
            compact ? 20 : 28,
            6,
          ),
          child: Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [AppTheme.primary, AppTheme.accentColor],
                  ),
                  borderRadius: BorderRadius.circular(8),
                  boxShadow: [
                    BoxShadow(
                      color: AppTheme.primary.withValues(alpha: 40 / 255),
                      blurRadius: 12,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: const Icon(
                  Icons.shield_rounded,
                  color: Colors.white,
                  size: 18,
                ),
              ),
              const SizedBox(width: 10),
              Text(
                'SSRVPN',
                style: TextStyle(
                  fontSize: compact ? 17 : 19,
                  fontWeight: FontWeight.w800,
                  color: textColor,
                  letterSpacing: 0,
                ),
              ),
              if (!compact) ...[
                const SizedBox(width: 10),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: AppTheme.primary.withValues(alpha: 15 / 255),
                    borderRadius: BorderRadius.circular(5),
                    border: Border.all(
                      color: AppTheme.primary.withValues(alpha: 30 / 255),
                    ),
                  ),
                  child: Text(
                    desktopPlatformLabel,
                    style: const TextStyle(
                      fontSize: 9,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.5,
                      color: AppTheme.primary,
                    ),
                  ),
                ),
              ],
              const Spacer(),
              if (isConnected && !compact)
                Container(
                  margin: const EdgeInsets.only(right: 8),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: AppTheme.success.withValues(alpha: 15 / 255),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: AppTheme.success.withValues(alpha: 30 / 255),
                    ),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.check_circle,
                        size: 13,
                        color: AppTheme.success,
                      ),
                      SizedBox(width: 4),
                      Text(
                        '已连接',
                        style: TextStyle(
                          fontSize: 11,
                          color: AppTheme.success,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              Tooltip(
                message: '使用教程',
                child: GestureDetector(
                  onTap: onShowTutorial,
                  child: Container(
                    padding: EdgeInsets.symmetric(
                      horizontal: compact ? 11 : 14,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [AppTheme.primary, AppTheme.accentColor],
                      ),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.18),
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: AppTheme.primary.withValues(alpha: 0.26),
                          blurRadius: 18,
                          offset: const Offset(0, 8),
                        ),
                      ],
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.menu_book_rounded,
                          size: 15,
                          color: Colors.white,
                        ),
                        if (!compact) ...[
                          const SizedBox(width: 6),
                          const Text(
                            '教程',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w800,
                              color: Colors.white,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _DesktopHomeStatusPanel extends StatelessWidget {
  final bool isDark;
  final Color textColor;
  final Color subColor;
  final AppSettings settings;
  final bool isConnected;
  final bool isConnecting;
  final String? errorMessage;
  final PublicIpInfo? publicIpInfo;
  final bool isRefreshingPublicIp;
  final String? publicIpError;
  final bool denseLayout;
  final Animation<double> glowAnimation;
  final VoidCallback onToggleConnection;
  final VoidCallback onShowForceProxySites;
  final VoidCallback onShowLogs;
  final VoidCallback onRefreshPublicIp;
  final ValueChanged<ProxyMode> onProxyModeChanged;
  final ValueChanged<bool> onEnableTunChanged;

  const _DesktopHomeStatusPanel({
    required this.isDark,
    required this.textColor,
    required this.subColor,
    required this.settings,
    required this.isConnected,
    required this.isConnecting,
    required this.errorMessage,
    required this.publicIpInfo,
    required this.isRefreshingPublicIp,
    required this.publicIpError,
    required this.denseLayout,
    required this.glowAnimation,
    required this.onToggleConnection,
    required this.onShowForceProxySites,
    required this.onShowLogs,
    required this.onRefreshPublicIp,
    required this.onProxyModeChanged,
    required this.onEnableTunChanged,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 430;
        final shortHeight =
            constraints.maxHeight.isFinite && constraints.maxHeight < 380;
        final dense = denseLayout || compact || shortHeight;
        final buttonSize = dense ? 108.0 : 140.0;
        final outerHorizontalPadding = compact ? 16.0 : 28.0;
        final outerVerticalPadding = dense ? 6.0 : 10.0;
        final cardHorizontalPadding = compact ? 18.0 : 24.0;
        final cardVerticalPadding = dense ? 18.0 : 28.0;
        final buttonGap = dense ? 14.0 : 20.0;
        final sectionGap = dense ? 12.0 : 16.0;
        final connectedGap = dense ? 8.0 : 12.0;
        return Padding(
          padding: EdgeInsets.fromLTRB(
            outerHorizontalPadding,
            outerVerticalPadding,
            outerHorizontalPadding,
            outerVerticalPadding,
          ),
          child: AnimatedBuilder(
            animation: glowAnimation,
            builder: (context, child) {
              final glowIntensity = isConnected
                  ? 0.2 + 0.12 * math.sin(glowAnimation.value * 2 * math.pi)
                  : 0.0;
              final glowColor = AppTheme.success.withAlpha(
                (glowIntensity * 255).toInt(),
              );
              return Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: isConnected
                      ? [
                          BoxShadow(
                            color: glowColor,
                            blurRadius: 28,
                            spreadRadius: 2,
                          ),
                        ]
                      : [],
                ),
                child: LiquidGlassContainer(
                  blur: 34,
                  opacity: isDark ? 0.055 : 0.58,
                  borderRadius: const BorderRadius.all(Radius.circular(24)),
                  padding: EdgeInsets.symmetric(
                    vertical: cardVerticalPadding,
                    horizontal: cardHorizontalPadding,
                  ),
                  borderOpacity: isDark ? 0.17 : 0.72,
                  shadowOpacity: isDark ? 0.42 : 0.1,
                  child: Column(
                    children: [
                      Row(
                        children: [
                          ConnectionButton(
                            isConnected: isConnected,
                            isConnecting: isConnecting,
                            onTap: onToggleConnection,
                            size: buttonSize,
                          ),
                          SizedBox(width: buttonGap),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Expanded(
                                      child: AnimatedSwitcher(
                                        duration:
                                            const Duration(milliseconds: 300),
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
                                            color: isConnected
                                                ? AppTheme.success
                                                : textColor,
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.end,
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
                                    ),
                                  ],
                                ),
                                if (errorMessage != null) ...[
                                  const SizedBox(height: 10),
                                  _DesktopConnectionError(
                                    message: errorMessage!,
                                    onShowLogs: onShowLogs,
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ],
                      ),
                      SizedBox(height: sectionGap),
                      if (isConnected) ...[
                        _DesktopPublicIpRow(
                          info: publicIpInfo,
                          isRefreshing: isRefreshingPublicIp,
                          error: publicIpError,
                          subColor: subColor,
                          onRefresh: onRefreshPublicIp,
                        ),
                        SizedBox(height: connectedGap),
                      ],
                      _DesktopConnectionOptions(
                        isDark: isDark,
                        textColor: textColor,
                        subColor: subColor,
                        settings: settings,
                        isConnecting: isConnecting,
                        onProxyModeChanged: onProxyModeChanged,
                        onEnableTunChanged: onEnableTunChanged,
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
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
    return Container(
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
              const Icon(
                Icons.error_outline,
                size: 14,
                color: AppTheme.error,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  message,
                  style: const TextStyle(
                    color: AppTheme.error,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          GestureDetector(
            onTap: onShowLogs,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.bug_report,
                  size: 12,
                  color: AppTheme.warning,
                ),
                const SizedBox(width: 4),
                Text(
                  '查看日志',
                  style: TextStyle(
                    fontSize: 11,
                    color: AppTheme.warning.withValues(alpha: 200 / 255),
                    decoration: TextDecoration.underline,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DesktopConnectionOptions extends StatelessWidget {
  final bool isDark;
  final Color textColor;
  final Color subColor;
  final AppSettings settings;
  final bool isConnecting;
  final ValueChanged<ProxyMode> onProxyModeChanged;
  final ValueChanged<bool> onEnableTunChanged;

  const _DesktopConnectionOptions({
    required this.isDark,
    required this.textColor,
    required this.subColor,
    required this.settings,
    required this.isConnecting,
    required this.onProxyModeChanged,
    required this.onEnableTunChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withValues(alpha: 4 / 255)
            : Colors.black.withValues(alpha: 4 / 255),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isDark ? AppTheme.border : AppTheme.lightBorder,
          width: 0.5,
        ),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final modeControl = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '代理模式',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: textColor,
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: SegmentedButton<ProxyMode>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment<ProxyMode>(
                      value: ProxyMode.rule,
                      icon: Icon(Icons.route_rounded, size: 16),
                      label: Text('规则'),
                    ),
                    ButtonSegment<ProxyMode>(
                      value: ProxyMode.global,
                      icon: Icon(Icons.public_rounded, size: 16),
                      label: Text('全局'),
                    ),
                  ],
                  selected: {settings.proxyMode},
                  onSelectionChanged: isConnecting
                      ? null
                      : (selection) => onProxyModeChanged(selection.first),
                ),
              ),
            ],
          );

          final tunControl = Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '代理方式',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: textColor,
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: SegmentedButton<bool>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment<bool>(
                      value: false,
                      icon: Icon(Icons.language_rounded, size: 16),
                      label: Text('系统代理'),
                    ),
                    ButtonSegment<bool>(
                      value: true,
                      icon: Icon(Icons.wifi_tethering_rounded, size: 16),
                      label: Text('TUN'),
                    ),
                  ],
                  selected: {settings.enableTun},
                  onSelectionChanged: isConnecting
                      ? null
                      : (selection) => onEnableTunChanged(selection.first),
                ),
              ),
            ],
          );

          if (constraints.maxWidth < 300) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [modeControl, const SizedBox(height: 12), tunControl],
            );
          }

          return Row(
            children: [
              Expanded(child: modeControl),
              Container(
                width: 1,
                height: 52,
                margin: const EdgeInsets.symmetric(horizontal: 12),
                color: isDark ? AppTheme.border : AppTheme.lightBorder,
              ),
              Expanded(child: tunControl),
            ],
          );
        },
      ),
    );
  }
}

class _DesktopForceProxyButton extends StatelessWidget {
  final VoidCallback onTap;
  final bool enabled;

  const _DesktopForceProxyButton({required this.onTap, required this.enabled});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Opacity(
      opacity: enabled ? 1 : 0.55,
      child: GestureDetector(
        onTap: enabled ? onTap : null,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 168),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: AppTheme.primary.withValues(alpha: (isDark ? 24 : 16) / 255),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: AppTheme.primary.withValues(
                alpha: (isDark ? 70 : 55) / 255,
              ),
            ),
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.add_link_rounded, size: 16, color: AppTheme.primary),
              SizedBox(width: 6),
              Flexible(
                child: Text(
                  '添加强制代理网站',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.2,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.primary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
