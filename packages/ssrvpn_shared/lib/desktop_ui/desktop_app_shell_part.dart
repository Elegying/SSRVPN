part of desktop_app;

const _shellNavItems = [
  NavItem(
    icon: Icons.home_outlined,
    activeIcon: Icons.home_rounded,
    label: '首页',
  ),
  NavItem(
    icon: Icons.rss_feed_outlined,
    activeIcon: Icons.rss_feed_rounded,
    label: '订阅',
  ),
  NavItem(
    icon: Icons.fact_check_outlined,
    activeIcon: Icons.fact_check_rounded,
    label: '解锁',
  ),
];

class _DesktopAppShell extends StatelessWidget {
  const _DesktopAppShell({
    required this.isDark,
    required this.safeMode,
    required this.startupFailureMessages,
    required this.runtimeNotice,
    required this.currentIndex,
    required this.onIndexChanged,
  });

  final bool isDark;
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
        child: LiquidGlassBackdrop(
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
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    if (constraints.maxWidth >= 900) {
                      return _DesktopShell(
                        isDark: isDark,
                        currentIndex: currentIndex,
                        onIndexChanged: onIndexChanged,
                      );
                    }

                    return _CompactShell(
                      currentIndex: currentIndex,
                      onIndexChanged: onIndexChanged,
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DesktopShell extends StatelessWidget {
  const _DesktopShell({
    required this.isDark,
    required this.currentIndex,
    required this.onIndexChanged,
  });

  final bool isDark;
  final int currentIndex;
  final ValueChanged<int> onIndexChanged;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Row(
          children: [
            _GlassSideRail(
              isDark: isDark,
              currentIndex: currentIndex,
              onIndexChanged: onIndexChanged,
            ),
            const SizedBox(width: 18),
            Expanded(
              child: LiquidGlassContainer(
                blur: 34,
                opacity: isDark ? 0.045 : 0.58,
                borderRadius: const BorderRadius.all(Radius.circular(30)),
                padding: EdgeInsets.zero,
                borderOpacity: isDark ? 0.16 : 0.74,
                shadowOpacity: isDark ? 0.44 : 0.12,
                child: _PageStack(currentIndex: currentIndex),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CompactShell extends StatelessWidget {
  const _CompactShell({
    required this.currentIndex,
    required this.onIndexChanged,
  });

  final int currentIndex;
  final ValueChanged<int> onIndexChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(child: _PageStack(currentIndex: currentIndex)),
        LiquidGlassNavBar(
          currentIndex: currentIndex,
          items: _shellNavItems,
          onTap: onIndexChanged,
        ),
      ],
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
        UnlockTestScreen(),
      ],
    );
  }
}

class _GlassSideRail extends StatelessWidget {
  const _GlassSideRail({
    required this.isDark,
    required this.currentIndex,
    required this.onIndexChanged,
  });

  final bool isDark;
  final int currentIndex;
  final ValueChanged<int> onIndexChanged;

  @override
  Widget build(BuildContext context) {
    final textColor = isDark ? AppTheme.textPrimary : AppTheme.lightTextPrimary;
    final subColor =
        isDark ? AppTheme.textSecondary : AppTheme.lightTextSecondary;

    return LiquidGlassContainer(
      width: 220,
      blur: 38,
      opacity: isDark ? 0.055 : 0.62,
      borderRadius: const BorderRadius.all(Radius.circular(30)),
      padding: const EdgeInsets.all(16),
      borderOpacity: isDark ? 0.18 : 0.74,
      shadowOpacity: isDark ? 0.46 : 0.1,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [AppTheme.primary, AppTheme.accentColor],
                  ),
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: [
                    BoxShadow(
                      color: AppTheme.primary.withValues(alpha: 0.28),
                      blurRadius: 24,
                      offset: const Offset(0, 12),
                    ),
                  ],
                ),
                child: const Icon(
                  Icons.shield_rounded,
                  color: Colors.white,
                  size: 24,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'SSRVPN',
                      style: TextStyle(
                        color: textColor,
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Liquid Glass',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: subColor,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 28),
          for (var index = 0; index < _shellNavItems.length; index++)
            _ShellRailItem(
              item: _shellNavItems[index],
              selected: currentIndex == index,
              onTap: () => onIndexChanged(index),
            ),
          const Spacer(),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: isDark
                  ? Colors.white.withValues(alpha: 0.045)
                  : Colors.white.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: isDark
                    ? Colors.white.withValues(alpha: 0.1)
                    : Colors.white.withValues(alpha: 0.8),
              ),
            ),
            child: Row(
              children: [
                Icon(Icons.memory_rounded, color: subColor, size: 18),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'By—两颗西柚',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: subColor,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0,
                    ),
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

class _ShellRailItem extends StatefulWidget {
  const _ShellRailItem({
    required this.item,
    required this.selected,
    required this.onTap,
  });

  final NavItem item;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_ShellRailItem> createState() => _ShellRailItemState();
}

class _ShellRailItemState extends State<_ShellRailItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final active = widget.selected || _hovered;
    final color = widget.selected
        ? AppTheme.primary
        : isDark
            ? AppTheme.textSecondary
            : AppTheme.lightTextSecondary;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: AnimatedSlide(
            offset: _hovered ? const Offset(0.018, 0) : Offset.zero,
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOutCubic,
              height: 48,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: active
                    ? AppTheme.primary.withValues(
                        alpha: widget.selected
                            ? (isDark ? 0.16 : 0.1)
                            : (isDark ? 0.08 : 0.06),
                      )
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: active
                      ? AppTheme.primary.withValues(
                          alpha: widget.selected ? 0.36 : 0.22,
                        )
                      : Colors.transparent,
                ),
                boxShadow: [
                  if (_hovered)
                    BoxShadow(
                      color: AppTheme.primary.withValues(alpha: 0.18),
                      blurRadius: 18,
                      spreadRadius: -12,
                      offset: const Offset(0, 8),
                    ),
                ],
              ),
              child: Row(
                children: [
                  Icon(
                    widget.selected ? widget.item.activeIcon : widget.item.icon,
                    color:
                        _hovered && !widget.selected ? AppTheme.primary : color,
                    size: 21,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      widget.item.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: _hovered && !widget.selected
                            ? AppTheme.primary
                            : color,
                        fontSize: 14,
                        fontWeight:
                            widget.selected ? FontWeight.w800 : FontWeight.w600,
                        letterSpacing: 0,
                      ),
                    ),
                  ),
                  AnimatedOpacity(
                    opacity: widget.selected ? 1 : (_hovered ? 0.55 : 0),
                    duration: const Duration(milliseconds: 180),
                    child: Container(
                      width: 5,
                      height: 5,
                      decoration: const BoxDecoration(
                        color: AppTheme.primary,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
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
